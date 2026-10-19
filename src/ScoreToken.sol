// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {VenueGate} from "./VenueGate.sol";

interface ICreditsCollection {
    function seedOf(uint256 id) external view returns (bytes21);
    function timestampOf(uint256 id) external view returns (uint64);
    function ownerOf(uint256 id) external view returns (address);
    function transferFrom(address from, address to, uint256 id) external;
    function setApprovalForAll(address operator, bool approved) external;
}

interface IStatements {
    function compose(uint256[80] calldata creditIds, uint8 format) external returns (uint256 statementId);
    function creditScoreOf(uint256 id) external view returns (uint256);
    function ownerOf(uint256 id) external view returns (address);
    function transferFrom(address from, address to, uint256 id) external;
}

interface ILaunched {
    function launched() external view returns (bool);
    function unlocked() external view returns (bool);
    function paused() external view returns (bool);
    function migrationOpen() external view returns (bool);
    function bootstrapFailed() external view returns (bool);
}

interface ICreditScore {
    function scoreOf(bytes21 seed, uint64 paidAt) external pure returns (uint256);
}

/// @notice Exchanges SCORE for the real token during a migration. ScoreToken burns the SCORE first, then calls
/// `onScoreRedeemed`, which pays `account` (or reverts, undoing the burn).
interface IScoreMigrator {
    function onScoreRedeemed(address account, uint256 amount) external;
}

interface IGuardOf {
    function guard() external view returns (address);
}

/// @notice The pool contracts SCORE recognises as its own, read from the pool and its hook once the pool is set.
interface IPoolWiring {
    function hook() external view returns (address);
}

interface IHookWiring {
    function burner() external view returns (address);
    function builder() external view returns (address);
}

