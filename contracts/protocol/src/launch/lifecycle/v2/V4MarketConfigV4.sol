// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { V4PositionConfigV1 } from "../v1/V4MarketConfigV2.sol";

/// @notice Explicit shared-hook and developer consent, committed in the V1 plan bytes.
struct V4MarketConfigV4 {
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
    bytes32 profileId;
    bytes32 termsDigest;
    address developerBeneficiary;
    uint16 developerFeeBps;
    V4PositionConfigV1[] positions;
}
