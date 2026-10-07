// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { LaunchGraphV2 } from "./ILaunchRegistryV2.sol";

interface IV4AdapterMetadataV2 {
    function core() external view returns (address);
    function implementationRegistry() external view returns (address);
    function PROFILE_ID() external view returns (bytes32);
    function CONFIG_SCHEMA() external view returns (bytes32);
    function CONFIG_VERSION() external view returns (uint32);
    function poolManager() external view returns (address);
    function hookRoot() external view returns (address);
    function oracleFactory() external view returns (address);
    function locker() external view returns (address);
    function collectorFactory() external view returns (address);
    function hookDeployer() external view returns (address);
}

interface ICollectorFactoryGraphV2 {
    function collectorDeployer() external view returns (address);
}

interface IHookDeployerGraphV2 {
    function creationCodeHash() external view returns (bytes32);
    function codeChunk0() external view returns (address);
    function codeChunk1() external view returns (address);
    function deployedCodeHash(address hook) external view returns (bytes32);
}

/// @notice The live graph is independently reconstructed by admission; no factory's
///         self-reported digest is accepted as certification.
library LaunchGraphLibV2 {
    bytes32 internal constant GRAPH_DOMAIN = keccak256("black-market.v4-dependencies.v2");

    function live(address registrar) internal view returns (LaunchGraphV2 memory graph) {
        IV4AdapterMetadataV2 adapter = IV4AdapterMetadataV2(registrar);
        graph.manager = adapter.poolManager();
        graph.hookRoot = adapter.hookRoot();
        graph.oracleFactory = adapter.oracleFactory();
        graph.locker = adapter.locker();
        graph.collectorFactory = adapter.collectorFactory();
        graph.collectorDeployer = ICollectorFactoryGraphV2(graph.collectorFactory).collectorDeployer();
        graph.hookDeployer = adapter.hookDeployer();
        graph.coreCodeHash = adapter.core().codehash;
        graph.managerCodeHash = graph.manager.codehash;
        graph.hookRuntimeCodeHash = graph.hookRoot == address(0) ? bytes32(0) : graph.hookRoot.codehash;
        graph.oracleFactoryCodeHash = graph.oracleFactory.codehash;
        graph.lockerCodeHash = graph.locker.codehash;
        graph.collectorFactoryCodeHash = graph.collectorFactory.codehash;
        graph.collectorDeployerCodeHash = graph.collectorDeployer.codehash;
        graph.hookDeployerCodeHash = graph.hookDeployer.codehash;
        IHookDeployerGraphV2 deployer = IHookDeployerGraphV2(graph.hookDeployer);
        graph.hookCreationCodeHash = deployer.creationCodeHash();
        graph.codeChunk0 = deployer.codeChunk0();
        graph.codeChunk0Hash = graph.codeChunk0.codehash;
        graph.codeChunk1 = deployer.codeChunk1();
        graph.codeChunk1Hash = graph.codeChunk1 == address(0) ? bytes32(0) : graph.codeChunk1.codehash;
    }

    function digest(address core, address registry, address registrar, LaunchGraphV2 memory graph)
        internal view returns (bytes32 result)
    {
        // All runtime hashes are measured live by the adapter helper. The registry calls
        // this with the independently validated frozen envelope. No root prediction or
        // plan hash enters constructor economics; shared salt is only provenance evidence.
        bytes32[25] memory words;
        words[0] = GRAPH_DOMAIN;
        words[1] = bytes32(block.chainid);
        words[2] = bytes32(uint256(uint160(core)));
        words[3] = graph.coreCodeHash;
        words[4] = bytes32(uint256(uint160(registry)));
        words[5] = bytes32(uint256(uint160(registrar)));
        words[6] = bytes32(uint256(uint160(graph.manager)));
        words[7] = graph.managerCodeHash;
        words[8] = bytes32(uint256(uint160(graph.hookRoot)));
        words[9] = graph.hookRuntimeCodeHash;
        words[10] = bytes32(uint256(uint160(graph.oracleFactory)));
        words[11] = graph.oracleFactoryCodeHash;
        words[12] = bytes32(uint256(uint160(graph.locker)));
        words[13] = graph.lockerCodeHash;
        words[14] = bytes32(uint256(uint160(graph.collectorFactory)));
        words[15] = graph.collectorFactoryCodeHash;
        words[16] = bytes32(uint256(uint160(graph.collectorDeployer)));
        words[17] = graph.collectorDeployerCodeHash;
        words[18] = bytes32(uint256(uint160(graph.hookDeployer)));
        words[19] = graph.hookDeployerCodeHash;
        words[20] = graph.hookCreationCodeHash;
        words[21] = bytes32(uint256(uint160(graph.codeChunk0)));
        words[22] = graph.codeChunk0Hash;
        words[23] = bytes32(uint256(uint160(graph.codeChunk1)));
        words[24] = graph.codeChunk1Hash;
        assembly ("memory-safe") { result := keccak256(words, 0x320) }
    }
}
