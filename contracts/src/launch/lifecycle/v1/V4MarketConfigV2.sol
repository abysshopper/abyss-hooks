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
