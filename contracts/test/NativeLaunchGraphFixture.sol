// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { IAbyssLaunchFactory } from "../src/interfaces/IAbyssLaunch.sol";
import { LaunchFeeOwnerRegistryV2 } from "../protocol/src/launch/LaunchFeeOwnerRegistryV2.sol";
// Artifact-only imports keep every real CREATE actor available in clean, repo-only CI builds.
import { LaunchOrchestratorV1 } from "../protocol/src/launch/lifecycle/v1/LaunchOrchestratorV1.sol";
import { LaunchDirectoryV1 } from "../protocol/src/launch/lifecycle/v1/LaunchDirectoryV1.sol";
import { LaunchFundingEscrowV1 } from "../protocol/src/launch/lifecycle/v1/LaunchFundingEscrowV1.sol";
import { LaunchImplementationRegistryV2 } from "../protocol/src/launch/lifecycle/v2/LaunchImplementationRegistryV2.sol";
import { LaunchPlanValidatorV2 } from "../protocol/src/launch/lifecycle/v2/LaunchPlanValidatorV2.sol";
import { LaunchLifecycleTokenFactoryV1 } from "../protocol/src/launch/lifecycle/v1/tokens/LaunchLifecycleTokenFactoryV1.sol";
import { LaunchERC20DeployerV1, LaunchERC404DeployerV1, LaunchStakingDeployerV1 } from "../protocol/src/launch/lifecycle/v1/tokens/LaunchTokenDeployerV1.sol";
import { LaunchFeeHubFactoryV3 } from "../protocol/src/launch/fees/v3/LaunchFeeHubFactoryV3.sol";
import { PoolFeeCollectorFactoryV1 } from "../protocol/src/launch/lifecycle/v2/PoolFeeCollectorFactoryV1.sol";
import { PoolFeeCollectorDeployerV1 } from "../protocol/src/launch/lifecycle/v2/PoolFeeCollectorDeployerV1.sol";
import { NativePoolMarketAdapterV1 } from "../protocol/src/launch/lifecycle/v2/NativePoolMarketAdapterV1.sol";
import { V4FeeLiquidityLockerV2 } from "../protocol/src/launch/fees/v2/V4FeeLiquidityLockerV2.sol";

