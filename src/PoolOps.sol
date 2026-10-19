// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/utils/CurrencySettler.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ScoreMath} from "./ScoreMath.sol";

/// @dev The hook exposes the block's opening price for the pool.
interface IRefPriceOps {
    function blockOpenSqrtPrice(PoolId id) external view returns (uint160 open);
}

/// @title PoolOps
/// @notice The Uniswap v4 unlock-callback body of ScoreLiquidity, as an external library.
/// @dev Reached by delegatecall, so inside these functions `address(this)` is the pool and the pool is the unlocker:
/// the manager sees the pool as msg.sender for modifyLiquidity/settle/take. No state is read or written here
/// directly; the pool passes its mutable position values in a memory `State` and writes back the returned one, so
/// all storage stays in the pool. Constants match ScoreLiquidity.
library PoolOps {
    using CurrencySettler for Currency;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;

    int24 private constant TICK_LOWER = -887_200;
    int24 private constant TICK_UPPER = 887_200;
    uint160 private constant SQRT_LO = 4_310_618_292;
    uint160 private constant SQRT_HI = 1_456_195_216_270_955_103_206_513_029_158_776_779_468_408_838_535;
    uint256 private constant BPS = 10_000;
    uint256 private constant BAND_SQRT_BPS = 50;
    uint256 private constant Q96 = 1 << 96;

    enum Op {
        Launch,
        Deposit,
        Withdraw,
        Harvest,
        AddProtocol,
        TakeProtocol,
        TakeUnits
    }

    /// @notice The pool's mutable liquidity/fee position, carried in and out so the pool keeps all storage writes.
    struct State {
        uint256 lpLiquidity;
        uint256 protocolLiquidity;
        uint256 compoundEth;
        uint256 compoundScore;
        uint256 polCompoundEth;
        uint256 polCompoundScore;
        uint256 devOwedEth;
        uint256 devOwedScore;
        uint256 totalUnits;
    }

    event FeesSplit(uint256 eth, uint256 score, uint256 toBurnEth, uint256 toBurnScore);
    event Compounded(uint128 lpLiquidity, uint128 protocolLiquidity);

    error Nothing();
    error Slippage();
    error TransferFailed();

    /// @notice Runs one unlock operation. `key`, `manager`, `hook`, `burner`, `score` and `devFeeBps` are the pool's
    /// (immutables plus the current dev fee); `s` is the pool's position, mutated in memory and returned for the pool
    /// to persist.
    function run(
        State memory s,
        PoolKey memory key,
        IPoolManager manager,
        address hook,
        address burner,
        address score,
        uint256 devFeeBps,
        bytes calldata data
    ) external returns (bytes memory ret, State memory) {
        (Op op, bytes memory args) = abi.decode(data, (Op, bytes));
        if (op == Op.Launch) {
            (uint256 e, uint256 sc) = abi.decode(args, (uint256, uint256));
            (uint128 liq, uint256 ue, uint256 us) = _add(key, manager, e, sc);
            return (abi.encode(liq, ue, us), s);
        }
        _harvest(s, key, manager, burner, score, devFeeBps);
        if (op == Op.Deposit) {
            (uint256 e, uint256 sc) = abi.decode(args, (uint256, uint256));
            _compound(s, key, manager, hook);
            (uint128 liq, uint256 ue, uint256 us) = _add(key, manager, e, sc);
            // Units are priced on the position plus the LP compounding balances (valued as liquidity at the current
            // price), so a deposit buys into those balances and cannot dilute them.
            uint256 unitsOut = s.totalUnits == 0 || s.lpLiquidity == 0
                ? 0
                : FullMath.mulDiv(liq, s.totalUnits, s.lpLiquidity + _bufferLiquidity(s, key, hook));
            s.lpLiquidity += liq;
            s.totalUnits += unitsOut;
            return (abi.encode(unitsOut, e - ue, sc - us), s);
        }
        if (op == Op.Withdraw) {
            uint256 unitsIn = abi.decode(args, (uint256));
            _compound(s, key, manager, hook);
            uint256 liq = unitsIn * s.lpLiquidity / s.totalUnits;
            uint256 be = FullMath.mulDiv(s.compoundEth, unitsIn, s.totalUnits);
            uint256 bs = FullMath.mulDiv(s.compoundScore, unitsIn, s.totalUnits);
            s.compoundEth -= be;
            s.compoundScore -= bs;
            s.totalUnits -= unitsIn;
            s.lpLiquidity -= liq;
            (uint256 e, uint256 sc) = liq == 0 ? (0, 0) : _remove(key, manager, uint128(liq));
            return (abi.encode(e + be, sc + bs), s);
        }
        if (op == Op.Harvest) {
            _compound(s, key, manager, hook);
            return ("", s);
        }
        if (op == Op.TakeProtocol) {
            uint256 pl = s.protocolLiquidity;
            s.protocolLiquidity = 0;
            (uint256 te, uint256 ts) = pl == 0 ? (0, 0) : _remove(key, manager, uint128(pl));
            te += s.polCompoundEth;
            ts += s.polCompoundScore;
            s.polCompoundEth = 0;
            s.polCompoundScore = 0;
            return (abi.encode(te, ts), s);
        }
        if (op == Op.TakeUnits) {
            uint256 want = abi.decode(args, (uint256));
            (uint160 sqrtP,,,) = manager.getSlot0(key.toId());
            uint256 all = s.lpLiquidity;
            if (all == 0 || !_priceInBand(key, hook, sqrtP)) revert Slippage();
            // Full range: score = L * (sqrtP - sqrtLo) / Q96, solved for L and rounded up.
            uint256 liq = Math.min(all, FullMath.mulDivRoundingUp(want, Q96, sqrtP - SQRT_LO));
            uint256 be = FullMath.mulDiv(s.compoundEth, liq, all);
            uint256 bs = FullMath.mulDiv(s.compoundScore, liq, all);
            s.compoundEth -= be;
            s.compoundScore -= bs;
            s.lpLiquidity = all - liq;
            (uint256 te, uint256 ts) = liq == 0 ? (0, 0) : _remove(key, manager, uint128(liq));
            return (abi.encode(te + be, ts + bs), s);
        }
        // Op.AddProtocol
        (uint256 pe, uint256 ps) = abi.decode(args, (uint256, uint256));
        (uint128 pliq, uint256 pue, uint256 pus) = _add(key, manager, pe, ps);
        s.protocolLiquidity += pliq;
        return (abi.encode(pliq, pe - pue, ps - pus), s);
    }

    /// @dev Adds the liquidity that (eth, scoreAmt) supports at the current price; returns the amounts used.
    function _add(PoolKey memory key, IPoolManager manager, uint256 eth, uint256 scoreAmt)
        private
        returns (uint128 liq, uint256 usedE, uint256 usedS)
    {
        (uint160 sqrtP,,,) = manager.getSlot0(key.toId());
        liq = LiquidityAmounts.getLiquidityForAmounts(sqrtP, SQRT_LO, SQRT_HI, eth, scoreAmt);
        if (liq == 0) revert Nothing();
        (BalanceDelta d,) = _modify(key, manager, int256(uint256(liq)));
        // Fees are always harvested before an add, so the delta is principal only.
        usedE = uint256(-int256(d.amount0()));
        usedS = uint256(-int256(d.amount1()));
        _settle(key, manager, d.amount0(), d.amount1());
    }

    function _remove(PoolKey memory key, IPoolManager manager, uint128 liq) private returns (uint256 e, uint256 s) {
        (BalanceDelta d,) = _modify(key, manager, -int256(uint256(liq)));
        _settle(key, manager, d.amount0(), d.amount1());
        e = uint256(int256(d.amount0()));
        s = uint256(int256(d.amount1()));
    }

    /// @dev Collects the position's fees and splits them: `devFeeBps` of all to the dev wallet, the rest pro rata to
    /// the units and the protocol, each part compounded and the rest to the Burner (rounding remainders too).
    function _harvest(State memory s, PoolKey memory key, IPoolManager manager, address burner, address score, uint256 devFeeBps)
        private
    {
        uint256 lp = s.lpLiquidity;
        uint256 all = lp + s.protocolLiquidity;
        if (all == 0) return;
        (BalanceDelta d,) = _modify(key, manager, 0);
        _settle(key, manager, d.amount0(), d.amount1());
        uint256 f0 = _pos(d.amount0());
        uint256 f1 = _pos(d.amount1());
        if (f0 == 0 && f1 == 0) return;
        ScoreMath.Split memory sp = ScoreMath.split(f0, f1, devFeeBps, lp, all);
        s.devOwedEth += sp.dv0;
        s.devOwedScore += sp.dv1;
        s.compoundEth += sp.c0;
        s.compoundScore += sp.c1;
        s.polCompoundEth += sp.pc0;
        s.polCompoundScore += sp.pc1;
        _send(score, burner, sp.burn0, sp.burn1);
        emit FeesSplit(f0, f1, sp.burn0, sp.burn1);
    }

    /// @dev Compounds both balances at the pool's ratio in one liquidity add, crediting each with the liquidity its
    /// own amounts support, while the price is within the band around the hook's block-open price. What does not
    /// fit, or everything when out of band, waits.
    function _compound(State memory s, PoolKey memory key, IPoolManager manager, address hook) private {
        (uint160 sqrtP,,,) = manager.getSlot0(key.toId());
        if (!_priceInBand(key, hook, sqrtP)) return;
        uint160 lo = SQRT_LO;
        uint160 hi = SQRT_HI;
        uint128 lpL = LiquidityAmounts.getLiquidityForAmounts(sqrtP, lo, hi, s.compoundEth, s.compoundScore);
        uint128 polL = LiquidityAmounts.getLiquidityForAmounts(sqrtP, lo, hi, s.polCompoundEth, s.polCompoundScore);
        if (uint256(lpL) + polL == 0) return;
        // Each balance pays for its own liquidity (rounded up); the combined add needs no more than the sum.
        s.compoundEth -= Math.min(s.compoundEth, _amount0(sqrtP, hi, lpL));
        s.compoundScore -= Math.min(s.compoundScore, _amount1(lo, sqrtP, lpL));
        s.polCompoundEth -= Math.min(s.polCompoundEth, _amount0(sqrtP, hi, polL));
        s.polCompoundScore -= Math.min(s.polCompoundScore, _amount1(lo, sqrtP, polL));
        (BalanceDelta d,) = _modify(key, manager, int256(uint256(lpL) + polL));
        _settle(key, manager, d.amount0(), d.amount1());
        s.lpLiquidity += lpL;
        s.protocolLiquidity += polL;
        emit Compounded(lpL, polL);
    }

    /// @dev The LP compounding balances valued as full-range liquidity at the hook's block-open price, so a trade in
    /// the block cannot move what they are worth. Each side counts as half a full-range position:
    /// L = eth * sqrtP / Q96 / 2 = score * Q96 / sqrtP / 2.
    function _bufferLiquidity(State memory s, PoolKey memory key, address hook) private view returns (uint256) {
        uint160 sqrtP = IRefPriceOps(hook).blockOpenSqrtPrice(key.toId());
        return (FullMath.mulDiv(s.compoundEth, sqrtP, Q96) + FullMath.mulDiv(s.compoundScore, Q96, sqrtP)) / 2;
    }

    function _amount0(uint160 sqrtP, uint160 hi, uint128 liq) private pure returns (uint256) {
        return liq == 0 ? 0 : SqrtPriceMath.getAmount0Delta(sqrtP, hi, liq, true);
    }

    function _amount1(uint160 lo, uint160 sqrtP, uint128 liq) private pure returns (uint256) {
        return liq == 0 ? 0 : SqrtPriceMath.getAmount1Delta(lo, sqrtP, liq, true);
    }

    /// @dev Whether `sqrtP` is strictly within the band around the hook's block-open price.
    function _priceInBand(PoolKey memory key, address hook, uint160 sqrtP) private view returns (bool) {
        uint160 open = IRefPriceOps(hook).blockOpenSqrtPrice(key.toId());
        return _near(sqrtP, open);
    }

    function _near(uint256 sqrtP, uint256 ref) private pure returns (bool) {
        return ref != 0 && sqrtP > ref * (BPS - BAND_SQRT_BPS) / BPS && sqrtP < ref * (BPS + BAND_SQRT_BPS) / BPS;
    }

    function _modify(PoolKey memory key, IPoolManager manager, int256 liquidityDelta)
        private
        returns (BalanceDelta, BalanceDelta)
    {
        return manager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                liquidityDelta: liquidityDelta,
                salt: bytes32(0)
            }),
            ""
        );
    }

    /// @dev Pays what the pool owes the pool manager and takes what it is owed.
    function _settle(PoolKey memory key, IPoolManager manager, int256 d0, int256 d1) private {
        if (d0 < 0) key.currency0.settle(manager, address(this), uint256(-d0), false);
        else if (d0 > 0) key.currency0.take(manager, address(this), uint256(d0), false);
        if (d1 < 0) key.currency1.settle(manager, address(this), uint256(-d1), false);
        else if (d1 > 0) key.currency1.take(manager, address(this), uint256(d1), false);
    }

    function _send(address score, address to, uint256 eth, uint256 scoreAmt) private {
        if (scoreAmt != 0) IERC20(score).safeTransfer(to, scoreAmt);
        if (eth != 0) {
            (bool ok,) = to.call{value: eth}("");
            if (!ok) revert TransferFailed();
        }
    }

    function _pos(int128 x) private pure returns (uint256) {
        return x > 0 ? uint256(int256(x)) : 0;
    }
}
