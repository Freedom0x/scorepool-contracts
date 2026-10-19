// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ScoreMath, IValueOf} from "./ScoreMath.sol";
import {PoolOps} from "./PoolOps.sol";

interface IScoreToken is IERC20 {
    function canReceive(address account) external view returns (bool);
    function wrap(uint256[] calldata ids, address to) external returns (uint256);
    function valueOf(uint256 id) external view returns (uint256);
}

interface ICreditsApproval {
    function transferFrom(address from, address to, uint256 id) external;
    function setApprovalForAll(address operator, bool approved) external;
}

interface IPoolLaunchOpen {
    function fund() external payable;
    function openPool() external;
}

/// POOL's burn (ERC20Burnable), for the farm POOL that can no longer stream to anyone.
interface IPoolTokenBurnable {
    function burn(uint256 amount) external;
}

/// The guard's active migrator, which receives week one's POOL at completion.
interface IGuardMigrator {
    function migrator() external view returns (address);
}

/// @title ScoreLiquidity
/// @notice SCORE/ETH full-range liquidity on Uniswap v4: a capped bootstrap, LP units (optionally locked for boosted
/// POOL emissions), compounding fees, and protocol-owned liquidity.
/// @dev Bootstrap: commitments open at `bootstrapOpenAt` (the contracts go live for review first; the guard can
/// bring the time forward until it passes). Until then the owner may change the minimum and the caps
/// (`setBootstrapLimits`), and until launch the owner or the price keeper keeps the launch price at the Credits
/// market (`setLaunchPrice`). Each commitment brings SCORE and/or Credits plus the ETH that matches them at the
/// launch price, plus a surcharge of `surchargeBps` on that ETH that seeds the POOL/ETH pool; excess ETH is
/// refunded. The SCORE side is capped in total and per wallet; a commit may exceed a cap by at most its largest
/// Credit, after which the cap is hard. Anyone can launch once `minEth` is committed and either `COMMIT_WINDOW`
/// (2 h) has passed since `bootstrapOpenAt` (the public open) or the SCORE cap is full (a full bootstrap launches at
/// once), but never in the same block as a commit, and only with a launch price set within `PRICE_FRESH`. The
/// minimum must be reached within `MIN_WINDOW` (6 h) of the open, or the bootstrap fails and commitments become
/// refundable. Launch initializes the pool at the launch price (the hook lets only this contract initialize it or
/// add liquidity), adds everything committed, forwards the accumulated surcharge to PoolLaunch and opens the
/// POOL/ETH pool.
///
/// Units are a pro-rata claim on `lpLiquidity` and on the LP compounding balances. Bootstrap units are locked until
/// `unlocked()`; units from later deposits are free unless their owner locks them. Once the guard opens the migration,
/// every unit is held in it until `unlocked()`, and the migrator pulls depositor liquidity in chunks; each unit keeps
/// its claim on what remains here plus its part of the migrator's output.
///
/// The POOL farm has three parts, all held here:
///  - pre-migration (`preMigAmount`): streams linearly from launch to `preMigEnd`, and stops early once the guard
///    reports the migration complete (`markMigrationComplete`); whatever it has not streamed by then is burned
///    (`burnUnemitted`). Every unit weighs 1; bootstrap units and units locked by their owner (cohort A) weigh
///    `boostBps` (3x) until the boost ends (`_boostEndA`: the early unlock, or the deadline).
///  - week one after the migration (`weekOneAmount`): handed to the active migrator when the migration completes,
///    for its farm on the real token's pool over the `WEEK_ONE` after completion.
///  - the reserve (`reserveAmount`): once the migration completes the owner may send it to a concentrated-liquidity
///    incentive (`routeReserve`) until `reserveDeadline()` (14 days after completion); otherwise it is burned
///    (`burnReserve`).
/// If the units unlock without the migration completing, week one and the reserve can be burned by anyone.
/// Each weight is tracked with its own tally, so the stream splits exactly by the weights active at each moment.
/// Bootstrap units also split the bootstrap allocation, claimable in full from launch (the POOL/ETH pool's
/// launch-period tax makes an early sale costly).
///
/// The guard (ScoreGuard) can schedule a pause, unlock every unit, open the migration (one way), and release
/// liquidity: depositor liquidity while the migration is open, or all protocol-owned liquidity.
///
/// Trading fees: `devFeeBps` of all of them accrues to the dev wallet. The rest is split pro rata between
/// `lpLiquidity` and `protocolLiquidity`; of each part, `COMPOUND_BPS` is compounded into that liquidity and the
/// rest is sent to the Burner. `harvest` (anyone) and every deposit and withdrawal collect the fees and, while the
/// price is within the band around the hook's block-open price, compound what fits at the pool's ratio; the remainder
/// waits, valued in the unit price at the hook's block-open price (not the spot price), so a trade cannot change
/// what it is worth to a deposit. Units cannot be withdrawn in the block of their owner's latest deposit, so liquidity
/// cannot be added just before a trade and removed just after it in the same block. Payouts can be sent to another
/// address (`to`), so an account that cannot take ETH or SCORE can still exit.
/// @custom:disclaimer Experimental software, not audited by an independent security firm. You may lose everything
/// you commit.
contract ScoreLiquidity is IUnlockCallback, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    int24 private constant TICK_SPACING = 200;
    /// @notice Maximum distance of the price from the hook's block-open price for compounding and for a migration
    /// pull, in bps of sqrtPrice (about twice that in price).
    uint256 public constant BAND_SQRT_BPS = 50;
    /// @notice Part of each owner's fees (after the dev wallet's) compounded; the rest goes to the Burner.
    uint256 public constant COMPOUND_BPS = 5_000;
    uint256 private constant ACC = 1e18;
    uint256 private constant BPS = 10_000;
    uint256 private constant MAX_BOOST_BPS = 100_000; // 10x
    /// @notice Launch liquidity that backs no units (as Uniswap v2's MINIMUM_LIQUIDITY), so the unit supply can
    /// never approach zero and rounding cannot be used to inflate the unit price.
    uint256 public constant DEAD_UNITS = 1_000;
    /// @notice Every unit unlocks this long after the migration opens, whatever its outcome.
    uint256 public constant MIGRATION_BACKSTOP = 3 days;
    /// @notice Week one (the migrator's farm, which the pool funds at completion) runs this long from the migration's
    /// completion.
    uint256 public constant WEEK_ONE = 7 days;
    /// @notice The owner may route the reserve until this long after the migration's completion (week two).
    uint256 public constant RESERVE_WINDOW = 14 days;
    /// @notice Anyone can launch once this commit window has passed since `bootstrapOpenAt` (the public open) and
    /// the minimum is in, or immediately once the SCORE cap is full.
    uint256 public constant COMMIT_WINDOW = 2 hours;
    /// @notice Launch needs the launch price set within this long (see `setLaunchPrice`).
    uint256 public constant PRICE_FRESH = 15 minutes;
    /// @notice The most one `setLaunchPrice` can move the price, in bps of it.
    uint256 public constant MAX_PRICE_STEP_BPS = 1_000;
    /// @notice The minimum must be reached within this window of `bootstrapOpenAt`, or the bootstrap fails and
    /// commitments become refundable (`bootstrapFailed`). Once the minimum is in, only the deadline fails it.
    uint256 public constant MIN_WINDOW = 6 hours;

    struct Config {
        address owner;
        IPoolManager manager;
        IScoreToken score;
        ICreditsApproval credits;
        IERC20 poolToken;
        address burner;
        IHooks hook;
        address devWallet;
        uint256 launchPrice;
        uint256 minLaunchPrice;
        uint256 maxLaunchPrice;
        uint256 minEth;
        uint256 capEth;
        uint256 walletCapEth;
        uint256 deadline;
        address guard;
        uint256 bootstrapAllocation;
        uint256 preMigAmount;
        uint256 weekOneAmount;
        uint256 reserveAmount;
        uint64 preMigEnd;
        uint256 boostBps;
        uint256 devFeeBps;
        uint256 surchargeBps;
        uint64 bootstrapOpenAt;
    }

    IPoolManager public immutable manager;
    IScoreToken public immutable score;
    ICreditsApproval public immutable credits;
    IERC20 public immutable poolToken;
    /// @notice Receives the fees not compounded or owed to the dev wallet.
    address public immutable burner;
    IHooks public immutable hook;
    /// @notice SCORE per ETH at launch (both 18 decimals). Until launch the owner or the price keeper keeps it at the
    /// Credits market (`setLaunchPrice`); commits pair at the price of their time, and all of them settle at the price
    /// the pool launches at: the scarcer side all goes in and each commit gets the same fraction of the other back.
    uint256 public launchPrice;
    /// @notice The band `launchPrice` stays within, fixed at deploy.
    uint256 public immutable minLaunchPrice;
    uint256 public immutable maxLaunchPrice;
    /// @notice May set the launch price (as may the owner), nothing else.
    address public priceKeeper;
    /// @notice When the launch price was last set (deploy, at first).
    uint64 public priceUpdatedAt;
    /// @notice The bootstrap's minimum, total cap and per-wallet cap, in ETH; the owner can change them until the
    /// bootstrap opens (`setBootstrapLimits`).
    uint256 public minEth;
    uint256 public capEth;
    uint256 public walletCapEth;
    /// @notice Launch must happen before this. If the migration has not opened, every unit unlocks here.
    /// ScoreGuard's rescue cannot be proposed before it.
    uint256 public immutable deadline;
    /// @notice ScoreGuard: pause, early unlock, migration and liquidity release.
    address public immutable guard;
    /// @notice POOL distributed to bootstrap units, claimable in full from launch.
    uint256 public immutable bootstrapAllocation;
    /// @notice The farm's three parts (see the contract notes): the pre-migration stream, week one's farm (funded to
    /// the migrator at completion), and the reserve.
    uint256 public immutable preMigAmount;
    uint256 public immutable weekOneAmount;
    uint256 public immutable reserveAmount;
    /// @notice When the pre-migration stream ends at the latest (it ends sooner if the migration completes first).
    uint64 public immutable preMigEnd;
    uint256 public immutable boostBps;
    /// @notice Surcharge on each bootstrap commit's paired ETH, in bps; accumulated in `poolSeedEth` and forwarded
    /// to PoolLaunch at launch to seed the POOL/ETH pool. Does not count toward the caps.
    uint256 public immutable surchargeBps;
    /// @notice Dev wallet part of all trading fees, in bps. Can only be lowered.
    uint256 public devFeeBps;
    address public devWallet;

    // --- lifecycle ---
    bool public launched;
    bool public live;
    uint64 public launchedAt;
    uint64 public liveAt;

    // --- farm ---
    /// @notice When the guard reported the migration complete (the leftover Credits topped up and all the SCORE/ETH
    /// liquidity moved to the real token); 0 until then. The pre-migration stream stops here if it is earlier than
    /// `preMigEnd`.
    uint64 public migrationCompletedAt;
    /// @notice Whether the pre-migration stream's unstreamed part has been burned, and whether week one's part has
    /// been handed to the migrator or burned.
    bool public preMigBurned;
    bool public weekOneSettled;
    /// @notice Whether the reserve has been routed or burned.
    bool public reserveSettled;

    // --- bootstrap ---
    mapping(address => uint256) public bootEth;
    mapping(address => uint256) public bootScore;
    /// @notice Surcharge the wallet has paid on its commits (returned with the rest by `refund`).
    mapping(address => uint256) public bootSurcharge;
    /// @notice Credits the wallet has committed, so `refund` can keep the `bootCredits` aggregate in step.
    mapping(address => uint256) public bootCreditsOf;
    mapping(address => bool) public bootSettled;
    uint256 public bootEthTotal;
    uint256 public bootScoreTotal;
    /// @notice Total surcharge accumulated across all commits; forwarded to PoolLaunch at launch.
    uint256 public poolSeedEth;
    uint256 public usedEth;
    uint256 public usedScore;
    uint128 public bootLiquidity;
    /// @notice Credits committed to the bootstrap.
    uint256 public bootCredits;
    /// @notice When bootstrap commits open (0 = not set yet, so commits are closed). The guard can bring it forward
    /// until it passes; before it, `deposit` reverts `NotOpenYet`.
    uint64 public bootstrapOpenAt;
    /// @notice The block of the most recent bootstrap commit. `launch` must happen in a strictly later block, so a
    /// deposit and the trading-enabling launch can never share a block (no atomic deposit -> launch -> trade).
    uint256 public lastCommitBlock;

    // --- set by the guard ---
    /// @notice Start of the scheduled pause (0 if none); see `paused()`.
    uint64 public pauseAt;
    bool public earlyUnlocked;
    /// @notice Set once by the guard: every unit is held in the migration until `unlocked()`.
    bool public migrationOpen;
    uint64 public migrationOpenedAt;
    /// @notice Unit snapshot at migration open, by which the migrator splits its output (read through
    /// ScoreLens.migrationUnitsOf). Per-user values are recorded at the user's first withdrawal after the migration
    /// opened, stored as units + 1 so that 0 means "not recorded" (the live balances still apply).
    uint256 public openTotalUnits;
    mapping(address => uint256) public openUnitsOf;
    mapping(address => uint256) public openLockedOf;
    /// @notice When the guard's early unlock happened (0 if it has not).
    uint64 public earlyUnlockedAt;

    // --- liquidity ---
    /// @notice Liquidity owned by the units; grows with compounded fees.
    uint256 public lpLiquidity;
    /// @notice Protocol-owned liquidity, backing no units. Only the guard can release it.
    uint256 public protocolLiquidity;
    /// @notice Fees awaiting compounding, for the units and for the protocol.
    uint256 public compoundEth;
    uint256 public compoundScore;
    uint256 public polCompoundEth;
    uint256 public polCompoundScore;
    /// @notice Fees owed to the dev wallet, paid by `claimDevFees`. Pull-based, so the dev wallet cannot block a harvest.
    uint256 public devOwedEth;
    uint256 public devOwedScore;

    // --- units, stream, bootstrap allocation ---
    mapping(address => uint256) public units;
    mapping(address => uint256) public lockedUnits;
    /// @notice Block of each user's latest deposit after launch; their units cannot be withdrawn in that block.
    mapping(address => uint256) public lastDepositBlock;
    uint256 public totalUnits;
    /// @notice Pre-migration POOL per unit of weight streamed so far (scaled by 1e18), over every weight active at
    /// the time.
    uint256 public accPerWeight;
    /// @notice Cohort A's boost weight, per user and in total (totals include unsettled bootstrap and dead units).
    mapping(address => uint256) public boostA;
    uint256 public totalBoostA;
    /// @notice accPerWeight when cohort A's boost ended, once it has.
    uint256 public accEndA;
    bool public boostAEnded;
    mapping(address => uint256) public emitDebt;
    mapping(address => uint256) public rewardOwed;
    uint256 public lastAccrue;
    /// @notice Bootstrap units per wallet, fixed at settlement; the bootstrap allocation is split by these.
    mapping(address => uint256) public bootUnits;
    mapping(address => uint256) public bootstrapAllocationPaid;

    /// @notice Bootstrap commitment not used by the position, paid out by `claimRemainder`.
    mapping(address => uint256) public looseEth;
    mapping(address => uint256) public looseScore;

    PoolKey private poolKey;
    address public poolLaunch;

    event Committed(address indexed user, uint256 eth, uint256 score);
    event Launched(uint256 eth, uint256 score, uint128 liquidity);
    event Deposited(address indexed user, uint256 eth, uint256 score, uint256 unitsOut);
    event LockedUnits(address indexed user, uint256 unitsIn);
    event ProtocolLiquidityAdded(address indexed from, uint256 eth, uint256 score, uint128 liquidity);
    event Withdrawn(address indexed user, uint256 unitsIn, uint256 eth, uint256 score);
    event BootstrapSettled(address indexed user, uint256 unitsOut, uint256 ethBack, uint256 scoreBack);
    event RewardPaid(address indexed user, uint256 amount);
    event FeesSplit(uint256 eth, uint256 score, uint256 toBurnEth, uint256 toBurnScore);
    event Compounded(uint128 lpLiquidity, uint128 protocolLiquidity);
    event DevFeesClaimed(address indexed devWallet, uint256 eth, uint256 score);
    event DevFeeLowered(uint256 bps);
    event DevWalletSet(address devWallet);
    event RealTokenLive();
    event GuardState(uint256 pauseAt, bool earlyUnlocked, bool migrationOpen);
    event LiquidityReleased(address indexed to, bool fromUnits, uint256 eth, uint256 score);
    event MigrationCompleted(uint256 at);
    event WeekOneFunded(address indexed migrator, uint256 amount);
    event FarmBurned(uint256 preMig, uint256 weekOne);
    event ReserveRouted(address indexed to, uint256 amount);
    event ReserveBurned(uint256 amount);
    event LaunchPriceSet(uint256 price);
    event BootstrapLimitsSet(uint256 minEth, uint256 capEth, uint256 walletCapEth);
    event PriceKeeperSet(address keeper);

    error NotLaunched();
    error AlreadyLaunched();
    error DepositsClosed();
    error BelowMinimum();
    error Unpaired();
    error CapReached();
    error WalletCapReached();
    error BadConfig();
    error NotWired();
    error Locked();
    error Unfunded();
    error Slippage();
    error NotManager();
    error Nothing();
    error Insufficient();
    error TransferFailed();
    error OnlyLower();
    error Paused();
    error NotGuard();
    error MigrationOpen();
    error TooEarly();
    error NotOpenYet();
    error SameBlockAsDeposit();
    error CommitThisBlock();
    error CannotReceiveScore();
    error BadPrice();
    error StalePrice();
    error NotKeeper();
    error StreamEnded();

    modifier onlyGuard() {
        if (msg.sender != guard) revert NotGuard();
        _;
    }

    constructor(Config memory c) Ownable(c.owner) {
        // surchargeBps == 0 would leave poolSeedEth at 0, so launch forwards no ETH and PoolLaunch.openPool reverts
        // Unfunded, bricking the launch; reject it here.
        if (c.boostBps < BPS || c.boostBps > MAX_BOOST_BPS || c.devFeeBps > BPS || c.surchargeBps == 0 || c.surchargeBps > BPS) revert BadConfig();
        _checkLimits(c.minEth, c.capEth, c.walletCapEth);
        if (c.minLaunchPrice == 0 || c.launchPrice < c.minLaunchPrice || c.launchPrice > c.maxLaunchPrice) revert BadConfig();
        if (c.maxLaunchPrice >= 1 << 64 || c.deadline <= block.timestamp) revert BadConfig();
        if (c.guard == address(0) || c.burner == address(0) || c.devWallet == address(0)) revert BadConfig();
        manager = c.manager;
        score = c.score;
        credits = c.credits;
        poolToken = c.poolToken;
        burner = c.burner;
        hook = c.hook;
        devWallet = c.devWallet;
        launchPrice = c.launchPrice;
        minLaunchPrice = c.minLaunchPrice;
        maxLaunchPrice = c.maxLaunchPrice;
        priceUpdatedAt = uint64(block.timestamp);
        minEth = c.minEth;
        capEth = c.capEth;
        walletCapEth = c.walletCapEth;
        deadline = c.deadline;
        guard = c.guard;
        bootstrapAllocation = c.bootstrapAllocation;
        preMigAmount = c.preMigAmount;
        weekOneAmount = c.weekOneAmount;
        reserveAmount = c.reserveAmount;
        preMigEnd = c.preMigEnd;
        boostBps = c.boostBps;
        devFeeBps = c.devFeeBps;
        surchargeBps = c.surchargeBps;
        bootstrapOpenAt = c.bootstrapOpenAt;
        poolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(c.score)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG, // set per swap by the hook
            tickSpacing: TICK_SPACING,
            hooks: c.hook
        });
        c.credits.setApprovalForAll(address(c.score), true);
    }

    receive() external payable {
        if (msg.sender != address(manager)) revert NotManager();
    }

    // --- bootstrap ---

    /// @notice Deposits SCORE and/or Credits with ETH (msg.value). Credits require setApprovalForAll(this).
    /// @dev Before launch this is a bootstrap commitment: it takes `ethRequired` of the ETH, refunds the rest and
    /// mints no units. Commitments are final; they settle into locked bootstrap units at launch, or are returned by
    /// `refund` if the bootstrap cannot launch. After launch, fees are harvested and compounded first, then
    /// both sides are added at the pool's ratio and the unused remainder is refunded.
    /// @param scoreIn SCORE to pull from the caller.
    /// @param ids Credits to pull from the caller and wrap.
    /// @param minUnits Minimum units out (after launch).
    /// @param lock Whether to lock the new units for boosted emissions.
    /// @return unitsOut Units minted (0 for a bootstrap commitment).
    function deposit(uint256 scoreIn, uint256[] calldata ids, uint256 minUnits, bool lock)
        external
        payable
        nonReentrant
        returns (uint256 unitsOut)
    {
        if (paused() || migrationOpen) revert Paused();
        if (live || bootstrapFailed()) revert DepositsClosed();
        if (!score.canReceive(msg.sender)) revert CannotReceiveScore(); // refunds and exits pay SCORE
        uint256 scoreAmt = _pullScore(scoreIn, ids);
        if (msg.value == 0 || scoreAmt == 0) revert Unpaired();

        if (!launched) {
            if (bootstrapOpenAt == 0 || block.timestamp < bootstrapOpenAt) revert NotOpenYet();
            uint256 need = _ethRequired(scoreAmt);
            uint256 surcharge = need * surchargeBps / BPS;
            if (msg.value < need + surcharge) revert Unpaired();
            ScoreMath.checkCaps(
                IValueOf(address(score)),
                ids,
                bootScoreTotal + scoreAmt,
                bootScore[msg.sender] + scoreAmt,
                capEth * launchPrice,
                walletCapEth * launchPrice
            );
            bootEth[msg.sender] += need;
            bootSurcharge[msg.sender] += surcharge;
            bootScore[msg.sender] += scoreAmt;
            bootEthTotal += need;
            poolSeedEth += surcharge;
            bootScoreTotal += scoreAmt;
            bootCredits += ids.length;
            bootCreditsOf[msg.sender] += ids.length;
            lastCommitBlock = block.number; // launch must be a later block (no same-block deposit -> launch -> trade)
            emit Committed(msg.sender, need, scoreAmt);
            // the surcharge does not count toward the caps; only `need` is paired and refundable as a commitment
            if (msg.value > need + surcharge) _send(msg.sender, msg.value - need - surcharge, 0);
            return 0;
        }

        _touch(msg.sender);
        (uint256 out, uint256 ethBack, uint256 scoreBack) =
            abi.decode(_run(PoolOps.Op.Deposit, abi.encode(msg.value, scoreAmt)), (uint256, uint256, uint256));
        unitsOut = out;
        if (unitsOut == 0 || unitsOut < minUnits) revert Slippage();
        units[msg.sender] += unitsOut;
        lastDepositBlock[msg.sender] = block.number;
        if (lock) {
            if (unlocked()) revert DepositsClosed(); // no boost for a lock that holds nothing
            lockedUnits[msg.sender] += unitsOut;
            emit LockedUnits(msg.sender, unitsOut);
        }
        _sync(msg.sender);
        _send(msg.sender, ethBack, scoreBack);
        emit Deposited(msg.sender, msg.value - ethBack, scoreAmt - scoreBack, unitsOut);
    }

    /// @dev ETH required to commit `scoreAmt` SCORE to the bootstrap: its value at the launch price, rounded up.
    /// ScoreLens exposes the public `ethRequired`.
    function _ethRequired(uint256 scoreAmt) private view returns (uint256) {
        return Math.ceilDiv(scoreAmt, launchPrice);
    }

    /// @notice Whether the bootstrap has failed, so commitments are refundable and new ones are refused: the minimum
    /// was not reached within `MIN_WINDOW` (6 h) of the public open, or the absolute deadline has passed. Once the
    /// minimum is in, only the deadline fails it. False once launched.
    function bootstrapFailed() public view returns (bool) {
        if (launched || bootstrapOpenAt == 0) return false;
        return (block.timestamp >= uint256(bootstrapOpenAt) + MIN_WINDOW && bootEthTotal < minEth)
            || block.timestamp >= deadline;
    }

    /// @notice Returns the caller's whole bootstrap commitment, both sides, to `to`, once the bootstrap cannot launch:
    /// it has failed (`bootstrapFailed`), or the real token went live, before launch.
    function refund(address to) external nonReentrant {
        if (to == address(0)) revert BadConfig();
        if (launched || !(bootstrapFailed() || live)) revert AlreadyLaunched();
        uint256 e = bootEth[msg.sender];
        uint256 sc = bootScore[msg.sender];
        uint256 su = bootSurcharge[msg.sender];
        if (e == 0 && sc == 0) revert Nothing();
        uint256 cr = bootCreditsOf[msg.sender];
        bootEth[msg.sender] = 0;
        bootScore[msg.sender] = 0;
        bootSurcharge[msg.sender] = 0;
        bootCreditsOf[msg.sender] = 0;
        // keep the aggregates in step with the zeroed per-user entries (each total is the sum of its per-user values,
        // so these never underflow)
        bootEthTotal -= e;
        bootScoreTotal -= sc;
        poolSeedEth -= su;
        bootCredits -= cr;
        _send(to, e + su, sc); // the paired ETH and its surcharge both come back
    }

    /// @dev Launch trigger: the SCORE cap is full, so a full bootstrap launches at once anytime, OR the minimum is
    /// in and `COMMIT_WINDOW` (2 h) has passed since `bootstrapOpenAt` (the public open) — a fixed offset from the
    /// open, so the minimum reached late (but before failure) launches as soon as it is reached. Any Credits that do
    /// not fill a whole Statement simply stay in the SCORE vault as loose Credits.
    function _launchTriggerMet() private view returns (bool) {
        if (bootScoreTotal >= capEth * launchPrice) return true; // cap full: no wait
        return bootEthTotal >= minEth && block.timestamp >= uint256(bootstrapOpenAt) + COMMIT_WINDOW;
    }

    /// @notice The pool's opening sqrt price (Q64.96) at the current launch price.
    function launchSqrtPriceX96() public view returns (uint160) {
        return uint160(Math.sqrt(launchPrice << 192));
    }

    /// @notice Owner, until the bootstrap opens: sets its minimum, total cap and per-wallet cap, in ETH.
    function setBootstrapLimits(uint256 minEth_, uint256 capEth_, uint256 walletCapEth_) external onlyOwner {
        if (launched || (bootstrapOpenAt != 0 && block.timestamp >= bootstrapOpenAt)) revert BadConfig();
        _checkLimits(minEth_, capEth_, walletCapEth_);
        minEth = minEth_;
        capEth = capEth_;
        walletCapEth = walletCapEth_;
        emit BootstrapLimitsSet(minEth_, capEth_, walletCapEth_);
    }

    function _checkLimits(uint256 minEth_, uint256 capEth_, uint256 walletCapEth_) private pure {
        if (minEth_ == 0 || capEth_ < minEth_ || walletCapEth_ == 0 || walletCapEth_ > capEth_) revert BelowMinimum();
    }

    /// @notice Owner: sets the price keeper (0 to remove it).
    function setPriceKeeper(address keeper) external onlyOwner {
        priceKeeper = keeper;
        emit PriceKeeperSet(keeper);
    }

    /// @notice Owner or price keeper, until launch: moves the launch price by at most `MAX_PRICE_STEP_BPS`, within
    /// the deploy-time band, once per block.
    function setLaunchPrice(uint256 price) external {
        if (msg.sender != owner() && msg.sender != priceKeeper) revert NotKeeper();
        if (launched || live || bootstrapFailed()) revert AlreadyLaunched();
        uint256 p = launchPrice;
        if (
            block.timestamp == priceUpdatedAt || price < minLaunchPrice || price > maxLaunchPrice
                || price * BPS > p * (BPS + MAX_PRICE_STEP_BPS) || price * BPS < p * (BPS - MAX_PRICE_STEP_BPS)
        ) revert BadPrice();
        launchPrice = price;
        priceUpdatedAt = uint64(block.timestamp);
        emit LaunchPriceSet(price);
    }

    /// @notice Initializes the pool at the launch price, adds the committed liquidity and opens the POOL/ETH pool.
    /// Callable by anyone once the launch conditions hold, with a launch price set within `PRICE_FRESH`, and only
    /// before `preMigEnd` (the pre-migration stream would have nothing left to stream). A bootstrap past that time
    /// that has not launched stays committed until `deadline`, when it becomes refundable (`bootstrapFailed`).
    function launch() external nonReentrant {
        if (launched || live || block.timestamp >= deadline) revert AlreadyLaunched();
        if (block.timestamp >= preMigEnd) revert StreamEnded();
        if (paused() || migrationOpen) revert Paused();
        if (bootEthTotal < minEth) revert BelowMinimum();
        if (!_launchTriggerMet()) revert TooEarly();
        if (block.number <= lastCommitBlock) revert CommitThisBlock(); // never in a commit's block
        if (poolLaunch == address(0)) revert NotWired();
        if (poolToken.balanceOf(address(this)) < bootstrapAllocation + farmTotal()) revert Unfunded();
        // Only this contract can initialize a pool on the hook, so the pool cannot already exist at another price.
        if (block.timestamp > uint256(priceUpdatedAt) + PRICE_FRESH) revert StalePrice();
        manager.initialize(poolKey, launchSqrtPriceX96());
        uint256 ethIn = Math.min(bootEthTotal, bootScoreTotal / launchPrice);
        (uint128 liq, uint256 e, uint256 s) =
            abi.decode(_run(PoolOps.Op.Launch, abi.encode(ethIn, ethIn * launchPrice)), (uint128, uint256, uint256));
        usedEth = e;
        usedScore = s;
        if (liq <= DEAD_UNITS) revert BelowMinimum();
        bootLiquidity = liq;
        totalUnits = liq;
        lpLiquidity = liq;
        totalBoostA = uint256(liq) * (boostBps - BPS) / BPS;
        launched = true;
        launchedAt = uint64(block.timestamp);
        lastAccrue = block.timestamp;
        emit Launched(e, s, liq);
        // seed the POOL/ETH pool with the accumulated surcharge, then open it
        IPoolLaunchOpen(poolLaunch).fund{value: poolSeedEth}();
        IPoolLaunchOpen(poolLaunch).openPool();
    }

    // --- units ---

    /// @notice Whether every unit can be withdrawn: after the guard's early unlock; at the deadline if the migration
    /// never opened; otherwise `MIGRATION_BACKSTOP` after it opened.
    function unlocked() public view returns (bool) {
        if (earlyUnlocked) return true;
        if (!migrationOpen) return block.timestamp >= deadline;
        return block.timestamp >= uint256(migrationOpenedAt) + MIGRATION_BACKSTOP;
    }

    /// @notice Claims the caller's accrued POOL emissions and the bootstrap allocation not yet paid to them, paid to
    /// `to`.
    /// @return amount POOL paid.
    function getReward(address to) external nonReentrant returns (uint256 amount) {
        if (to == address(0)) revert BadConfig();
        if (!launched) revert NotLaunched();
        _touch(msg.sender);
        amount = rewardOwed[msg.sender];
        rewardOwed[msg.sender] = 0;
        uint256 vested = _bootstrapVested(bootUnits[msg.sender]);
        amount += vested - bootstrapAllocationPaid[msg.sender];
        bootstrapAllocationPaid[msg.sender] = vested;
        if (amount != 0) poolToken.safeTransfer(to, amount);
        emit RewardPaid(msg.sender, amount);
    }

    /// @notice Pays out the caller's bootstrap remainder, to `to`: the part of their commitment the position did not
    /// use.
    function claimRemainder(address to) external nonReentrant {
        if (to == address(0)) revert BadConfig();
        if (launched) _touch(msg.sender);
        uint256 e = looseEth[msg.sender];
        uint256 s = looseScore[msg.sender];
        looseEth[msg.sender] = 0;
        looseScore[msg.sender] = 0;
        _send(to, e, s);
    }

    /// @notice Burns `unitsIn` of the caller's units for ETH and SCORE, paid to `to`, after harvesting and
    /// compounding.
    /// @dev Not in the block of the caller's latest deposit. Before `unlocked()`, only free units can be withdrawn,
    /// and not while paused or while the migration is open. Once unlocked, the caller's locked units are released.
    /// @return ethOut ETH paid.
    /// @return scoreOut SCORE paid.
    function withdraw(uint256 unitsIn, uint256 minEthOut, uint256 minScoreOut, address to)
        external
        nonReentrant
        returns (uint256 ethOut, uint256 scoreOut)
    {
        if (to == address(0)) revert BadConfig();
        if (lastDepositBlock[msg.sender] == block.number) revert SameBlockAsDeposit();
        _touch(msg.sender);
        _snapshot(msg.sender);
        uint256 have = units[msg.sender];
        if (unitsIn == 0 || unitsIn > have) revert Insufficient();
        if (!unlocked()) {
            if (paused() || migrationOpen || unitsIn > have - lockedUnits[msg.sender]) revert Locked();
        } else if (lockedUnits[msg.sender] != 0) {
            lockedUnits[msg.sender] = 0;
        }
        units[msg.sender] -= unitsIn;
        _sync(msg.sender);
        // The units' part of the position plus the same fraction of the LP compounding balances.
        (ethOut, scoreOut) = abi.decode(_run(PoolOps.Op.Withdraw, abi.encode(unitsIn)), (uint256, uint256));
        if (ethOut < minEthOut || scoreOut < minScoreOut) revert Slippage();
        _send(to, ethOut, scoreOut);
        emit Withdrawn(msg.sender, unitsIn, ethOut, scoreOut);
    }

    /// @notice Locks `unitsIn` of the caller's free units until `unlocked()`, for boosted emissions (cohort A) from
    /// this point. Irreversible. Not once the real token is live or the migration is open.
    function lockUnits(uint256 unitsIn) external nonReentrant {
        if (!launched) revert NotLaunched();
        if (paused() || unlocked() || live || migrationOpen) revert DepositsClosed();
        _touch(msg.sender);
        if (unitsIn == 0 || unitsIn > units[msg.sender] - lockedUnits[msg.sender]) revert Insufficient();
        lockedUnits[msg.sender] += unitsIn;
        _sync(msg.sender);
        emit LockedUnits(msg.sender, unitsIn);
    }

    // --- fees ---

    /// @notice Collects the position's fees, splits them and compounds what fits at the pool's ratio. Callable by
    /// anyone.
    function harvest() external nonReentrant {
        if (!launched) revert NotLaunched();
        _run(PoolOps.Op.Harvest, "");
    }

    /// @notice Adds msg.value ETH and `scoreIn` SCORE as protocol-owned liquidity (no units). The part that does not
    /// fit the pool's ratio is returned.
    /// @return liquidity Liquidity added.
    /// @return ethBack ETH returned.
    /// @return scoreBack SCORE returned.
    function addProtocolLiquidity(uint256 scoreIn)
        external
        payable
        nonReentrant
        returns (uint128 liquidity, uint256 ethBack, uint256 scoreBack)
    {
        if (!launched) revert NotLaunched();
        if (msg.value == 0 || scoreIn == 0) revert Unpaired();
        IERC20(address(score)).safeTransferFrom(msg.sender, address(this), scoreIn);
        (liquidity, ethBack, scoreBack) =
            abi.decode(_run(PoolOps.Op.AddProtocol, abi.encode(msg.value, scoreIn)), (uint128, uint256, uint256));
        _send(msg.sender, ethBack, scoreBack);
        emit ProtocolLiquidityAdded(msg.sender, msg.value - ethBack, scoreIn - scoreBack, liquidity);
    }

    /// @notice Pays the dev wallet its accrued fee part. Callable by anyone.
    /// @dev Best-effort per side: a dev wallet that cannot take a side (reverting ETH receiver, or not an allowed SCORE
    /// receiver) keeps that side owed for a later claim rather than reverting, so the pull can never be blocked. The
    /// fees stay safe in the contract meanwhile.
    function claimDevFees() external nonReentrant {
        address t = devWallet;
        uint256 e = devOwedEth;
        uint256 s = devOwedScore;
        devOwedEth = 0;
        devOwedScore = 0;
        if (s != 0) {
            (bool ok, bytes memory ret) = address(score).call(abi.encodeCall(IERC20.transfer, (t, s)));
            if (!(ok && (ret.length == 0 || abi.decode(ret, (bool))))) {
                devOwedScore = s; // the devWallet could not take the SCORE: keep it owed
                s = 0;
            }
        }
        if (e != 0) {
            (bool ok,) = t.call{value: e}("");
            if (!ok) {
                devOwedEth = e; // the devWallet could not take the ETH: keep it owed
                e = 0;
            }
        }
        emit DevFeesClaimed(t, e, s); // the amounts actually paid this call
    }

    // --- owner ---

    /// @notice Permanently lowers the dev wallet's fee part (0 removes it). The difference stays with the owners.
    /// Once launched, the position's fees are harvested first, so fees earned before the change split at the old part.
    function lowerDevFee(uint256 bps) external onlyOwner nonReentrant {
        if (bps >= devFeeBps) revert OnlyLower();
        if (launched) _run(PoolOps.Op.Harvest, "");
        devFeeBps = bps;
        emit DevFeeLowered(bps);
    }

    /// @notice Owner only: sets the dev wallet.
    function setDevWallet(address devWallet_) external onlyOwner {
        if (devWallet_ == address(0)) revert BadConfig();
        devWallet = devWallet_;
        emit DevWalletSet(devWallet_);
    }

    /// @notice Sets, once and before launch, the PoolLaunch whose POOL/ETH pool opens at launch.
    function setPoolLaunch(address poolLaunch_) external onlyOwner {
        if (poolLaunch != address(0) || poolLaunch_ == address(0) || launched) revert BadConfig();
        poolLaunch = poolLaunch_;
    }

    /// @notice Marks the real token as trading, once. Deposits and locking close, and an unlaunched bootstrap becomes
    /// refundable. The POOL stream runs on to its end.
    function markRealTokenLive() external onlyOwner {
        if (live) revert AlreadyLaunched();
        live = true;
        liveAt = uint64(block.timestamp);
        emit RealTokenLive();
    }

    // --- farm ---

    /// @notice Guard only (reported by the active migrator), once, while the migration is open: the migration is
    /// complete (the leftover Credits topped up and all the SCORE/ETH liquidity moved to the real token). The
    /// pre-migration stream stops now if it has not ended, what it had not streamed is burned, and week one's POOL
    /// goes to the active migrator for its week-one farm (the migrator must be allowed to receive POOL).
    function markMigrationComplete() external onlyGuard nonReentrant {
        // not once unlocked: by then week one and the reserve may already have been burned as never-completed
        if (!migrationOpen || migrationCompletedAt != 0 || unlocked()) revert BadConfig();
        _accrue(); // the pre-migration stream up to now, over the weights that earned it
        migrationCompletedAt = uint64(block.timestamp);
        weekOneSettled = true;
        emit MigrationCompleted(block.timestamp);
        _burnUnemitted();
        address m = IGuardMigrator(guard).migrator();
        if (weekOneAmount != 0) poolToken.safeTransfer(m, weekOneAmount);
        emit WeekOneFunded(m, weekOneAmount);
    }

    /// @notice Callable by anyone: burns the farm POOL that can no longer stream to anyone: the pre-migration part
    /// not streamed by the time that stream ended, and all of week one's part if the units unlocked without the
    /// migration completing.
    function burnUnemitted() external nonReentrant {
        if (!launched) revert NotLaunched();
        _accrue();
        if (_burnUnemitted() == 0) revert Nothing();
    }

    function _burnUnemitted() private returns (uint256 n) {
        uint256 a;
        uint256 b;
        uint256 e1 = phase1End();
        if (!preMigBurned && block.timestamp >= e1) {
            preMigBurned = true;
            a = preMigAmount - ScoreMath.linear(preMigAmount, e1, launchedAt, preMigEnd);
        }
        if (!weekOneSettled && unlocked()) {
            weekOneSettled = true; // only reachable without completion: completion settles it, and needs !unlocked()
            b = weekOneAmount;
        }
        n = a + b;
        if (n != 0) {
            IPoolTokenBurnable(address(poolToken)).burn(n);
            emit FarmBurned(a, b);
        }
    }

    /// @notice Owner only, once the migration has completed and before `reserveDeadline()`: sends the reserve to `to`
    /// (a concentrated-liquidity incentive). One way.
    function routeReserve(address to) external onlyOwner {
        if (reserveSettled || migrationCompletedAt == 0 || block.timestamp >= reserveDeadline() || to == address(0)) {
            revert BadConfig();
        }
        reserveSettled = true;
        poolToken.safeTransfer(to, reserveAmount);
        emit ReserveRouted(to, reserveAmount);
    }

    /// @notice Burns the reserve if it was not routed: by the owner once the migration has completed, by anyone from
    /// `reserveDeadline()`, or by anyone once the units have unlocked without the migration completing. One way.
    function burnReserve() external {
        if (reserveSettled) revert Nothing();
        uint256 d = reserveDeadline();
        bool open = d != 0 ? block.timestamp >= d || msg.sender == owner() : unlocked();
        if (!open) revert TooEarly();
        reserveSettled = true;
        if (reserveAmount != 0) IPoolTokenBurnable(address(poolToken)).burn(reserveAmount);
        emit ReserveBurned(reserveAmount);
    }

    // --- guard ---

    /// @notice Guard only: updates the pause, early unlock and migration state.
    /// @param pauseAt_ Start of the pause (0 lifts it). From then on bootstrap commits, deposits, locking, launch and
    /// withdrawals revert; trading continues. It does not block withdrawals once `unlocked()`.
    /// @param earlyUnlock_ Unlocks every unit now. One way.
    /// @param openMigration_ Opens the migration. One way; ignored before launch, once unlocked, or if already open.
    function setGuardState(uint64 pauseAt_, bool earlyUnlock_, bool openMigration_) external onlyGuard {
        _accrue(); // cohort A's end can move to now
        pauseAt = pauseAt_;
        if (earlyUnlock_ && !earlyUnlocked) {
            earlyUnlocked = true;
            earlyUnlockedAt = uint64(block.timestamp);
        }
        // Nothing to hold before launch or once unlocked; the SCORE vault's migration proceeds on its own.
        if (openMigration_ && launched && !unlocked() && !migrationOpen) {
            migrationOpen = true;
            migrationOpenedAt = uint64(block.timestamp);
            openTotalUnits = totalUnits;
        }
        emit GuardState(pauseAt_, earlyUnlocked, migrationOpen);
    }

    /// @notice Guard only: sets or brings forward the bootstrap's open time, only before the current one passes and
    /// before launch (so commits can be opened after the public review window, and never reclosed once open). The new
    /// time is now or later (0 keeps it closed), so the commit and minimum windows always run from a time not yet past.
    function setBootstrapOpenAt(uint64 at) external onlyGuard {
        if (launched || (bootstrapOpenAt != 0 && block.timestamp >= bootstrapOpenAt)) revert BadConfig();
        if (at != 0 && at < block.timestamp) revert BadConfig();
        bootstrapOpenAt = at;
    }

    /// @notice Whether the scheduled pause is in effect.
    function paused() public view returns (bool) {
        return pauseAt != 0 && block.timestamp >= pauseAt;
    }

    /// @notice Guard only: sends liquidity to `to`.
    /// @dev With `fromUnits` (only while the migration is open and before `unlocked()`): depositor liquidity worth
    /// `scoreWanted` SCORE at the current price, which must be within the band around the block's opening price, plus
    /// the same fraction of the LP compounding balances. Unit balances do not change; each unit keeps its claim on
    /// what remains here and on its part of the migrator's output. Without `fromUnits`: all protocol-owned liquidity
    /// and its compounding balances.
    /// @return e ETH sent.
    /// @return s SCORE sent.
    function releaseLiquidity(bool fromUnits, uint256 scoreWanted, address to)
        external
        onlyGuard
        nonReentrant
        returns (uint256 e, uint256 s)
    {
        if (!launched) return (0, 0);
        if (fromUnits && (!migrationOpen || unlocked())) revert MigrationOpen();
        (e, s) = abi.decode(_run(fromUnits ? PoolOps.Op.TakeUnits : PoolOps.Op.TakeProtocol, abi.encode(scoreWanted)), (uint256, uint256));
        _send(to, e, s);
        emit LiquidityReleased(to, fromUnits, e, s);
    }

    // --- views ---

    /// @notice The farm's POOL in all: the pre-migration stream, week one's farm, and the reserve.
    function farmTotal() public view returns (uint256) {
        return preMigAmount + weekOneAmount + reserveAmount;
    }

    /// @notice When the pre-migration stream ends: the migration's completion if earlier than `preMigEnd`, else
    /// `preMigEnd`.
    function phase1End() public view returns (uint256) {
        uint256 c = migrationCompletedAt;
        return c != 0 && c < preMigEnd ? c : preMigEnd;
    }

    /// @notice When week one's farm ends: `WEEK_ONE` after the migration's completion; 0 until it completes.
    function weekOneEndAt() public view returns (uint256) {
        uint256 c = migrationCompletedAt;
        return c == 0 ? 0 : c + WEEK_ONE;
    }

    /// @notice Until when the owner may route the reserve: `RESERVE_WINDOW` after the migration's completion; 0 until
    /// it completes.
    function reserveDeadline() public view returns (uint256) {
        uint256 c = migrationCompletedAt;
        return c == 0 ? 0 : c + RESERVE_WINDOW;
    }

    /// @notice Farm POOL still held here that has not streamed to anyone and has not been burned, handed to the
    /// migrator or routed: POOL that belongs to no one yet. The pre-migration stream counts as streamed on its
    /// schedule, and what has left this contract counts as streamed, so this never overstates what is held back.
    function unstreamed() external view returns (uint256 n) {
        uint256 t = block.timestamp;
        uint256 e1 = phase1End();
        if (!preMigBurned) {
            n += preMigAmount - (launched ? ScoreMath.linear(preMigAmount, t < e1 ? t : e1, launchedAt, preMigEnd) : 0);
        }
        if (!weekOneSettled) n += weekOneAmount;
        if (!reserveSettled) n += reserveAmount;
    }

    /// @dev Bootstrap units `user` receives at settlement, split by committed value at the launch price, and the
    /// unused ETH and SCORE returned. Used amounts round up, so refunds round down.
    function _bootstrapOf(address user) private view returns (uint256 unitsOut, uint256 ethBack, uint256 scoreBack) {
        if (!launched || bootSettled[user]) return (0, 0, 0);
        uint256 e = bootEth[user];
        uint256 s = bootScore[user];
        if (e == 0 && s == 0) return (0, 0, 0);
        return ScoreMath.bootstrapShare(
            e, s, usedEth, usedScore, bootEthTotal, bootScoreTotal, launchPrice, bootLiquidity
        );
    }

    // --- internals: users ---

    function _pullScore(uint256 scoreIn, uint256[] calldata ids) private returns (uint256 amount) {
        if (scoreIn != 0) {
            IERC20(address(score)).safeTransferFrom(msg.sender, address(this), scoreIn);
            amount = scoreIn;
        }
        if (ids.length != 0) {
            for (uint256 i; i < ids.length; ++i) {
                credits.transferFrom(msg.sender, address(this), ids[i]);
            }
            amount += score.wrap(ids, address(this));
        }
    }

    /// @dev The bootstrap allocation `bu` bootstrap units are due: their whole pro-rata part, from launch.
    function _bootstrapVested(uint256 bu) private view returns (uint256) {
        if (!launched || bootLiquidity == 0 || bu == 0) return 0;
        return FullMath.mulDiv(bootstrapAllocation, bu, bootLiquidity);
    }

    /// @dev When cohort A's boost ends: when locked units stop being held, as `unlocked()` has it. At the early unlock
    /// (or the deadline, if earlier); else, with the migration open, at `MIGRATION_BACKSTOP` after it opened (units
    /// are held until then, and the stream itself stops earlier at `preMigEnd` or the migration's completion); else at
    /// the deadline. ScoreLens exposes the public view (`ScoreLens.boostEndA`).
    function _boostEndA() private view returns (uint256) {
        if (earlyUnlocked) return Math.min(earlyUnlockedAt, deadline);
        if (migrationOpen) return uint256(migrationOpenedAt) + MIGRATION_BACKSTOP;
        return deadline;
    }

    /// @dev Accrues the pre-migration stream up to now (ScoreMath.accrue), split at cohort A's end, so each segment is
    /// shared by the weights active in it.
    function _accrue() private {
        if (!launched) return;
        uint256 last = lastAccrue;
        if (block.timestamp <= last) return;
        ScoreMath.Stream memory s = ScoreMath.accrue(
            ScoreMath.Stream(accPerWeight, accEndA, boostAEnded),
            ScoreMath.Params(
                last, block.timestamp, launchedAt, preMigEnd, phase1End(), _boostEndA(), totalUnits, totalBoostA, preMigAmount
            )
        );
        accPerWeight = s.acc;
        if (s.aEnded && !boostAEnded) {
            accEndA = s.accA;
            boostAEnded = true;
        }
        lastAccrue = block.timestamp;
    }

    /// @dev Everything `user` has earned by the last accrual, at their current weights: units at accPerWeight, and
    /// cohort A's boost at its tally (frozen at its end).
    function _earned(address user) private view returns (uint256) {
        uint256 acc = accPerWeight;
        return (units[user] * acc + boostA[user] * (boostAEnded ? accEndA : acc)) / ACC;
    }

    /// @dev Accrues the stream, settles the user's bootstrap if pending, and banks the user's accrued emissions.
    function _touch(address user) private {
        _accrue();
        if (!bootSettled[user]) {
            (uint256 bu, uint256 be, uint256 bsc) = _bootstrapOf(user);
            bootSettled[user] = true;
            if (bu != 0 || be != 0 || bsc != 0) {
                // Bootstrap units earn from launch: their weight has been in the totals since then, and the user
                // has no other weight before settlement, so the debt stays at zero.
                units[user] += bu;
                lockedUnits[user] += bu;
                bootUnits[user] = bu;
                boostA[user] += bu * (boostBps - BPS) / BPS;
                looseEth[user] += be;
                looseScore[user] += bsc;
                emit BootstrapSettled(user, bu, be, bsc);
            }
        }
        uint256 e = _earned(user);
        rewardOwed[user] += e - emitDebt[user];
        emitDebt[user] = e;
    }

    /// @dev Once the migration is open, records the user's units and locked units before their first change.
    function _snapshot(address user) private {
        if (migrationOpen && openUnitsOf[user] == 0) {
            openUnitsOf[user] = units[user] + 1;
            openLockedOf[user] = lockedUnits[user];
        }
    }

    /// @dev Recomputes the user's cohort A boost (units weigh themselves, in totalUnits). Call after `_touch` and a
    /// change to their units or locked units.
    function _sync(address user) private {
        uint256 a = lockedUnits[user] * (boostBps - BPS) / BPS;
        totalBoostA = totalBoostA - boostA[user] + a;
        boostA[user] = a;
        emitDebt[user] = _earned(user);
    }

    function _send(address to, uint256 eth, uint256 scoreAmt) private {
        if (scoreAmt != 0) IERC20(address(score)).safeTransfer(to, scoreAmt);
        if (eth != 0) {
            (bool ok,) = to.call{value: eth}("");
            if (!ok) revert TransferFailed();
        }
    }

    // --- internals: pool ---

    function _run(PoolOps.Op op, bytes memory args) private returns (bytes memory) {
        return manager.unlock(abi.encode(op, args));
    }

    /// @dev The v4 unlock callback. The position logic lives in PoolOps, delegatecalled so it runs in this
    /// contract's context. The pool's mutable position is handed to it in a memory `State` and the returned one is
    /// persisted here, so all storage writes stay in the pool.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert NotManager();
        PoolOps.State memory st = PoolOps.State({
            lpLiquidity: lpLiquidity,
            protocolLiquidity: protocolLiquidity,
            compoundEth: compoundEth,
            compoundScore: compoundScore,
            polCompoundEth: polCompoundEth,
            polCompoundScore: polCompoundScore,
            devOwedEth: devOwedEth,
            devOwedScore: devOwedScore,
            totalUnits: totalUnits
        });
        bytes memory ret;
        (ret, st) =
            PoolOps.run(st, poolKey, manager, address(hook), burner, address(score), devFeeBps, data);
        lpLiquidity = st.lpLiquidity;
        protocolLiquidity = st.protocolLiquidity;
        compoundEth = st.compoundEth;
        compoundScore = st.compoundScore;
        polCompoundEth = st.polCompoundEth;
        polCompoundScore = st.polCompoundScore;
        devOwedEth = st.devOwedEth;
        devOwedScore = st.devOwedScore;
        totalUnits = st.totalUnits;
        return ret;
    }
}