/// @notice Fresh actual V6 launch infrastructure against existing, untouched fork venues.
/// @dev Bootstrap order follows black-market's LaunchHookQualificationHarnessV1._deployCore.
///      Admission remains the caller's responsibility: no selected hook, locker, adapter or
///      profile is deployed or registered here, and no public launch graph is reused or relabeled.
abstract contract NativeLaunchGraphFixture is Test {
    string internal constant NATIVE_POOL_MARKET_ADAPTER_ARTIFACT =
        "contracts/protocol/src/launch/lifecycle/v2/NativePoolMarketAdapterV1.sol:NativePoolMarketAdapterV1";
    string internal constant NATIVE_FEE_LIQUIDITY_LOCKER_ARTIFACT =
        "contracts/protocol/src/launch/fees/v2/V4FeeLiquidityLockerV2.sol:V4FeeLiquidityLockerV2";

    struct NativeLaunchGraph {
        address core;
        address registry;
        address collectorFactory;
        address collectorDeployer;
    }

    struct NativeCoreBootstrap {
        address tokenFactory;
        address feeOwnerRegistry;
        address feeFactory;
        address directory;
        address escrow;
        address validator;
    }

    function _deployNativeLaunchGraph(
        IPoolManager manager,
        IAbyssLaunchFactory oracleFactory,
        address wrappedNative,
        bytes32 registeredOracleId,
        uint16 protocolMaximumDeveloperFeeBps
    ) internal returns (NativeLaunchGraph memory graph) {
        require(address(manager).code.length != 0 && address(oracleFactory).code.length != 0,
            "native graph venues require actual code");
        require(wrappedNative.code.length != 0, "native graph wrapped native requires actual code");
        (uint24 move, uint16 cardinality) = oracleFactory.oracleConfigs(registeredOracleId);
        require(move != 0 && move <= uint24(uint256(int256(TickMath.MAX_TICK)))
            && cardinality >= 2 && cardinality <= 4_096, "native graph oracle must be registered");

        graph = _deployNativeCore(wrappedNative, protocolMaximumDeveloperFeeBps);
        graph.collectorDeployer = _deployNativeActor(
            "contracts/protocol/src/launch/lifecycle/v2/PoolFeeCollectorDeployerV1.sol:PoolFeeCollectorDeployerV1", ""
        );
        graph.collectorFactory = _deployNativeActor(
            "contracts/protocol/src/launch/lifecycle/v2/PoolFeeCollectorFactoryV1.sol:PoolFeeCollectorFactoryV1",
            abi.encode(graph.collectorDeployer)
        );
    }

    function _deployNativeCore(address wrappedNative, uint16 protocolMaximumDeveloperFeeBps)
        private returns (NativeLaunchGraph memory graph)
    {
        uint256 nonce = vm.getNonce(address(this));
        address predictedTokenFactory = vm.computeCreateAddress(address(this), nonce + 3);
        graph.core = vm.computeCreateAddress(address(this), nonce + 10);
        NativeCoreBootstrap memory actors;
        // These eleven top-level CREATEs must remain consecutive. Constructors' own CREATEs
        // use the actors' nonces, not this fixture's, and therefore do not alter these bindings.
        {
            address erc20 = _deployNativeActor(
                "contracts/protocol/src/launch/lifecycle/v1/tokens/LaunchTokenDeployerV1.sol:LaunchERC20DeployerV1",
                abi.encode(predictedTokenFactory, graph.core)
            );
            address erc404 = _deployNativeActor(
                "contracts/protocol/src/launch/lifecycle/v1/tokens/LaunchTokenDeployerV1.sol:LaunchERC404DeployerV1",
                abi.encode(predictedTokenFactory, graph.core)
            );
            address staking = _deployNativeActor(
                "contracts/protocol/src/launch/lifecycle/v1/tokens/LaunchTokenDeployerV1.sol:LaunchStakingDeployerV1",
                abi.encode(predictedTokenFactory, graph.core)
            );
            actors.tokenFactory = _deployNativeActor(
                "contracts/protocol/src/launch/lifecycle/v1/tokens/LaunchLifecycleTokenFactoryV1.sol:LaunchLifecycleTokenFactoryV1",
                abi.encode(graph.core, erc20, erc404, staking)
            );
        }
        assertEq(actors.tokenFactory, predictedTokenFactory, "native token factory CREATE binding");
        graph.registry = _deployNativeActor(
            "contracts/protocol/src/launch/lifecycle/v2/LaunchImplementationRegistryV2.sol:LaunchImplementationRegistryV2",
            abi.encode(address(this), graph.core, protocolMaximumDeveloperFeeBps)
        );
        actors.feeOwnerRegistry = _deployNativeActor(
            "contracts/protocol/src/launch/LaunchFeeOwnerRegistryV2.sol:LaunchFeeOwnerRegistryV2",
            abi.encode(address(this))
        );
        actors.feeFactory = _deployNativeActor(
            "contracts/protocol/src/launch/fees/v3/LaunchFeeHubFactoryV3.sol:LaunchFeeHubFactoryV3",
            abi.encode(actors.feeOwnerRegistry, graph.core, graph.registry)
        );
        LaunchFeeOwnerRegistryV2(actors.feeOwnerRegistry).setLauncher(actors.feeFactory);
        actors.directory = _deployNativeActor(
            "contracts/protocol/src/launch/lifecycle/v1/LaunchDirectoryV1.sol:LaunchDirectoryV1", abi.encode(graph.core)
        );
        actors.escrow = _deployNativeActor(
            "contracts/protocol/src/launch/lifecycle/v1/LaunchFundingEscrowV1.sol:LaunchFundingEscrowV1",
            abi.encode(graph.core, graph.registry, wrappedNative)
        );
        actors.validator = _deployNativeActor(
            "contracts/protocol/src/launch/lifecycle/v2/LaunchPlanValidatorV2.sol:LaunchPlanValidatorV2",
            abi.encode(graph.registry, actors.tokenFactory, actors.escrow)
        );
        address deployedCore = _deployNativeActor(
            "contracts/protocol/src/launch/lifecycle/v1/LaunchOrchestratorV1.sol:LaunchOrchestratorV1",
            abi.encode(graph.registry, actors.tokenFactory, actors.feeFactory, actors.directory, actors.escrow, actors.validator)
        );
        assertEq(deployedCore, graph.core, "native core CREATE binding");
    }

    function _deployNativeActor(string memory artifact, bytes memory args) internal returns (address deployed) {
        bytes memory code = bytes.concat(vm.getCode(artifact), args);
        assertLe(code.length, 49_152, string.concat(artifact, " EIP3860 initcode"));
        assertLe(vm.getDeployedCode(artifact).length, 24_576, string.concat(artifact, " EIP170 template runtime"));
        assembly ("memory-safe") {
            deployed := create(0, add(code, 0x20), mload(code))
            if and(iszero(deployed), returndatasize()) {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
        }
        require(deployed != address(0) && deployed.code.length != 0, string.concat(artifact, " CREATE failed"));
        assertLe(deployed.code.length, 24_576, string.concat(artifact, " actual runtime"));
    }
}