/// @title SCORE
/// @notice Credits wrapped by Credit Score. Wrapping a Credit mints exactly its score (18 decimals: one token per
/// score point), with no fee. The score is computed by the CreditScore contract from the Credit's own seed and
/// payment time, so no caller can supply it. Until the bootstrap has launched (or failed) only the pool wraps.
/// Until Statements open, a held Credit can be unwrapped for exactly the SCORE it minted (`unwrap`); once they open,
/// anyone can compose 80 held Credits into a Statement (not once the emergency exit is open), which stays here and
/// carries their summed score.
/// Statements can be wrapped too (minting exactly the score they record, `creditScoreOf`, overprints included), but
/// only once Statement wrapping has opened: either the pool has launched and the guard's owner has set
/// `statementsOpenAt` and it has passed, or a migrator has been set, launched or not (the pre-migration conversion
/// window). It never opens on its own at the full unlock. Total supply always equals `backing`.
/// @dev Apart from `unwrap` before Statements open, items leave only through one of three exits:
/// - Migration: the pool's guard sets a migrator, then enables it. From then on minting stops, anyone can release
///   the held Statements to the migrator in chunks, holders `redeem` SCORE there for the real token, and `topUp`
///   completes the last Statement. The guard can remove the migrator at any time.
/// - Emergency exit in kind: if no migration is active, the guardian can open it (one way). Minting stops, and
///   holders burn SCORE for specific held items at exactly the value they minted.
/// - Rescue: only while the emergency exit is open, only while every LP unit in the pool is withdrawable, and only
///   after `TIMELOCK` (see `proposeRescue`).
///
/// There is no owner. The guardian can pause wrapping, remove a migrator that is not yet enabled, open the
/// emergency exit and propose or cancel a rescue; it cannot mint, burn or move items itself.
///
/// Trading is kept in the SCORE/ETH pool (see VenueGate): its hook, read from the pool, is the only one that can
/// credit the pool manager budget, and the pool, its hook, the Burner, the Builder and the current migrator always
/// receive.
/// The pool's guard is the gate's admin. The checks apply to minting too, so Credits cannot be wrapped straight
/// into another venue.
/// @custom:disclaimer Experimental software, not audited by an independent security firm. You may lose everything
/// you commit.
contract ScoreToken is ERC20, ReentrancyGuard, IERC721Receiver, VenueGate {
    using EnumerableSet for EnumerableSet.UintSet;

    /// CreditScore reports score x 10,000; one token per score point at 18 decimals is x 1e14.
    uint256 private constant TO_WEI = 1e14;
    /// @notice Delay between proposing and executing a rescue.
    uint256 public constant TIMELOCK = 7 days;

    ICreditsCollection public immutable credits;
    ICreditScore public immutable creditScore;
    IStatements public immutable statements;
    /// @notice May set `pool` once; it has no other rights.
    address public immutable deployer;
    /// @notice May pause wrapping, remove a migrator before it is enabled, open the emergency exit, and propose or
    /// cancel a rescue.
    address public immutable guardian;
    /// @notice When Statement wrapping opens by the guard owner's schedule (0 = not set, closed). Set/brought forward
    /// by the pool's guard (ScoreGuard.setStatementsOpenAt) only before it has opened; never reclosed through it.
    /// Statement wrapping also opens on its own once a migrator is set (the pre-migration conversion window).
    uint64 public statementsOpenAt;
    /// @notice The SCORE/ETH pool. Statements open by schedule only once it has launched; its guard manages the
    /// migration and the pause.
    address public pool;

    /// @notice SCORE outstanding, in token units: the summed score of the Credits and Statements wrapped, less what
    /// `unwrap`, `redeem` and `redeemInKind` burned. Until a migration or rescue moves items out, it is also the
    /// summed score of the items held here.
    uint256 public backing;
    /// What each held Credit minted, so `compose` need not recompute 80 scores.
    mapping(uint256 => uint256) private heldValue;
    EnumerableSet.UintSet private held;
    EnumerableSet.UintSet private heldStatements;
    /// Set during this contract's own compose, so the minted Statement is accepted without minting SCORE.
    bool private composing;

    /// @notice Start of the wrap pause (0 if none); see `wrapPaused()`.
    uint64 public wrapPauseAt;
    /// @notice Set once by the pool's guard: the wrap pause cannot be changed again.
    bool public pauseRenounced;
    /// @notice The set or enabled migrator; zero if none.
    address public migrator;
    /// @notice When the migrator was enabled; type(uint256).max while set but not enabled; zero if none.
    uint256 public migrationReadyAt;
    /// @notice Set once by the guardian; never cleared.
    bool public emergencyOpen;
    /// @notice SCORE value given to each migrator: the recorded score of every Statement released to it, plus each
    /// top-up's score as it is paid (see `topUp`), less any top-up whose Statement left the vault without reaching
    /// that migrator (see `advanceOf`). No redemption can take `redeemedAt` of a migrator past it.
    mapping(address => uint256) public releasedTo;
    /// @notice SCORE redeemed through each migrator, while active (`redeem`, `topUp`) and after removal
    /// (`redeemFromFormer`).
    mapping(address => uint256) public redeemedAt;
    /// @notice Whether an address was ever a migrator here and has been removed; SCORE stays redeemable there for
    /// what it was given and has not yet paid out.
    mapping(address => bool) public formerMigrator;
    /// @notice Part of a held Statement's score already counted in `releasedTo` of the migrator that paid its top-up
    /// (`advanceBy`). Released to that migrator, only the rest of the score is added; leaving the vault any other way
    /// (or being wrapped again), the advance is taken back off that migrator's `releasedTo`, since it never received
    /// the Credits it paid for. Either way it is then cleared.
    mapping(uint256 => uint256) public advanceOf;
    /// @notice The migrator that paid a held Statement's top-up advance; zero if none.
    mapping(uint256 => address) public advanceBy;
    /// @notice Where a proposed rescue sends the remaining items; zero if none.
    address public rescueTo;
    /// @notice When the proposed rescue may run; zero if none.
    uint256 public rescueReadyAt;

    event Wrapped(address indexed from, address indexed to, uint256[] ids, uint256 amount);
    event WrappedStatements(address indexed from, address indexed to, uint256[] ids, uint256 amount);
    event Composed(address indexed by, uint256 indexed statementId, uint256[80] ids, uint256 amount);
    event WrapPauseSet(uint256 paused);
    event StatementsOpenAtSet(uint64 at);
    event MigratorSet(address indexed migrator, uint256 readyAt);
    event MigrationEnabled(address indexed migrator);
    event ToppedUp(address indexed from, address indexed to, uint256 statementId, uint256[] ids, uint256 amount);
    event MigratorRemoved(address indexed migrator);
    event StatementsReleased(address indexed migrator, uint256 statementCount, uint256 creditCount);
    event Redeemed(address indexed account, address indexed migrator, uint256 amount);
    event EmergencyExitOpened();
    event Unwrapped(address indexed from, address indexed to, uint256[] ids, uint256 amount);
    event UnwrappedStatements(address indexed from, address indexed to, uint256[] ids, uint256 amount);
    event RedeemedInKind(
        address indexed account, address indexed to, uint256[] creditIds, uint256[] statementIds, uint256 amount
    );
    event RescueProposed(address indexed to, uint256 readyAt);
    event RescueCancelled(address indexed to);
    /// @notice Items moved out without burning SCORE: the SCORE they backed stays outstanding.
    event RescueExecuted(address indexed to, uint256 statementCount, uint256 creditCount);

    error EmptyIds();
    error NotHeld(uint256 id);
    error BadAddress();
    error OnlyCredits();
    error SupplyMismatch();
    error ScoreMismatch();
    error BadData();
    error StatementsClosed();
    error AlreadySet();
    error OnlyGuardian();
    error OnlyPool();
    error WrapPaused();
    error Migrating();
    error NotMigrating();
    error ExitOpen();
    error ExitClosed();
    error NothingPending();
    error NotReady();
    error TooLate();
    error ZeroAmount();
    error BadTopUp();
    error UnitsLocked();
    error NotLaunched();
    error UnwrapClosed();
    error OverRedeemed();
    error NotFormerMigrator();

    modifier onlyGuardian() {
        if (msg.sender != guardian) revert OnlyGuardian();
        _;
    }

    constructor(
        string memory name_,
        string memory symbol_,
        ICreditsCollection credits_,
        ICreditScore creditScore_,
        IStatements statements_,
        address guardian_,
        address poolManager_,
        uint256 statementsOpenAt_
    ) ERC20(name_, symbol_) VenueGate(poolManager_) {
        if (
            address(credits_) == address(0) || address(creditScore_) == address(0)
                || address(statements_) == address(0) || guardian_ == address(0)
        ) {
            revert BadAddress();
        }
        credits = credits_;
        creditScore = creditScore_;
        statements = statements_;
        guardian = guardian_;
        statementsOpenAt = uint64(statementsOpenAt_); // the initial value of the mutable schedule (0 = closed)
        credits_.setApprovalForAll(address(statements_), true); // compose burns from this contract
        deployer = msg.sender;
    }

    /// @notice Deployer only, once: sets the pool. Its hook becomes the pool hook, and the pool, the hook and the
    /// hook's Burner and Builder become protocol contracts (the hook's protocol contracts must be set first).
    function setPool(address pool_) external {
        if (msg.sender != deployer || pool != address(0) || pool_ == address(0)) revert AlreadySet();
        address h = IPoolWiring(pool_).hook();
        address b = IHookWiring(h).burner();
        address c = IHookWiring(h).builder();
        if (b == address(0) || c == address(0)) revert BadAddress();
        pool = pool_;
        _setPoolHook(h);
        _markProtocol(pool_);
        _markProtocol(b);
        _markProtocol(c);
    }

    /// @notice Whether Statements can be wrapped (and composed): whenever a migrator is set (the window to convert
    /// Statements before minting stops, launched or not, so held Credits can always be composed for a migrator), or
    /// once the pool has launched and the guard owner's `statementsOpenAt` is set and has passed. It does not open at
    /// the full unlock.
    function statementsOpen() public view returns (bool) {
        if (migrator != address(0)) return true;
        if (pool == address(0) || !ILaunched(pool).launched()) return false;
        return statementsOpenAt != 0 && block.timestamp >= statementsOpenAt;
    }

    /// @notice The pool's guard only (ScoreGuard.setStatementsOpenAt): sets or brings forward the time the guard
    /// owner's Statement-wrapping schedule opens (0 keeps it closed). Only before that schedule has opened, so it is
    /// never reclosed through this path; the migrator-set window is independent.
    function setStatementsOpenAt(uint64 at) external {
        if (pool == address(0) || msg.sender != IGuardOf(pool).guard()) revert OnlyPool();
        if (statementsOpenAt != 0 && ILaunched(pool).launched() && block.timestamp >= statementsOpenAt) revert AlreadySet();
        statementsOpenAt = at;
        emit StatementsOpenAtSet(at);
    }

    /// @notice SCORE one Statement wraps to: the summed score it records.
    function statementValueOf(uint256 id) public view returns (uint256) {
        return statements.creditScoreOf(id) * TO_WEI;
    }

    /// @notice Wraps Statements owned by the caller (requires setApprovalForAll on Statements), minting their
    /// recorded score to `to`.
    function wrapStatements(uint256[] calldata ids, address to) external nonReentrant returns (uint256 amount) {
        _checkMintOpen(msg.sender);
        if (ids.length == 0) revert EmptyIds();
        if (to == address(0)) revert BadAddress();
        if (!statementsOpen()) revert StatementsClosed();
        for (uint256 i; i < ids.length; ++i) {
            statements.transferFrom(msg.sender, address(this), ids[i]);
            amount += _takeStatement(ids[i]);
        }
        _mint(to, amount);
        _assertBacked();
        emit WrappedStatements(msg.sender, to, ids, amount);
    }

    function _takeStatement(uint256 id) private returns (uint256 amount) {
        if (statements.ownerOf(id) != address(this) || !heldStatements.add(id)) revert NotHeld(id);
        _settleAdvance(id, address(0));
        amount = statementValueOf(id);
        if (amount == 0) revert NotHeld(id);
        backing += amount;
    }

    /// @notice SCORE one Credit wraps to.
    function valueOf(uint256 id) public view returns (uint256) {
        return creditScore.scoreOf(credits.seedOf(id), credits.timestampOf(id)) * TO_WEI;
    }

    /// @notice Sum of `valueOf` over `ids`.
    function valueOfAll(uint256[] calldata ids) public view returns (uint256 total) {
        for (uint256 i; i < ids.length; ++i) total += valueOf(ids[i]);
    }

    /// @notice Wraps Credits owned by the caller (requires setApprovalForAll on Credits), minting their value to `to`.
    function wrap(uint256[] calldata ids, address to) external nonReentrant returns (uint256 amount) {
        _checkMintOpen(msg.sender);
        if (ids.length == 0) revert EmptyIds();
        if (to == address(0)) revert BadAddress();
        for (uint256 i; i < ids.length; ++i) {
            uint256 id = ids[i];
            credits.transferFrom(msg.sender, address(this), id);
            amount += _take(id);
        }
        _mint(to, amount);
        _assertBacked();
        emit Wrapped(msg.sender, to, ids, amount);
    }

    /// @notice Wraps one Credit, or one Statement once Statements are open, sent with safeTransferFrom (no approval
    /// needed). `data` is empty (mint to the sender) or abi.encode(recipient).
    /// @dev The Statement minted by this contract's own compose is accepted without minting.
    function onERC721Received(address operator, address from, uint256 id, bytes calldata data) external returns (bytes4) {
        if (msg.sender == address(statements)) {
            // the Statement minted by this contract's compose: compose does the accounting
            if (composing) {
                if (operator != address(this) || from != address(0)) revert OnlyCredits();
                return IERC721Receiver.onERC721Received.selector;
            }
            // a Statement sent in to be wrapped
            _receiveStatement(from, id, data);
            return IERC721Receiver.onERC721Received.selector;
        }
        if (msg.sender != address(credits)) revert OnlyCredits();
        _receiveCredit(from, id, data);
        return IERC721Receiver.onERC721Received.selector;
    }

    function _receiveStatement(address from, uint256 id, bytes calldata data) private nonReentrant {
        _checkMintOpen(from);
        if (!statementsOpen()) revert StatementsClosed();
        if (data.length != 0 && data.length != 32) revert BadData();
        address to = data.length == 32 ? abi.decode(data, (address)) : from;
        if (to == address(0)) revert BadAddress();
        uint256 amount = _takeStatement(id);
        _mint(to, amount);
        _assertBacked();
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        emit WrappedStatements(from, to, ids, amount);
    }

    function _receiveCredit(address from, uint256 id, bytes calldata data) private nonReentrant {
        _checkMintOpen(from);
        // Only empty data (the sender) or a 32-byte recipient: other data is not meant for this contract and could
        // decode to an unintended recipient.
        if (data.length != 0 && data.length != 32) revert BadData();
        address to = data.length == 32 ? abi.decode(data, (address)) : from;
        if (to == address(0)) revert BadAddress();
        uint256 amount = _take(id);
        _mint(to, amount);
        _assertBacked();
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        emit Wrapped(from, to, ids, amount);
    }

    /// @notice Burns 80 held Credits into a Statement that stays here. Callable by anyone once Statements open
    /// (`statementsOpen`), except while the emergency exit is open (the held Credits then stay redeemable in kind one
    /// by one). Until then held Credits can be unwrapped.
    /// @dev Supply does not change: the Statement records exactly the 80 Credits' summed score, which is checked.
    /// Which 80 Credits are composed does not affect SCORE.
    function compose(uint256[80] calldata ids, uint8 format) external nonReentrant returns (uint256 statementId) {
        if (emergencyOpen) revert ExitOpen();
        if (!statementsOpen()) revert StatementsClosed();
        return _compose(ids, format);
    }

    /// @notice Until Statements open (`statementsOpen`, when composing starts; in practice from launch or a failed
    /// bootstrap, since only the pool wraps before then): burns the caller's SCORE equal to the recorded score of the
    /// held Credits `ids`, and sends those Credits to `to`. Each Credit costs exactly the SCORE it minted, whatever
    /// SCORE trades at. Closed while wrapping is paused, while migrating and once the emergency exit is open (which has
    /// its own in-kind exit).
    function unwrap(uint256[] calldata ids, address to) external nonReentrant returns (uint256 amount) {
        if (ids.length == 0) revert EmptyIds();
        if (to == address(0) || to == address(this)) revert BadAddress();
        if (emergencyOpen) revert ExitOpen();
        if (migrating()) revert Migrating();
        if (wrapPaused()) revert WrapPaused();
        if (statementsOpen()) revert UnwrapClosed();
        for (uint256 i; i < ids.length; ++i) {
            uint256 id = ids[i];
            if (!held.remove(id)) revert NotHeld(id);
            amount += heldValue[id];
            delete heldValue[id];
        }
        // burn first, send last (a plain transfer: no callback into the receiver)
        _burn(msg.sender, amount);
        backing -= amount;
        for (uint256 i; i < ids.length; ++i) credits.transferFrom(address(this), to, ids[i]);
        _assertBacked();
        emit Unwrapped(msg.sender, to, ids, amount);
    }

    /// @notice Until the migration (and outside the wrap pause): burns the caller's SCORE equal to the recorded score
    /// of the held Statements `ids` and sends those Statements to `to`. A held Statement's score cannot change, so each
    /// costs exactly the SCORE it backs, whatever SCORE trades at. Closed while wrapping is paused, while migrating and
    /// once the emergency exit is open (which has its own in-kind exit).
    function unwrapStatements(uint256[] calldata ids, address to) external nonReentrant returns (uint256 amount) {
        if (ids.length == 0) revert EmptyIds();
        if (to == address(0) || to == address(this)) revert BadAddress();
        if (emergencyOpen) revert ExitOpen();
        if (migrating()) revert Migrating();
        if (wrapPaused()) revert WrapPaused();
        for (uint256 i; i < ids.length; ++i) {
            uint256 id = ids[i];
            if (!heldStatements.remove(id)) revert NotHeld(id);
            amount += statementValueOf(id);
            _settleAdvance(id, address(0));
        }
        // burn first, send last (a plain transfer: no callback into the receiver)
        _burn(msg.sender, amount);
        backing -= amount;
        for (uint256 i; i < ids.length; ++i) statements.transferFrom(address(this), to, ids[i]);
        _assertBacked();
        emit UnwrappedStatements(msg.sender, to, ids, amount);
    }

    function _compose(uint256[80] memory ids, uint8 format) private returns (uint256 statementId) {
        uint256 total;
        for (uint256 i; i < 80; ++i) {
            uint256 id = ids[i];
            if (!held.remove(id)) revert NotHeld(id);
            total += heldValue[id];
            delete heldValue[id];
        }
        composing = true;
        statementId = statements.compose(ids, format);
        composing = false;
        if (statements.creditScoreOf(statementId) * TO_WEI != total) revert ScoreMismatch();
        heldStatements.add(statementId);
        emit Composed(msg.sender, statementId, ids, total);
    }

    // --- pause ---

    /// @notice Guardian or the pool's guard: from time `at` (0 = never), pauses every path that mints SCORE (`wrap`,
    /// `wrapStatements` and both safe-transfer paths). Compose and the exits are unaffected.
    function setWrapPauseAt(uint64 at) external nonReentrant {
        if (msg.sender != guardian && (pool == address(0) || msg.sender != IGuardOf(pool).guard())) revert OnlyGuardian();
        if (pauseRenounced) revert AlreadySet();
        wrapPauseAt = at;
        emit WrapPauseSet(at);
    }

    /// @notice The pool's guard only (ScoreGuard.renouncePause): freezes the wrap pause setting permanently.
    function renouncePause() external {
        if (pool == address(0) || msg.sender != IGuardOf(pool).guard()) revert OnlyPool();
        pauseRenounced = true;
    }

    /// @notice Whether the wrap pause is in effect.
    function wrapPaused() public view returns (bool) {
        return wrapPauseAt != 0 && block.timestamp >= wrapPauseAt;
    }

    /// @notice Whether anyone (not only the pool) can wrap now: the bootstrap has launched or failed, and wrapping is
    /// not paused, stopped by a migration or closed by the emergency exit.
    function wrapOpen() external view returns (bool) {
        address p = pool;
        return p != address(0) && (ILaunched(p).launched() || ILaunched(p).bootstrapFailed()) && !migrating()
            && !emergencyOpen && !wrapPaused();
    }

    // --- migration ---

    /// @notice Whether a migrator is set and enabled. While true, minting is off and the emergency exit cannot open.
    function migrating() public view returns (bool) {
        return migrator != address(0) && block.timestamp >= migrationReadyAt;
    }

    /// @notice The pool's guard only (ScoreGuard.setMigrator): sets the contract that will take the held Statements
    /// and pay out the real token for redeemed SCORE. It has no effect until `enableMigration`. One at a time, and
    /// not while the emergency exit is open.
    function setMigrator(address m) external nonReentrant {
        if (pool == address(0) || msg.sender != IGuardOf(pool).guard()) revert OnlyPool();
        if (migrator != address(0)) revert AlreadySet();
        if (emergencyOpen) revert ExitOpen();
        if (m == address(0) || m == address(this) || m.code.length == 0) revert BadAddress();
        migrator = m;
        migrationReadyAt = type(uint256).max; // set, not enabled
        emit MigratorSet(m, migrationReadyAt);
    }

    /// @notice The pool's guard only (ScoreGuard.enableMigration): minting stops, the held Statements can be released
    /// to the migrator, and SCORE can be redeemed there for the real token.
    function enableMigration() external nonReentrant {
        if (pool == address(0) || msg.sender != IGuardOf(pool).guard()) revert OnlyPool();
        if (migrator == address(0) || migrationReadyAt != type(uint256).max) revert NothingPending();
        migrationReadyAt = block.timestamp;
        emit MigrationEnabled(migrator);
    }

    /// @notice Removes the migrator. The pool's guard can do so at any time, which halts releases and redemptions;
    /// the guardian directly only before it is enabled. A removed migrator stays redeemable for what it was given and
    /// has not paid out (`redeemFromFormer`).
    function removeMigrator() external nonReentrant {
        bool byGuard = pool != address(0) && msg.sender == IGuardOf(pool).guard();
        if (msg.sender != guardian && !byGuard) revert OnlyGuardian();
        if (migrator == address(0)) revert NothingPending();
        if (!byGuard && block.timestamp >= migrationReadyAt) revert TooLate();
        _clearMigration();
    }

    /// @notice Once migrating, callable by anyone: moves up to `maxItems` held Statements to the migrator. Loose
    /// Credits stay for `topUp`. SCORE stays outstanding (`backing` unchanged) until holders redeem it.
    function releaseStatements(uint256 maxItems)
        external
        nonReentrant
        returns (uint256 statementCount_, uint256 creditCount)
    {
        if (!migrating()) revert NotMigrating();
        address m = migrator;
        uint256 value;
        (statementCount_, creditCount, value) = _release(m, maxItems, true);
        releasedTo[m] += value;
        emit StatementsReleased(m, statementCount_, creditCount);
    }

    /// @notice Once migrating: burns `amount` of the caller's SCORE, then the migrator pays the caller the real
    /// token. If the migrator reverts, so does the burn. The migrator can only be asked for what it has been given:
    /// after its payout (in which it may still take Statements with `releaseStatements`), everything redeemed through
    /// it must not exceed `releasedTo`.
    function redeem(uint256 amount) external {
        address m = _burnForRedeem(amount);
        // Outside the reentrancy lock (state is final): the migrator may call releaseStatements during the payout.
        IScoreMigrator(m).onScoreRedeemed(msg.sender, amount);
        if (redeemedAt[m] > releasedTo[m]) revert OverRedeemed();
    }

    /// @notice After a migrator is removed: burns `amount` of the caller's SCORE, then that former migrator pays the
    /// caller the real token, up to what it was given and has not paid out (`releasedTo - redeemedAt`). If it reverts,
    /// so does the burn.
    function redeemFromFormer(address m, uint256 amount) external {
        _burnForFormer(m, amount);
        // outside the reentrancy lock, as in `redeem`
        IScoreMigrator(m).onScoreRedeemed(msg.sender, amount);
    }

    function _burnForFormer(address m, uint256 amount) private nonReentrant {
        if (!formerMigrator[m] || m == migrator) revert NotFormerMigrator();
        if (amount == 0) revert ZeroAmount();
        if (redeemedAt[m] + amount > releasedTo[m]) revert OverRedeemed();
        redeemedAt[m] += amount;
        _burn(msg.sender, amount);
        backing -= amount;
        _assertBacked();
        emit Redeemed(msg.sender, m, amount);
    }

    function _burnForRedeem(uint256 amount) private nonReentrant returns (address m) {
        if (!migrating()) revert NotMigrating();
        if (amount == 0) revert ZeroAmount();
        _burn(msg.sender, amount);
        backing -= amount;
        _assertBacked();
        m = migrator;
        redeemedAt[m] += amount;
        emit Redeemed(msg.sender, m, amount);
    }

    /// @notice Final top-up, once migrating: with fewer than 80 loose Credits held, the caller brings exactly the
    /// missing ones; together they compose the last Statement (`format` is its Statement format), and the migrator
    /// pays `to` the real token for the score of the Credits brought, as if they had been wrapped and redeemed. No
    /// SCORE is minted, and no loose Credits remain. The brought score counts as given to the migrator at once
    /// (`releasedTo`) and as paid (`redeemedAt`); when the Statement is released, only the rest of its score is
    /// added to `releasedTo`.
    function topUp(uint256[] calldata ids, uint8 format, address to)
        external
        returns (uint256 statementId, uint256 amount)
    {
        address m;
        (statementId, amount, m) = _topUp(ids, format, to);
        // outside the reentrancy lock, as in `redeem`
        IScoreMigrator(m).onScoreRedeemed(to, amount);
    }

    function _topUp(uint256[] calldata ids, uint8 format, address to)
        private
        nonReentrant
        returns (uint256 statementId, uint256 amount, address m)
    {
        if (!migrating()) revert NotMigrating();
        uint256 h = held.length();
        if (h == 0 || h + ids.length != 80 || to == address(0)) revert BadTopUp();
        for (uint256 i; i < ids.length; ++i) {
            credits.transferFrom(msg.sender, address(this), ids[i]);
            amount += _take(ids[i]);
        }
        // the score brought backs no SCORE: the migrator pays it out instead
        backing -= amount;
        uint256[80] memory all;
        for (uint256 i; i < 80; ++i) all[i] = held.at(i);
        statementId = _compose(all, format);
        _assertBacked();
        m = migrator;
        advanceOf[statementId] = amount;
        advanceBy[statementId] = m;
        releasedTo[m] += amount;
        redeemedAt[m] += amount;
        emit ToppedUp(msg.sender, to, statementId, ids, amount);
    }

    // --- emergency exit in kind ---

    /// @notice Guardian only, one way: opens the in-kind exit and stops minting permanently. Not while migrating,
    /// nor while the pool's migration holds its LP units; a migrator that is set but not enabled is removed.
    function openEmergencyExit() external onlyGuardian nonReentrant {
        if (emergencyOpen) revert AlreadySet();
        if (migrating()) revert Migrating();
        address p = pool;
        if (p != address(0) && ILaunched(p).migrationOpen() && !ILaunched(p).unlocked()) revert UnitsLocked();
        if (migrator != address(0)) _clearMigration();
        emergencyOpen = true;
        emit EmergencyExitOpened();
    }

    /// @notice While the emergency exit is open: burns from the caller exactly what the given held items minted
    /// (each Credit's recorded value, each Statement's recorded score) and sends those items to `to`.
    function redeemInKind(uint256[] calldata creditIds, uint256[] calldata statementIds, address to)
        external
        nonReentrant
        returns (uint256 amount)
    {
        if (!emergencyOpen) revert ExitClosed();
        if (creditIds.length == 0 && statementIds.length == 0) revert EmptyIds();
        if (to == address(0) || to == address(this)) revert BadAddress();
        for (uint256 i; i < creditIds.length; ++i) {
            uint256 id = creditIds[i];
            if (!held.remove(id)) revert NotHeld(id);
            amount += heldValue[id];
            delete heldValue[id];
        }
        for (uint256 i; i < statementIds.length; ++i) {
            uint256 id = statementIds[i];
            if (!heldStatements.remove(id)) revert NotHeld(id);
            amount += statementValueOf(id);
            _settleAdvance(id, address(0));
        }
        _burn(msg.sender, amount);
        backing -= amount;
        for (uint256 i; i < creditIds.length; ++i) credits.transferFrom(address(this), to, creditIds[i]);
        for (uint256 i; i < statementIds.length; ++i) statements.transferFrom(address(this), to, statementIds[i]);
        _assertBacked();
        emit RedeemedInKind(msg.sender, to, creditIds, statementIds, amount);
    }

    // --- rescue ---

    /// @notice Guardian only, while the emergency exit is open: proposes moving every remaining item to `to` after
    /// `TIMELOCK`.
    /// @dev Intended for a failed migration where in-kind exits do not work (for example, a collection that blocks
    /// transfers to holders). It burns no SCORE, so any remaining SCORE stays outstanding with nothing held behind it.
    /// Holders can keep exiting in kind until it runs. Both proposing and running it need the pool's LP units to be
    /// withdrawable (unlocked and not paused), so depositors can take their SCORE out and exit in kind during the
    /// timelock.
    function proposeRescue(address to) external onlyGuardian nonReentrant {
        if (!emergencyOpen) revert ExitClosed();
        _checkUnitsFree();
        if (rescueTo != address(0)) revert AlreadySet();
        if (to == address(0) || to == address(this)) revert BadAddress();
        rescueTo = to;
        rescueReadyAt = block.timestamp + TIMELOCK;
        emit RescueProposed(to, rescueReadyAt);
    }

    /// @notice Guardian only: cancels the proposed rescue, also halting one in progress; the rest stays held.
    function cancelRescue() external onlyGuardian nonReentrant {
        address to = rescueTo;
        if (to == address(0)) revert NothingPending();
        delete rescueTo;
        delete rescueReadyAt;
        emit RescueCancelled(to);
    }

    /// @notice Once the rescue's timelock has passed, callable by anyone: moves up to `maxItems` held items to
    /// `rescueTo`, Statements first. Burns no SCORE and leaves `backing` unchanged.
    function executeRescue(uint256 maxItems)
        external
        nonReentrant
        returns (uint256 statementCount_, uint256 creditCount)
    {
        address to = rescueTo;
        if (to == address(0)) revert NothingPending();
        if (block.timestamp < rescueReadyAt) revert NotReady();
        _checkUnitsFree();
        (statementCount_, creditCount,) = _release(to, maxItems, false);
        emit RescueExecuted(to, statementCount_, creditCount);
    }

    // --- views ---

    function statementCount() external view returns (uint256) {
        return heldStatements.length();
    }

    function statementAt(uint256 index) external view returns (uint256) {
        return heldStatements.at(index);
    }

    function heldCount() external view returns (uint256) {
        return held.length();
    }

    function heldAt(uint256 index) external view returns (uint256) {
        return held.at(index);
    }

    /// @notice Paged list of held Credits.
    function heldPage(uint256 start, uint256 count) external view returns (uint256[] memory ids) {
        uint256 n = held.length();
        if (start >= n) return ids;
        uint256 end = start + count > n ? n : start + count;
        ids = new uint256[](end - start);
        for (uint256 i; i < ids.length; ++i) ids[i] = held.at(start + i);
    }

    function isHeld(uint256 id) external view returns (bool) {
        return held.contains(id);
    }

    // --- internals ---

    function _update(address from, address to, uint256 value) internal override {
        _checkTransfer(from, to, value);
        super._update(from, to, value);
    }

    /// @dev The gate's admin is the pool's guard.
    function _checkGateAdmin() internal view override {
        if (pool == address(0) || msg.sender != IGuardOf(pool).guard()) revert OnlyPool();
    }

    /// @dev The migrator receives the pool's liquidity during a migration.
    function _isOwnReceiver(address a) internal view override returns (bool) {
        return a == migrator;
    }

    /// @dev A removed migrator can still send the SCORE it holds, though it no longer receives.
    function _isOwnSender(address a) internal view override returns (bool) {
        return formerMigrator[a];
    }

    /// @dev Reverts unless the pool's LP units can be withdrawn now: unlocked, and not paused.
    function _checkUnitsFree() private view {
        address p = pool;
        if (p != address(0) && (!ILaunched(p).unlocked() || ILaunched(p).paused())) revert UnitsLocked();
    }

    /// @dev Checked first by every minting path.
    /// @dev Until the bootstrap has launched (or failed), only the pool wraps: the bootstrap's Credit commits.
    function _checkMintOpen(address caller) private view {
        address p = pool;
        if (caller != p && (p == address(0) || !(ILaunched(p).launched() || ILaunched(p).bootstrapFailed()))) {
            revert NotLaunched();
        }
        if (migrating()) revert Migrating();
        if (emergencyOpen) revert ExitOpen();
        if (wrapPaused()) revert WrapPaused();
    }

    function _clearMigration() private {
        address m = migrator;
        delete migrator;
        delete migrationReadyAt;
        formerMigrator[m] = true;
        emit MigratorRemoved(m);
    }

    /// @dev Moves up to `maxItems` held items to `to`: Statements first, then Credits unless `statementsOnly`, each
    /// from the end of its set. Plain transferFrom, so the receiver gets no callback.
    function _release(address to, uint256 maxItems, bool statementsOnly)
        private
        returns (uint256 nStatements, uint256 nCredits, uint256 value)
    {
        uint256 n = heldStatements.length();
        while (nStatements < maxItems && n != 0) {
            uint256 id = heldStatements.at(--n);
            heldStatements.remove(id);
            value += statementValueOf(id) - _settleAdvance(id, to);
            statements.transferFrom(address(this), to, id);
            ++nStatements;
        }
        if (statementsOnly) return (nStatements, 0, value); // the migrator receives loose Credits only through topUp
        n = held.length();
        while (nStatements + nCredits < maxItems && n != 0) {
            uint256 id = held.at(--n);
            held.remove(id);
            delete heldValue[id];
            credits.transferFrom(address(this), to, id);
            ++nCredits;
        }
    }

    /// @dev Clears Statement `id`'s top-up advance as it leaves the vault for `to` (zero when it is wrapped again).
    /// Going to the migrator that paid the advance, the advance stays counted in its `releasedTo` and is returned, so
    /// the release adds only the rest; otherwise it is taken back off that migrator's `releasedTo` and 0 is returned.
    /// The burn of a Statement leaving in exchange for SCORE stays its full recorded score, so with the advance taken
    /// back, SCORE stays equal to the vault's value net of advances plus what each migrator still owes.
    /// It never lowers an enabled migrator's `releasedTo`: the advance is taken back only while no migrator is enabled
    /// (`unwrapStatements`), with the emergency exit open (no migrator at all), or on a release to another address
    /// than the one that paid it (so that one has been removed). Only a former migrator can be left owing less than
    /// nothing; `redeemFromFormer` refuses it more, and if it is set again its `redeem` waits on further releases.
    function _settleAdvance(uint256 id, address to) private returns (uint256 kept) {
        uint256 a = advanceOf[id];
        if (a == 0) return 0;
        address m = advanceBy[id];
        delete advanceOf[id];
        delete advanceBy[id];
        if (to == m) return a;
        releasedTo[m] -= a;
    }

    function _take(uint256 id) private returns (uint256 amount) {
        // The collection must have moved the Credit here, and an id is counted only once.
        if (credits.ownerOf(id) != address(this) || !held.add(id)) revert NotHeld(id);
        amount = valueOf(id);
        heldValue[id] = amount;
        backing += amount;
    }

    function _assertBacked() private view {
        if (totalSupply() != backing) revert SupplyMismatch();
    }
}
