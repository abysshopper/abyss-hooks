// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Salt-independent constructor commitment for one lifecycle V4 market.
/// @dev Collector and hub are bound later by the registrar in the core's Prepare context.
struct PoolBoundHookParametersV2 {
    address poolManager;
    address registrar;
    address oracleFactory;
    address core;
    address liquidityLocker;
    address token;
    address quoteCurrency;
    uint24 lpFeePips;
    int24 tickSpacing;
    uint160 sqrtPriceX96;
    uint24 hookFeePips;
    uint24 minimumHookFeePips;
    uint32 feeSensitivityPipsSecondsPerTick;
    uint8 feeMode;
    uint8 protocolFeeDenominator;
    address treasury;
    bool externalLiquidityDisabled;
    bytes32 oracleConfigId;
    bytes32 marketCommitment;
    uint32 expectedPositionCount;
}
