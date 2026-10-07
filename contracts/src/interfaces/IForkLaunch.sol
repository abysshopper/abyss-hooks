// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { IAbyssLaunchFactory } from "./IAbyssLaunch.sol";
import { ILaunchHookV1 } from "../hooks/v4/authoring/ILaunchHookV1.sol";
import { PoolHookDeployerV1 } from "../hooks/v4/authoring/PoolHookDeployerV1.sol";
import { PoolBoundHookParametersV2 } from "../hooks/v4/PoolBoundHookParametersV2.sol";
import { ILaunchFeeSourceV1 } from "../launch/fees/v1/ILaunchFeeSourceV1.sol";
import { V4FeeLiquidityLockerV2 } from "../launch/fees/v2/V4FeeLiquidityLockerV2.sol";
import {
    ILaunchLifecycleV1, ILaunchMarketAdapterV1, ILaunchImplementationRegistryV1,
    ILaunchTokenFactoryV1, ILaunchLifecycleFeeFactoryV1, ILaunchDirectoryV1
} from "../launch/lifecycle/v1/ILaunchLifecycleV1.sol";
import { MarketConfigV1 } from "../launch/lifecycle/v1/LaunchTypesV1.sol";
import { ILaunchRegistryV2 } from "../launch/lifecycle/v2/ILaunchRegistryV2.sol";

/// @notice Black Market integration ABIs used for the pinned venues and fresh V6 fixture actors.
interface LaunchOrchestratorV1 is ILaunchLifecycleV1 {
    function registry() external view returns (ILaunchImplementationRegistryV1);
    function tokenFactory() external view returns (ILaunchTokenFactoryV1);
    function feeFactory() external view returns (ILaunchLifecycleFeeFactoryV1);
    function directory() external view returns (ILaunchDirectoryV1);
    function fundingEscrow() external view returns (address);
    function validator() external view returns (address);
}

interface LaunchImplementationRegistryV2 is ILaunchRegistryV2 {
    function admin() external view returns (address);
    function registerAdapter(bytes32 id, address implementation, uint64 capabilities, uint32 configVersion) external;
    function setFundingInputAllowed(address asset, bool allowed) external;
}

interface V4MarketAdapterBaseV1 is ILaunchMarketAdapterV1 {
    function poolManager() external view returns (IPoolManager);
    function locker() external view returns (V4FeeLiquidityLockerV2);
    function collectorFactory() external view returns (PoolFeeCollectorFactoryV1);
    function implementationRegistry() external view returns (ILaunchRegistryV2);
    function PROFILE_ID() external view returns (bytes32);
    function CONFIG_SCHEMA() external view returns (bytes32);
    function CONFIG_VERSION() external view returns (uint32);
    function oracleFactory() external view returns (IAbyssLaunchFactory);
}

interface PoolMarketAdapterV1 is V4MarketAdapterBaseV1 {
    function hookRoot() external pure returns (address);
    function hookDeployer() external view returns (PoolHookDeployerV1);
    function hookDeploymentMetadata(address token, MarketConfigV1 calldata market)
        external view returns (address deployer, bytes32 initCodeHash, bytes32 salt, address predictedHook);
}

interface V4FeeCollectorV2 is ILaunchFeeSourceV1 {
    function poolManager() external view returns (IPoolManager);
    function locker() external view returns (V4FeeLiquidityLockerV2);
    function hookRoot() external view returns (ILaunchHookV1);
    function poolId() external view returns (bytes32);
    function expectedPositionCount() external view returns (uint256);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function poolKey() external view returns (PoolKey memory);
}

interface PoolFeeCollectorFactoryV1 {
    function poolBoundHookParameters(address registrar, address token, MarketConfigV1 calldata market)
        external view returns (PoolBoundHookParametersV2 memory parameters, bytes32 salt);
}
