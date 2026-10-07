// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolId } from "@uniswap/v4-core/src/types/PoolId.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { ILaunchFeeSourceV1 } from "../../../launch/fees/v1/ILaunchFeeSourceV1.sol";
import { ILaunchFeeHubV3, SourceTermsV3 } from "../../../launch/fees/v3/ILaunchFeeHubV3.sol";
import { V4FeeLiquidityLockerV2 } from "../../../launch/fees/v2/V4FeeLiquidityLockerV2.sol";
import { ILaunchLifecycleV1 } from "../../../launch/lifecycle/v1/ILaunchLifecycleV1.sol";
import { LaunchExecutionContextV1, LaunchProgressV1, LaunchOperationV1, LaunchPhaseV1 } from "../../../launch/lifecycle/v1/LaunchTypesV1.sol";
import { ILaunchHookV1 } from "./ILaunchHookV1.sol";
import { ILaunchHookAuthorTerms } from "./ILaunchHookAuthorTerms.sol";

interface IPoolBoundLaunchHookValidationSourceV2 is ILaunchHookV1, ILaunchHookAuthorTerms {
    function core() external view returns (address);
    function liquidityLocker() external view returns (address);
    function token() external view returns (address);
    function boundPoolId() external view returns (bytes32);
    function expectedPositionCount() external view returns (uint32);
}

interface IPoolBoundLaunchHookValidationCollectorV2 is ILaunchFeeSourceV1 {
    function poolManager() external view returns (IPoolManager);
    function locker() external view returns (V4FeeLiquidityLockerV2);
    function hookRoot() external view returns (address);
    function poolId() external view returns (bytes32);
    function poolKey() external view returns (PoolKey memory);
    function expectedPositionCount() external view returns (uint256);
}

