// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IUnlockCallback } from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import { BalanceDelta } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import { BeforeSwapDelta } from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { ModifyLiquidityParams, SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { IAbyssLaunchFactory } from "../../../interfaces/IAbyssLaunch.sol";

/// @notice Full-key collection and binding contract for author-submitted launch hooks.
/// @dev The wire tuple and legacy-required getters match the canonical V2 collector/locker.
///      ABI conformance, inheritance and permission flags do not prove arbitrary runtime safety.
///      Admission must review the entire concrete runtime, creation artifact and dependency graph.
interface ILaunchHookV1 is IUnlockCallback {
    enum FeeMode {
        InputToken,
        QuoteOnly
    }

    struct PoolConfig {
        address collector;
        address liquidityLocker;
        Currency quoteCurrency;
        FeeMode feeMode;
        uint24 hookFeePips;
        uint8 protocolFeeDenominator;
        address treasury;
        bool externalLiquidityDisabled;
        bytes32 oracleConfigId;
    }

    function PIPS_DENOMINATOR() external view returns (uint24);
    function REQUIRED_HOOK_FLAGS() external view returns (uint160);
    function ALL_HOOK_MASK() external view returns (uint160);
    function poolManager() external view returns (IPoolManager);
    function registrar() external view returns (address);
    function oracleFactory() external view returns (IAbyssLaunchFactory);
    function pools() external view returns (bytes32[] memory);
    function registered(bytes32 id) external view returns (bool);
    function initialized(bytes32 id) external view returns (bool);
    function poolKey(bytes32 id) external view returns (PoolKey memory);
    function poolConfig(bytes32 id) external view returns (PoolConfig memory);
    function pendingFees(bytes32 id, address asset) external view returns (uint256);
    function pendingTreasurySweeps(bytes32 id, address asset) external view returns (uint256);
    function settledFees(bytes32 id, address asset) external view returns (uint256);
    function aggregateLiabilities(address asset) external view returns (uint256);
    function aggregateManagerClaims(address asset) external view returns (uint256);
    function registerPool(PoolKey calldata key, PoolConfig calldata config) external;
    function completePoolOpening(PoolKey calldata key) external;
    function openingCompletedAt(bytes32 id) external view returns (uint256);
    function validateCollector(PoolKey calldata key, address collector, address liquidityLocker)
        external
        view;
    function collectFees(PoolKey calldata key)
        external
        returns (uint256 amount0, uint256 amount1);
    /// @notice Genuine oracle genesis timestamp, or zero when no oracle is composed.
    function oracleInitializedAt(bytes32 id) external view returns (uint256);

    function afterInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96, int24 tick)
        external
        returns (bytes4);
    function beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external returns (bytes4);
    function beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external returns (bytes4);
    function beforeSwap(
        address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData
    ) external returns (bytes4, BeforeSwapDelta, uint24);
    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external returns (bytes4, int128);
    function beforeDonate(
        address sender,
        PoolKey calldata key,
        uint256 amount0,
        uint256 amount1,
        bytes calldata hookData
    ) external returns (bytes4);
    function afterDonate(
        address sender,
        PoolKey calldata key,
        uint256 amount0,
        uint256 amount1,
        bytes calldata hookData
    ) external returns (bytes4);
}
