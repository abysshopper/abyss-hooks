// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.28;

/// @dev Shared domain for canonical Abyss lifecycle registry profile identities:
///      profileId = keccak256(abi.encode(DOMAIN, chainid, canonicalFactory, profile)).
bytes32 constant ABYSS_PROFILE_DOMAIN_V1 = keccak256("BLACK_MARKET_ABYSS_CANONICAL_PROFILE_V1");

/// @notice Exact concentrated-liquidity mint instruction, measured in token base units.
struct AbyssPositionConfigV1 {
    int24 tickLower;
    int24 tickUpper;
    uint128 liquidity;
    uint256 tokenAmountMaximum;
}

/// @notice ABI-encoded `MarketConfigV1.config` for AbyssMarketAdapterV1, configVersion = 1.
/// @dev Profile values select the canonical Abyss curve variants (0 standard, 1 standard oracle,
///      2 quote-only fees, 3 quote-only fees + truncated oracle) on the already-deployed
///      canonical factory; oracle profiles require a registered `oracleConfigId`. The explicit
///      MarketConfigV1.quoteAsset defines buy direction and the quote-pool orientation
///      independently of token order.
struct AbyssMarketConfigV1 {
    uint8 profile;
    uint24 fee;
    bytes32 oracleConfigId;
    uint160 openingSqrtPriceX96;
    AbyssPositionConfigV1[] positions;
}
