// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/base/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IVenueToken} from "./VenueGate.sol";

/// @title PoolHookBase
/// @notice Common base of the two pool hooks:
///  - `gate`: the only address allowed to initialize a pool on the hook, and by default the only one allowed to add
///    liquidity to it, so nobody can initialize the pool first at their own price or trade around it with range
///    orders or just-in-time liquidity (PoolTaxHook lets anyone add once its launch window is over);
///  - one reference price per pool: the price at the start of the current block, recorded by the block's first
///    swap before it moves the price, so one block's own trades cannot move it. The Burner, the Builder and the
///    pool's compounding act only within a band around it;
///  - the protocol's own contracts (`burner`, `builder`, `pool`, and `gate`), which PoolTaxHook exempts from its tax;
///  - after every swap, liquidity change and donation, a report to the pool's token (currency1; currency0 is ETH)
///    of how much of it the operation left owed to or by the pool manager, which is what the token lets move in or
///    out of the pool manager (see VenueGate).
/// `gate` and the protocol contracts are set once by the deployer.
abstract contract PoolHookBase is BaseHook {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address public immutable deployer;
    address public gate;
    /// @notice Buys and burns POOL with fees and tax.
    address public burner;
    /// @notice Adds protocol-owned SCORE/ETH liquidity with tax.
    address public builder;
    /// @notice ScoreLiquidity.
    address public pool;

    struct Ref {
        uint64 blockNumber;
        uint160 sqrtPriceX96;
    }

    mapping(PoolId => Ref) private refs;

    error NotGate();
    error AlreadySet();

    /// @dev `deployer_` is passed in because hooks are deployed through a CREATE2 factory, so msg.sender is the
    /// factory.
    constructor(IPoolManager manager_, address deployer_) BaseHook(manager_) {
        deployer = deployer_;
    }

    /// @notice Deployer only, once: sets the gate.
    function setGate(address gate_) external {
        if (msg.sender != deployer || gate != address(0) || gate_ == address(0)) revert AlreadySet();
        gate = gate_;
    }

    /// @notice Deployer only, once: sets the protocol's own contracts.
    function setProtocol(address burner_, address builder_, address pool_) external {
        if (msg.sender != deployer || burner != address(0)) revert AlreadySet();
        if (burner_ == address(0) || builder_ == address(0) || pool_ == address(0)) revert AlreadySet();
        burner = burner_;
        builder = builder_;
        pool = pool_;
    }

    /// @notice The pool's reference sqrtPrice: its price at the start of this block (recorded by the block's first
    /// swap before it moved it), or its current price if nothing has traded yet this block.
    function blockOpenSqrtPrice(PoolId id) public view returns (uint160 open) {
        Ref memory r = refs[id];
        if (r.blockNumber == block.number) return r.sqrtPriceX96;
        (open,,,) = poolManager.getSlot0(id);
    }

    /// @dev Whether `sender` is one of the protocol's contracts (the gate included).
    function _isProtocol(address sender) internal view returns (bool) {
        return sender == burner || sender == builder || sender == pool || sender == gate;
    }

    /// @dev Records the reference price at the block's first swap, before the swap moves the price.
    function _recordRef(PoolKey calldata key) internal {
        PoolId id = key.toId();
        if (refs[id].blockNumber != block.number) {
            (uint160 p,,,) = poolManager.getSlot0(id);
            refs[id] = Ref(uint64(block.number), p);
        }
    }

    /// @dev Only the gate.
    function _beforeInitialize(address sender, PoolKey calldata, uint160) internal override returns (bytes4) {
        if (sender != gate || sender == address(0)) revert NotGate();
        return this.beforeInitialize.selector;
    }

    function _beforeAddLiquidity(address sender, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        virtual
        override
        returns (bytes4)
    {
        if (sender != gate || sender == address(0)) revert NotGate();
        return this.beforeAddLiquidity.selector;
    }

    function _afterAddLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        _credit(key, delta.amount1());
        return (this.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /// @dev Also runs for a zero liquidity change, which collects fees.
    function _afterRemoveLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        _credit(key, delta.amount1());
        return (this.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /// @dev A donation is owed to the pool manager.
    function _afterDonate(address, PoolKey calldata key, uint256, uint256 amount1, bytes calldata)
        internal
        override
        returns (bytes4)
    {
        _credit(key, -int128(int256(amount1))); // the pool manager has already checked it fits int128
        return this.afterDonate.selector;
    }

    /// @dev Reports the caller's token delta for this operation to the token: negative is owed to the pool manager
    /// (inbound), positive is owed by it. The hooks never take a delta on the token side, so the caller's delta
    /// passed to the hook is what will be settled.
    function _credit(PoolKey calldata key, int128 amount1) internal {
        if (amount1 == 0) return;
        bool inbound = amount1 < 0;
        uint256 amount = inbound ? uint256(-int256(amount1)) : uint256(int256(amount1));
        IVenueToken(Currency.unwrap(key.currency1)).creditPoolManager(inbound, amount);
    }
}
