// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/utils/CurrencySettler.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// The bootstrap's state, read to tell whether it can still launch.
interface ILauncherState {
    function launched() external view returns (bool);
    function live() external view returns (bool);
    function deadline() external view returns (uint256);
    function bootstrapFailed() external view returns (bool);
}

/// The POOL/ETH hook's reference price (HookBase.blockOpenSqrtPrice).
interface IBlockOpenPrice {
    function blockOpenSqrtPrice(PoolId id) external view returns (uint160);
}

/// @title PoolLaunch
/// @notice Opens the POOL/ETH pool (POOL is the protocol token) and adds all the POOL it holds against the ETH the
/// launcher forwarded (`seededEth`) as one full-range position, so the opening price is their ratio. It has no function
/// to remove that liquidity. In the live system ScoreLiquidity funds it at launch with the accumulated bootstrap
/// surcharge (via the launcher-gated `fund`). Anyone else may also send ETH before the launch (`fund` or a plain
/// transfer); it is held but is NOT priced into the opening ratio, so a pre-funder cannot skew it. If the bootstrap can
/// never launch, the owner can take the POOL and all the ETH back (`reclaim`); once the pool is open, nothing can
/// leave. The seed position's LP fees are added back into it (`compound`), so they stay locked with it.
/// @dev Pool: ETH/POOL, a static LP fee (`lpFee`, set at deploy) on top of the hook's tax, tick spacing 200.
contract PoolLaunch is IUnlockCallback, Ownable2Step {
    using CurrencySettler for Currency;
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;

    int24 public constant TICK_SPACING = 200;
    int24 public constant TICK_LOWER = -887_200;
    int24 public constant TICK_UPPER = 887_200;
    /// @notice sqrt(1.04) in Q96: `compound` adds only while the price is within a factor of 1.04 of the block's
    /// opening price (the same band as the Burner's POOL buy).
    uint256 public constant SQRT_1_04_Q96 = 80_797_189_337_266_850_215_793_353_563;
    uint256 private constant Q96 = 1 << 96;

    IPoolManager public immutable manager;
    IERC20 public immutable poolToken;
    IHooks public immutable hook;
    address public immutable launcher;
    /// @notice The pool's LP fee, in hundredths of a bip (a static fee, part of the pool key).
    uint24 public immutable lpFee;
    bool public done;
    uint128 public liquidity;
    /// @notice ETH the launcher forwarded for the opening liquidity (the bootstrap surcharge). Only this seeds the
    /// opening price; ETH sent in by anyone else (`fund` from a non-launcher, or a plain transfer) is held but never
    /// priced in, so a pre-funder cannot skew the POOL/ETH opening ratio.
    uint256 public seededEth;

    event Funded(address indexed from, uint256 eth);
    event Opened(uint160 sqrtPriceX96, uint256 eth, uint256 poolToken, uint128 liquidity);
    event Reclaimed(address indexed to, uint256 eth, uint256 poolToken);
    event Compounded(uint256 eth, uint256 poolToken, uint128 liquidity);

    error OnlyLauncher();
    error Done();
    error Unfunded();
    error OnlyManager();
    error CanStillLaunch();
    error TransferFailed();
    error BadFee();
    error NotOpen();
    error OutOfBand();

    constructor(IPoolManager manager_, IERC20 poolToken_, IHooks hook_, address launcher_, address owner_, uint24 lpFee_)
        Ownable(owner_)
    {
        if (lpFee_ == 0 || lpFee_ > LPFeeLibrary.MAX_LP_FEE) revert BadFee();
        lpFee = lpFee_;
        manager = manager_;
        poolToken = poolToken_;
        hook = hook_;
        launcher = launcher_;
    }

    /// @notice Adds ETH before the launch. Only the launcher's ETH counts toward the opening price (`seededEth`);
    /// anyone else's ETH is held (and reclaimable while the launch can still fail) but never priced in.
    function fund() external payable {
        if (done) revert Done();
        if (msg.sender == launcher) seededEth += msg.value;
        emit Funded(msg.sender, msg.value);
    }

    /// @dev After the open, only the pool manager sends ETH here (a compound's leftover).
    receive() external payable {
        if (done && msg.sender != address(manager)) revert Done();
        emit Funded(msg.sender, msg.value);
    }

    /// @notice Owner only, once the bootstrap can never launch (not launched, and either the real token went live or
    /// the bootstrap failed — its minimum missed within the window, or the deadline passed): sends all the ETH and
    /// POOL held to `to`. The pool can then never open from here.
    function reclaim(address to) external onlyOwner {
        if (done) revert Done();
        ILauncherState l = ILauncherState(launcher);
        if (l.launched() || !(l.live() || l.bootstrapFailed())) revert CanStillLaunch();
        done = true;
        uint256 eth = address(this).balance;
        uint256 amount = poolToken.balanceOf(address(this));
        if (amount != 0) poolToken.safeTransfer(to, amount);
        (bool ok,) = to.call{value: eth}("");
        if (!ok) revert TransferFailed();
        emit Reclaimed(to, eth, amount);
    }

    function key() public view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(poolToken)),
            fee: lpFee,
            tickSpacing: TICK_SPACING,
            hooks: hook
        });
    }

    function poolId() external view returns (PoolId) {
        return key().toId();
    }

    /// @notice Launcher only, once: initializes the pool at the ratio of the POOL held to the ETH the launcher
    /// forwarded (POOL per ETH) and adds both in full range. The opening price is set from `seededEth` only, so
    /// donated ETH cannot skew it; any surplus ETH stays locked (harmless).
    /// @dev The POOL side is priced from the live balance (`poolToken.balanceOf`). Unlike ETH, POOL arrives by a plain
    /// ERC-20 transfer with no receiver hook, so there is no arrival-time signal to tell the deployer's seed from a
    /// donation; a clean snapshot would need the intended amount declared out of band (a constructor immutable or an
    /// armed setter wired into the deploy), which adds a bricking path to the launch flow for no gain in the
    /// canonical deploy: the whole POOL supply is distributed at deploy (70% to ScoreLiquidity for the bootstrap
    /// allocation and the farm, 30% here), and none of it reaches a third party before launch, so no pre-launch POOL
    /// donation is possible.
    function openPool() external {
        if (msg.sender != launcher) revert OnlyLauncher();
        if (done) revert Done();
        uint256 eth = seededEth;
        uint256 amount = poolToken.balanceOf(address(this));
        if (eth == 0 || amount == 0) revert Unfunded();
        done = true;
        // price = POOL / ETH, so sqrtPriceX96 = sqrt(amount / eth) * 2^96
        uint160 sqrtP = uint160(Math.sqrt(FullMath.mulDiv(amount, 1 << 192, eth)));
        manager.initialize(key(), sqrtP);
        manager.unlock(abi.encode(false, sqrtP, eth, amount));
    }

    /// @notice Callable by anyone once the pool is open: collects the seed position's LP fees and adds them, with any
    /// ETH and POOL held here, back into the same full-range position at the current price. What does not fit at that
    /// ratio stays here for the next call. It adds only while the price is within a factor of 1.04 of the block's
    /// opening price (the hook's reference), so a trade earlier in the block cannot set the price it adds at.
    function compound() external {
        if (!done || liquidity == 0) revert NotOpen();
        manager.unlock(abi.encode(true, uint160(0), uint256(0), uint256(0)));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert OnlyManager();
        (bool compounding, uint160 sqrtP, uint256 eth, uint256 amount) =
            abi.decode(data, (bool, uint160, uint256, uint256));
        if (compounding) {
            _compound();
            return "";
        }
        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtP, TickMath.getSqrtPriceAtTick(TICK_LOWER), TickMath.getSqrtPriceAtTick(TICK_UPPER), eth, amount
        );
        (BalanceDelta d,) = manager.modifyLiquidity(
            key(),
            ModifyLiquidityParams({
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                liquidityDelta: int256(uint256(liquidity)),
                salt: bytes32(0)
            }),
            ""
        );
        uint256 usedEth = uint256(-int256(d.amount0()));
        uint256 usedPool = uint256(-int256(d.amount1()));
        Currency.wrap(address(0)).settle(manager, address(this), usedEth, false);
        Currency.wrap(address(poolToken)).settle(manager, address(this), usedPool, false);
        emit Opened(sqrtP, usedEth, usedPool, liquidity);
        return "";
    }

    function _compound() private {
        PoolKey memory k = key();
        PoolId id = k.toId();
        (uint160 sqrtP,,,) = StateLibrary.getSlot0(manager, id);
        uint256 open = IBlockOpenPrice(address(hook)).blockOpenSqrtPrice(id);
        if (sqrtP <= FullMath.mulDivRoundingUp(open, Q96, SQRT_1_04_Q96) || sqrtP >= FullMath.mulDiv(open, SQRT_1_04_Q96, Q96)) {
            revert OutOfBand();
        }
        // a zero-liquidity change collects the position's fees, as credits to this contract
        ModifyLiquidityParams memory p =
            ModifyLiquidityParams({tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: 0, salt: bytes32(0)});
        (BalanceDelta fees,) = manager.modifyLiquidity(k, p, "");
        uint256 eth = uint256(int256(fees.amount0())) + address(this).balance;
        uint256 amount = uint256(int256(fees.amount1())) + poolToken.balanceOf(address(this));
        uint128 added = LiquidityAmounts.getLiquidityForAmounts(
            sqrtP, TickMath.getSqrtPriceAtTick(TICK_LOWER), TickMath.getSqrtPriceAtTick(TICK_UPPER), eth, amount
        );
        int256 net0 = fees.amount0();
        int256 net1 = fees.amount1();
        if (added != 0) {
            p.liquidityDelta = int256(uint256(added));
            (BalanceDelta d,) = manager.modifyLiquidity(k, p, "");
            net0 += d.amount0();
            net1 += d.amount1();
            liquidity += added;
        }
        // settle what the add used beyond the fees from the balance held here; take any fees left over
        _close(Currency.wrap(address(0)), net0);
        _close(Currency.wrap(address(poolToken)), net1);
        emit Compounded(eth, amount, added);
    }

    function _close(Currency c, int256 net) private {
        if (net < 0) c.settle(manager, address(this), uint256(-net), false);
        else if (net > 0) c.take(manager, address(this), uint256(net), false);
    }
}
