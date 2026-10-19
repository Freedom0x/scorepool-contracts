// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice What a token's pool hook calls after each swap and liquidity change in the token's pool.
interface IVenueToken {
    /// @param inbound True if the operation left the token owed to the pool manager, false if owed by it.
    /// @param amount How much of the token.
    function creditPoolManager(bool inbound, uint256 amount) external;

    /// @notice What is left of this transaction's budget into and out of the pool manager.
    function poolManagerBudget() external view returns (uint256 into, uint256 outOf);
}

/// @title VenueGate
/// @notice Keeps a token's trading in its own Uniswap v4 pool, with two checks on every balance change:
///  - Pool manager budget: the token moves into or out of the v4 pool manager only as far as the token's pool hook
///    has reported for the current transaction, after each swap and liquidity change in that pool. Reports in
///    opposite directions offset each other, so the budget is the net of what the pool's operations left owed to
///    or by the pool manager: liquidity added and removed again in one transaction leaves (almost) nothing. Any
///    other v4 pool of the token gets nothing reported, so it cannot be paid or pay out in the token.
///  - Receiver allowlist: an account with code receives the token only if it is one of the protocol's contracts, an
///    allowed address, an account whose code hash is allowed (wallet proxies), a Safe proxy whose code hash and
///    singleton are both allowed, or an EIP-7702 delegated account whose delegate is allowed. Accounts without code
///    always receive. The same rule applies to senders other than the pool manager: an account with code sends
///    only if it could receive, so a contract deployed at an address that was funded before it had code (a pair at
///    its predicted address) cannot pay out. Burning is never restricted.
/// The token's admin can allow addresses, code hashes, Safe proxy code hashes, Safe singletons and 7702 delegates,
/// and switch either check off (with the allowlist off, neither receivers nor senders are checked).
/// @dev An allowed code hash admits every account with that code, whatever it points to: a plain hash fits code
/// that cannot be redirected, and is only advisory for upgradeable proxies (an ERC-1967 / UUPS wallet proxy or a
/// clone can point anywhere). Safe proxies are checked more closely: they answer `masterCopy()` themselves with
/// their singleton, which must be allowed too.
/// @dev The budget is kept in transient storage, so it lapses at the end of the transaction. Pool manager deltas
/// net per currency across pools within one unlock, so the budget limits the tokens that actually move, not how
/// a pool's internal balance is booked. Because credits net, a transfer must follow the credit it pays for before
/// an opposite credit arrives: an operation that both takes the token out and has it paid in reports the outbound
/// part, moves it, and only then reports the inbound part.
abstract contract VenueGate is IVenueToken {
    /// Transient budget slots: keccak256("scorepool.venuegate.budget.into") and ("...budget.outof").
    bytes32 private constant INTO_SLOT = 0x316cff5d37520958a45090dc9ca45d6bdd5a0267871e65d4074be37fd1f53f2b;
    bytes32 private constant OUTOF_SLOT = 0xaffabc52035060b28337cb7ca62ea3d067c215fcd2fef6a9b1391633d8482c4d;
    uint8 private constant ALLOWED = 1;
    uint8 private constant PROTOCOL = 2;
    /// An EIP-7702 delegated account's code: 0xef0100 followed by the delegate's 20-byte address.
    uint256 private constant DELEGATION_PREFIX = 0xef0100;
    uint256 private constant DELEGATION_SIZE = 23;
    /// Safe proxies answer masterCopy() (selector 0xa619486e) themselves, from storage slot 0, without delegating.
    uint256 private constant MASTER_COPY = 0xa619486e;
    uint256 private constant MASTER_COPY_GAS = 10_000;

    address public immutable poolManager;
    /// @notice The only hook that can credit the budget; zero until set.
    address public poolHook;
    /// @notice Whether the pool manager budget is switched off.
    bool public budgetOff;
    /// @notice Whether the receiver allowlist is switched off.
    bool public allowlistOff;
    /// 0: not listed, ALLOWED: allowed by the admin, PROTOCOL: one of the protocol's contracts (permanent).
    mapping(address => uint8) private access;
    /// @notice Code hashes whose accounts may receive.
    mapping(bytes32 => bool) public allowedCodeHash;
    /// @notice Safe proxy code hashes whose accounts may receive if their singleton is allowed.
    mapping(bytes32 => bool) public safeProxyCodeHash;
    /// @notice Safe singletons a Safe proxy may point to.
    mapping(address => bool) public allowedSingleton;
    /// @notice Implementations an EIP-7702 account may delegate to and still receive.
    mapping(address => bool) public allowedDelegate;

    event ReceiverAllowed(address indexed account, bool allowed);
    event CodeHashAllowed(bytes32 indexed codeHash, bool allowed);
    event SafeProxyCodeHashAllowed(bytes32 indexed codeHash, bool allowed);
    event SingletonAllowed(address indexed singleton, bool allowed);
    event DelegateAllowed(address indexed delegate, bool allowed);
    event ProtocolReceiver(address indexed account);
    event ChecksSet(bool budget, bool allowlist);

    error OverPoolManagerBudget(bool inbound);
    error ReceiverNotAllowed(address to);
    error SenderNotAllowed(address from);
    error NotPoolHook();
    error ProtocolContract();
    error NoPoolManager();

    constructor(address poolManager_) {
        if (poolManager_ == address(0)) revert NoPoolManager();
        poolManager = poolManager_;
    }

    /// @notice Pool hook only: adds to this transaction's budget into (`inbound`) or out of the pool manager. The
    /// credit first uses up what is left of the budget the other way, and only the remainder is added.
    function creditPoolManager(bool inbound, uint256 amount) external {
        address h = poolHook;
        if (h == address(0) || msg.sender != h) revert NotPoolHook();
        (bytes32 slot, bytes32 other) = inbound ? (INTO_SLOT, OUTOF_SLOT) : (OUTOF_SLOT, INTO_SLOT);
        uint256 opposite = _tload(other);
        if (opposite >= amount) {
            unchecked {
                _tstore(other, opposite - amount);
            }
            return;
        }
        if (opposite != 0) _tstore(other, 0);
        unchecked {
            amount -= opposite;
        }
        _tstore(slot, _tload(slot) + amount);
    }

    /// @notice What is left of this transaction's budget into and out of the pool manager.
    function poolManagerBudget() external view returns (uint256 into, uint256 outOf) {
        return (_tload(INTO_SLOT), _tload(OUTOF_SLOT));
    }

    /// @notice Whether `account` may receive the token now (the pool manager only within the budget).
    function canReceive(address account) external view returns (bool) {
        return account != poolManager && _receiverAllowed(account);
    }

    /// @notice Whether `account` is allowed by address, either by the admin or as one of the protocol's contracts.
    function isAllowed(address account) external view returns (bool) {
        return access[account] != 0;
    }

    // --- admin ---

    /// @notice Admin only: allows `account` to receive the token, or withdraws that. Protocol contracts stay allowed.
    function setAllowed(address account, bool allowed) external {
        _checkGateAdmin();
        if (access[account] == PROTOCOL) revert ProtocolContract();
        access[account] = allowed ? ALLOWED : 0;
        emit ReceiverAllowed(account, allowed);
    }

    /// @notice Admin only: allows every account whose code hashes to `codeHash` (a wallet proxy) to receive the
    /// token, or withdraws that.
    function setAllowedCodeHash(bytes32 codeHash, bool allowed) external {
        _checkGateAdmin();
        allowedCodeHash[codeHash] = allowed;
        emit CodeHashAllowed(codeHash, allowed);
    }

    /// @notice Admin only: allows Safe proxies with code hash `codeHash` to receive the token when their singleton is
    /// allowed, or withdraws that.
    function setSafeProxyCodeHash(bytes32 codeHash, bool allowed) external {
        _checkGateAdmin();
        safeProxyCodeHash[codeHash] = allowed;
        emit SafeProxyCodeHashAllowed(codeHash, allowed);
    }

    /// @notice Admin only: allows a Safe singleton for the Safe proxy check, or withdraws that.
    function setAllowedSingleton(address singleton, bool allowed) external {
        _checkGateAdmin();
        allowedSingleton[singleton] = allowed;
        emit SingletonAllowed(singleton, allowed);
    }

    /// @notice Admin only: allows EIP-7702 accounts delegating to `delegate` to receive the token, or withdraws that.
    function setAllowedDelegate(address delegate, bool allowed) external {
        _checkGateAdmin();
        allowedDelegate[delegate] = allowed;
        emit DelegateAllowed(delegate, allowed);
    }

    /// @notice Admin only: switches the pool manager budget and the receiver allowlist on or off. With both off the
    /// token behaves as a plain ERC-20.
    function setChecks(bool budget, bool allowlist) external {
        _checkGateAdmin();
        budgetOff = !budget;
        allowlistOff = !allowlist;
        emit ChecksSet(budget, allowlist);
    }

    // --- for the token ---

    /// @dev Reverts unless the caller is the token's admin.
    function _checkGateAdmin() internal view virtual;

    /// @dev Protocol contracts the token recognises without a listing (for example, a migrator that can change).
    function _isOwnReceiver(address) internal view virtual returns (bool) {
        return false;
    }

    /// @dev Contracts the token lets send although they may no longer receive (for example, a former migrator).
    function _isOwnSender(address) internal view virtual returns (bool) {
        return false;
    }

    /// @dev Sets the pool hook, which is also a protocol contract.
    function _setPoolHook(address hook) internal {
        poolHook = hook;
        _markProtocol(hook);
    }

    /// @dev Allows `account` permanently as one of the protocol's contracts.
    function _markProtocol(address account) internal {
        if (account == address(0) || access[account] == PROTOCOL) return;
        access[account] = PROTOCOL;
        emit ProtocolReceiver(account);
    }

    /// @dev Runs both checks for a balance change of `value` from `from` to `to` (zero for a mint or burn). A
    /// sender other than the pool manager is held to the receiver rule, except when it burns.
    function _checkTransfer(address from, address to, uint256 value) internal {
        if (
            from != poolManager && from != address(0) && to != address(0) && !_receiverAllowed(from)
                && !_isOwnSender(from)
        ) {
            revert SenderNotAllowed(from);
        }
        if (to == poolManager) {
            if (!budgetOff) _spend(INTO_SLOT, value, true);
            return;
        }
        if (from == poolManager && !budgetOff) _spend(OUTOF_SLOT, value, false);
        if (to != address(0)) _checkVenue(to);
    }

    /// @dev The check on every receiver other than the pool manager.
    function _checkVenue(address to) internal view {
        if (!_receiverAllowed(to)) revert ReceiverNotAllowed(to);
    }

    // --- internals ---

    function _receiverAllowed(address to) private view returns (bool) {
        uint256 size = to.code.length;
        if (size == 0) return true;
        if (size == DELEGATION_SIZE) {
            address d = _delegateOf(to);
            if (d != address(0) && allowedDelegate[d]) return true;
        }
        // the toggle last: a listed receiver then reads one slot
        if (access[to] != 0) return true;
        bytes32 h = to.codehash;
        return allowedCodeHash[h] || (safeProxyCodeHash[h] && allowedSingleton[_singletonOf(to)]) || _isOwnReceiver(to)
            || allowlistOff;
    }

    /// @dev A Safe proxy's singleton, read with one bounded-gas static call (zero if the call fails or answers
    /// anything but one word).
    function _singletonOf(address proxy) private view returns (address s) {
        assembly ("memory-safe") {
            mstore(0x00, shl(224, MASTER_COPY))
            let ok := staticcall(MASTER_COPY_GAS, proxy, 0x00, 0x04, 0x00, 0x20)
            if and(ok, eq(returndatasize(), 0x20)) { s := and(mload(0x00), 0xffffffffffffffffffffffffffffffffffffffff) }
        }
    }

    /// @dev The delegate of an EIP-7702 account (its 23-byte code: 0xef0100 then the delegate's address), or zero if
    /// `a`'s code does not start with that prefix. No deployed contract can start with 0xef (EIP-3541), so only a
    /// delegated account matches.
    function _delegateOf(address a) private view returns (address d) {
        assembly ("memory-safe") {
            mstore(0x00, 0)
            extcodecopy(a, 0x09, 0, 23) // the 23 bytes into the low bytes of the scratch word
            let w := mload(0x00)
            if eq(shr(160, w), DELEGATION_PREFIX) { d := and(w, 0xffffffffffffffffffffffffffffffffffffffff) }
        }
    }

    function _spend(bytes32 slot, uint256 value, bool inbound) private {
        uint256 left = _tload(slot);
        if (value > left) revert OverPoolManagerBudget(inbound);
        unchecked {
            _tstore(slot, left - value);
        }
    }

    function _tload(bytes32 slot) private view returns (uint256 v) {
        assembly ("memory-safe") {
            v := tload(slot)
        }
    }

    function _tstore(bytes32 slot, uint256 v) private {
        assembly ("memory-safe") {
            tstore(slot, v)
        }
    }
}
