// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Ring of quote-normalized, per-block clamped tick/liquidity observations.
/// @dev Project-owned implementation of the Abyss truncated-oracle semantics:
///      - Ticks are persisted quote-normalized (raw quote units per raw base unit) and each new
///        persisted tick moves at most `maxAbsTickMove` from the previously persisted tick.
///      - At most one observation is written per block; a record carries the tick/liquidity that
///        prevailed BEFORE the triggering price/liquidity change.
///      - Timestamps and accumulators are modular uint32/int56/uint160 counters; all elapsed-time
///        math is wraparound-safe across the 2**32 timestamp boundary.
///      - Reads fail closed: targets older than the oldest stored observation revert, and a ring
///        that was never initialized cannot be observed.
library TruncatedOracle {
    error InvalidObservationState();
    error ObservationTooOld();

    /// @dev One observation packs into exactly one storage slot (4 + 7 + 20 + 1 bytes).
    struct Observation {
        uint32 blockTimestamp;
        int56 tickCumulative;
        uint160 secondsPerLiquidityCumulativeX128;
        bool initialized;
    }

    /// @notice Spot tick expressed in quote-per-base orientation.
    /// @dev The raw pool tick prices currency1 per currency0; quoting with currency0 as the quote
    ///      asset flips the sign.
    function normalizeTick(int24 spotTick, bool quoteIsToken0) internal pure returns (int24) {
        return quoteIsToken0 ? -spotTick : spotTick;
    }

    /// @notice Next persisted tick: the normalized spot tick clamped so the move from the
    ///         previously persisted tick never exceeds `maxAbsTickMove` in either direction.
    /// @dev Both endpoints are within the int24 tick range, and clamping a difference keeps the
    ///      result between them, so the narrowed casts cannot wrap.
    function nextTruncatedTick(
        int24 previousTick,
        int24 spotTick,
        int24 maxAbsTickMove,
        bool quoteIsToken0
    ) internal pure returns (int24) {
        int256 delta = int256(normalizeTick(spotTick, quoteIsToken0)) - int256(previousTick);
        int256 cap = int256(maxAbsTickMove);
        if (delta > cap) {
            delta = cap;
        } else if (delta < -cap) {
            delta = -cap;
        }
        return int24(int256(previousTick) + delta);
    }

    /// @notice Writes the genesis observation and reports the ring as a single populated slot.
    function initialize(Observation[65_535] storage self, uint32 time)
        internal
        returns (uint16 cardinality, uint16 cardinalityNext)
    {
        self[0] = Observation({
            blockTimestamp: time,
            tickCumulative: 0,
            secondsPerLiquidityCumulativeX128: 0,
            initialized: true
        });
        return (1, 1);
    }

    /// @notice Prepares slots so the ring can grow to `requestedNext` on future writes.
    /// @dev Stamping `blockTimestamp = 1` keeps untouched slots out of timestamp order ambiguity
    ///      (they sort at the dawn of the modular epoch and stay `initialized == false`), and
    ///      moves the fresh-slot SSTORE cost out of the swap path. Never shrinks.
    function grow(Observation[65_535] storage self, uint16 currentNext, uint16 requestedNext)
        internal
        returns (uint16)
    {
        if (currentNext == 0) revert InvalidObservationState();
        if (requestedNext <= currentNext) return currentNext;
        for (uint16 i = currentNext; i < requestedNext; ++i) {
            self[i].blockTimestamp = 1;
        }
        return requestedNext;
    }

    /// @notice Appends an observation at `time` carrying `tick` and `liquidity`.
    /// @dev Writes at most once per timestamp. When the write wraps the populated tail of the
    ///      ring and a larger prepared cardinality exists, the populated cardinality lazily
    ///      expands to it; the new slot then overwrites the oldest position.
    function write(
        Observation[65_535] storage self,
        uint16 index,
        uint32 time,
        int24 tick,
        uint128 liquidity,
        uint16 cardinality,
        uint16 cardinalityNext
    ) internal returns (uint16 indexUpdated, uint16 cardinalityUpdated) {
        Observation memory last = self[index];
        if (last.blockTimestamp == time) return (index, cardinality);

        cardinalityUpdated = cardinalityNext > cardinality && index == cardinality - 1
            ? cardinalityNext
            : cardinality;
        indexUpdated = (index + 1) % cardinalityUpdated;
        self[indexUpdated] = _advanceObservation(last, time, tick, liquidity);
    }

    /// @notice Counterfactual accumulator values as of each `secondsAgo`, in input order.
    /// @dev `tick`/`liquidity` are the current values used only to extrapolate from the newest
    ///      stored observation up to `time` (or an intermediate target newer than the newest
    ///      observation). Reverts InvalidObservationState before any initialization and
    ///      ObservationTooOld for targets older than the oldest retrievable observation
    ///      (including wrapped targets that would land in the future).
    function observe(
        Observation[65_535] storage self,
        uint32 time,
        uint32[] calldata secondsAgos,
        int24 tick,
        uint16 index,
        uint128 liquidity,
        uint16 cardinality
    )
        internal
        view
        returns (
            int56[] memory tickCumulatives,
            uint160[] memory secondsPerLiquidityCumulativeX128s
        )
    {
        if (cardinality == 0) {
            revert InvalidObservationState();
        }

        tickCumulatives = new int56[](secondsAgos.length);
        secondsPerLiquidityCumulativeX128s = new uint160[](secondsAgos.length);
        for (uint256 i; i < secondsAgos.length; ++i) {
            (tickCumulatives[i], secondsPerLiquidityCumulativeX128s[i]) =
                _observeSingle(self, time, secondsAgos[i], tick, index, liquidity, cardinality);
        }
    }

    /// @dev The observation that would exist at `blockTimestamp` if the state holding `last`
    ///      kept accruing `tick` per second and seconds-per-unit-liquidity at `liquidity`.
    ///      A zero-liquidity interval still advances the tick accumulator and counts elapsed
    ///      seconds against a single unit of liquidity.
    function _advanceObservation(
        Observation memory last,
        uint32 blockTimestamp,
        int24 tick,
        uint128 liquidity
    ) private pure returns (Observation memory) {
        unchecked {
            // Accumulators and timestamps are modular counters by design.
            uint32 delta = blockTimestamp - last.blockTimestamp;
            return Observation({
                blockTimestamp: blockTimestamp,
                tickCumulative: last.tickCumulative + int56(tick) * int56(uint56(delta)),
                secondsPerLiquidityCumulativeX128: last.secondsPerLiquidityCumulativeX128
                    + ((uint160(delta) << 128) / (liquidity > 0 ? liquidity : 1)),
                initialized: true
            });
        }
    }

    /// @dev Modular-timestamp "`a` is chronologically at or before `b`", given both are at or
    ///      before `time`; correct across a single 2**32 wrap.
    function _atOrBefore(uint32 time, uint32 a, uint32 b) private pure returns (bool) {
        if (a <= time && b <= time) return a <= b;
        uint256 aOrdered = a > time ? uint256(a) : uint256(a) + (1 << 32);
        uint256 bOrdered = b > time ? uint256(b) : uint256(b) + (1 << 32);
        return aOrdered <= bOrdered;
    }

    /// @dev Accumulator values exactly at `time - secondsAgo` (mod 2**32).
    function _observeSingle(
        Observation[65_535] storage self,
        uint32 time,
        uint32 secondsAgo,
        int24 tick,
        uint16 index,
        uint128 liquidity,
        uint16 cardinality
    ) private view returns (int56 tickCumulative, uint160 secondsPerLiquidityCumulativeX128) {
        if (secondsAgo == 0) {
            Observation memory last = self[index];
            if (last.blockTimestamp != time) {
                last = _advanceObservation(last, time, tick, liquidity);
            }
            return (last.tickCumulative, last.secondsPerLiquidityCumulativeX128);
        }

        uint32 target;
        unchecked {
            target = time - secondsAgo;
        }

        (Observation memory beforeOrAt, Observation memory atOrAfter) =
            _bracketingObservations(self, time, target, tick, index, liquidity, cardinality);

        if (target == beforeOrAt.blockTimestamp) {
            return (beforeOrAt.tickCumulative, beforeOrAt.secondsPerLiquidityCumulativeX128);
        }
        if (target == atOrAfter.blockTimestamp) {
            return (atOrAfter.tickCumulative, atOrAfter.secondsPerLiquidityCumulativeX128);
        }

        unchecked {
            // Interior target: linear interpolation. The tick path divides before multiplying
            // (truncating toward zero); the liquidity path multiplies first to keep precision.
            uint32 observationTimeDelta = atOrAfter.blockTimestamp - beforeOrAt.blockTimestamp;
            uint32 targetDelta = target - beforeOrAt.blockTimestamp;
            return (
                beforeOrAt.tickCumulative
                    + ((atOrAfter.tickCumulative - beforeOrAt.tickCumulative)
                        / int56(uint56(observationTimeDelta))) * int56(uint56(targetDelta)),
                beforeOrAt.secondsPerLiquidityCumulativeX128
                    + uint160(
                        uint256(
                                atOrAfter.secondsPerLiquidityCumulativeX128
                                    - beforeOrAt.secondsPerLiquidityCumulativeX128
                            ) * targetDelta / observationTimeDelta
                    )
            );
        }
    }

    /// @dev The stored (or counterfactual newest) observations straddling `target`.
    function _bracketingObservations(
        Observation[65_535] storage self,
        uint32 time,
        uint32 target,
        int24 tick,
        uint16 index,
        uint128 liquidity,
        uint16 cardinality
    ) private view returns (Observation memory beforeOrAt, Observation memory atOrAfter) {
        beforeOrAt = self[index];
        if (_atOrBefore(time, beforeOrAt.blockTimestamp, target)) {
            // Target at the newest observation is exact; a later target extrapolates from it.
            return beforeOrAt.blockTimestamp == target
                ? (beforeOrAt, atOrAfter)
                : (beforeOrAt, _advanceObservation(beforeOrAt, target, tick, liquidity));
        }

        beforeOrAt = self[(index + 1) % cardinality];
        if (!beforeOrAt.initialized) beforeOrAt = self[0];
        if (!_atOrBefore(time, beforeOrAt.blockTimestamp, target)) revert ObservationTooOld();

        return _locateBracket(self, time, target, index, cardinality);
    }

    /// @dev Binary search over the populated window, treating the ring position after `index` as
    ///      the oldest. Uninitialized (prepared but never written) slots sort above the search
    ///      window's lower edge and are skipped toward newer entries.
    function _locateBracket(
        Observation[65_535] storage self,
        uint32 time,
        uint32 target,
        uint16 index,
        uint16 cardinality
    ) private view returns (Observation memory beforeOrAt, Observation memory atOrAfter) {
        uint256 lo = (index + 1) % cardinality;
        uint256 hi = lo + cardinality - 1;
        while (true) {
            uint256 mid = (lo + hi) / 2;
            beforeOrAt = self[mid % cardinality];
            if (!beforeOrAt.initialized) {
                lo = mid + 1;
                continue;
            }
            atOrAfter = self[(mid + 1) % cardinality];
            bool targetAtOrAfter = _atOrBefore(time, beforeOrAt.blockTimestamp, target);
            if (targetAtOrAfter && _atOrBefore(time, target, atOrAfter.blockTimestamp)) break;
            if (!targetAtOrAfter) {
                hi = mid - 1;
            } else {
                lo = mid + 1;
            }
        }
    }
}
