// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { IAbyssLaunchFactory, IAbyssLaunchPoolDeployer, IAbyssLaunchPositionManager,
    IAbyssLaunchPositionLocker, PoolProfile } from "../../../interfaces/IAbyssLaunch.sol";
import { ProfileRegistrationV1, AdapterRegistrationV1, ProfileTopologyV1,
    LaunchHookTopologyV1, LaunchCapabilitiesV1 } from "../v1/LaunchTypesV1.sol";
import { ABYSS_PROFILE_DOMAIN_V1 } from "../v1/AbyssMarketConfigV1.sol";
import { LaunchEnvelopeV2, LaunchGraphV2 } from "./ILaunchRegistryV2.sol";
import { LaunchGraphLibV2, IV4AdapterMetadataV2,
    IHookDeployerGraphV2 } from "./LaunchGraphLibV2.sol";
import { V4MarketConfigLibV4 } from "./V4MarketConfigLibV4.sol";
import { V4MarketConfigLibV6 } from "./V4MarketConfigLibV6.sol";

interface ISharedHookGraphV2 {
    function poolManager() external view returns (address);
    function registrar() external view returns (address);
    function oracleFactory() external view returns (address);
    function REQUIRED_HOOK_FLAGS() external view returns (uint160);
    function ALL_HOOK_MASK() external view returns (uint160);
}
interface ISharedDeployerProvenanceV2 {
    function predict(IPoolManager manager, address registrar, IAbyssLaunchFactory oracleFactory, bytes32 salt)
        external view returns (address);
}
interface ILockerGraphV2 {
    function poolManager() external view returns (address);
    function launcher() external view returns (address);
}
interface ICoreGraphV2 {
    function registry() external view returns (address);
}

interface IAbyssAdapterMetadataV2 {
    function core() external view returns (address);
    function factory() external view returns (IAbyssLaunchFactory);
    function positionManager() external view returns (IAbyssLaunchPositionManager);
    function locker() external view returns (IAbyssLaunchPositionLocker);
    function sourceFactory() external view returns (address);
    function profileId(uint8 variant) external view returns (bytes32);
    function PROFILE_DOMAIN() external view returns (bytes32);
    function CONFIG_SCHEMA() external view returns (bytes32);
    function CONFIG_VERSION() external view returns (uint32);
    function CAPABILITIES() external view returns (uint64);
}
interface IAbyssSourceFactoryGraphV2 {
    function core() external view returns (address);
    function factory() external view returns (address);
    function positionManager() external view returns (address);
    function locker() external view returns (address);
}
interface IAbyssPoolDeployerGraphV2 is IAbyssLaunchPoolDeployer {
    function factory() external view returns (address);
}

