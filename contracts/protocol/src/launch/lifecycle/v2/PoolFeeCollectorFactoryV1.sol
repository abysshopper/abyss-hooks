// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { IAbyssLaunchFactory } from "../../../interfaces/IAbyssLaunch.sol";
import { ILaunchHookV1 } from "../../../hooks/v4/authoring/ILaunchHookV1.sol";
import { PoolBoundLaunchHookBaseV1 } from "../../../hooks/v4/authoring/PoolBoundLaunchHookBaseV1.sol";
import { PoolHookDeployerV1 } from "../../../hooks/v4/authoring/PoolHookDeployerV1.sol";
import { V4HookFlags } from "../../../hooks/v4/V4HookFlags.sol";
import { PoolBoundHookParametersV2 } from "../../../hooks/v4/PoolBoundHookParametersV2.sol";
import { V4FeeCollectorV2 } from "../../fees/v2/V4FeeCollectorV2.sol";
import { V4FeeLiquidityLockerV2 } from "../../fees/v2/V4FeeLiquidityLockerV2.sol";
import { ILaunchFeeHubV3 } from "../../fees/v3/ILaunchFeeHubV3.sol";
import { MarketConfigV1, LaunchCapabilitiesV1, LaunchHookTopologyV1 } from "../v1/LaunchTypesV1.sol";
import { ILaunchRegistryV2, LaunchEnvelopeV2 } from "./ILaunchRegistryV2.sol";
import { LaunchGraphLibV2, IV4AdapterMetadataV2 } from "./LaunchGraphLibV2.sol";
import { PoolFeeCollectorDeployerV1 } from "./PoolFeeCollectorDeployerV1.sol";
import { V4MarketConfigV4 } from "./V4MarketConfigV4.sol";
import { V4MarketConfigV6 } from "./V4MarketConfigV6.sol";
import { V4MarketConfigLibV4 } from "./V4MarketConfigLibV4.sol";
import { V4MarketConfigLibV6 } from "./V4MarketConfigLibV6.sol";

