// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { PoolId } from "@uniswap/v4-core/src/types/PoolId.sol";
import { ModifyLiquidityParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { PoolBoundHookParametersV1 } from "../PoolBoundHookParametersV1.sol";
import { TruncatedOracle } from "../TruncatedOracle.sol";
import { ILaunchHookOracleV1 } from "./ILaunchHookOracleV1.sol";
import { PoolBoundLaunchHookBaseV2 } from "./PoolBoundLaunchHookBaseV2.sol";

/// @notice Opt-in truncated oracle composed into the single pool-bound hook runtime.
/// @dev Inherit this instead of PoolBoundLaunchHookBaseV2 and forward the same constructor tuple.
///      Final core callbacks authenticate each notification; the oracle notifications are sealed.
///      No history exists before the authenticated pool initialization.
abstract contract PoolBoundTruncatedOracleV2 is PoolBoundLaunchHookBaseV2, ILaunchHookOracleV1 {
    using TruncatedOracle for TruncatedOracle.Observation[65_535];

    uint16 public constant override MAX_ORACLE_CARDINALITY = 4_096;

    bool private immutable _quoteIs0;
    OracleState private _oracleState;
    TruncatedOracle.Observation[65_535] private _observations;

    event IncreaseObservationCardinalityNext(
        bytes32 indexed poolId, uint16 cardinalityNextOld, uint16 cardinalityNextNew
    );

    constructor(PoolBoundHookParametersV1 memory parameters) PoolBoundLaunchHookBaseV2(parameters) {
        _quoteIs0 = parameters.quoteCurrency < parameters.token;
        (uint24 maxAbsTickMove, uint16 cardinality) =
            validateOracleConfig(parameters.oracleConfigId);
        _oracleState.maxAbsTickMove = int24(maxAbsTickMove);
        _oracleState.cardinalityCap = cardinality;
    }

    function oracleState(bytes32 id)
        external
        view
        override
        returns (
            uint16 index,
            uint16 cardinality,
            uint16 cardinalityNext,
            int24 tick,
            uint64 lastBlock,
            uint64 initializedAt,
            int24 maxAbsTickMove,
            uint16 cardinalityCap
        )
    {
        _requireBoundPool(id);
        OracleState storage state = _oracleState;
        return (
            state.index,
            state.cardinality,
            state.cardinalityNext,
            state.tick,
            state.lastBlock,
            state.initializedAt,
            state.maxAbsTickMove,
            state.cardinalityCap
        );
    }

    function observations(bytes32 id, uint256 index)
        external
        view
        override
        returns (
            uint32 blockTimestamp,
            int56 tickCumulative,
            uint160 secondsPerLiquidityCumulativeX128,
            bool observationInitialized
        )
    {
        _requireBoundPool(id);
        TruncatedOracle.Observation storage observation = _observations[index];
        return (
            observation.blockTimestamp,
            observation.tickCumulative,
            observation.secondsPerLiquidityCumulativeX128,
            observation.initialized
        );
    }

    /// @notice Validates the canonical registry entry; numeric overrides are never accepted.
    function validateOracleConfig(bytes32 oracleConfigId)
        public
        view
        override
        returns (uint24 maxAbsTickMove, uint16 cardinality)
    {
        (maxAbsTickMove, cardinality) = oracleFactory.oracleConfigs(oracleConfigId);
        if (
            maxAbsTickMove == 0 || maxAbsTickMove > uint24(uint256(int256(TickMath.MAX_TICK)))
                || cardinality < 2 || cardinality > MAX_ORACLE_CARDINALITY
        ) revert InvalidConfiguration();
    }

    /// @notice Quote-per-base tick and liquidity cumulatives for the exact single pool.
    /// @dev Interpolation, boundaries and modular counters are unchanged; pre-genesis fails closed.
    function observeTruncated(bytes32 id, uint32[] calldata secondsAgos)
        external
        view
        override
        returns (
            int56[] memory tickCumulatives,
            uint160[] memory secondsPerLiquidityCumulativeX128s
        )
    {
        _requireBoundPool(id);
        OracleState storage state = _oracleState;
        if (state.cardinality == 0) revert TruncatedOracle.InvalidObservationState();
        return _observations.observe(
            uint32(block.timestamp),
            secondsAgos,
            state.tick,
            state.index,
            StateLibrary.getLiquidity(poolManager, PoolId.wrap(boundPoolId)),
            state.cardinality
        );
    }

    /// @notice Monotonic capacity preparation capped by the frozen constructor snapshot.
    function increaseObservationCardinalityNext(bytes32 id, uint16 requested)
        external
        override
        nonReadReentrant
    {
        _requireBoundPool(id);
        OracleState storage state = _oracleState;
        if (requested > state.cardinalityCap) requested = state.cardinalityCap;
        uint16 oldNext = state.cardinalityNext;
        uint16 newNext = _observations.grow(oldNext, requested);
        state.cardinalityNext = newNext;
        if (oldNext != newNext) emit IncreaseObservationCardinalityNext(id, oldNext, newNext);
    }

    function _onPoolRegistered(PoolConfig calldata config) internal view override {
        (uint24 maxAbsTickMove, uint16 cardinality) = validateOracleConfig(config.oracleConfigId);
        if (
            int24(maxAbsTickMove) != _oracleState.maxAbsTickMove
                || cardinality != _oracleState.cardinalityCap
        ) revert InvalidConfiguration();
    }

    function _onPoolInitialized(int24 tick) internal override {
        OracleState storage state = _oracleState;
        (state.cardinality, state.cardinalityNext) =
            _observations.initialize(uint32(block.timestamp));
        state.tick = TruncatedOracle.normalizeTick(tick, _quoteIs0);
        state.lastBlock = uint64(block.number);
        state.initializedAt = uint64(block.timestamp);
    }

    function _onBeforeLiquidityChange(ModifyLiquidityParams calldata params) internal override {
        if (params.liquidityDelta == 0 || block.number == _oracleState.lastBlock) return;
        PoolId pool = PoolId.wrap(boundPoolId);
        (, int24 spotTick,,) = StateLibrary.getSlot0(poolManager, pool);
        if (spotTick < params.tickLower || spotTick >= params.tickUpper) return;
        _record(spotTick, StateLibrary.getLiquidity(poolManager, pool));
    }

    function _onBeforeSwap(int24 spotTick, uint128 activeLiquidity) internal override {
        if (block.number != _oracleState.lastBlock) _record(spotTick, activeLiquidity);
    }

    function _oracleInitializedAt() internal view override returns (uint256) {
        return _oracleState.initializedAt;
    }

    function _record(int24 spotTick, uint128 activeLiquidity) private {
        OracleState storage state = _oracleState;
        (state.index, state.cardinality) = _observations.write(
            state.index,
            uint32(block.timestamp),
            state.tick,
            activeLiquidity,
            state.cardinality,
            state.cardinalityNext
        );
        state.tick = TruncatedOracle.nextTruncatedTick(
            state.tick, spotTick, state.maxAbsTickMove, _quoteIs0
        );
        state.lastBlock = uint64(block.number);
    }
}
