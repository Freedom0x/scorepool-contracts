// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

import {ScoreLiquidity} from "./ScoreLiquidity.sol";
import {ScoreMath, IPoolView} from "./ScoreMath.sol";

/// @title ScoreLens
/// @notice Read-only views over ScoreLiquidity for frontends and the migrator. Reads go straight to the pool's
/// (and its guard's) public getters, so there is no interface to keep in step.
contract ScoreLens {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint256 private constant BPS = 10_000;
    uint256 private constant COMMIT_WINDOW = 2 hours;
    int24 private constant TICK_SPACING = 200;
    // TickMath.getSqrtPriceAtTick(-887_200) and (887_200), precomputed to keep TickMath out of the bytecode.
    uint160 private constant SQRT_LO = 4_310_618_292;
    uint160 private constant SQRT_HI = 1_456_195_216_270_955_103_206_513_029_158_776_779_468_408_838_535;

    ScoreLiquidity public immutable pool;

    constructor(address pool_) {
        pool = ScoreLiquidity(payable(pool_));
    }

    /// @notice The SCORE/ETH pool key, rebuilt from the pool's immutables. The SCORE pool uses a dynamic fee set
    /// per swap by the hook.
    function poolKeyOf() public view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(pool.score())),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: pool.hook()
        });
    }

    function poolId() public view returns (PoolId) {
        return poolKeyOf().toId();
    }

    /// @notice ETH required to commit `scoreAmt` SCORE to the bootstrap: its value at the launch price, rounded up.
    function ethRequired(uint256 scoreAmt) public view returns (uint256) {
        uint256 p = pool.launchPrice();
        return (scoreAmt + p - 1) / p;
    }

    /// @notice When cohort A's boost ends (mirrors ScoreLiquidity's internal rule): at the early unlock (or the
    /// deadline, if earlier); else, with the migration open, `MIGRATION_BACKSTOP` after it opened; else at the
    /// deadline. It only weighs in the pre-migration stream, which may end sooner.
    function boostEndA() public view returns (uint256) {
        return ScoreMath.boostEndA(IPoolView(address(pool)));
    }

    // --- bootstrap ---

    /// @notice When the bootstrap's commits open (0 = not set yet). Commits are open once `block.timestamp` reaches
    /// it; the site shows "bootstrap opens <time>".
    function bootstrapOpenAt() external view returns (uint64) {
        return pool.bootstrapOpenAt();
    }

    /// @notice SCORE still open under the bootstrap's total cap. A commit may exceed it by at most its largest Credit;
    /// once the cap is crossed no further commit is accepted.
    function remainingCapacity() external view returns (uint256) {
        uint256 cap = pool.capEth() * pool.launchPrice();
        uint256 t = pool.bootScoreTotal();
        return pool.launched() || t >= cap ? 0 : cap - t;
    }

    /// @notice SCORE `user` can still commit under the wallet cap (a commit may exceed it by one Credit).
    function remainingWalletCapacity(address user) external view returns (uint256) {
        uint256 cap = pool.walletCapEth() * pool.launchPrice();
        uint256 mine = pool.bootScore(user);
        return pool.launched() || mine >= cap ? 0 : cap - mine;
    }

    /// @notice Whether the launch conditions currently hold (the commit window has passed or the SCORE cap is full,
    /// the launch price is fresh, and neither the deadline nor `preMigEnd` has passed).
    /// This does not reflect the one-block guard in `launch()`: launch cannot happen in a commit's own block, so a
    /// launch sent in the same block as a commit still reverts.
    function canLaunch() external view returns (bool) {
        return !pool.launched() && !pool.live() && !pool.paused() && !pool.migrationOpen()
            && block.timestamp < pool.deadline() && block.timestamp < pool.preMigEnd()
            && pool.bootEthTotal() >= pool.minEth()
            && block.timestamp <= uint256(pool.priceUpdatedAt()) + pool.PRICE_FRESH()
            && (launchTimeReached() || pool.bootScoreTotal() >= pool.capEth() * pool.launchPrice())
            && pool.poolLaunch() != address(0) && pool.poolSeedEth() != 0
            && pool.poolToken().balanceOf(pool.poolLaunch()) != 0
            && pool.poolToken().balanceOf(address(pool)) >= pool.bootstrapAllocation() + pool.farmTotal();
    }

    /// @notice Mirrors ScoreLiquidity's commit-window timing: `COMMIT_WINDOW` (2 h) after `bootstrapOpenAt` (the
    /// public open). A full SCORE cap launches without this, and the minimum still has to be in (see `canLaunch`).
    function launchTimeReached() public view returns (bool) {
        uint64 o = pool.bootstrapOpenAt();
        return o != 0 && block.timestamp >= uint256(o) + COMMIT_WINDOW;
    }

    // --- users ---

    /// @notice Mirrors ScoreLiquidity._bootstrapOf: bootstrap units `user` receives at settlement, and the unused
    /// ETH and SCORE returned.
    function bootstrapOf(address user) public view returns (uint256 unitsOut, uint256 ethBack, uint256 scoreBack) {
        if (!pool.launched() || pool.bootSettled(user)) return (0, 0, 0);
        uint256 e = pool.bootEth(user);
        uint256 s = pool.bootScore(user);
        if (e == 0 && s == 0) return (0, 0, 0);
        return ScoreMath.bootstrapShare(
            e,
            s,
            pool.usedEth(),
            pool.usedScore(),
            pool.bootEthTotal(),
            pool.bootScoreTotal(),
            pool.launchPrice(),
            pool.bootLiquidity()
        );
    }

    /// @notice `user`'s units, including bootstrap units not yet settled.
    function unitsOf(address user) public view returns (uint256) {
        (uint256 bu,,) = bootstrapOf(user);
        return pool.units(user) + bu;
    }

    /// @notice The farm's start.
    function launchedAt() external view returns (uint64) {
        return pool.launchedAt();
    }

    /// @notice The farm's schedule: when the pre-migration stream ends, when week one's farm ends, until when the
    /// owner may route the reserve, and when the migration completed (the last three are 0 until it has).
    function farmSchedule()
        external
        view
        returns (uint256 preMigrationEnd, uint256 weekOneEnd, uint256 reserveDeadline, uint256 migrationCompletedAt)
    {
        return (pool.phase1End(), pool.weekOneEndAt(), pool.reserveDeadline(), pool.migrationCompletedAt());
    }

    /// @notice `user`'s lock boost: cohort A units (bootstrap and locked by their owner) and when that boost ends.
    function boostOf(address user) external view returns (uint256 unitsA, uint256 endA) {
        (uint256 bu,,) = bootstrapOf(user);
        unitsA = pool.lockedUnits(user) + bu;
        endA = boostEndA();
    }

    /// @notice `user`'s bootstrap allocation: the total, the part claimable (all of it from launch), and the part
    /// already paid.
    function bootstrapAllocationOf(address user) public view returns (uint256 total, uint256 vested, uint256 paid) {
        uint256 bl = pool.bootLiquidity();
        if (bl == 0) return (0, 0, 0);
        uint256 bu = pool.bootUnits(user);
        if (!pool.bootSettled(user)) (bu,,) = bootstrapOf(user);
        total = FullMath.mulDiv(pool.bootstrapAllocation(), bu, bl);
        vested = pool.launched() ? total : 0;
        paid = pool.bootstrapAllocationPaid(user);
    }

    /// @notice A user's position: units, pending POOL (stream plus bootstrap allocation not yet paid), withdrawal
    /// value, and bootstrap remainder.
    function userInfo(address user)
        external
        view
        returns (uint256 userUnits, uint256 pendingReward, uint256 ethValue, uint256 scoreValue, uint256 ethLoose, uint256 scoreLoose)
    {
        (uint256 bu, uint256 be, uint256 bsc) = bootstrapOf(user);
        userUnits = pool.units(user) + bu;
        uint256 earned =
            ScoreMath.earned(IPoolView(address(pool)), userUnits, pool.boostA(user) + bu * (pool.boostBps() - BPS) / BPS);
        (, uint256 vested, uint256 paid) = bootstrapAllocationOf(user);
        pendingReward = pool.rewardOwed(user) + earned - pool.emitDebt(user) + vested - paid;
        if (userUnits != 0) (ethValue, scoreValue) = valueOfUnits(userUnits);
        ethLoose = pool.looseEth(user) + be;
        scoreLoose = pool.looseScore(user) + bsc;
    }

    /// @notice `user`'s locked units, including bootstrap units not yet settled. The migrator's output for the
    /// units locked when the migration opened vests over MigratorBase.VEST.
    function lockedUnitsOf(address user) external view returns (uint256) {
        (uint256 bu,,) = bootstrapOf(user);
        return pool.lockedUnits(user) + bu;
    }

    /// @notice What the migrator splits its output by: `user`'s units and locked units when the migration opened, and
    /// the total then. Until the user's snapshot is recorded (at their first withdrawal after opening), their live
    /// balances (bootstrap included) apply.
    function migrationUnitsOf(address user) external view returns (uint256 userUnits, uint256 locked, uint256 total) {
        total = pool.openTotalUnits();
        uint256 rec = pool.openUnitsOf(user);
        if (rec != 0) return (rec - 1, pool.openLockedOf(user), total);
        (uint256 bu,,) = bootstrapOf(user);
        return (pool.units(user) + bu, pool.lockedUnits(user) + bu, total);
    }

    /// @notice Whether every LP unit can be withdrawn (the pool's `unlocked`); the migrator reads it to free the
    /// locked parts of a migration that can no longer complete.
    function unlocked() external view returns (bool) {
        return pool.unlocked();
    }

    /// @notice `user`'s units that cannot be withdrawn now (all of them while the migration is open or the pause is in
    /// effect, until everything unlocks, and in the block of their latest deposit).
    function lockedOf(address user) external view returns (uint256) {
        if (pool.lastDepositBlock(user) == block.number) return unitsOf(user);
        if (pool.unlocked()) return 0;
        if (pool.migrationOpen() || pool.paused()) return unitsOf(user);
        (uint256 bu,,) = bootstrapOf(user);
        return pool.lockedUnits(user) + bu;
    }

    /// @notice ETH and SCORE that `n` units would withdraw now: their part of the position and of the LP
    /// compounding balances.
    function valueOfUnits(uint256 n) public view returns (uint256 eth, uint256 scoreAmt) {
        uint256 tu = pool.totalUnits();
        if (tu == 0) return (0, 0);
        (eth, scoreAmt) = valueOfLiquidity(n * pool.lpLiquidity() / tu);
        eth += FullMath.mulDiv(pool.compoundEth(), n, tu);
        scoreAmt += FullMath.mulDiv(pool.compoundScore(), n, tu);
    }

    /// @notice ETH and SCORE in `n` full-range liquidity at the pool's current price.
    function valueOfLiquidity(uint256 n) public view returns (uint256 eth, uint256 scoreAmt) {
        (uint160 sqrtP,,,) = pool.manager().getSlot0(poolId());
        if (sqrtP == 0) return (0, 0);
        eth = ScoreMath.amount0(sqrtP, SQRT_HI, uint128(n), false);
        scoreAmt = ScoreMath.amount1(SQRT_LO, sqrtP, uint128(n), false);
    }
}
