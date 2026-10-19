// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

interface IGuardedPool {
    function deadline() external view returns (uint256);
    function paused() external view returns (bool);
    function pauseAt() external view returns (uint64);
    function migrationOpen() external view returns (bool);
    function setGuardState(uint64 pauseAt_, bool earlyUnlock_, bool openMigration_) external;
    function releaseLiquidity(bool fromUnits, uint256 scoreWanted, address to) external returns (uint256 eth, uint256 score);
    function launched() external view returns (bool);
    function launchedAt() external view returns (uint64);
    function migrationOpenedAt() external view returns (uint64);
    function markMigrationComplete() external;
    function setBootstrapOpenAt(uint64 at) external;
}

interface IMigratingScore {
    function setMigrator(address m) external;
    function enableMigration() external;
    function heldCount() external view returns (uint256);
    function setWrapPauseAt(uint64 at) external;
    function renouncePause() external;
    function removeMigrator() external;
    function setStatementsOpenAt(uint64 at) external;
    function migrating() external view returns (bool);
    function migrator() external view returns (address);
    function setAllowed(address account, bool allowed) external;
    function setAllowedCodeHash(bytes32 codeHash, bool allowed) external;
    function setChecks(bool budget, bool allowlist) external;
    function setSafeProxyCodeHash(bytes32 codeHash, bool allowed) external;
    function setAllowedSingleton(address singleton, bool allowed) external;
    function setAllowedDelegate(address delegate, bool allowed) external;
    function wrapPauseAt() external view returns (uint64);
}