/// @notice Immutable configuration, typed hook derivation and validation helper.
///         Canonical V2 collector creation uses a separately pinned typed deployer.
/// @dev Permissionless source creation confers no source admission or payout authority.
contract PoolFeeCollectorFactoryV1 {
    using PoolIdLibrary for PoolKey;
    error InvalidConfiguration();
    error InvalidMarket();
    bytes32 private constant MARKET_ECONOMICS_DOMAIN = keccak256("black-market.pool-bound-market-economics.v1");
    PoolFeeCollectorDeployerV1 public immutable collectorDeployer;
    bytes32 private immutable _collectorDeployerCodeHash;
    event FeeSourceCreated(address indexed collector, address indexed hub, bytes32 indexed poolId);

    constructor(PoolFeeCollectorDeployerV1 deployer_) {
        if (address(deployer_).code.length == 0) revert InvalidConfiguration();
        collectorDeployer = deployer_;
        _collectorDeployerCodeHash = address(deployer_).codehash;
    }

    function decodeAndValidate(address registrar, address token, MarketConfigV1 calldata market)
        external view returns (V4MarketConfigV4 memory config)
    {
        IV4AdapterMetadataV2 adapter = IV4AdapterMetadataV2(registrar);
        if (adapter.CONFIG_VERSION() == 4) {
            config = abi.decode(market.config, (V4MarketConfigV4));
            V4MarketConfigLibV4.validate(config, token, market.quoteAsset, market.tokenBudget);
            _validateAdmission(registrar, token, market, config);
            ILaunchHookV1(adapter.hookRoot()).validateOracleConfig(config.oracleConfigId);
        } else {
            config = _sharedFields(_decodePoolBoundAndValidate(registrar, token, market));
        }
    }

    function _decodePoolBoundAndValidate(address registrar, address token, MarketConfigV1 calldata market)
        private view returns (V4MarketConfigV6 memory config)
    {
        if (IV4AdapterMetadataV2(registrar).CONFIG_VERSION() != 6) revert InvalidConfiguration();
        config = abi.decode(market.config, (V4MarketConfigV6));
        V4MarketConfigLibV6.validate(config, token, market.quoteAsset, market.tokenBudget);
        _validateAdmission(registrar, token, market, _sharedFields(config));
    }

    function _validateAdmission(address registrar, address token, MarketConfigV1 calldata market,
        V4MarketConfigV4 memory config) private view
    {
        IV4AdapterMetadataV2 adapter = IV4AdapterMetadataV2(registrar);
        ILaunchRegistryV2 registry = ILaunchRegistryV2(adapter.implementationRegistry());
        uint64 required = LaunchCapabilitiesV1.REQUIRED;
        if (config.positions.length > 1) required |= LaunchCapabilitiesV1.MULTI_POSITION;
        if (market.profileId != adapter.PROFILE_ID() || config.profileId != market.profileId
            || market.configVersion != adapter.CONFIG_VERSION() || config.version != market.configVersion
            || registry.core() != adapter.core()
            || registry.requireEligible(market.adapterId, market.profileId, market.configVersion, required) != registrar) {
            revert InvalidConfiguration();
        }
        LaunchEnvelopeV2 memory envelope = registry.profileEnvelope(market.profileId);
        if (envelope.economicVersion != 3 || envelope.configVersion != market.configVersion
            || envelope.topology != (market.configVersion == 4 ? LaunchHookTopologyV1.SharedV4 : LaunchHookTopologyV1.PoolBoundV4)
            || config.termsDigest != envelope.termsDigest || config.developerBeneficiary != envelope.beneficiary
            || config.developerBeneficiary == token || config.developerBeneficiary == market.quoteAsset
            || config.developerFeeBps > envelope.maximumDeveloperFeeBps
            || config.developerFeeBps > registry.protocolMaximumDeveloperFeeBps()
            || config.treasury != envelope.protocolTreasury || config.protocolFeeDenominator != envelope.protocolFeeDenominator
            || (envelope.bounds.feeModeFlags & (uint8(1) << config.feeMode)) == 0
            || config.tickSpacing < envelope.bounds.minimumTickSpacing || config.tickSpacing > envelope.bounds.maximumTickSpacing
            || config.positions.length > envelope.bounds.maximumPositions) revert InvalidConfiguration();
        (uint24 move, uint16 cardinality) = IAbyssLaunchFactory(adapter.oracleFactory()).oracleConfigs(config.oracleConfigId);
        if (move == 0 || move > uint24(uint256(int256(TickMath.MAX_TICK))) || cardinality < 2
            || cardinality > envelope.bounds.maximumOracleCardinality) revert InvalidConfiguration();
    }

    function _sharedFields(V4MarketConfigV6 memory config) private pure returns (V4MarketConfigV4 memory shared) {
        shared.version = config.version;
        shared.lpFeePips = config.lpFeePips;
        shared.tickSpacing = config.tickSpacing;
        shared.sqrtPriceX96 = config.sqrtPriceX96;
        shared.hookFeePips = config.hookFeePips;
        shared.feeMode = config.feeMode;
        shared.protocolFeeDenominator = config.protocolFeeDenominator;
        shared.treasury = config.treasury;
        shared.externalLiquidityDisabled = config.externalLiquidityDisabled;
        shared.oracleConfigId = config.oracleConfigId;
        shared.profileId = config.profileId;
        shared.termsDigest = config.termsDigest;
        shared.developerBeneficiary = config.developerBeneficiary;
        shared.developerFeeBps = config.developerFeeBps;
        shared.positions = config.positions;
    }

    /// @dev Only deployment salt is normalized. Author terms remain in this full config
    ///      commitment; neither plan hash, hook prediction, collector nor hub enters it.
    function poolBoundHookParameters(address registrar, address token, MarketConfigV1 calldata market)
        external view returns (PoolBoundHookParametersV2 memory parameters, bytes32 salt)
    {
        return _parameters(registrar, token, market, _decodePoolBoundAndValidate(registrar, token, market));
    }

    function poolBoundDeploymentMetadata(address registrar, address token, MarketConfigV1 calldata market)
        external view returns (address deployer, bytes32 initCodeHash, bytes32 salt, address predictedHook)
    {
        PoolBoundHookParametersV2 memory parameters;
        (parameters, salt) = _parameters(registrar, token, market, _decodePoolBoundAndValidate(registrar, token, market));
        deployer = IV4AdapterMetadataV2(registrar).hookDeployer();
        initCodeHash = PoolHookDeployerV1(deployer).initCodeHash(parameters);
        predictedHook = _predict(deployer, salt, initCodeHash);
    }

    function resolvePoolBound(address registrar, address token, MarketConfigV1 calldata market)
        external view returns (V4MarketConfigV4 memory config, PoolKey memory key)
    {
        (config,,,, key) = _poolBoundConfiguration(registrar, token, market);
    }

    /// @dev Permissionless typed predeployment only. Registrar remains the adapter; pool
    ///      registration, initialization, source terms and lifecycle state never move here.
    function preparePoolBound(address registrar, address token, MarketConfigV1 calldata market)
        external returns (V4MarketConfigV4 memory config, PoolKey memory key)
    {
        PoolBoundHookParametersV2 memory parameters;
        bytes32 salt;
        PoolHookDeployerV1 deployer;
        (config, parameters, salt, deployer, key) = _poolBoundConfiguration(registrar, token, market);
        PoolBoundLaunchHookBaseV1 hook = PoolBoundLaunchHookBaseV1(address(key.hooks));
        if (address(hook).code.length == 0 && address(deployer.deploy(parameters, salt)) != address(hook)) {
            revert InvalidMarket();
        }
        _validatePoolBoundHook(deployer, hook, parameters, PoolId.unwrap(key.toId()));
    }

    function _poolBoundConfiguration(address registrar, address token, MarketConfigV1 calldata market)
        private view returns (V4MarketConfigV4 memory config, PoolBoundHookParametersV2 memory parameters,
            bytes32 salt, PoolHookDeployerV1 deployer, PoolKey memory key)
    {
        V4MarketConfigV6 memory bound = _decodePoolBoundAndValidate(registrar, token, market);
        config = _sharedFields(bound);
        (parameters, salt) = _parameters(registrar, token, market, bound);
        deployer = PoolHookDeployerV1(IV4AdapterMetadataV2(registrar).hookDeployer());
        address hook = _predict(address(deployer), salt, deployer.initCodeHash(parameters));
        if (!V4HookFlags.hasSharedLaunchV2Permissions(hook)) revert InvalidConfiguration();
        address quote = market.quoteAsset;
        key.currency0 = Currency.wrap(token < quote ? token : quote);
        key.currency1 = Currency.wrap(token < quote ? quote : token);
        key.fee = config.lpFeePips;
        key.tickSpacing = config.tickSpacing;
        key.hooks = IHooks(hook);
    }

    function _predict(address deployer, bytes32 salt, bytes32 initCodeHash) private pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
    }

    function _parameters(address registrar, address token, MarketConfigV1 calldata market, V4MarketConfigV6 memory config)
        private view returns (PoolBoundHookParametersV2 memory parameters, bytes32 salt)
    {
        IV4AdapterMetadataV2 adapter = IV4AdapterMetadataV2(registrar);
        salt = config.hookSalt;
        config.hookSalt = bytes32(0);
        parameters.poolManager = adapter.poolManager();
        parameters.registrar = registrar;
        parameters.oracleFactory = adapter.oracleFactory();
        parameters.core = adapter.core();
        parameters.liquidityLocker = adapter.locker();
        parameters.token = token;
        parameters.quoteCurrency = market.quoteAsset;
        parameters.lpFeePips = config.lpFeePips;
        parameters.tickSpacing = config.tickSpacing;
        parameters.sqrtPriceX96 = config.sqrtPriceX96;
        parameters.hookFeePips = config.hookFeePips;
        parameters.minimumHookFeePips = config.minimumHookFeePips;
        parameters.feeSensitivityPipsSecondsPerTick = config.feeSensitivityPipsSecondsPerTick;
        parameters.feeMode = config.feeMode;
        parameters.protocolFeeDenominator = config.protocolFeeDenominator;
        parameters.treasury = config.treasury;
        parameters.externalLiquidityDisabled = config.externalLiquidityDisabled;
        parameters.oracleConfigId = config.oracleConfigId;
        parameters.marketCommitment = _marketCommitment(parameters.core, registrar, token, market, keccak256(abi.encode(config)));
        parameters.expectedPositionCount = uint32(config.positions.length);
    }

    function dependencyDigest(address registrar) external view returns (bytes32) {
        _requireCollectorDeployer();
        IV4AdapterMetadataV2 adapter = IV4AdapterMetadataV2(registrar);
        return LaunchGraphLibV2.digest(adapter.core(), adapter.implementationRegistry(), registrar,
            LaunchGraphLibV2.live(registrar));
    }

    function _validatePoolBoundHook(PoolHookDeployerV1 deployer, PoolBoundLaunchHookBaseV1 hook,
        PoolBoundHookParametersV2 memory parameters, bytes32 id) private view
    {
        bytes32 recorded = deployer.deployedCodeHash(address(hook));
        if (recorded == bytes32(0) || recorded != address(hook).codehash
            || hook.deploymentConfigHash() != keccak256(abi.encode(parameters))
            || hook.boundPoolId() != id || hook.marketCommitment() != parameters.marketCommitment
            || hook.core() != parameters.core || hook.registrar() != parameters.registrar
            || address(hook.poolManager()) != parameters.poolManager || address(hook.oracleFactory()) != parameters.oracleFactory
            || hook.liquidityLocker() != parameters.liquidityLocker || hook.token() != parameters.token
            || hook.openingSqrtPriceX96() != parameters.sqrtPriceX96
            || hook.expectedPositionCount() != parameters.expectedPositionCount
            || hook.minimumHookFeePips() != parameters.minimumHookFeePips
            || hook.feeSensitivityPipsSecondsPerTick() != parameters.feeSensitivityPipsSecondsPerTick
            || hook.REQUIRED_HOOK_FLAGS() != 0x1afc || hook.ALL_HOOK_MASK() != 0x3fff) revert InvalidMarket();
        if (hook.registered(id) || hook.initialized(id) || hook.openingCompletedAt(id) != 0
            || hook.poolConfig(id).collector != address(0)) revert InvalidMarket();
    }

    function validateHub(address registrar, address hub, address token) external view {
        IV4AdapterMetadataV2 adapter = IV4AdapterMetadataV2(registrar);
        if (hub.code.length == 0 || ILaunchFeeHubV3(hub).economicVersion() != 3
            || address(ILaunchFeeHubV3(hub).implementationRegistry()) != adapter.implementationRegistry()
            || ILaunchFeeHubV3(hub).configurator() != adapter.core() || ILaunchFeeHubV3(hub).launchToken() != token
            || ILaunchFeeHubV3(hub).finalized()) revert InvalidConfiguration();
    }

    function validateEmptyOpening(IPoolManager manager, V4FeeLiquidityLockerV2 locker,
        PoolKey calldata key, uint160 opening) external view
    {
        bytes32 id = PoolId.unwrap(key.toId());
        ILaunchHookV1 hook = ILaunchHookV1(address(key.hooks));
        if (!hook.registered(id) || !hook.initialized(id)) revert InvalidMarket();
        (uint160 price,,,) = StateLibrary.getSlot0(manager, PoolId.wrap(id));
        if (price != opening || StateLibrary.getLiquidity(manager, PoolId.wrap(id)) != 0
            || locker.positionCount(id) != 0 || locker.isSealed(id)) revert InvalidMarket();
    }

    function _marketCommitment(address core, address registrar, address token, MarketConfigV1 calldata market, bytes32 configHash)
        private view returns (bytes32 commitment)
    {
        bytes32[11] memory terms;
        terms[0] = MARKET_ECONOMICS_DOMAIN;
        terms[1] = bytes32(block.chainid);
        terms[2] = bytes32(uint256(uint160(core)));
        terms[3] = bytes32(uint256(uint160(registrar)));
        terms[4] = bytes32(uint256(uint160(token)));
        terms[5] = market.adapterId;
        terms[6] = market.profileId;
        terms[7] = bytes32(uint256(uint160(market.quoteAsset)));
        terms[8] = bytes32(market.tokenBudget);
        terms[9] = bytes32(uint256(market.configVersion));
        terms[10] = configHash;
        assembly ("memory-safe") { commitment := keccak256(terms, 0x160) }
    }

    function create(address hub, V4FeeLiquidityLockerV2 locker, PoolKey calldata key, uint256 expectedPositionCount)
        external returns (V4FeeCollectorV2 collector)
    {
        _requireCollectorDeployer();
        collector = collectorDeployer.create(hub, locker, key, expectedPositionCount);
        emit FeeSourceCreated(address(collector), hub, PoolId.unwrap(key.toId()));
    }

    function _requireCollectorDeployer() private view {
        if (address(collectorDeployer).codehash != _collectorDeployerCodeHash) revert InvalidConfiguration();
    }
}
