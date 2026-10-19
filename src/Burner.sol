// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/utils/CurrencySettler.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IBurnerRef {
    function blockOpenSqrtPrice(PoolId id) external view returns (uint160 open);
}

interface IBurnablePoolToken {
    function burn(uint256 amount) external;
}

/// @title Burner
/// @notice Turns its part of the SCORE/ETH pool's fees (ETH and SCORE) and its half of the CreditRouter's routed fee
/// (ETH) into burned POOL (POOL is the protocol token). `burn` (anyone, at most once per block) sells all the SCORE held for ETH in the SCORE/ETH pool,
/// then buys POOL with the ETH held in the POOL/ETH pool and burns it.
/// @dev Both swaps are exact-input with a price limit at the edge of a band around the pool hook's reference price
/// (the block's opening price, recorded before the block's first swap moves it), so a partial fill is accepted and
/// a pool already outside its band is not traded: SCORE/ETH within `SCORE_BAND_SQRT_BPS` of sqrtPrice (about 1% in
/// price), POOL/ETH within a factor of 1.04 in price (`SQRT_1_04_Q96`). Each band is narrower than the round trip
/// a sandwich pays in that pool (the LP fee each way, of which a dominant LP gets about half back; the POOL tax
/// each way), and the block's own trades cannot move its reference, so moving the price against a burn costs more
/// than it can take from it.
///
/// A burn uses up its block only if it spent at least `MIN_SPEND`, or a tenth of the ETH it offered, so a dust fill
/// at a band's edge does not block a real burn later in the block.
///
/// The caller is paid a tip of `tipBps` of the ETH spent on POOL: 0 to start (the protocol runs its own keeper), and
/// the guardian can set it up to `MAX_TIP_BPS`. To cover it, a burn keeps back `tipBps` of the ETH held, which waits
/// for the next burn. The guardian can pause.
contract Burner is IUnlockCallback, ReentrancyGuard {
    using CurrencySettler for Currency;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint256 private constant BPS = 10_000;
    uint256 private constant Q96 = 1 << 96;
    uint256 private constant DUST = 1e9;
    int24 private constant TICK_SPACING = 200;
    /// @notice SCORE/ETH band, in bps of sqrtPrice either way.
    uint256 public constant SCORE_BAND_SQRT_BPS = 50;
    /// @notice sqrt(1.04) * 2^96, rounded down: the POOL/ETH band is a factor of 1.04 in price either way (about
    /// 1.98% above and 1.94% below in sqrtPrice).
    uint256 public constant SQRT_1_04_Q96 = 80_797_189_337_266_850_215_793_353_563;
    /// @notice The most the tip can be set to, in bps of the ETH spent.
    uint256 public constant MAX_TIP_BPS = 200;
    /// @notice The caller's tip, in bps of the ETH spent. Starts at 0; the guardian can set it up to `MAX_TIP_BPS`.
    uint256 public tipBps;
    /// @notice ETH a burn must spend to use up its block (or a tenth of the ETH it offered).
    uint256 public constant MIN_SPEND = 0.001 ether;

    IPoolManager public immutable manager;
    address public immutable guardian;
    IERC20 public immutable score;
    IERC20 public immutable poolToken;
    IHooks public immutable scoreHook;
    IHooks public immutable poolTaxHook;
    /// @notice The POOL/ETH pool's LP fee (part of its key, as PoolLaunch sets it).
    uint24 public immutable poolLpFee;

    bool public paused;
    uint256 public lastBurnBlock;

    // running totals
    uint256 public totalScoreSold;
    uint256 public totalEthBurned;
    uint256 public totalPoolBurned;
    uint256 public totalTips;

    event PauseSet(bool paused);
    event TipSet(uint256 bps);
    event Burned(uint256 scoreSold, uint256 ethFromScore, uint256 ethSpent, uint256 poolBurned);
    event TipPaid(address indexed to, uint256 eth);
    event TipSkipped(address indexed to, uint256 eth);

    error NotGuardian();
    error Paused();
    error OncePerBlock();
    error NothingToBurn();
    error OnlyManager();
    error BadConfig();

    constructor(
        IPoolManager manager_,
        address guardian_,
        IERC20 score_,
        IERC20 poolToken_,
        IHooks scoreHook_,
        IHooks poolTaxHook_,
        uint24 poolLpFee_
    ) {
        if (guardian_ == address(0) || address(score_) == address(0) || address(poolToken_) == address(0)) revert BadConfig();
        manager = manager_;
        guardian = guardian_;
        score = score_;
        poolToken = poolToken_;
        scoreHook = scoreHook_;
        poolTaxHook = poolTaxHook_;
        poolLpFee = poolLpFee_;
    }

    /// @notice Accepts ETH: fees from the SCORE/ETH pool, tax from PoolTaxHook, and swap output.
    receive() external payable {}

    /// @notice Guardian only. While paused, `burn` reverts; ETH and SCORE keep arriving.
    function setPaused(bool paused_) external {
        if (msg.sender != guardian) revert NotGuardian();
        paused = paused_;
        emit PauseSet(paused_);
    }

    /// @notice Guardian only: sets the caller's tip, up to `MAX_TIP_BPS`.
    function setTipBps(uint256 bps) external {
        if (msg.sender != guardian) revert NotGuardian();
        if (bps > MAX_TIP_BPS) revert BadConfig();
        tipBps = bps;
        emit TipSet(bps);
    }

    /// @notice ETH kept back from the POOL buy so the tip can be paid, in bps of the ETH held: the tip itself.
    function reserveBps() public view returns (uint256) {
        return tipBps;
    }

    /// @notice The SCORE/ETH pool (ScoreLiquidity's key).
    function scoreKey() public view returns (PoolKey memory) {
        return PoolKey(Currency.wrap(address(0)), Currency.wrap(address(score)), LPFeeLibrary.DYNAMIC_FEE_FLAG, TICK_SPACING, scoreHook);
    }

    /// @notice The POOL/ETH pool (PoolLaunch's key).
    function poolTokenKey() public view returns (PoolKey memory) {
        return PoolKey(Currency.wrap(address(0)), Currency.wrap(address(poolToken)), poolLpFee, TICK_SPACING, poolTaxHook);
    }

    /// @notice Sells the SCORE held for ETH, buys POOL with the ETH held (less the tip reserve) and burns it, each
    /// within its band. Callable by anyone, at most once per block (see `MIN_SPEND`); reverts if neither swap can
    /// trade.
    /// @return burned POOL burned.
    function burn() external nonReentrant returns (uint256 burned) {
        if (paused) revert Paused();
        if (lastBurnBlock == block.number) revert OncePerBlock();
        (uint256 sold, uint256 ethFromScore, uint256 spent, uint256 got, uint256 offered) =
            abi.decode(manager.unlock(""), (uint256, uint256, uint256, uint256, uint256));
        if (sold == 0 && spent == 0) revert NothingToBurn();
        if (spent >= MIN_SPEND || (spent != 0 && spent * 10 >= offered)) lastBurnBlock = block.number;
        burned = got;
        if (got != 0) IBurnablePoolToken(address(poolToken)).burn(got);
        totalScoreSold += sold;
        totalEthBurned += spent;
        totalPoolBurned += got;
        emit Burned(sold, ethFromScore, spent, got);
        _tip(spent);
    }

    /// @dev Pool manager callback for `burn`: the SCORE sale, then the POOL buy.
    function unlockCallback(bytes calldata) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert OnlyManager();
        uint256 sold;
        uint256 ethFromScore;
        uint256 scoreIn = score.balanceOf(address(this));
        if (scoreIn >= DUST) {
            PoolKey memory k = scoreKey();
            uint160 open = IBurnerRef(address(scoreHook)).blockOpenSqrtPrice(k.toId());
            uint256 lo = uint256(open) * (BPS - SCORE_BAND_SQRT_BPS) / BPS;
            uint256 hi = uint256(open) * (BPS + SCORE_BAND_SQRT_BPS) / BPS;
            // the band's upper edge can exceed the pool's max near MAX_SQRT_PRICE; clamp before the uint160 cast so it
            // does not truncate into a tiny (invalid) limit and revert the burn. MAX_SQRT_PRICE - 1 is the highest
            // valid limit for a price-raising swap, so a partial fill still goes through.
            if (hi >= TickMath.MAX_SQRT_PRICE) hi = uint256(TickMath.MAX_SQRT_PRICE) - 1;
            // selling SCORE (currency1 in) raises sqrtPrice
            if (_inBand(k, lo, hi)) (sold, ethFromScore) = _swap(k, false, scoreIn, uint160(hi));
        }
        uint256 spent;
        uint256 got;
        uint256 eth = address(this).balance;
        uint256 ethIn = eth - eth * reserveBps() / BPS;
        if (ethIn >= DUST) {
            PoolKey memory k = poolTokenKey();
            uint160 open = IBurnerRef(address(poolTaxHook)).blockOpenSqrtPrice(k.toId());
            uint256 lo = FullMath.mulDivRoundingUp(open, Q96, SQRT_1_04_Q96);
            uint256 hi = FullMath.mulDiv(open, SQRT_1_04_Q96, Q96);
            // the band's lower edge can fall below the pool's min for an extreme reference; clamp before the uint160
            // cast so it does not truncate into an invalid limit and revert the buy, mirroring the SCORE sale's upper
            // clamp. MIN_SQRT_PRICE + 1 is the lowest valid limit for a price-lowering swap, so a partial fill still
            // goes through.
            if (lo <= TickMath.MIN_SQRT_PRICE) lo = uint256(TickMath.MIN_SQRT_PRICE) + 1;
            // buying POOL (currency0 in) lowers sqrtPrice
            if (_inBand(k, lo, hi)) (spent, got) = _swap(k, true, ethIn, uint160(lo));
        }
        return abi.encode(sold, ethFromScore, spent, got, ethIn);
    }

    /// @dev Whether the pool's price is strictly between `lo` and `hi` (at an edge there is no room to swap; an
    /// uninitialized reference gives lo == 0 and nothing is in band).
    function _inBand(PoolKey memory k, uint256 lo, uint256 hi) private view returns (bool) {
        (uint160 sqrtP,,,) = manager.getSlot0(k.toId());
        return lo != 0 && sqrtP > lo && sqrtP < hi;
    }

    /// @dev Exact-input swap of up to `amountIn` with price limit `limit`; returns what was paid and received.
    function _swap(PoolKey memory k, bool zeroForOne, uint256 amountIn, uint160 limit)
        private
        returns (uint256 paid, uint256 got)
    {
        BalanceDelta d = manager.swap(
            k, SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: limit}), ""
        );
        (int128 a0, int128 a1) = (d.amount0(), d.amount1());
        (Currency payC, int128 p, Currency getC, int128 g) =
            zeroForOne ? (k.currency0, a0, k.currency1, a1) : (k.currency1, a1, k.currency0, a0);
        paid = p < 0 ? uint256(int256(-p)) : 0;
        got = g > 0 ? uint256(int256(g)) : 0;
        if (paid != 0) payC.settle(manager, address(this), paid, false);
        if (got != 0) getC.take(manager, address(this), got, false);
    }

    /// @dev Pays msg.sender `tipBps` of `spent`. A failed transfer is skipped and the ETH stays.
    function _tip(uint256 spent) private {
        uint256 tip = spent * tipBps / BPS;
        if (tip > address(this).balance) tip = address(this).balance;
        if (tip == 0) return;
        (bool ok,) = msg.sender.call{value: tip}("");
        if (!ok) {
            emit TipSkipped(msg.sender, tip);
            return;
        }
        totalTips += tip;
        emit TipPaid(msg.sender, tip);
    }
}
