// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface IMigrationUnits {
    /// @notice `user`'s LP units and locked units when the migration opened, and the total then
    /// (ScoreLens.migrationUnitsOf).
    function migrationUnitsOf(address user) external view returns (uint256 units, uint256 locked, uint256 total);
    /// @notice Whether every LP unit can be withdrawn from the pool (ScoreLens.unlocked): the migration can then no
    /// longer complete.
    function unlocked() external view returns (bool);
}

/// @title MigratorBase
/// @notice Claim accounting for the migrator, independent of the real token's specifics (implemented by the
/// concrete migrator). The migration runs in batches; each batch converts part of the SCORE/ETH depositors'
/// liquidity into an amount of the migrator's real-token/ETH position, booked here with `_book`.
/// @dev Every LP unit that existed when the migration opened owns the same part of every batch, so a running tally
/// booked per opening unit (`accPerUnit`, as in MasterChef-style reward accounting) is sufficient: a user's claim is
/// their opening units times the tally, minus what they already claimed. Units cannot change while the migration is
/// open (no deposits or withdrawals), and the snapshot covers withdrawals after an unlock, so nothing can be claimed
/// twice or by units that were not there.
///
/// The part of the units locked when the migration opened (bootstrap and locked deposits) streams out by the second
/// over `VEST` (24 hours) from when the migration completes (`_startVest`, once all the liquidity has moved), and
/// none of it before; if the pool unlocks first (so the migration can no longer complete), it is claimable at once.
/// The rest is withdrawable at once. The concrete migrator can hold part of a user's units until one
/// fixed time for all (`_hold`): their part here (of every batch, past and future) is held until then. Any part not yet
/// claimed can be held: still vesting, vested, or free. Held units come out of the part still vesting first, so holding
/// it never delays the part already vested. Every division rounds down, so total claims never exceed what was booked.
abstract contract MigratorBase is ReentrancyGuard {
    uint256 public constant VEST = 24 hours;
    uint256 private constant ACC = 1e36;

    IMigrationUnits public immutable source;
    /// @notice When the migration was enabled (0 before).
    uint64 public startedAt;
    /// @notice When the migration completed (0 before); the locked parts stream out over `VEST` from here.
    uint64 public vestStart;
    /// @notice When every hold ends (one fixed time for all), set at the first hold.
    uint64 public holdEndAt;
    /// @notice Total LP units when the migration opened, including dead units and rounding remainders, whose part is
    /// never claimed.
    uint256 public openTotal;
    /// @notice Amount booked over all batches, and booked per opening unit (scaled by 1e36).
    uint256 public totalBooked;
    uint256 public accPerUnit;
    mapping(address => uint256) public withdrawnOf;
    /// @notice Claimed by everyone; totalBooked - totalWithdrawn is still in the migrator's position.
    uint256 public totalWithdrawn;
    /// @notice Units each user has held until `holdEndAt`.
    mapping(address => uint256) public heldOf;

    event Booked(uint256 amount, uint256 accPerUnit);
    event Withdrawn(address indexed user, address indexed to, uint256 amount);
    event Held(address indexed user, uint256 units, uint256 until);

    error NotStarted();
    error NoUnits();
    error Nothing();
    error NotYet();
    error TooMuch();
    error AlreadyWithdrawn();

    constructor(IMigrationUnits source_) {
        source = source_;
    }

    /// @dev Call when the migration is enabled; later calls do nothing.
    function _start() internal {
        if (startedAt != 0) return;
        (,, uint256 total) = source.migrationUnitsOf(address(0));
        if (total == 0) revert NoUnits();
        startedAt = uint64(block.timestamp);
        openTotal = total;
    }

    /// @dev Call when the migration completes (all the liquidity moved); the locked parts start streaming. Later calls
    /// do nothing, and so does a call once the pool has unlocked (the locked parts are then already free).
    function _startVest() internal {
        if (startedAt == 0) revert NotStarted();
        if (vestStart == 0 && !source.unlocked()) vestStart = uint64(block.timestamp);
    }

    /// @dev Amount to book for a batch that added `liquidityAdded` to the migrator's position, which held
    /// `liquidityBefore` (compounded fees included) for the amount still unclaimed. Priced like LP units, so the
    /// position's fees accrue to everything still in it and a batch at any price cannot dilute or favour anyone.
    function _bookedFor(uint256 liquidityAdded, uint256 liquidityBefore) internal view returns (uint256) {
        uint256 outstanding = totalBooked - totalWithdrawn;
        return outstanding == 0 || liquidityBefore == 0
            ? liquidityAdded
            : Math.mulDiv(liquidityAdded, outstanding, liquidityBefore);
    }

    /// @dev Books a batch's output (`amount` from `_bookedFor`) across all opening units.
    function _book(uint256 amount) internal {
        if (startedAt == 0) revert NotStarted();
        totalBooked += amount;
        accPerUnit += amount * ACC / openTotal;
        emit Booked(amount, accPerUnit);
    }

    /// @notice `user`'s units held, until `holdEndAt`.
    function activeHold(address user) public view returns (uint256) {
        return block.timestamp < holdEndAt ? heldOf[user] : 0;
    }

    /// @notice What `user` can claim now: every batch's part for their free units, plus the vested part (over `VEST`)
    /// for their locked units, but nothing for their units held until `holdEndAt`.
    function withdrawable(address user) public view returns (uint256) {
        return _owed(user, 0) - Math.min(_owed(user, 0), withdrawnOf[user]);
    }

    /// @dev What `user` is owed now with `extra` more units held back. Held units come out of the part still vesting
    /// first, then out of the part claimable now (vested and free), so any part not yet claimed can be held, and
    /// holding the part still vesting never delays the part already vested.
    function _owed(address user, uint256 extra) private view returns (uint256) {
        if (startedAt == 0) return 0;
        (uint256 u, uint256 locked,) = source.migrationUnitsOf(user);
        uint256 held = activeHold(user) + extra;
        uint256 v = vestStart;
        // a migration that can no longer complete (the pool unlocked first) leaves nothing to wait for
        uint256 dt = v != 0 ? block.timestamp - v : source.unlocked() ? VEST : 0;
        uint256 vested = dt >= VEST ? locked : Math.mulDiv(locked, dt, VEST);
        uint256 vesting = locked - vested;
        uint256 claimable = u - vesting; // the free part plus the vested part
        uint256 fromClaimable = held > vesting ? held - vesting : 0;
        if (fromClaimable >= claimable) return 0;
        return Math.mulDiv(claimable - fromClaimable, accPerUnit, ACC);
    }

    /// @notice Claims the caller's withdrawable amount, paid to `to`.
    function withdraw(address to) external nonReentrant returns (uint256 amount) {
        amount = withdrawable(msg.sender);
        if (amount == 0) revert Nothing();
        withdrawnOf[msg.sender] += amount;
        totalWithdrawn += amount;
        emit Withdrawn(msg.sender, to, amount);
        _payOut(to, amount);
    }

    /// @dev Holds `units` more of `user`'s opening units, not already held, until `until`, which must be in the
    /// future and the same for every hold (the first one sets it). Only a part not yet claimed can be held.
    function _hold(address user, uint256 units, uint64 until) internal {
        if (startedAt == 0 || until <= block.timestamp) revert NotYet();
        uint64 end = holdEndAt;
        if (end != 0 && until != end) revert NotYet();
        (uint256 u,,) = source.migrationUnitsOf(user);
        if (units == 0 || activeHold(user) + units > u) revert TooMuch();
        if (withdrawnOf[user] > _owed(user, units)) revert AlreadyWithdrawn();
        if (end == 0) holdEndAt = until;
        heldOf[user] += units;
        emit Held(user, units, until);
    }

    /// @dev Pays `amount` of the migrator's position to `to`: amount * positionLiquidity / (amount outstanding
    /// before this claim). Implemented by the concrete migrator. It is called after `totalWithdrawn` already includes
    /// `amount`, so the amount outstanding before this claim is `totalBooked - totalWithdrawn + amount`; dividing by
    /// `totalBooked - totalWithdrawn` instead would overpay.
    function _payOut(address to, uint256 amount) internal virtual;
}
