// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @dev Minimal view of ScoreToken used by the bootstrap cap check.
interface IValueOf {
    function valueOf(uint256 id) external view returns (uint256);
}

/// @dev The ScoreLiquidity getters the farm-stream aggregation reads, shared by this library's callers.
interface IPoolView {
    function launched() external view returns (bool);
    function accPerWeight() external view returns (uint256);
    function boostAEnded() external view returns (bool);
    function accEndA() external view returns (uint256);
    function lastAccrue() external view returns (uint256);
    function launchedAt() external view returns (uint64);
    function preMigEnd() external view returns (uint64);
    function phase1End() external view returns (uint256);
    function totalUnits() external view returns (uint256);
    function totalBoostA() external view returns (uint256);
    function preMigAmount() external view returns (uint256);
    function migrationOpen() external view returns (bool);
    function earlyUnlocked() external view returns (bool);
    function earlyUnlockedAt() external view returns (uint64);
    function deadline() external view returns (uint256);
    function migrationOpenedAt() external view returns (uint64);
    function MIGRATION_BACKSTOP() external view returns (uint256);
}

/// @title ScoreMath
/// @notice Self-contained math shared by ScoreLiquidity and ScoreLens.
/// @dev An external library: its functions are deployed separately and reached by delegatecall, which keeps the
/// arithmetic out of the pool's bytecode. Every function is pure or view (value in, value out); the pool keeps all
/// storage reads and writes. Constants mirror ScoreLiquidity exactly.
library ScoreMath {
    uint256 private constant ACC = 1e18;
    uint256 private constant BPS = 10_000;
    uint256 private constant COMPOUND_BPS = 5_000;
    uint256 private constant DEAD_UNITS = 1_000;

    // Same selectors as ScoreLiquidity's (no-arg errors), so reverts reach callers unchanged.
    error CapReached();
    error WalletCapReached();

    /// @notice The pre-migration stream's accumulators: the per-weight tally (`acc`), and cohort A's tally frozen at its
    /// boost's end (`accA`, once `aEnded`).
    struct Stream {
        uint256 acc;
        uint256 accA;
        bool aEnded;
    }

    /// @notice An accrual from `last` to `t`: `preMigAmount` streams linearly over [`t0`, `p`] (launch to the
    /// pre-migration end) and stops at `e1` (the migration's completion, if earlier); every unit weighs 1 and cohort
    /// A's boost adds on top until `endA`.
    struct Params {
        uint256 last;
        uint256 t;
        uint256 t0;
        uint256 p;
        uint256 e1;
        uint256 endA;
        uint256 totalUnits;
        uint256 totalBoostA;
        uint256 preMigAmount;
    }

    /// @notice `amount` streamed linearly over [`start`, `end`], by time `x`.
    function linear(uint256 amount, uint256 x, uint256 start, uint256 end) public pure returns (uint256) {
        if (end <= start || x <= start) return 0;
        if (x >= end) return amount;
        return FullMath.mulDiv(amount, x - start, end - start);
    }

    /// @notice The farm-stream accrual of ScoreLiquidity._accrue (see `Params`).
    function accrue(Stream memory s, Params memory q) external pure returns (Stream memory) {
        return _accrue(s, q);
    }

    function _accrue(Stream memory s, Params memory q) private pure returns (Stream memory) {
        // over [last, min(t, e1)], split at cohort A's end
        uint256 a = q.last;
        uint256 t1 = q.t < q.e1 ? q.t : q.e1;
        if (!s.aEnded && q.endA <= a) {
            s.accA = s.acc;
            s.aEnded = true;
        }
        if (t1 > a) {
            if (!s.aEnded && q.endA < t1) {
                s.acc += _perWeight(q, a, q.endA, q.totalUnits + q.totalBoostA);
                s.accA = s.acc;
                s.aEnded = true;
                a = q.endA;
            }
            s.acc += _perWeight(q, a, t1, q.totalUnits + (s.aEnded ? 0 : q.totalBoostA));
        }
        return s;
    }

    /// @dev The stream's POOL over [`a`, `b`], per unit of weight `w` (scaled by ACC).
    function _perWeight(Params memory q, uint256 a, uint256 b, uint256 w) private pure returns (uint256) {
        if (w == 0) return 0;
        return (linear(q.preMigAmount, b, q.t0, q.p) - linear(q.preMigAmount, a, q.t0, q.p)) * ACC / w;
    }

    /// @notice ETH (currency0) in `liq` full-range liquidity between `sqrtP` and `hi`; `roundUp` as SqrtPriceMath.
    function amount0(uint160 sqrtP, uint160 hi, uint128 liq, bool roundUp) external pure returns (uint256) {
        return liq == 0 ? 0 : SqrtPriceMath.getAmount0Delta(sqrtP, hi, liq, roundUp);
    }

    /// @notice SCORE (currency1) in `liq` full-range liquidity between `lo` and `sqrtP`; `roundUp` as SqrtPriceMath.
    function amount1(uint160 lo, uint160 sqrtP, uint128 liq, bool roundUp) external pure returns (uint256) {
        return liq == 0 ? 0 : SqrtPriceMath.getAmount1Delta(lo, sqrtP, liq, roundUp);
    }

    /// @notice The liquidity that (`amt0` ETH, `amt1` SCORE) supports at `sqrtP` over the range [`lo`, `hi`].
    function liquidityFor(uint160 sqrtP, uint160 lo, uint160 hi, uint256 amt0, uint256 amt1)
        external
        pure
        returns (uint128)
    {
        return LiquidityAmounts.getLiquidityForAmounts(sqrtP, lo, hi, amt0, amt1);
    }

    /// @notice When cohort A's boost ends (mirrors ScoreLiquidity._boostEndA): at the early unlock (or the deadline,
    /// if earlier); else, with the migration open, at `MIGRATION_BACKSTOP` after it opened; else at the deadline.
    function boostEndA(IPoolView p) public view returns (uint256) {
        if (p.earlyUnlocked()) return Math.min(p.earlyUnlockedAt(), p.deadline());
        if (p.migrationOpen()) return uint256(p.migrationOpenedAt()) + p.MIGRATION_BACKSTOP();
        return p.deadline();
    }

    /// @notice Everything earned from the farm stream by now at weights `u` (units) and `wA` (cohort A), mirroring
    /// ScoreLiquidity._earned over an off-chain accrual to now. Reads the pool's getters here so the code stays out of
    /// ScoreLens.
    function earned(IPoolView p, uint256 u, uint256 wA) external view returns (uint256) {
        Stream memory s = Stream(p.accPerWeight(), p.accEndA(), p.boostAEnded());
        uint256 last = p.lastAccrue();
        if (p.launched() && block.timestamp > last) {
            s = _accrue(
                s,
                Params(
                    last,
                    block.timestamp,
                    p.launchedAt(),
                    p.preMigEnd(),
                    p.phase1End(),
                    boostEndA(p),
                    p.totalUnits(),
                    p.totalBoostA(),
                    p.preMigAmount()
                )
            );
        }
        return (u * s.acc + wA * (s.aEnded ? s.accA : s.acc)) / ACC;
    }

    struct Split {
        uint256 dv0;
        uint256 dv1;
        uint256 c0;
        uint256 c1;
        uint256 pc0;
        uint256 pc1;
        uint256 burn0;
        uint256 burn1;
    }

    /// @notice Splits collected fees (`f0` ETH, `f1` SCORE): `devFeeBps` to the dev wallet, the rest pro rata to the
    /// units (`lp` of `all` liquidity) and the protocol, each part `COMPOUND_BPS` compounded and the rest to the
    /// Burner.
    function split(uint256 f0, uint256 f1, uint256 devFeeBps, uint256 lp, uint256 all)
        external
        pure
        returns (Split memory s)
    {
        s.dv0 = f0 * devFeeBps / BPS;
        s.dv1 = f1 * devFeeBps / BPS;
        uint256 r0 = f0 - s.dv0;
        uint256 r1 = f1 - s.dv1;
        uint256 lp0 = FullMath.mulDiv(r0, lp, all);
        uint256 lp1 = FullMath.mulDiv(r1, lp, all);
        s.c0 = lp0 * COMPOUND_BPS / BPS;
        s.c1 = lp1 * COMPOUND_BPS / BPS;
        s.pc0 = (r0 - lp0) * COMPOUND_BPS / BPS;
        s.pc1 = (r1 - lp1) * COMPOUND_BPS / BPS;
        s.burn0 = r0 - s.c0 - s.pc0;
        s.burn1 = r1 - s.c1 - s.pc1;
    }

    /// @notice The bootstrap's cap check (ScoreLiquidity.deposit): a commit must fit under both caps once its largest
    /// Credit is excluded, so a single wrap can cross a cap by at most its largest Credit; once a cap is crossed the
    /// next commit is refused (SCORE, whose slack is zero, can never cross). `cap` and `walletCap` are already in
    /// SCORE (capEth/walletCapEth * launchPrice).
    function checkCaps(
        IValueOf score,
        uint256[] calldata ids,
        uint256 total,
        uint256 mine,
        uint256 cap,
        uint256 walletCap
    ) external view {
        if (total <= cap && mine <= walletCap) return;
        uint256 slack;
        for (uint256 i; i < ids.length; ++i) {
            uint256 v = score.valueOf(ids[i]);
            if (v > slack) slack = v;
        }
        if (total - slack > cap) revert CapReached();
        if (mine - slack > walletCap) revert WalletCapReached();
    }

    /// @notice ScoreLiquidity._bootstrapOf: the bootstrap units a commitment of (`e` ETH, `s` SCORE) earns at
    /// settlement, split by committed value at the launch price, and the unused ETH and SCORE returned. Used amounts
    /// round up, so refunds round down.
    function bootstrapShare(
        uint256 e,
        uint256 s,
        uint256 usedEth,
        uint256 usedScore,
        uint256 bootEthTotal,
        uint256 bootScoreTotal,
        uint256 launchPrice,
        uint256 bootLiquidity
    ) external pure returns (uint256 unitsOut, uint256 ethBack, uint256 scoreBack) {
        uint256 valueIn =
            FullMath.mulDiv(e, usedEth, bootEthTotal) + FullMath.mulDiv(s, usedScore, bootScoreTotal) / launchPrice;
        uint256 valueAll = usedEth + usedScore / launchPrice;
        unitsOut = FullMath.mulDiv(bootLiquidity - DEAD_UNITS, valueIn, valueAll);
        ethBack = e - FullMath.mulDivRoundingUp(e, usedEth, bootEthTotal);
        scoreBack = s - FullMath.mulDivRoundingUp(s, usedScore, bootScoreTotal);
    }
}
