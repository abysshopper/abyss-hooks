// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { FeeAssetPolicyV2 } from "../../fees/v2/ILaunchFeeHubV2.sol";
import {
    TokenConfigV1, LaunchPlanV1, MarketConfigV1, InitialBuyV1, LaunchModeV1,
    LaunchPhaseV1, LaunchOperationV1, MarketIdentityV1, PreparedMarketV1,
    PositionIdentityV1, LaunchExecutionContextV1, LaunchProgressV1, LaunchReceiptV1,
    AdapterRegistrationV1, ProfileRegistrationV1, ProfileTopologyV1, MarketLiveStateV1
} from "./LaunchTypesV1.sol";

interface ILaunchLifecycleV1 {
    event LaunchBegun(bytes32 indexed launchId, bytes32 indexed planHash, address indexed creator, address token, address feeHub, address rewards, LaunchModeV1 mode);
    event MarketPrepared(bytes32 indexed launchId, uint32 indexed marketIndex, bytes32 indexed canonicalId, address adapter, address feeSource, uint32 positionCount);
    event LaunchReady(bytes32 indexed launchId);
    event InitialBuyExecuted(bytes32 indexed launchId, uint32 indexed buyIndex, uint32 indexed marketIndex, address quoteAsset, uint256 quoteSpent, uint256 tokenOut, address recipient);
    event LaunchActivated(bytes32 indexed launchId, bytes32 indexed planHash, address indexed token, uint32 marketCount, uint32 positionCount);
    event LaunchCancelled(bytes32 indexed launchId, address indexed creator, bool inventoryBurned);
    event AssetRefunded(bytes32 indexed launchId, address indexed asset, address indexed creator, uint256 amount);

    function hashPlan(LaunchPlanV1 calldata plan) external pure returns (bytes32);
    function launchIdOf(LaunchPlanV1 calldata plan) external pure returns (bytes32);
    function predictToken(LaunchPlanV1 calldata plan) external view returns (address);
    function launchAtomic(LaunchPlanV1 calldata plan) external payable returns (LaunchReceiptV1 memory);
    function beginLaunch(LaunchPlanV1 calldata plan, LaunchModeV1 mode) external payable returns (LaunchProgressV1 memory);
    function prepareMarkets(LaunchPlanV1 calldata plan, uint32 firstMarket, uint32 count) external;
    function activateLaunch(LaunchPlanV1 calldata plan) external returns (LaunchReceiptV1 memory);
    function cancelLaunch(LaunchPlanV1 calldata plan) external;
    function readLaunchProgress(bytes32 launchId) external view returns (LaunchProgressV1 memory);
    function executionContext() external view returns (LaunchExecutionContextV1 memory);
    function isLaunchActive(bytes32 launchId) external view returns (bool);
    function authorizeTokenTransfer(address token, address caller, address from, address to, uint256 amount, bool nft) external view returns (bool);
    function escrowBalance(bytes32 launchId, address asset) external view returns (uint256);
}

interface ILaunchLifecycleTokenV1 {
    function finalizeExclusions(address[] calldata exclusions) external;
    function activate() external;
    function cancel(bool burnInventory) external;
}

interface ILaunchTokenFactoryV1 {
    function core() external view returns (address);
    function predictToken(bytes32 launchId, TokenConfigV1 calldata config) external view returns (address);
    function deployToken(bytes32 launchId, TokenConfigV1 calldata config) external returns (address token);
    function createRewards(address token, address hub, address[] calldata rewardAssets) external returns (address rewards);
}

