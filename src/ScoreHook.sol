// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {PoolHookBase} from "./HookBase.sol";

/// @title ScoreHook
/// @notice Hook for the SCORE/ETH pool, a dynamic-fee pool whose LP fee this hook sets on every swap: a flat
/// `BASE_FEE` (1%) from the opening, for everyone, the protocol's own swaps included. The fee is an ordinary LP fee,
/// so all of it accrues to the pool's position. Only the pool contract (`gate`) may initialize the pool or add
/// liquidity, so all of the pool's liquidity, and all of its fees, go through the pool contract's split.
/// It also records each block's opening price (see PoolHookBase).
contract ScoreHook is PoolHookBase {
    /// @notice LP fee of every swap, in hundredths of a bip (1%).
    uint24 public constant BASE_FEE = 10_000;

    constructor(IPoolManager manager_, address deployer_) PoolHookBase(manager_, deployer_) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.beforeAddLiquidity = true;
        p.afterAddLiquidity = true;
        p.afterRemoveLiquidity = true;
        p.afterDonate = true;
        p.beforeSwap = true;
        p.afterSwap = true;
    }

    /// @notice LP fee a swap pays now, in hundredths of a bip.
    function currentFee() public pure returns (uint24) {
        return BASE_FEE;
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _recordRef(key);
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, BASE_FEE | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        _credit(key, delta.amount1()); // the hook takes no delta: the pool's delta is the caller's
        return (this.afterSwap.selector, 0);
    }
}
