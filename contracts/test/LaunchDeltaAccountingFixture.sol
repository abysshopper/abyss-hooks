// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { BalanceDelta, BalanceDeltaLibrary } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import { TransientStateLibrary } from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import { ILaunchHookV1 } from "../src/hooks/v4/authoring/ILaunchHookV1.sol";
import { IERC20Fork } from "./ForkTrader.sol";

/// @notice Reusable real-manager accounting assertions for lifecycle hook qualification.
/// @dev Read-only proof; does not settle, mint claims, change fees or replace hook callbacks.
abstract contract LaunchDeltaAccountingFixture is Test {
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;

    struct SwapBalances {
        uint256 amount0;
        uint256 amount1;
    }

    function _snapshotSwapBalances(PoolKey memory key, address payer)
        internal view returns (SwapBalances memory)
    {
        return SwapBalances(
            IERC20Fork(Currency.unwrap(key.currency0)).balanceOf(payer),
            IERC20Fork(Currency.unwrap(key.currency1)).balanceOf(payer)
        );
    }

    function _assertSwapAccounting(
        IPoolManager manager, PoolKey memory key, address swapper, address payer,
        SwapBalances memory beforeBalances, BalanceDelta delta
    ) internal view {
        _assertBalanceDelta(key.currency0, payer, beforeBalances.amount0, delta.amount0());
        _assertBalanceDelta(key.currency1, payer, beforeBalances.amount1, delta.amount1());
        assertEq(TransientStateLibrary.currencyDelta(manager, swapper, key.currency0), 0);
        assertEq(TransientStateLibrary.currencyDelta(manager, swapper, key.currency1), 0);
        assertEq(TransientStateLibrary.currencyDelta(manager, address(key.hooks), key.currency0), 0);
        assertEq(TransientStateLibrary.currencyDelta(manager, address(key.hooks), key.currency1), 0);
        _assertHookFeeBacking(manager, key);
    }

    function _assertHookFeeBacking(IPoolManager manager, PoolKey memory key) internal view {
        bytes32 id = PoolId.unwrap(key.toId());
        _assertCurrencyBacking(manager, ILaunchHookV1(address(key.hooks)), id, key.currency0);
        _assertCurrencyBacking(manager, ILaunchHookV1(address(key.hooks)), id, key.currency1);
    }

    function _assertCurrencyBacking(
        IPoolManager manager, ILaunchHookV1 hook, bytes32 id, Currency currency
    ) private view {
        address asset = Currency.unwrap(currency);
        uint256 pending = hook.pendingFees(id, asset);
        uint256 settled = hook.settledFees(id, asset);
        uint256 claims = hook.aggregateManagerClaims(asset);
        assertLe(settled, pending);
        assertEq(hook.aggregateLiabilities(asset), pending);
        assertEq(claims, pending - settled);
        assertEq(manager.balanceOf(address(hook), uint160(asset)), claims);
        assertGe(IERC20Fork(asset).balanceOf(address(hook)), settled);
        assertLe(hook.pendingTreasurySweeps(id, asset), pending);
    }

    function _assertBalanceDelta(Currency currency, address payer, uint256 beforeBalance, int128 delta)
        private view
    {
        uint256 afterBalance = IERC20Fork(Currency.unwrap(currency)).balanceOf(payer);
        if (delta < 0) assertEq(beforeBalance - afterBalance, uint256(-int256(delta)));
        else assertEq(afterBalance - beforeBalance, uint256(int256(delta)));
    }
}
