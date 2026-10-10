// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { LaunchDeltaAccountingFixture } from "./LaunchDeltaAccountingFixture.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { ILaunchHookV1 } from "../src/hooks/v4/authoring/ILaunchHookV1.sol";
import { ILaunchHookOracleV1 } from "../src/hooks/v4/authoring/ILaunchHookOracleV1.sol";

/// @notice Optional composition assertions, independent of any reference rate formula.
abstract contract HookOracleAssertions is LaunchDeltaAccountingFixture {
    using PoolIdLibrary for PoolKey;

    struct OracleBefore {
        uint16 index;
        int24 tick;
        int24 spotTick;
        int24 maximumMove;
        uint64 lastBlock;
        uint32 timestamp;
        int56 tickCumulative;
        uint160 liquidityCumulative;
        uint128 liquidity;
    }

    function _assertOracleGenesis(address hook, bytes32 id) internal {
        uint256 genesis = ILaunchHookV1(hook).oracleInitializedAt(id);
        if (!vm.envOr("HOOK_HAS_ORACLE", false)) {
            assertEq(genesis, 0);
            return;
        }
        assertEq(genesis, block.timestamp, "oracle history starts at actual initialization");
        ILaunchHookOracleV1 oracle = ILaunchHookOracleV1(hook);
        (uint16 index, uint16 cardinality, uint16 next,,,,, uint16 cap) = oracle.oracleState(id);
        assertEq(index, 0);
        assertEq(cardinality, 1, "initialization must not fabricate history");
        assertGe(next, cardinality);
        assertLe(next, cap);
        (uint32 timestamp, int56 ticks, uint160 liquidity, bool initialized) = oracle.observations(id, 0);
        assertEq(timestamp, uint32(genesis));
        assertEq(ticks, 0);
        assertEq(liquidity, 0);
        assertTrue(initialized);
        uint256 snapshot = vm.snapshotState();
        oracle.increaseObservationCardinalityNext(id, 3);
        (, cardinality, next,,,,,) = oracle.oracleState(id);
        assertEq(cardinality, 1, "prepared capacity is not populated history");
        assertGe(next, cap < 3 ? cap : 3);
        assertLe(next, cap);
        require(vm.revertToStateAndDelete(snapshot), "restore constructor-selected oracle capacity");
    }

    function _oracleBeforeSwap(IPoolManager manager, PoolKey memory key)
        internal view returns (OracleBefore memory snapshot)
    {
        if (!vm.envOr("HOOK_HAS_ORACLE", false)) return snapshot;
        ILaunchHookOracleV1 oracle = ILaunchHookOracleV1(address(key.hooks));
        bytes32 id = PoolId.unwrap(key.toId());
        (snapshot.index,,, snapshot.tick, snapshot.lastBlock,, snapshot.maximumMove,) = oracle.oracleState(id);
        (snapshot.timestamp, snapshot.tickCumulative, snapshot.liquidityCumulative,) =
            oracle.observations(id, snapshot.index);
        (, snapshot.spotTick,,) = StateLibrary.getSlot0(manager, key.toId());
        snapshot.liquidity = StateLibrary.getLiquidity(manager, key.toId());
    }

    function _expectedOracleTick(OracleBefore memory previous, bool quoteIs0) private pure returns (int256) {
        int256 spot = quoteIs0 ? -int256(previous.spotTick) : int256(previous.spotTick);
        int256 lower = int256(previous.tick) - previous.maximumMove;
        int256 upper = int256(previous.tick) + previous.maximumMove;
        return spot < lower ? lower : spot > upper ? upper : spot;
    }

    function _assertOracleAfterSwap(PoolKey memory key, OracleBefore memory beforeOracle, bool quoteIs0)
        internal view
    {
        if (!vm.envOr("HOOK_HAS_ORACLE", false)) return;
        if (beforeOracle.lastBlock == block.number) {
            _assertOracleUnchanged(key, beforeOracle);
            return;
        }
        ILaunchHookOracleV1 oracle = ILaunchHookOracleV1(address(key.hooks));
        bytes32 id = PoolId.unwrap(key.toId());
        (uint16 index, uint16 cardinality,, int24 tick, uint64 lastBlock,,,) = oracle.oracleState(id);
        assertEq(lastBlock, block.number);
        assertEq(index, uint32(block.timestamp) == beforeOracle.timestamp
            ? beforeOracle.index : (beforeOracle.index + 1) % cardinality,
            "only a distinct timestamp may append genuine history");
        assertEq(tick, _expectedOracleTick(beforeOracle, quoteIs0));
        (uint32 timestamp, int56 ticks, uint160 liquidity, bool initialized) = oracle.observations(id, index);
        assertEq(timestamp, uint32(block.timestamp));
        assertTrue(initialized);
        unchecked {
            uint32 elapsed = timestamp - beforeOracle.timestamp;
            assertEq(ticks, beforeOracle.tickCumulative + int56(beforeOracle.tick) * int56(uint56(elapsed)));
            assertEq(liquidity, beforeOracle.liquidityCumulative
                + ((uint160(elapsed) << 128) / (beforeOracle.liquidity > 0 ? beforeOracle.liquidity : 1)));
        }
        uint32[] memory nowOnly = new uint32[](1);
        (int56[] memory observedTicks, uint160[] memory observedLiquidity) = oracle.observeTruncated(id, nowOnly);
        assertEq(observedTicks[0], ticks);
        assertEq(observedLiquidity[0], liquidity);
    }

    function _assertOracleUnchanged(PoolKey memory key, OracleBefore memory beforeOracle) internal view {
        ILaunchHookOracleV1 oracle = ILaunchHookOracleV1(address(key.hooks));
        bytes32 id = PoolId.unwrap(key.toId());
        (uint16 index,,, int24 tick, uint64 lastBlock,,,) = oracle.oracleState(id);
        assertEq(index, beforeOracle.index, "same-block swap must not advance the ring");
        assertEq(tick, beforeOracle.tick, "same-block swap must not reclamp the tick");
        assertEq(lastBlock, beforeOracle.lastBlock);
        (uint32 timestamp, int56 ticks, uint160 liquidity,) = oracle.observations(id, index);
        assertEq(timestamp, beforeOracle.timestamp);
        assertEq(ticks, beforeOracle.tickCumulative);
        assertEq(liquidity, beforeOracle.liquidityCumulative);
    }

    function _assertOracleElapsedHistory(IPoolManager manager, PoolKey memory key) internal {
        OracleBefore memory previous = _oracleBeforeSwap(manager, key);
        vm.warp(block.timestamp + 6);
        vm.roll(block.number + 1);
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[1] = 6;
        (int56[] memory ticks, uint160[] memory liquidity) =
            ILaunchHookOracleV1(address(key.hooks)).observeTruncated(PoolId.unwrap(key.toId()), secondsAgos);
        assertEq(ticks[1], previous.tickCumulative);
        assertEq(liquidity[1], previous.liquidityCumulative);
        unchecked {
            assertEq(ticks[0], previous.tickCumulative + int56(previous.tick) * 6);
            assertEq(liquidity[0], previous.liquidityCumulative
                + ((uint160(6) << 128) / (previous.liquidity > 0 ? previous.liquidity : 1)));
        }
    }
}