/// @notice Ordinary-call, frozen-core adapters. No payer pulls, delegatecall or ambient sweeps.
interface ILaunchMarketAdapterV1 {
    function core() external view returns (address);
    function dependencyDigest() external view returns (bytes32);
    function resolve(bytes32 launchId, address token, MarketConfigV1 calldata market) external view returns (MarketIdentityV1 memory);
    function prepareMarket(bytes32 launchId, uint32 marketIndex, address token, address hub, MarketConfigV1 calldata market) external returns (PreparedMarketV1 memory);
    function validatePrepared(bytes32 launchId, uint32 marketIndex, address token, MarketConfigV1 calldata market, MarketIdentityV1 calldata identity) external view;
    /// @dev Receives exactly tokenBudget before entry, returns unused token to core before exit;
    ///      quote debt must be zero. Positions must be permanently collector-owned/sealed.
    function mintAndLock(bytes32 launchId, uint32 marketIndex, address token, MarketConfigV1 calldata market) external returns (PositionIdentityV1[] memory positions, uint256 tokenSpent);
    /// @dev Receives exactly quoteAmountIn before entry, returns unused quote to core before exit.
    ///      Output goes to the committed recipient; core independently measures recipient delta.
    function executeBuy(bytes32 launchId, uint32 marketIndex, address token, MarketConfigV1 calldata market, InitialBuyV1 calldata buy) external returns (uint256 quoteSpent, uint256 tokenOut);
    /// @dev Called only after ALL positions/buys succeed. No venue pool gate exists: the
    ///      reported live state becomes publicTrading=true only when BOTH the adapter-local
    ///      activation (with canonical opening-state verification) AND core Active hold.
    function activateMarket(bytes32 launchId, uint32 marketIndex) external;
    /// @dev Called through core only with an exact live context. Must authenticate venue-specific
    ///      caller/from/to edges, including NPM account callbacks and ERC404 operator paths.
    function authorizeTokenTransfer(bytes32 launchId, uint32 marketIndex, LaunchOperationV1 operation, address caller, address from, address to, uint256 amount, bool nft) external view returns (bool);
    function readMarket(bytes32 launchId, uint32 marketIndex) external view returns (MarketLiveStateV1 memory);
    function readPosition(PositionIdentityV1 calldata position) external view returns (uint128 liquidity, address owner);
}

interface ILaunchImplementationRegistryV1 {
    function core() external view returns (address);
    function adapter(bytes32 adapterId) external view returns (AdapterRegistrationV1 memory);
    function profile(bytes32 profileId) external view returns (ProfileRegistrationV1 memory);
    function profileTopology(bytes32 profileId) external view returns (ProfileTopologyV1 memory);
    function fundingInputAllowed(address asset) external view returns (bool);
    function requireEligible(bytes32 adapterId, bytes32 profileId, uint32 configVersion, uint64 requiredCapabilities) external view returns (address implementation);
    function fundingTarget(address target) external view returns (address spender, bytes32 codeHash, bool enabled);
}

interface ILaunchDirectoryV1 {
    function core() external view returns (address);
    function recordLaunch(bytes32 launchId, address token, address creator, address hub) external;
    function recordMarket(bytes32 launchId, uint32 marketIndex, address adapter, PreparedMarketV1 calldata prepared) external;
    function recordPositions(bytes32 launchId, uint32 marketIndex, PositionIdentityV1[] calldata positions) external;
    function market(bytes32 launchId, uint32 marketIndex) external view returns (address adapter, PreparedMarketV1 memory prepared);
    function positions(bytes32 launchId, uint32 marketIndex, uint256 offset, uint256 limit) external view returns (PositionIdentityV1[] memory);
    function launches(uint256 offset, uint256 limit) external view returns (bytes32[] memory);
    function launchOfToken(address token) external view returns (bytes32);
    function marketCount(bytes32 launchId) external view returns (uint256);
    function positionCount(bytes32 launchId, uint32 marketIndex) external view returns (uint256);
}

/// @dev V1 and V2 factories share this construction shape; lifecycle uses the generalized V2.
interface ILaunchLifecycleFeeFactoryV1 {
    function deploymentAuthority() external view returns (address);
    function createHub(address launchToken, address initialOwner, FeeAssetPolicyV2[] calldata policies, uint16 executorFeeBps, address configurator) external returns (address hub);
}

interface ILaunchLifecycleFeeHubV1 {
    function configureSources(address[] calldata sources, address rewards) external;
    function finalized() external view returns (bool);
}