/// @notice Fixed read-only scalar registration/Prepare validator, created by the V2 base itself.
/// @dev No constructor input, owner, storage, delegatecall or replacement route. Moving cold
///      validation out of the near-EIP170 scalar callback runtime does not remove any checks.
///      Its exact creation code is embedded in the concrete hook creation artifact; admission
///      must review that transitive dependency, not mistake the existing graph tuple for an
///      additional independently certified helper role. validationHelper() exposes the instance.
contract PoolBoundLaunchHookValidationV2 {
    error InvalidConfiguration();
    error Unauthorized();

    /// @dev Read the nonvirtual hook getters once; all downstream checks use that exact snapshot.
    struct ValidationContext {
        bytes32 poolId;
        IPoolManager manager;
        address locker;
        address registrar;
        address core;
        address token;
        address asset0;
        address asset1;
        uint32 expectedPositionCount;
    }

    function validateRegistration(ILaunchHookV1.PoolConfig calldata config) external view {
        IPoolBoundLaunchHookValidationSourceV2 hook = IPoolBoundLaunchHookValidationSourceV2(msg.sender);
        ValidationContext memory c = _validationContext(hook);
        ILaunchHookV1.PoolConfig memory frozen = hook.poolConfig(c.poolId);
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(c.manager, PoolId.wrap(c.poolId));
        if (
            c.asset0.code.length == 0 || c.asset1.code.length == 0 || sqrtPriceX96 != 0
                || config.liquidityLocker != c.locker
                || Currency.unwrap(config.quoteCurrency) != Currency.unwrap(frozen.quoteCurrency)
                || config.feeMode != frozen.feeMode || config.hookFeePips != frozen.hookFeePips
                || config.protocolFeeDenominator != frozen.protocolFeeDenominator
                || config.treasury != frozen.treasury
                || config.externalLiquidityDisabled != frozen.externalLiquidityDisabled
                || config.oracleConfigId != frozen.oracleConfigId
                || config.collector.code.length == 0 || config.collector == c.locker
                || config.collector == msg.sender || config.collector == address(c.manager)
        ) revert InvalidConfiguration();
        _validateCollector(c, config);
    }

    /// @notice Validate the required author rate only after the adapter has bound source terms.
    /// @dev Registration and afterInitialize run before bindSourceTerms. The canonical collector's
    ///      hub is immutable and that hub binds terms once, so successful authentication may be
    ///      cached for the pool lifetime. No author-supplied payee or second royalty debit exists.
    function validateAuthorTerms() external view {
        IPoolBoundLaunchHookValidationSourceV2 hook = IPoolBoundLaunchHookValidationSourceV2(msg.sender);
        ILaunchHookV1.PoolConfig memory config = hook.poolConfig(hook.boundPoolId());
        ILaunchFeeHubV3 feeHub = ILaunchFeeHubV3(ILaunchFeeSourceV1(config.collector).hub());
        SourceTermsV3 memory terms = feeHub.sourceTerms(config.collector);
        uint16 requiredBps = hook.authorFeeBps();
        if (
            requiredBps > 9_999 || feeHub.launchToken() != hook.token()
                || feeHub.configurator() != hook.core() || terms.adapter != hook.registrar()
                || terms.profileId == bytes32(0) || terms.termsDigest == bytes32(0)
                || terms.beneficiary == address(0) || terms.developerFeeBps != requiredBps
                || terms.developerFeeBps > terms.maximumDeveloperFeeBps
        ) revert InvalidConfiguration();
    }

    function _validationContext(IPoolBoundLaunchHookValidationSourceV2 hook)
        private view returns (ValidationContext memory c)
    {
        c.poolId = hook.boundPoolId();
        c.manager = hook.poolManager();
        c.locker = hook.liquidityLocker();
        c.registrar = hook.registrar();
        c.core = hook.core();
        c.token = hook.token();
        c.expectedPositionCount = hook.expectedPositionCount();
        PoolKey memory key = hook.poolKey(c.poolId);
        c.asset0 = Currency.unwrap(key.currency0);
        c.asset1 = Currency.unwrap(key.currency1);
    }

    function _validateCollector(ValidationContext memory c, ILaunchHookV1.PoolConfig calldata config)
        private view
    {
        IPoolBoundLaunchHookValidationCollectorV2 collector = IPoolBoundLaunchHookValidationCollectorV2(config.collector);
        V4FeeLiquidityLockerV2 locker = V4FeeLiquidityLockerV2(c.locker);
        address hub = collector.hub();
        address[] memory sourceAssets = collector.assets();
        if (
            address(collector.poolManager()) != address(c.manager)
                || address(collector.locker()) != c.locker
                || collector.hookRoot() != msg.sender || collector.poolId() != c.poolId
                || keccak256(abi.encode(collector.poolKey())) != c.poolId
                || collector.expectedPositionCount() != c.expectedPositionCount
                || address(locker.poolManager()) != address(c.manager)
                || locker.launcher() != c.registrar || locker.positionCount(c.poolId) != 0
                || locker.isSealed(c.poolId) || locker.positionsHash(c.poolId) != bytes32(0)
                || locker.feeRecipient(c.poolId) != address(0)
                || sourceAssets.length != 2 || sourceAssets[0] != c.asset0
                || sourceAssets[1] != c.asset1
                || hub.code.length == 0 || hub == msg.sender || hub == config.collector
                || hub == c.locker || hub == address(c.manager)
                || hub == c.asset0 || hub == c.asset1
                || config.treasury == hub || config.treasury == config.collector
        ) revert InvalidConfiguration();
        ILaunchFeeHubV3 feeHub = ILaunchFeeHubV3(hub);
        if (
            feeHub.launchToken() != c.token || feeHub.configurator() != c.core || feeHub.finalized()
        ) revert InvalidConfiguration();
        _validatePrepareContext(c, hub, Currency.unwrap(config.quoteCurrency));
    }

    function _validatePrepareContext(ValidationContext memory c, address hub, address quote)
        private view
    {
        ILaunchLifecycleV1 lifecycle = ILaunchLifecycleV1(c.core);
        LaunchExecutionContextV1 memory context = lifecycle.executionContext();
        if (
            context.launchId == bytes32(0) || context.operation != LaunchOperationV1.Prepare
                || context.adapter != c.registrar || context.executor != c.registrar
                || context.token != c.token || context.quoteAsset != quote
                || context.manager != address(c.manager)
        ) revert Unauthorized();
        LaunchProgressV1 memory progress = lifecycle.readLaunchProgress(context.launchId);
        if (
            progress.launchId != context.launchId || progress.phase != LaunchPhaseV1.Preparing
                || progress.token != c.token || progress.feeHub != hub
                || context.marketIndex >= progress.marketCount
        ) revert Unauthorized();
    }
}
