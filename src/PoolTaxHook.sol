// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/utils/CurrencySettler.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {PoolHookBase} from "./HookBase.sol";
import {IVenueToken} from "./VenueGate.sol";

/// The POOL token's burn (ERC20Burnable).
interface IPoolTokenBurn {
    function burn(uint256 amount) external;
}

/// @title PoolTaxHook
/// @notice Hook for the POOL/ETH pool (POOL is the protocol token). Every trade pays a tax at the same rate `f` on
/// buys and sells, in three parts: `devShareBps` for the dev wallet, and the rest in equal halves for the Builder
/// (protocol-owned SCORE/ETH liquidity) and for a burn. The dev wallet and Builder parts are taken in ETH; the burn
/// part is taken in POOL and burned in the same transaction:
///  - a buy pays the ETH parts off its ETH input before the swap, swaps the rest, and has the burn part's value, at
///    the swap's own price, burned out of the POOL it bought;
///  - a sell has the burn part burned off its POOL input before the swap, and pays the ETH parts out of the ETH
///    the swap pays out, at `f (1 - b) / (1 - b f)` of it (b the burn part), so it keeps `1 - f` of the whole, as a
///    buy does, at any rate.
/// Only exact-input swaps are accepted, in both directions (an exact-output one reverts), so the POOL side a burn is
/// taken from is always the side the hook can take from.
///
/// The rate is `LAUNCH_BLOCK_FEE` in the block in which the pool's liquidity is added, then falls linearly by the
/// second from `startFee` to `endFee` over `decay` seconds from that block's timestamp, and stays at `endFee`.
///
/// The pool also has a static LP fee (in its key), paid to its liquidity on every swap, the protocol's included.
/// PoolLaunch adds the seed; anyone may add full-range liquidity once the decay is over, and remove it (or collect
/// its fees) from the block after the position's latest add.
///
/// The ETH parts are held as ETH claims in the pool manager until collected. `collectTax` (anyone) keeps the
/// dev wallet's part, which anyone can pay out, and sends the Builder its part. The protocol's own contracts
/// (the Burner's POOL buys) are not taxed.
contract PoolTaxHook is PoolHookBase, IUnlockCallback, Ownable2Step {
    using CurrencySettler for Currency;

    uint256 private constant FEE_DENOM = 1e6; // hundredths of a bip
    uint256 private constant BPS = 10_000;
    Currency private constant ETH = Currency.wrap(address(0));
    /// @notice Tax in the launch block, in hundredths of a bip (99.9%); also the cap on `startFee`.
    uint24 public constant LAUNCH_BLOCK_FEE = 999_000;

    uint24 public immutable startFee;
    uint24 public immutable endFee;
    uint32 public immutable decay;

    /// @notice Dev wallet part of the tax, in bps. Can only be lowered.
    uint16 public devShareBps;
    address public devWallet;
    /// @notice When, and in which block, the launcher added the pool's liquidity.
    uint64 public openedAt;
    uint64 public openedBlock;
    /// @notice ETH claims (ERC-6909, in the pool manager) owed to the dev wallet.
    uint256 public devClaims;
    /// @notice The block of each third-party position's latest add, by its pool manager position key (owner, ticks,
    /// salt; see Position.calculatePositionKey).
    mapping(bytes32 => uint256) public addedInBlock;

    /// @notice The ETH parts of a trade's tax (dev wallet and Builder).
    event Taxed(address indexed sender, uint256 eth);
    /// @notice The burn part of a trade's tax, burned in POOL.
    event TaxBurned(address indexed sender, uint256 poolToken);
    event TaxCollected(uint256 toBuilder, uint256 toDev);
    event DevFeesClaimed(address indexed devWallet, uint256 eth);
    event DevShareLowered(uint16 bps);
    event DevWalletSet(address devWallet);

    error BadConfig();
    error ExactOutputSwap();
    error OnlyPoolManager();
    error OnlyLower();
    error NotWired();
    error NotSelf();
    error LiquidityNotOpen();
    error FullRangeOnly();
    error SameBlockRemove();

    constructor(
        IPoolManager manager_,
        address owner_,
        address devWallet_,
        uint24 startFee_,
        uint24 endFee_,
        uint32 decay_,
        uint16 devShareBps_
    ) PoolHookBase(manager_, owner_) Ownable(owner_) {
        if (startFee_ < endFee_ || startFee_ > LAUNCH_BLOCK_FEE || devShareBps_ > BPS || devWallet_ == address(0)) {
            revert BadConfig();
        }
        devWallet = devWallet_;
        startFee = startFee_;
        endFee = endFee_;
        decay = decay_;
        devShareBps = devShareBps_;
    }

    /// @notice Current tax rate in hundredths of a bip (1e6 = 100%).
    function currentFee() public view returns (uint24) {
        uint256 t0 = openedAt;
        if (t0 == 0 || block.number == openedBlock) return LAUNCH_BLOCK_FEE;
        uint256 dt = block.timestamp - t0;
        if (dt >= decay) return endFee;
        return uint24(startFee - (uint256(startFee - endFee) * dt) / decay);
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.beforeAddLiquidity = true;
        p.afterAddLiquidity = true;
        p.beforeRemoveLiquidity = true;
        p.afterRemoveLiquidity = true;
        p.afterDonate = true;
        p.beforeSwap = true;
        p.afterSwap = true;
        p.beforeSwapReturnDelta = true;
        p.afterSwapReturnDelta = true;
    }

    /// @dev The gate (PoolLaunch) adds the seed, which opens the pool, and adds its compounded fees at any time.
    /// Anyone else may add once the launch tax has decayed (`openedAt + decay`), so nobody provides liquidity to
    /// collect the LP fee on the launch window's trades, and only in full range: a one-sided range would let a POOL
    /// holder sell to the next buyer as liquidity, paying the LP fee instead of the tax. Each third-party add records
    /// its block for the position (`addedInBlock`).
    function _beforeAddLiquidity(address sender, PoolKey calldata key, ModifyLiquidityParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4)
    {
        uint256 t0 = openedAt;
        if (sender == gate && sender != address(0)) {
            if (t0 == 0) {
                openedAt = uint64(block.timestamp);
                openedBlock = uint64(block.number);
            }
        } else {
            if (t0 == 0 || block.timestamp < t0 + decay) revert LiquidityNotOpen();
            if (
                params.tickLower != TickMath.minUsableTick(key.tickSpacing)
                    || params.tickUpper != TickMath.maxUsableTick(key.tickSpacing)
            ) revert FullRangeOnly();
            addedInBlock[Position.calculatePositionKey(sender, params.tickLower, params.tickUpper, params.salt)] =
                block.number;
        }
        return this.beforeAddLiquidity.selector;
    }

    /// @dev A third-party position cannot be reduced, nor its fees collected (a zero change), in the block of its
    /// latest add, so liquidity cannot be put in around a block's trades and taken out with them. The gate's
    /// position is not limited.
    function _beforeRemoveLiquidity(address sender, PoolKey calldata, ModifyLiquidityParams calldata params, bytes calldata)
        internal
        view
        override
        returns (bytes4)
    {
        if (
            sender != gate
                && addedInBlock[Position.calculatePositionKey(sender, params.tickLower, params.tickUpper, params.salt)]
                    == block.number
        ) revert SameBlockRemove();
        return this.beforeRemoveLiquidity.selector;
    }

    /// @notice When anyone may add liquidity (0 before the pool opens): the end of the launch tax's decay.
    function liquidityOpensAt() external view returns (uint256) {
        uint256 t0 = openedAt;
        return t0 == 0 ? 0 : t0 + decay;
    }

    /// @notice The burn part of the tax, in bps of it: half of what the dev wallet does not take.
    function burnShareBps() public view returns (uint256) {
        return (BPS - devShareBps) / 2;
    }

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _recordRef(key);
        // exact input only (a negative amountSpecified), so a burn always comes off a side the hook can take from
        if (params.amountSpecified > 0) revert ExactOutputSwap();
        if (!_isProtocol(sender)) {
            uint256 amountIn = uint256(-params.amountSpecified);
            uint256 f = currentFee();
            uint256 b = burnShareBps();
            if (params.zeroForOne) {
                // buy (ETH is currency0): the ETH parts come off the ETH input; the burn part is swapped with the
                // rest and burned out of the POOL bought (afterSwap)
                uint256 fee = amountIn * f / FEE_DENOM;
                uint256 eth = fee - fee * b / BPS;
                if (eth != 0) {
                    ETH.take(poolManager, address(this), eth, true);
                    emit Taxed(sender, eth);
                    return (this.beforeSwap.selector, toBeforeSwapDelta(int128(int256(eth)), 0), 0);
                }
            } else {
                // sell: the burn part comes off the POOL input before the swap
                uint256 burnAmt = FullMath.mulDiv(amountIn, f * b, FEE_DENOM * BPS);
                if (burnAmt != 0) {
                    _burnTax(key, sender, burnAmt);
                    return (this.beforeSwap.selector, toBeforeSwapDelta(int128(int256(burnAmt)), 0), 0);
                }
            }
        }
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _afterSwap(address sender, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        // `delta` is the pool's own swap, before this hook's deltas: on a sell its POOL side is the input less the
        // burn already taken, which beforeSwap budgeted separately.
        _credit(key, delta.amount1());
        if (_isProtocol(sender)) return (this.afterSwap.selector, 0);
        uint256 f = currentFee();
        uint256 b = burnShareBps();
        if (params.zeroForOne) {
            // buy: burn the burn part's value, at this swap's price, out of the POOL bought (the unspecified side).
            // It is the burn part's fraction of the ETH beforeSwap left to swap, applied to the POOL actually bought:
            // on a full fill that is the burn part's value at the swap's price, and on a partial fill (a price
            // limit) it shrinks with the fill, so it never exceeds the POOL bought (fee <= amountIn).
            uint256 amountIn = uint256(-params.amountSpecified);
            uint256 fee = amountIn * f / FEE_DENOM;
            uint256 burnEth = fee * b / BPS;
            if (burnEth == 0) return (this.afterSwap.selector, 0);
            uint256 burnAmt =
                FullMath.mulDiv(uint256(int256(delta.amount1())), burnEth, amountIn - (fee - burnEth));
            if (burnAmt == 0) return (this.afterSwap.selector, 0);
            _burnTax(key, sender, burnAmt);
            return (this.afterSwap.selector, int128(int256(burnAmt)));
        }
        // sell: the ETH parts, out of the ETH paid out (the unspecified side). The burn part already came off the
        // input, so they are f (1 - b) / (1 - b f) of it, leaving the seller 1 - f of the whole.
        uint256 eth = FullMath.mulDiv(uint256(int256(delta.amount0())), f * (BPS - b), FEE_DENOM * BPS - f * b);
        if (eth != 0) {
            ETH.take(poolManager, address(this), eth, true);
            emit Taxed(sender, eth);
        }
        return (this.afterSwap.selector, int128(int256(eth)));
    }

    /// @dev Takes `amount` POOL out of the pool manager and burns it, and reports `amount` to the token as owed to
    /// the pool manager: on a sell (`beforeSwap`) it is the part of the seller's input that the swap's own report
    /// does not cover; on a buy (`afterSwap`) the swap's report covered all the POOL the pool pays out, and this
    /// takes the burn back out of what the buyer may take. The token nets opposite reports, so the take is reported
    /// out first, padded by any budget already pending into the pool manager (which would otherwise absorb it), made,
    /// and then reported in by the same padded amount: the take leaves any pending budget as it was.
    function _burnTax(PoolKey calldata key, address sender, uint256 amount) private {
        address token = Currency.unwrap(key.currency1);
        (uint256 pending,) = IVenueToken(token).poolManagerBudget();
        IVenueToken(token).creditPoolManager(false, pending + amount);
        key.currency1.take(poolManager, address(this), amount, false);
        IVenueToken(token).creditPoolManager(true, pending + amount);
        IPoolTokenBurn(token).burn(amount);
        emit TaxBurned(sender, amount);
    }

    // --- payouts ---

    /// @notice Splits the ETH tax collected since the last call: the dev wallet part stays as claims, and the Builder
    /// part is sent to the Builder as ETH. Callable by anyone.
    function collectTax() external {
        if (builder == address(0)) revert NotWired();
        poolManager.unlock(abi.encode(uint8(0)));
    }

    /// @notice Pays the dev wallet its accrued part of the tax. Callable by anyone.
    function claimDevFees() external {
        poolManager.unlock(abi.encode(uint8(1)));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        if (abi.decode(data, (uint8)) == 0) _collect();
        else _payDev();
        return "";
    }

    function _collect() private {
        uint256 fresh = poolManager.balanceOf(address(this), ETH.toId()) - devClaims;
        if (fresh == 0) return;
        // the ETH holds the dev wallet and Builder parts only (the burn part was burned in POOL), so the dev wallet's
        // part of it is devShareBps out of devShareBps + the Builder's part
        uint256 dev = fresh * devShareBps / (BPS - burnShareBps());
        uint256 toBuilder = fresh - dev;
        devClaims += dev;
        if (toBuilder != 0) {
            ETH.settle(poolManager, address(this), toBuilder, true); // burn the claims...
            ETH.take(poolManager, builder, toBuilder, false); // ...and send the ETH
        }
        emit TaxCollected(toBuilder, dev);
    }

    /// @dev Best-effort, mirroring ScoreLiquidity.claimDevFees and CreditRouter._payDev: a dev wallet that cannot
    /// take ETH must not revert the claim. The ETH is held as claims in the pool manager, so it is pushed out through
    /// a self-call (`pushDevFees`); a reverting recipient is caught, the dev part stays owed (`devClaims` and the
    /// pool-manager deltas are untouched, the failed frame having reverted) and can be claimed later once the dev wallet
    /// can take ETH. collectTax and the Builder's part are never blocked.
    function _payDev() private {
        uint256 owed = devClaims;
        if (owed == 0) return;
        try this.pushDevFees(devWallet, owed) {
            devClaims = 0;
            emit DevFeesClaimed(devWallet, owed);
        } catch {
            emit DevFeesClaimed(devWallet, 0); // the devWallet could not take it: kept owed for a later claim
        }
    }

    /// @notice Self only: burns `amount` of the hook's ETH claims and sends the ETH to `to`. Reachable only from
    /// `_payDev`, through an external call so a reverting recipient can be caught without reverting the claim.
    function pushDevFees(address to, uint256 amount) external {
        if (msg.sender != address(this)) revert NotSelf();
        ETH.settle(poolManager, address(this), amount, true);
        ETH.take(poolManager, to, amount, false);
    }

    // --- owner ---

    /// @notice Permanently lowers the dev wallet's part of the tax (0 removes it). Once the Builder is wired, the tax
    /// collected so far is split first (as `collectTax`), so tax taken before the change splits at the old part.
    function lowerDevShare(uint16 bps) external onlyOwner {
        if (bps >= devShareBps) revert OnlyLower();
        if (builder != address(0)) poolManager.unlock(abi.encode(uint8(0)));
        devShareBps = bps;
        emit DevShareLowered(bps);
    }

    /// @notice Owner only: sets the dev wallet.
    function setDevWallet(address devWallet_) external onlyOwner {
        if (devWallet_ == address(0)) revert BadConfig();
        devWallet = devWallet_;
        emit DevWalletSet(devWallet_);
    }
}
