// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { V4PositionConfigV1 } from "./V4MarketConfigV2.sol";

/// @notice Pool-bound V4 economics and its exact CREATE2 salt, committed by the launch plan.
struct V4MarketConfigV3 {
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
    bytes32 hookSalt;
    V4PositionConfigV1[] positions;
}