/// @notice Stateless certification helper owned immutably by the V2 registry.
/// @dev Exact hashes are governance's full-code approval, not an ABI/flag safety oracle.
contract LaunchCertificationV2 {
    error InvalidRegistration();
    uint64 private constant SUPPORTED_CAPABILITIES = LaunchCapabilitiesV1.REQUIRED
        | LaunchCapabilitiesV1.ERC404 | LaunchCapabilitiesV1.MULTI_POSITION;
    uint256 private constant MAX_CHUNK = 24_575;
    bytes32 private constant ABYSS_CONFIG_SCHEMA =
        keccak256("(uint8,uint24,bytes32,uint160,(int24,int24,uint128,uint256)[])");
    bytes32 private constant ABYSS_PROVENANCE =
        keccak256("abyss-canonical:c66eb07986b88db11ad617be7cf362e1368d72e6;lifecycle-v1");

    /// @notice Certify the unchanged config1 canonical graph, never an unsigned V4 envelope.
    function certifyAbyss(
        address core,
        bytes32 id,
        uint8 variant,
        ProfileRegistrationV1 calldata registration,
        AdapterRegistrationV1 calldata implementation
    ) external view returns (ProfileTopologyV1 memory) {
        IAbyssAdapterMetadataV2 adapter = IAbyssAdapterMetadataV2(implementation.implementation);
        if (variant > uint8(PoolProfile.QUOTE_ORACLE) || implementation.configVersion != 1
            || implementation.capabilities != SUPPORTED_CAPABILITIES
            || registration.capabilities != SUPPORTED_CAPABILITIES
            || registration.configSchema != ABYSS_CONFIG_SCHEMA
            || adapter.CONFIG_VERSION() != 1 || adapter.CONFIG_SCHEMA() != ABYSS_CONFIG_SCHEMA
            || adapter.CAPABILITIES() != SUPPORTED_CAPABILITIES
            || adapter.PROFILE_DOMAIN() != ABYSS_PROFILE_DOMAIN_V1 || adapter.core() != core
            || core.code.length == 0 || ICoreGraphV2(core).registry() != msg.sender) {
            revert InvalidRegistration();
        }
        IAbyssLaunchFactory factory = adapter.factory();
        if (address(factory).code.length == 0 || registration.venue != address(factory)
            || registration.factory != address(factory) || registration.hook != address(0)
            || id != keccak256(abi.encode(ABYSS_PROFILE_DOMAIN_V1, block.chainid, address(factory), variant))) {
            revert InvalidRegistration();
        }
        // Preserve the unchanged adapter's exact graph order and dependencyDigest encoding.
        address[6] memory graph = [
            address(factory), address(factory.poolDeployer()), address(adapter.positionManager()),
            address(adapter.locker()), adapter.sourceFactory(), factory.feeVault()
        ];
        _validateAbyssGraph(core, graph);
        if (registration.dependencyDigest != _abyssDependencyDigest(core, graph)) revert InvalidRegistration();
        return ProfileTopologyV1(LaunchHookTopologyV1.None, 1, address(0), bytes32(0));
    }

    function _validateAbyssGraph(address core, address[6] memory graph) private view {
        for (uint256 i; i < graph.length; ++i) {
            if (graph[i].code.length == 0) revert InvalidRegistration();
        }
        IAbyssSourceFactoryGraphV2 sourceFactory = IAbyssSourceFactoryGraphV2(graph[4]);
        if (IAbyssPoolDeployerGraphV2(graph[1]).factory() != graph[0]
            || address(IAbyssLaunchPositionManager(graph[2]).factory()) != graph[0]
            || address(IAbyssLaunchPositionLocker(graph[3]).positionManager()) != graph[2]
            || sourceFactory.core() != core || sourceFactory.factory() != graph[0]
            || sourceFactory.positionManager() != graph[2] || sourceFactory.locker() != graph[3]) {
            revert InvalidRegistration();
        }
    }

    function _abyssDependencyDigest(address core, address[6] memory graph)
        private view returns (bytes32)
    {
        bytes32 acc;
        for (uint256 i; i < graph.length; ++i) {
            acc = keccak256(abi.encode(acc, graph[i], graph[i].codehash));
        }
        IAbyssLaunchPoolDeployer deployer = IAbyssLaunchPoolDeployer(graph[1]);
        for (uint8 variant; variant < 4; ++variant) {
            bytes32 initCodeHash = deployer.expectedInitCodeHash(PoolProfile(variant));
            if (initCodeHash == bytes32(0)) revert InvalidRegistration();
            acc = keccak256(abi.encode(acc, initCodeHash));
        }
        return keccak256(abi.encode(ABYSS_PROVENANCE, core, core.codehash, acc));
    }

    function certify(
        address core,
        bytes32 id,
        ProfileRegistrationV1 calldata registration,
        AdapterRegistrationV1 calldata implementation,
        LaunchEnvelopeV2 calldata envelope,
        uint16 protocolCeiling
    ) external view returns (ProfileTopologyV1 memory topology) {
        IV4AdapterMetadataV2 adapter =
            IV4AdapterMetadataV2(implementation.implementation);
        bool shared = envelope.topology == LaunchHookTopologyV1.SharedV4;
        if (!shared && envelope.topology != LaunchHookTopologyV1.PoolBoundV4) revert InvalidRegistration();
        uint32 version = shared ? 4 : 6;
        bytes32 schema = shared ? V4MarketConfigLibV4.CONFIG_SCHEMA : V4MarketConfigLibV6.CONFIG_SCHEMA;
        if (envelope.artifactDigest == bytes32(0) || envelope.reviewManifestDigest == bytes32(0)
            || envelope.termsDigest == bytes32(0) || envelope.configBoundsDigest != keccak256(abi.encode(envelope.bounds))
            || envelope.configVersion != version || envelope.economicVersion != 3 || envelope.flags != 0
            || envelope.callbackFlags != 0x1afc || envelope.callbackMask != 0x3fff
            || envelope.capabilities != registration.capabilities || envelope.capabilities != implementation.capabilities
            || (envelope.capabilities & ~SUPPORTED_CAPABILITIES) != 0
            || implementation.configVersion != version || registration.configSchema != schema
            || adapter.PROFILE_ID() != id || adapter.CONFIG_SCHEMA() != schema || adapter.CONFIG_VERSION() != version
            || adapter.implementationRegistry() != msg.sender || adapter.core() != core
            || registration.factory != address(0) || registration.venue != envelope.graph.manager
            || registration.hook != envelope.graph.hookRoot
            || envelope.maximumDeveloperFeeBps > protocolCeiling) revert InvalidRegistration();
        _validateBounds(envelope);
        _validateGraph(core, implementation.implementation, envelope.graph, shared);
        _validateBeneficiary(core, implementation.implementation, envelope);
        if (registration.dependencyDigest != LaunchGraphLibV2.digest(
            core, msg.sender, implementation.implementation, envelope.graph
        )) revert InvalidRegistration();
        topology = ProfileTopologyV1(envelope.topology, version,
            envelope.graph.hookDeployer, envelope.graph.hookCreationCodeHash);
    }

    function _validateBounds(LaunchEnvelopeV2 calldata envelope) private pure {
        if (envelope.bounds.minimumTickSpacing < TickMath.MIN_TICK_SPACING
            || envelope.bounds.maximumTickSpacing > TickMath.MAX_TICK_SPACING
            || envelope.bounds.minimumTickSpacing > envelope.bounds.maximumTickSpacing
            || envelope.bounds.maximumPositions == 0 || envelope.bounds.maximumPositions > 32
            || envelope.bounds.maximumOracleCardinality < 2 || envelope.bounds.maximumOracleCardinality > 4096
            || envelope.bounds.feeModeFlags == 0 || (envelope.bounds.feeModeFlags & ~uint8(3)) != 0
            || envelope.protocolTreasury == address(0)
            || (envelope.protocolFeeDenominator != 0
                && (envelope.protocolFeeDenominator < 4 || envelope.protocolFeeDenominator > 10))) {
            revert InvalidRegistration();
        }
    }

    function _validateGraph(address core, address registrar, LaunchGraphV2 calldata expected, bool shared)
        private view
    {
        LaunchGraphV2 memory live = LaunchGraphLibV2.live(registrar);
        // Salt is immutable provenance evidence, not a live executable dependency.
        live.sharedHookSalt = expected.sharedHookSalt;
        if (keccak256(abi.encode(live)) != keccak256(abi.encode(expected))
            || core.code.length == 0 || ICoreGraphV2(core).registry() != msg.sender
            || expected.manager.code.length == 0 || expected.oracleFactory.code.length == 0
            || expected.locker.code.length == 0 || expected.collectorFactory.code.length == 0
            || expected.collectorDeployer.code.length == 0 || expected.hookDeployer.code.length == 0
            || ILockerGraphV2(expected.locker).launcher() != registrar
            || ILockerGraphV2(expected.locker).poolManager() != expected.manager
            || expected.locker == expected.manager || expected.locker == expected.hookRoot) revert InvalidRegistration();
        _validateCreationCode(expected);
        if (shared) {
            ISharedHookGraphV2 root = ISharedHookGraphV2(expected.hookRoot);
            if (expected.hookRoot.code.length == 0 || root.registrar() != registrar
                || root.poolManager() != expected.manager || root.oracleFactory() != expected.oracleFactory
                || root.REQUIRED_HOOK_FLAGS() != 0x1afc || root.ALL_HOOK_MASK() != 0x3fff
                || (uint160(expected.hookRoot) & 0x3fff) != 0x1afc
                || IHookDeployerGraphV2(expected.hookDeployer).deployedCodeHash(expected.hookRoot)
                    != expected.hookRuntimeCodeHash
                || ISharedDeployerProvenanceV2(expected.hookDeployer).predict(
                    IPoolManager(expected.manager), registrar, IAbyssLaunchFactory(expected.oracleFactory),
                    expected.sharedHookSalt) != expected.hookRoot) revert InvalidRegistration();
        } else if (expected.hookRoot != address(0) || expected.hookRuntimeCodeHash != bytes32(0)
            || expected.sharedHookSalt != bytes32(0)) revert InvalidRegistration();
    }

    function _validateBeneficiary(address core, address registrar, LaunchEnvelopeV2 calldata envelope)
        private view
    {
        address beneficiary = envelope.beneficiary;
        if (beneficiary == address(0) || beneficiary == core || beneficiary == msg.sender
            || beneficiary == registrar || beneficiary == envelope.graph.manager || beneficiary == envelope.graph.hookRoot
            || beneficiary == envelope.graph.locker || beneficiary == envelope.graph.collectorFactory
            || beneficiary == envelope.graph.collectorDeployer || beneficiary == envelope.graph.hookDeployer) {
            revert InvalidRegistration();
        }
    }

    function _validateCreationCode(LaunchGraphV2 calldata graph) private view {
        if (graph.hookCreationCodeHash == bytes32(0) || graph.codeChunk0 == graph.codeChunk1) revert InvalidRegistration();
        uint256 length0 = _payloadLength(graph.codeChunk0);
        uint256 length1 = graph.codeChunk1 == address(0) ? 0 : _payloadLength(graph.codeChunk1);
        if (length1 != 0 && length0 != MAX_CHUNK) revert InvalidRegistration();
        // Bound's exact V2 constructor is twenty words; shared's is three words.
        uint256 argsLength = graph.hookRoot == address(0) ? 20 * 32 : 3 * 32;
        if (length0 + length1 + argsLength > 49_152) revert InvalidRegistration();
        bytes memory creationCode = new bytes(length0 + length1);
        address chunk0 = graph.codeChunk0;
        address chunk1 = graph.codeChunk1;
        assembly ("memory-safe") {
            let output := add(creationCode, 0x20)
            extcodecopy(chunk0, output, 1, length0)
            if length1 { extcodecopy(chunk1, add(output, length0), 1, length1) }
        }
        if (keccak256(creationCode) != graph.hookCreationCodeHash) revert InvalidRegistration();
    }

    function _payloadLength(address chunk) private view returns (uint256) {
        uint256 length = chunk.code.length;
        if (length <= 1 || length > MAX_CHUNK + 1) revert InvalidRegistration();
        uint256 prefix;
        assembly ("memory-safe") { extcodecopy(chunk, 0, 0, 1) prefix := byte(0, mload(0)) }
        if (prefix != 0) revert InvalidRegistration();
        return length - 1;
    }
}
