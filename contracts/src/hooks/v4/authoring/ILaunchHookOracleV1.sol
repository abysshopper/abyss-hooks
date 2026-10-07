// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Optional quote-normalized truncated-oracle ABI for a pool-bound launch hook.
/// @dev Implemented in the hook itself by inheriting PoolBoundTruncatedOracleV2.
interface ILaunchHookOracleV1 {
    /// @dev Capacity is not populated history; initializedAt is the genuine oracle genesis.
    struct OracleState {
        uint16 index;
        uint16 cardinality;
        uint16 cardinalityNext;
        int24 tick;
        uint64 lastBlock;
        uint64 initializedAt;
        int24 maxAbsTickMove;
        uint16 cardinalityCap;
    }

    function MAX_ORACLE_CARDINALITY() external view returns (uint16);
    function oracleState(bytes32 id)
        external
        view
        returns (
            uint16 index,
            uint16 cardinality,
            uint16 cardinalityNext,
            int24 tick,
            uint64 lastBlock,
            uint64 initializedAt,
            int24 maxAbsTickMove,
            uint16 cardinalityCap
        );
    function observations(bytes32 id, uint256 index)
        external
        view
        returns (
            uint32 blockTimestamp,
            int56 tickCumulative,
            uint160 secondsPerLiquidityCumulativeX128,
            bool observationInitialized
        );
    function validateOracleConfig(bytes32 oracleConfigId)
        external
        view
        returns (uint24 maxAbsTickMove, uint16 cardinality);
    function observeTruncated(bytes32 id, uint32[] calldata secondsAgos)
        external
        view
        returns (
            int56[] memory tickCumulatives,
            uint160[] memory secondsPerLiquidityCumulativeX128s
        );
    function increaseObservationCardinalityNext(bytes32 id, uint16 requested) external;
}
