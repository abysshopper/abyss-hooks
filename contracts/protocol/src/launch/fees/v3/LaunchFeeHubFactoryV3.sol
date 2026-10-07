// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ReentrancyGuard } from "solady/utils/ReentrancyGuard.sol";

import { ILaunchFeeOwnerRegistry } from "../../../interfaces/ILaunchRewards.sol";
import { LaunchFeeOwnerRegistryV2 } from "../../LaunchFeeOwnerRegistryV2.sol";
import { FeeAssetPolicyV2 } from "../v2/ILaunchFeeHubV2.sol";
import { ILaunchRegistryV2 } from "../../lifecycle/v2/ILaunchRegistryV2.sol";
import { DeveloperClaimResultV3, ILaunchFeeHubV3, ILaunchFeeHubFactoryV3 } from "./ILaunchFeeHubV3.sol";
import { LaunchFeeHubV3 } from "./LaunchFeeHubV3.sol";

/// @notice Fresh-stack, core-only V3 deployment with the unchanged lifecycle createHub ABI.
/// @dev The protocol admin must explicitly bind this factory as the dedicated fee registry's
///      launcher. No existing fee registry, hub, profile or default stack is converted.
contract LaunchFeeHubFactoryV3 is ILaunchFeeHubFactoryV3, ReentrancyGuard {
    error ZeroAddress();
    error InvalidRegistry();
    error InvalidImplementationRegistry();
    error InvalidConfigurator();
    error Unauthorized();
    error RegistryNotBound();
    error ExistingLaunchBinding();
    error InvalidPageLimit();
    error InvalidAssetList();
    error InsufficientPageGas();

    event HubCreated(
        address indexed launchToken,
        address indexed hub,
        address indexed initialOwner,
        address configurator,
        uint16 executorFeeBps
    );

    uint256 public constant MAX_CLAIM_HUBS = 10;
    uint256 public constant MAX_CLAIM_ASSETS = 8;
    uint256 public constant DEVELOPER_CLAIM_GAS = 200_000;
    uint256 private constant RESULT_GAS_RESERVE = 10_000;
    uint256 private constant PAGE_GAS_RESERVE = 30_000;

    LaunchFeeOwnerRegistryV2 public immutable registry;
    address public immutable deploymentAuthority;
    ILaunchRegistryV2 public immutable implementationRegistry;
    mapping(address hub => bool canonical) public override isHub;

    constructor(
        LaunchFeeOwnerRegistryV2 registry_,
        address core_,
        ILaunchRegistryV2 implementationRegistry_
    ) {
        if (core_ == address(0)) revert ZeroAddress();
        if (
            address(registry_).code.length == 0 || registry_.protocolAdmin() == address(0)
                || registry_.launcher() != address(0)
        ) revert InvalidRegistry();
        if (
            address(implementationRegistry_).code.length == 0
                || implementationRegistry_.protocolMaximumDeveloperFeeBps() >= 10_000
                || implementationRegistry_.core() != core_
        ) revert InvalidImplementationRegistry();
        registry = registry_;
        deploymentAuthority = core_;
        implementationRegistry = implementationRegistry_;
    }

    /// @notice Deploys a true V3 hub, then registers its owner and splitter atomically.
    /// @dev The old lifecycle interface returns address; the encoded result is identical.
    function createHub(
        address launchToken,
        address initialOwner,
        FeeAssetPolicyV2[] memory policies,
        uint16 executorFeeBps,
        address configurator
    ) external returns (LaunchFeeHubV3 hub) {
        if (msg.sender != deploymentAuthority) revert Unauthorized();
        if (configurator != deploymentAuthority) revert InvalidConfigurator();
        if (registry.launcher() != address(this)) revert RegistryNotBound();
        if (
            registry.feeOwner(launchToken) != address(0)
                || registry.feeSplitter(launchToken) != address(0)
        ) revert ExistingLaunchBinding();
        hub = new LaunchFeeHubV3(
            launchToken,
            ILaunchFeeOwnerRegistry(address(registry)),
            policies,
            executorFeeBps,
            configurator,
            implementationRegistry
        );
        registry.registerLaunch(launchToken, initialOwner);
        registry.bindSplitter(launchToken, address(hub));
        isHub[address(hub)] = true;
        emit HubCreated(launchToken, address(hub), initialOwner, configurator, executorFeeBps);
    }

    /// @notice Pays one bounded discovery page directly from canonical hubs to live author payouts.
    /// @dev An empty asset list selects each hub's own assets. Failed rows retain their credits;
    ///      retry them directly or rescan from zero after later accrual. No funds enter the factory.
    function claimDeveloperFeesPage(
        address authorId, uint256 offset, uint256 limit, address[] calldata assets
    ) external override nonReentrant returns (
        DeveloperClaimResultV3[] memory results, uint256 nextOffset, uint256 total
    ) {
        if (limit == 0 || limit > MAX_CLAIM_HUBS) revert InvalidPageLimit();
        if (assets.length > MAX_CLAIM_ASSETS) revert InvalidAssetList();
        address previous;
        for (uint256 i; i < assets.length; ++i) {
            if (assets[i] <= previous) revert InvalidAssetList();
            previous = assets[i];
        }
        address[] memory hubs;
        (hubs, nextOffset, total) = implementationRegistry.authorHubs(authorId, offset, limit);
        address[][] memory pageAssets = new address[][](hubs.length);
        address[] memory explicitAssets = assets;
        uint256 rowCount;
        for (uint256 i; i < hubs.length; ++i) {
            pageAssets[i] = assets.length == 0 ? ILaunchFeeHubV3(hubs[i]).assets() : explicitAssets;
            rowCount += pageAssets[i].length;
        }
        results = new DeveloperClaimResultV3[](rowCount);
        if (gasleft() < rowCount * RESULT_GAS_RESERVE + PAGE_GAS_RESERVE) revert InsufficientPageGas();
        _claimPageRows(authorId, hubs, pageAssets, results);
        emit DeveloperClaimPage(authorId, offset, nextOffset, total);
    }

    function _claimPageRows(
        address authorId,
        address[] memory hubs,
        address[][] memory pageAssets,
        DeveloperClaimResultV3[] memory results
    ) private {
        uint256 row;
        for (uint256 i; i < hubs.length; ++i) {
            address[] memory hubAssets = pageAssets[i];
            for (uint256 j; j < hubAssets.length; ++j) {
                DeveloperClaimResultV3 memory result = results[row];
                result.hub = hubs[i];
                result.asset = hubAssets[j];
                _claimDeveloperFees(
                    authorId, result,
                    (results.length - row) * RESULT_GAS_RESERVE + PAGE_GAS_RESERVE
                );
                emit DeveloperClaimResult(
                    authorId, result.hub, result.asset, result.amount, result.status, result.errorSelector
                );
                ++row;
            }
        }
    }

    function _claimDeveloperFees(
        address authorId, DeveloperClaimResultV3 memory result, uint256 completionGas
    ) private {
        result.status = 3;
        // Leave enough gas to record every remaining row and the cursor even if this call
        // exhausts its allowance. The additional 1/63 accounts for EIP-150 forwarding.
        if (gasleft() < DEVELOPER_CLAIM_GAS + DEVELOPER_CLAIM_GAS / 63 + 10_000 + completionGas) return;
        address hub = result.hub;
        address asset = result.asset;
        bool success;
        uint256 returnSize;
        uint256 amount;
        bytes4 selector = ILaunchFeeHubV3.claimDeveloperFees.selector;
        bytes4 returnedSelector;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, selector)
            mstore(add(ptr, 4), authorId)
            mstore(add(ptr, 36), asset)
            // Copy at most one word, including on revert; arbitrary return data stays in
            // the child frame and cannot consume this page's completion reserve.
            success := call(DEVELOPER_CLAIM_GAS, hub, 0, ptr, 68, ptr, 32)
            returnSize := returndatasize()
            amount := mload(ptr)
            returnedSelector := and(mload(ptr), shl(224, 0xffffffff))
        }
        if (success && returnSize == 32) {
            result.amount = amount;
            result.status = amount == 0 ? 1 : 0;
        } else if (!success && returnSize >= 4) {
            result.errorSelector = returnedSelector;
            if (returnedSelector == LaunchFeeHubV3.UnsupportedAsset.selector) result.status = 2;
        }
    }
}
