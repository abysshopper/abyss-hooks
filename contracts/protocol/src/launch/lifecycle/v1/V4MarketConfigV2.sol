// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice One permanently held V4 range; the opening-price mint is launch-token-only.
struct V4PositionConfigV1 {
    int24 tickLower;
    int24 tickUpper;
    uint128 liquidity;
    bytes32 salt;
    uint256 maxTokenAmount;
}

/// @notice ABI-encoded in MarketConfigV1.config. The full tuple is committed by the launch plan.
struct V4MarketConfigV2 {
    uint16 version;
    uint24 lpFeePips;
    int24 tickSpacing;
    uint160 sqrtPriceX96;
    uint24 hookFeePips;
    uint8 feeMode;
    uint8 protocolFeeDenominator;
    address treasury;
    bool externalLiquidityDisabled;
    bytes32 oracleConfigId;
    V4PositionConfigV1[] positions;
}
