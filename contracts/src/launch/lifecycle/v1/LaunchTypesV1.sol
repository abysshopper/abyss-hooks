// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { FeeAssetPolicyV2 } from "../../fees/v2/ILaunchFeeHubV2.sol";

enum LaunchModeV1 { Atomic, Staged }
enum LaunchPhaseV1 { None, Preparing, Ready, Activating, Active, Cancelled }
enum TokenKindV1 { ERC20, ERC404 }
enum RewardModeV1 { None, Staking, Dividends }
enum FundingKindV1 { ERC20, NativeWrap, Swap }
enum LaunchOperationV1 { None, Prepare, Mint, Buy, Open, Inventory }
enum LaunchVenueV1 { UniswapV4, Abyss }
enum LaunchHookTopologyV1 { None, SharedV4, PoolBoundV4 }

struct TokenConfigV1 {
    TokenKindV1 kind;
    RewardModeV1 rewardMode;
    string name;
    string symbol;
    uint256 supply;
    uint256 nftUnit;
    string metadataURI;
    bytes32 salt;
    address inventoryRecipient;
    bool burnOnCancel;
}

/// @dev `amount` is minimum committed output funding. Swap surplus is launch-local refundable
///      escrow. ERC20/NativeWrap use inputAmount == amount, inputAsset == asset, no swap data.
struct AssetFundingV1 {
    address asset;
    uint256 amount;
    FundingKindV1 kind;
    address inputAsset;
    uint256 inputAmount;
    address target;
    bytes data;
}

struct MarketConfigV1 {
    bytes32 adapterId;
    bytes32 profileId;
    address quoteAsset;
    uint256 tokenBudget;
    uint32 configVersion;
    bytes config;
}

struct InitialBuyV1 {
    uint32 marketIndex;
    uint256 quoteAmountIn;
    uint256 minTokenOut;
    address recipient;
    uint160 sqrtPriceLimitX96;
}

/// @notice Full immutable economic commitment. Execution mode/batch boundaries are separate.
struct LaunchPlanV1 {
    uint256 chainId;
    address orchestrator;
    address creator;
    uint256 nonce;
    TokenConfigV1 token;
    AssetFundingV1[] funding;
    FeeAssetPolicyV2[] feeAssets;
    MarketConfigV1[] markets;
    InitialBuyV1[] buys;
    uint256 deadline;
    uint16 executorFeeBps;
}

/// @notice Full manager/key identity for V4, factory/profile/pool identity for Abyss.
/// @dev V4 poolId = keccak256(abi.encode(currency0,currency1,fee,tickSpacing,hook));
///      canonicalId includes chain, venue, manager, factory, pool, poolId and profileId.
struct MarketIdentityV1 {
    LaunchVenueV1 venue;
    bytes32 canonicalId;
    address manager;
    address factory;
    address pool;
    bytes32 poolId;
    bytes32 profileId;
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hook;
    uint160 openingSqrtPriceX96;
}

struct PreparedMarketV1 {
    MarketIdentityV1 identity;
    address feeSource;
    address custody;
    address mintExecutor;
    address buyExecutor;
    address[] exclusions;
    uint32 positionCount;
}

struct PositionIdentityV1 {
    bytes32 canonicalId;
    bytes32 marketId;
    address manager;
    address custody;
    uint256 tokenId;
    int24 tickLower;
    int24 tickUpper;
    bytes32 salt;
    uint128 liquidity;
}

struct LaunchExecutionContextV1 {
    bytes32 launchId;
    uint32 marketIndex;
    LaunchOperationV1 operation;
    address adapter;
    address executor;
    address token;
    address quoteAsset;
    address manager;
    address custody;
    address recipient;
    uint256 amount;
}

struct LaunchProgressV1 {
    bytes32 launchId;
    bytes32 planHash;
    address creator;
    uint256 nonce;
    LaunchModeV1 mode;
    LaunchPhaseV1 phase;
    address token;
    address feeHub;
    address rewards;
    uint32 preparedMarkets;
    uint32 marketCount;
    uint32 buyCount;
    uint32 positionCount;
    uint256 deadline;
}

struct LaunchReceiptV1 {
    bytes32 launchId;
    bytes32 planHash;
    address token;
    address feeHub;
    address rewards;
    uint32 marketCount;
    uint32 positionCount;
    uint256[] quoteSpent;
    uint256[] tokenOut;
}

struct AdapterRegistrationV1 {
    address implementation;
    bytes32 codeHash;
    uint64 capabilities;
    uint32 configVersion;
    bool enabled;
}

struct ProfileRegistrationV1 {
    bytes32 adapterId;
    bytes32 configSchema;
    bytes32 dependencyDigest;
    address venue;
    address factory;
    address hook;
    uint64 capabilities;
    bool enabled;
}

/// @notice Registry-certified hook derivation for an immutable profile.
struct ProfileTopologyV1 {
    LaunchHookTopologyV1 hookTopology;
    uint32 configVersion;
    address hookDeployer;
    bytes32 hookCreationCodeHash;
}

struct MarketLiveStateV1 {
    uint160 sqrtPriceX96;
    int24 tick;
    uint128 liquidity;
    bool publicTrading;
    uint256 oracleReadyAt;
}

library LaunchCapabilitiesV1 {
    /// @dev uint64 bits: TOKEN_ONLY=1, EMPTY_PREPARE=2, PERMANENT_CUSTODY=8,
    ///      CANONICAL_FEES=16, ERC404=32, MULTI_POSITION=64. Value 4 (`POOL_GATE`, former 1<<2) is retired:
    ///      preactivation protection is the lifecycle token's transfer restrictions, narrow
    ///      activation-callback authorization and per-market activation-time canonical
    ///      opening-state verification; no venue pool gate or hook oracle is assumed.
    ///      REQUIRED = 1|2|8|16 = 27 is the venue-agnostic admission floor for BOTH modes
    ///      and BOTH venues; ERC404/MULTI_POSITION are plan-driven additions (full
    ///      registration set for both live adapters is REQUIRED|ERC404|MULTI_POSITION = 123).
    uint64 internal constant TOKEN_ONLY = 1 << 0;
    uint64 internal constant EMPTY_PREPARE = 1 << 1;
    // Retired (was POOL_GATE = 1 << 2).
    uint64 internal constant PERMANENT_CUSTODY = 1 << 3;
    uint64 internal constant CANONICAL_FEES = 1 << 4;
    uint64 internal constant ERC404 = 1 << 5;
    uint64 internal constant MULTI_POSITION = 1 << 6;
    uint64 internal constant REQUIRED = TOKEN_ONLY | EMPTY_PREPARE | PERMANENT_CUSTODY | CANONICAL_FEES;
}
