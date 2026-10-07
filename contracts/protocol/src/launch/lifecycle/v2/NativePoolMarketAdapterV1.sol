// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { IAbyssLaunchFactory } from "../../../interfaces/IAbyssLaunch.sol";
import { PoolHookDeployerV1 } from "../../../hooks/v4/authoring/PoolHookDeployerV1.sol";
import { V4FeeLiquidityLockerV2 } from "../../fees/v2/V4FeeLiquidityLockerV2.sol";
import { MarketConfigV1 } from "../v1/LaunchTypesV1.sol";
import { ILaunchRegistryV2 } from "./ILaunchRegistryV2.sol";
import { V4MarketConfigV4 } from "./V4MarketConfigV4.sol";
import { V4MarketConfigLibV6 } from "./V4MarketConfigLibV6.sol";
import { PoolFeeCollectorFactoryV1 } from "./PoolFeeCollectorFactoryV1.sol";
import { V4MarketAdapterBaseV1 } from "./V4MarketAdapterBaseV1.sol";

/// @notice Derives one exact scalar hook per admitted market, with provenance-authenticated
///         permissionless predeployment adoption and immutable V3 source economics.
contract NativePoolMarketAdapterV1 is V4MarketAdapterBaseV1 {
    bytes32 public constant CONFIG_SCHEMA = V4MarketConfigLibV6.CONFIG_SCHEMA;
    uint32 public constant CONFIG_VERSION = 6;
    IAbyssLaunchFactory public immutable oracleFactory;
    PoolHookDeployerV1 public immutable hookDeployer;

    constructor(address core_, IPoolManager manager_, IAbyssLaunchFactory oracleFactory_, V4FeeLiquidityLockerV2 locker_,
        PoolHookDeployerV1 deployer_, PoolFeeCollectorFactoryV1 helper_,
        ILaunchRegistryV2 registry_, bytes32 profileId_)
        V4MarketAdapterBaseV1(core_, manager_, locker_, helper_, registry_, profileId_)
    {
        if (address(oracleFactory_).code.length == 0 || address(deployer_).code.length == 0
            || deployer_.creationCodeHash() == bytes32(0) || deployer_.codeChunk0().code.length <= 1
            || (deployer_.codeChunk1() != address(0) && deployer_.codeChunk1().code.length <= 1)) revert InvalidConfiguration();
        oracleFactory = oracleFactory_;
        hookDeployer = deployer_;
    }

    /// @dev Zero means exact typed derivation in this topology, never arbitrary hook choice.
    function hookRoot() external pure returns (address) { return address(0); }

    /// @notice Available before a valid salt is mined; execution, not this metadata read,
    ///         enforces hook-address permission bits and unused instance state.
    function hookDeploymentMetadata(address token, MarketConfigV1 calldata market)
        external view returns (address deployer, bytes32 initCodeHash, bytes32 salt, address predictedHook)
    {
        return collectorFactory.poolBoundDeploymentMetadata(address(this), token, market);
    }

    function _resolveConfiguration(address token, MarketConfigV1 calldata market)
        internal view override returns (V4MarketConfigV4 memory config, PoolKey memory key)
    {
        return collectorFactory.resolvePoolBound(address(this), token, market);
    }

    function _prepareConfiguration(address token, MarketConfigV1 calldata market)
        internal override returns (V4MarketConfigV4 memory config, PoolKey memory key)
    {
        return collectorFactory.preparePoolBound(address(this), token, market);
    }
}
