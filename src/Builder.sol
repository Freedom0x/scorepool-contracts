// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/utils/CurrencySettler.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

interface IBuilderPool {
    function score() external view returns (address);
    function hook() external view returns (address);
    function addProtocolLiquidity(uint256 scoreIn)
        external
        payable
        returns (uint128 liquidity, uint256 ethBack, uint256 scoreBack);
    function migrationOpen() external view returns (bool);
    function owner() external view returns (address);
}

interface IBuilderRef {
    function blockOpenSqrtPrice(PoolId id) external view returns (uint160 open);
}

/// @title Builder
/// @notice Turns its part of the POOL tax (ETH; POOL is the protocol token) into protocol-owned SCORE/ETH liquidity.
/// `build` (anyone, at most once per block) buys SCORE from the pool with the part of the ETH held that leaves the rest
/// pairing with all the SCORE held at the pool's ratio (a zap), then adds the pair through
/// ScoreLiquidity.addProtocolLiquidity; what does not fit waits for the next build.
/// @dev The SCORE buy is exact-input with a price limit at the edge of a band of `BAND_SQRT_BPS` of sqrtPrice (about
/// 1% in price) around the pool hook's reference price (the block's opening price, recorded before the block's first
/// swap moves it): a partial fill is accepted, and nothing trades or is added while the price is outside the band.
/// The band is narrower than the round trip a sandwich pays (the 1% LP fee each way, of which a dominant LP gets
/// about half back), and the block's own trades cannot move its reference.
///
/// The caller of `build` is paid a tip of `tipBps` of the ETH swapped and added: 0 to start (the protocol runs its own
/// keeper), and the guardian can set it up to `MAX_TIP_BPS`. To cover it, a build keeps back `tipBps` of the ETH
/// held. A build uses up its block only if it moved at least `MIN_SPEND` of ETH, or a tenth
/// of what it had, so a dust fill at the band's edge does not block a real build later in the block. The guardian can
/// pause.
///
/// Once the migration opens, the SCORE/ETH pool is being wound down, so nothing more is built there: `build` reverts,
/// and `forward` (anyone) sends the ETH, and any SCORE, held to the protocol-owned-liquidity vault on the real token's
/// pool, which the pool's owner sets once (`setPolVault`). The POOL tax keeps arriving and goes on there.
contract Builder is IUnlockCallback, ReentrancyGuard {
    using CurrencySettler for Currency;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;

    uint256 private constant BPS = 10_000;
    int24 private constant TICK_SPACING = 200;
    uint256 private constant Q96 = 1 << 96;
    uint256 private constant PPM = 1e6;
    uint256 private constant DUST = 1e9;
    /// The LP fee the protocol's swaps pay in the SCORE/ETH pool (ScoreHook.BASE_FEE).
    uint256 private constant SWAP_FEE = 10_000;
    /// @notice Band around each reference price, in bps of sqrtPrice either way.
    uint256 public constant BAND_SQRT_BPS = 50;
    /// @notice The most the tip can be set to, in bps of the ETH swapped and added.
    uint256 public constant MAX_TIP_BPS = 200;
    /// @notice The caller's tip, in bps of the ETH swapped and added. Starts at 0; the guardian can set it up to
    /// `MAX_TIP_BPS`.
    uint256 public tipBps;
    /// @notice ETH a build must move to use up its block (or a tenth of the ETH it had).
    uint256 public constant MIN_SPEND = 0.001 ether;

    IPoolManager public immutable manager;
    address public immutable guardian;
    /// @notice ScoreLiquidity.
    IBuilderPool public immutable pool;
    IERC20 public immutable score;
    address private immutable scoreHook;

    bool public paused;
    uint256 public lastBuildBlock;
    /// @notice Where the ETH and SCORE held go once the migration opens (`forward`): the protocol-owned-liquidity
    /// vault on the real token's pool. Set once by the pool's owner.
    address public polVault;

    // running totals
    uint256 public totalEthSwapped;
    uint256 public totalLiquidityEth;
    uint256 public totalLiquidityScore;
    uint256 public totalTips;

    event PauseSet(bool paused);
    event TipSet(uint256 bps);
    event Built(uint256 ethSwapped, uint256 scoreBought, uint256 ethAdded, uint256 scoreAdded, uint128 liquidity);
    event TipPaid(address indexed to, uint256 eth);
    event TipSkipped(address indexed to, uint256 eth);
    event PolVaultSet(address indexed vault);
    event Forwarded(address indexed vault, uint256 eth, uint256 score);

    error NotGuardian();
    error Paused();
    error OncePerBlock();
    error NothingToBuild();
    error OnlyManager();
    error BadConfig();
    error Migrating();
    error NotOwner();
    error NotReady();
    error TransferFailed();

    constructor(IPoolManager manager_, address guardian_, IBuilderPool pool_) {
        if (guardian_ == address(0) || address(pool_) == address(0)) revert BadConfig();
        manager = manager_;
        guardian = guardian_;
        pool = pool_;
        score = IERC20(pool_.score());
        scoreHook = pool_.hook();
    }

    /// @dev The SCORE/ETH pool key, rebuilt from the pool's immutables; the SCORE pool uses a dynamic fee.
    function _scoreKey() private view returns (PoolKey memory) {
        return PoolKey(
            Currency.wrap(address(0)), Currency.wrap(address(score)), LPFeeLibrary.DYNAMIC_FEE_FLAG, TICK_SPACING, IHooks(scoreHook)
        );
    }

    /// @notice Accepts ETH: tax from PoolTaxHook and what the pool sends back.
    receive() external payable {}

    /// @notice Guardian only. While paused, `build` reverts; ETH keeps arriving.
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

    /// @notice ETH kept back from a build so the tip can be paid, in bps of the ETH held: the tip itself.
    function reserveBps() public view returns (uint256) {
        return tipBps;
    }

    /// @notice Buys SCORE with the part of the ETH held (less the tip reserve) that leaves the rest pairing with all
    /// the SCORE held, within the band, and adds the pair as protocol-owned liquidity. Callable by anyone, at most once
    /// per block (see `MIN_SPEND`); reverts if nothing can be swapped or added.
    /// @return liquidity Liquidity added.
    function build() external nonReentrant returns (uint128 liquidity) {
        if (paused) revert Paused();
        if (pool.migrationOpen()) revert Migrating(); // the pool is being wound down: `forward` instead
        if (lastBuildBlock == block.number) revert OncePerBlock();
        uint256 eth = address(this).balance;
        uint256 avail = eth - eth * reserveBps() / BPS;
        PoolKey memory k = _scoreKey();
        (uint160 sqrtP,,,) = manager.getSlot0(k.toId());
        uint160 open = IBuilderRef(scoreHook).blockOpenSqrtPrice(k.toId());
        uint256 lo = uint256(open) * (BPS - BAND_SQRT_BPS) / BPS;
        uint256 hi = uint256(open) * (BPS + BAND_SQRT_BPS) / BPS;
        // clamp the lower edge to the pool's min before it is used as the swap limit (and the band check below),
        // mirroring the Burner's upper clamp so an extreme reference cannot truncate into an invalid limit; the
        // open == 0 guard still rejects an uninitialised reference.
        if (lo <= TickMath.MIN_SQRT_PRICE) lo = uint256(TickMath.MIN_SQRT_PRICE) + 1;
        if (open == 0 || sqrtP <= lo || sqrtP >= hi) revert NothingToBuild();
        uint256 swapIn = _zapIn(k, sqrtP, avail, score.balanceOf(address(this)));
        uint256 paid;
        uint256 bought;
        if (swapIn >= DUST) {
            (paid, bought) = abi.decode(manager.unlock(abi.encode(k, swapIn, lo)), (uint256, uint256));
            totalEthSwapped += paid;
        }
        (uint128 liq, uint256 ethAdded, uint256 scoreAdded) = _pairAndAdd(avail - paid);
        if (paid == 0 && liq == 0) revert NothingToBuild();
        uint256 moved = paid + ethAdded;
        if (moved >= MIN_SPEND || (moved != 0 && moved * 10 >= avail)) lastBuildBlock = block.number;
        liquidity = liq;
        emit Built(paid, bought, ethAdded, scoreAdded, liq);
        _tip(moved);
    }

    /// @notice The pool's owner only, once: sets the protocol-owned-liquidity vault (a contract) that receives what
    /// the Builder holds once the migration opens.
    function setPolVault(address vault) external {
        if (msg.sender != pool.owner()) revert NotOwner();
        if (polVault != address(0) || vault.code.length == 0) revert BadConfig();
        polVault = vault;
        emit PolVaultSet(vault);
    }

    /// @notice Callable by anyone once the migration is open and the vault is set: sends all the ETH held to the
    /// protocol-owned-liquidity vault, and the SCORE held if the vault can take it (best effort: SCORE that cannot move
    /// stays here and is retried by the next call).
    function forward() external nonReentrant returns (uint256 eth, uint256 scoreSent) {
        if (paused) revert Paused();
        address v = polVault;
        if (v == address(0) || !pool.migrationOpen()) revert NotReady();
        scoreSent = score.balanceOf(address(this));
        if (scoreSent != 0) {
            (bool sOk, bytes memory ret) = address(score).call(abi.encodeCall(IERC20.transfer, (v, scoreSent)));
            if (!(sOk && (ret.length == 0 || abi.decode(ret, (bool))))) scoreSent = 0;
        }
        eth = address(this).balance;
        if (eth != 0) {
            (bool ok,) = v.call{value: eth}("");
            if (!ok) revert TransferFailed();
        }
        emit Forwarded(v, eth, scoreSent);
    }

    /// @dev Pool manager callback for the SCORE buy in `build`.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert OnlyManager();
        (PoolKey memory k, uint256 amountIn, uint256 limit) = abi.decode(data, (PoolKey, uint256, uint256));
        // buying SCORE (currency0 in) lowers sqrtPrice
        BalanceDelta d = manager.swap(
            k, SwapParams({zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: uint160(limit)}), ""
        );
        uint256 paid = d.amount0() < 0 ? uint256(int256(-d.amount0())) : 0;
        uint256 got = d.amount1() > 0 ? uint256(int256(d.amount1())) : 0;
        if (paid != 0) k.currency0.settle(manager, address(this), paid, false);
        if (got != 0) k.currency1.take(manager, address(this), got, false);
        return abi.encode(paid, got);
    }

    /// @dev ETH to swap for SCORE so that what is left of `eth` pairs with `held` SCORE plus the SCORE bought, at the
    /// pool's ratio: the single-sided zap s = (sqrt(r^2 (2 - f)^2 + 4 (1 - f) r a) - r (2 - f)) / (2 (1 - f)) for the
    /// excess `a` of ETH over the held SCORE's value, where `r` is the pool's ETH reserve and `f` the swap fee.
    function _zapIn(PoolKey memory k, uint160 sqrtP, uint256 eth, uint256 held) private view returns (uint256) {
        uint256 heldAsEth = FullMath.mulDiv(FullMath.mulDiv(held, Q96, sqrtP), Q96, sqrtP);
        if (eth <= heldAsEth) return 0;
        uint256 a = eth - heldAsEth;
        uint256 r = FullMath.mulDiv(manager.getLiquidity(k.toId()), Q96, sqrtP);
        uint256 twoMinusF = 2 * PPM - SWAP_FEE;
        uint256 oneMinusF = PPM - SWAP_FEE;
        uint256 root = Math.sqrt(r * r * twoMinusF * twoMinusF + 4 * PPM * oneMinusF * r * a);
        return (root - r * twoMinusF) / (2 * oneMinusF);
    }

    /// @dev Adds up to `eth` ETH with all the SCORE held as protocol-owned liquidity; the pool returns what does not
    /// fit. Returns the liquidity and the amounts added.
    function _pairAndAdd(uint256 eth) private returns (uint128 liq, uint256 ethAdded, uint256 scoreAdded) {
        uint256 s = score.balanceOf(address(this));
        if (s < DUST || eth < DUST) return (0, 0, 0);
        score.forceApprove(address(pool), s);
        (uint128 l, uint256 ethBack, uint256 scoreBack) = pool.addProtocolLiquidity{value: eth}(s);
        liq = l;
        ethAdded = eth - ethBack;
        scoreAdded = s - scoreBack;
        totalLiquidityEth += ethAdded;
        totalLiquidityScore += scoreAdded;
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