/// @title ScoreGuard
/// @notice Migration, pause and rescue policy for ScoreLiquidity and the SCORE vault, kept outside the pool.
/// @dev Roles:
/// - The owner sets the migrator once its contract exists, then enables it in a separate call. Enabling opens the
///   pool's migration permanently (every LP unit is held in it), stops minting in the SCORE vault, and lets SCORE be
///   redeemed at the migrator for the real token. The migrator pulls depositor liquidity in chunks
///   (`pullLiquidity`) and the protocol-owned liquidity in one call (`migrateProtocolLiquidity`), and once the
///   leftover Credits are topped up and all the liquidity has moved, it reports the migration complete
///   (`completeMigration`), which ends the pool's pre-migration POOL stream. The guardian can remove the migrator
///   at any time, which halts the migration until the owner sets another one or the guardian unlocks every unit.
/// - The owner or the guardian can schedule the pause or renounce it; the guardian can unlock every unit.
/// - Last resort, only if nothing has migrated by the pool's deadline: the guardian proposes a rescue address, and
///   after `TIMELOCK` anyone can send the protocol-owned liquidity there. It never touches depositor liquidity.
/// - The owner is the admin of SCORE's venue gate (VenueGate): which contracts may receive SCORE, and whether the
///   checks are on.
contract ScoreGuard is Ownable2Step {
    /// @notice Delay between proposing and executing a rescue.
    uint256 public constant TIMELOCK = 7 days;

    address public immutable guardian;
    IMigratingScore public immutable score;
    address private immutable deployer;
    IGuardedPool public pool;

    /// @notice The migrator set here. The vault can drop it without this contract (the guardian removes one that is
    /// not yet enabled, or opens the emergency exit); one the vault no longer has counts as cleared.
    address public migrator;
    /// @notice When the migrator was enabled; 0 while it is set but not enabled, or if there is none.
    uint64 public migrationReadyAt;
    /// @notice Set once protocol-owned liquidity has gone to the migrator, after which the rescue cannot run.
    bool public migrated;
    /// @notice Once set, the pause cannot be scheduled, moved or lifted again, in the pool or the vault.
    bool public pauseRenounced;
    address public rescueTo;
    uint64 public rescueReadyAt;

    event MigratorSet(address indexed migrator, uint256 readyAt);
    event MigrationEnabled(address indexed migrator);
    event PauseRenounced();
    event MigratorRemoved(address indexed migrator);
    event ProtocolLiquidityMigrated(address indexed migrator, uint256 eth, uint256 score);
    event RescueProposed(address indexed to, uint256 readyAt);
    event RescueCancelled(address indexed to);
    event RescueExecuted(address indexed to, uint256 eth, uint256 score);
    event MigrationCompleted(address indexed migrator);

    error NotGuardian();
    error BadConfig();
    error NotReady();
    error AlreadyMigrated();
    error NotMigrator();
    error LooseCredits();
    error PoolMigrationClosed();

    modifier onlyGuardian() {
        if (msg.sender != guardian) revert NotGuardian();
        _;
    }

    constructor(address owner_, address guardian_, IMigratingScore score_) Ownable(owner_) {
        if (guardian_ == address(0) || address(score_) == address(0)) revert BadConfig();
        guardian = guardian_;
        score = score_;
        deployer = msg.sender;
    }

    /// @notice Deployer only, once: sets the pool, which names this contract as its guard.
    function setPool(IGuardedPool pool_) external {
        if (msg.sender != deployer || address(pool) != address(0) || address(pool_) == address(0)) revert BadConfig();
        pool = pool_;
    }

    /// @notice Owner only: sets or brings forward the bootstrap's commit-open time (see
    /// ScoreLiquidity.setBootstrapOpenAt). Commits open once it passes; the contracts go live for review first.
    function setBootstrapOpenAt(uint64 at) external onlyOwner {
        pool.setBootstrapOpenAt(at);
    }

    /// @notice Owner only: sets or brings forward the time Statement wrapping opens in the SCORE vault
    /// (ScoreToken.setStatementsOpenAt), only before it has opened; 0 keeps it closed. Statement wrapping also
    /// opens on its own once a migrator is set (the pre-migration conversion window); it never opens at the full unlock.
    function setStatementsOpenAt(uint64 at) external onlyOwner {
        score.setStatementsOpenAt(at);
    }

    // --- migration ---

    /// @notice Owner only: sets the contract that will take the pool's liquidity and the vault's Statements and pay
    /// out the real token. Nothing moves until `enableMigration`. One at a time; a removed migrator can be replaced,
    /// including one the vault dropped directly.
    function setMigrator(address m) external onlyOwner {
        address cur = migrator;
        if ((cur != address(0) && score.migrator() == cur) || m == address(0) || m.code.length == 0) revert BadConfig();
        migrator = m;
        migrationReadyAt = 0;
        score.setMigrator(m);
        emit MigratorSet(m, 0);
    }

    /// @notice Owner only: enables the migrator. Every LP unit is then held in the migration, the vault stops
    /// minting, and SCORE can be redeemed at the migrator for the real token.
    /// @dev Reverts while the vault holds Credits not yet composed into Statements, so that every SCORE is backed by
    /// Statements the migrator can take. `allowLooseCredits` skips the check, for when the remainder cannot be
    /// composed (for example, if the Statement supply cap prevents it). Reverts if the pool has launched but its
    /// migration cannot open (its units have already unlocked), so the vault is never switched over while the pool's
    /// liquidity cannot follow; `enableVaultMigration` does that deliberately. Before launch there are no units to
    /// hold, and the vault migrates on its own.
    function enableMigration(bool allowLooseCredits) external onlyOwner {
        _enableMigration(allowLooseCredits, false);
    }

    /// @notice Owner only, the deliberate fallback once the pool's units have unlocked (its migration can no longer
    /// open): enables the migrator for the SCORE vault alone. LPs withdraw their own liquidity and redeem their SCORE
    /// at the migrator; there is no pool migration to complete.
    function enableVaultMigration(bool allowLooseCredits) external onlyOwner {
        _enableMigration(allowLooseCredits, true);
    }

    function _enableMigration(bool allowLooseCredits, bool vaultOnly) private {
        address m = migrator;
        if (m == address(0) || migrationReadyAt != 0 || score.migrator() != m) revert NotReady();
        if (!allowLooseCredits && score.heldCount() != 0) revert LooseCredits();
        migrationReadyAt = uint64(block.timestamp);
        score.enableMigration();
        if (!pool.migrationOpen()) pool.setGuardState(pool.pauseAt(), false, true);
        if (!vaultOnly && pool.launched() && !pool.migrationOpen()) revert PoolMigrationClosed();
        emit MigrationEnabled(m);
    }

    /// @notice Guardian only, at any time: removes the migrator here and in the SCORE vault, which halts the
    /// migration. The pool's migration stays open: units stay held until the owner sets another migrator or the
    /// guardian unlocks every unit.
    function removeMigrator() external onlyGuardian {
        address m = migrator;
        if (m == address(0)) revert NotReady();
        migrator = address(0);
        migrationReadyAt = 0;
        if (score.migrator() == m) score.removeMigrator();
        emit MigratorRemoved(m);
    }

    /// @notice The active migrator only: pulls depositor liquidity worth `scoreWanted` SCORE
    /// (see ScoreLiquidity.releaseLiquidity).
    function pullLiquidity(uint256 scoreWanted) external returns (uint256 e, uint256 s) {
        _checkActive();
        if (msg.sender != migrator) revert NotMigrator();
        return pool.releaseLiquidity(true, scoreWanted, msg.sender);
    }

    /// @dev Reverts unless the migrator is set and enabled here and is the vault's active migrator.
    function _checkActive() private view {
        address m = migrator;
        if (m == address(0) || migrationReadyAt == 0 || !score.migrating() || score.migrator() != m) {
            revert NotReady();
        }
    }

    /// @notice The active migrator only: pulls all protocol-owned liquidity, so it can move it into the real pool in
    /// the same transaction (as with `pullLiquidity`).
    function migrateProtocolLiquidity() external returns (uint256 e, uint256 s) {
        _checkActive();
        address m = migrator;
        if (msg.sender != m) revert NotMigrator();
        migrated = true;
        (e, s) = pool.releaseLiquidity(false, 0, m);
        emit ProtocolLiquidityMigrated(m, e, s);
    }

    /// @notice The active migrator only, once the protocol-owned liquidity has gone to it: reports the migration
    /// complete (the leftover Credits topped up and all the SCORE/ETH liquidity moved to the real token). The pool's
    /// pre-migration POOL stream stops and its remainder is burned (ScoreLiquidity.markMigrationComplete).
    function completeMigration() external {
        _checkActive();
        if (msg.sender != migrator) revert NotMigrator();
        if (!migrated) revert NotReady();
        pool.markMigrationComplete();
        emit MigrationCompleted(msg.sender);
    }

    // --- pause and unlock ---

    /// @notice Owner or guardian: schedules the pause for time `at`, or lifts it with 0. From `at`, wrapping stops
    /// in the SCORE vault and the pool's commits, deposits, locking, launch and withdrawals stop; trading continues.
    /// The pool stops applying it to withdrawals once every unit is unlocked.
    function setPauseAt(uint64 at) external {
        if (msg.sender != guardian && msg.sender != owner()) revert NotGuardian();
        if (pauseRenounced) revert BadConfig();
        pool.setGuardState(at, false, false);
        score.setWrapPauseAt(at);
    }

    /// @notice Owner or guardian, one way: gives up the pause permanently, in the pool and the SCORE vault. Only
    /// while no pause is scheduled or in effect in either, so a pause can never be made permanent.
    function renouncePause() external {
        if (msg.sender != guardian && msg.sender != owner()) revert NotGuardian();
        if (pool.pauseAt() != 0 || score.wrapPauseAt() != 0) revert BadConfig();
        pauseRenounced = true;
        score.renouncePause();
        emit PauseRenounced();
    }

    /// @notice Guardian only, one way: unlocks every unit now.
    function unlockAll() external onlyGuardian {
        pool.setGuardState(pool.pauseAt(), true, false);
    }

    // --- SCORE venue gate ---

    /// @notice Owner only: allows `account` to receive SCORE, or withdraws that (see VenueGate.setAllowed).
    function setAllowed(address account, bool allowed) external onlyOwner {
        score.setAllowed(account, allowed);
    }

    /// @notice Owner only: allows accounts with code hash `codeHash` to receive SCORE, or withdraws that.
    function setAllowedCodeHash(bytes32 codeHash, bool allowed) external onlyOwner {
        score.setAllowedCodeHash(codeHash, allowed);
    }

    /// @notice Owner only: allows Safe proxies with code hash `codeHash` to receive SCORE when their singleton is
    /// allowed (see VenueGate.setSafeProxyCodeHash).
    function setSafeProxyCodeHash(bytes32 codeHash, bool allowed) external onlyOwner {
        score.setSafeProxyCodeHash(codeHash, allowed);
    }

    /// @notice Owner only: allows or withdraws a Safe singleton for SCORE's Safe proxy check.
    function setAllowedSingleton(address singleton, bool allowed) external onlyOwner {
        score.setAllowedSingleton(singleton, allowed);
    }

    /// @notice Owner only: allows or withdraws an EIP-7702 delegate for SCORE's receiver check.
    function setAllowedDelegate(address delegate, bool allowed) external onlyOwner {
        score.setAllowedDelegate(delegate, allowed);
    }

    /// @notice Owner only: switches SCORE's pool manager budget and receiver allowlist on or off.
    function setChecks(bool budget, bool allowlist) external onlyOwner {
        score.setChecks(budget, allowlist);
    }

    // --- rescue ---

    /// @notice Guardian only, last resort: proposes a rescue address for the protocol-owned liquidity. Only after
    /// the pool's deadline, and only if nothing has migrated.
    function proposeRescue(address to) external onlyGuardian {
        if (migrated) revert AlreadyMigrated();
        if (block.timestamp < pool.deadline() || to == address(0) || rescueTo != address(0)) revert NotReady();
        rescueTo = to;
        rescueReadyAt = uint64(block.timestamp + TIMELOCK);
        emit RescueProposed(to, rescueReadyAt);
    }

    /// @notice Guardian only: cancels the proposed rescue.
    function cancelRescue() external onlyGuardian {
        address to = rescueTo;
        if (to == address(0)) revert NotReady();
        rescueTo = address(0);
        rescueReadyAt = 0;
        emit RescueCancelled(to);
    }

    /// @notice After the rescue's timelock, callable by anyone if nothing has migrated: sends the protocol-owned
    /// liquidity to the rescue address.
    function executeRescue() external {
        address to = rescueTo;
        if (migrated) revert AlreadyMigrated();
        if (to == address(0) || block.timestamp < rescueReadyAt) revert NotReady();
        rescueTo = address(0);
        rescueReadyAt = 0;
        (uint256 e, uint256 s) = pool.releaseLiquidity(false, 0, to);
        emit RescueExecuted(to, e, s);
    }
}
