// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { HookLaunchFixture, LaunchScenario, LaunchReceiptV1, ILaunchSupplyFork, PoolKey, PoolId, PoolIdLibrary, Currency, SwapParams, TickMath, StateLibrary, SqrtPriceMath, FullMath, PoolBoundLaunchHookBaseV2, ILaunchHookV1, ILaunchHookOracleV1, IHookFeeRatePreviewFork } from "../../../contracts/test/HookLaunchFixture.sol";
import { DynamicFeeHook } from "../DynamicFeeHook.sol";

/// @notice Reference-policy assertions, independent from the universal smoke contract.
contract DynamicFeeHookPolicyTest is HookLaunchFixture {
    using PoolIdLibrary for PoolKey;

    constructor() HookLaunchFixture("hooks/dynamic-fee/DynamicFeeHook.sol:DynamicFeeHook") { }

    function _configureScenario() internal view override returns (LaunchScenario memory selected) {
        selected = _defaultScenario();
        selected.preparedOracleCardinality = 2;
    }

    function testPolicyLaunchBurnsUnusedInventory() public {
        for (uint8 mode; mode < 2; ++mode) {
            if ((vm.envUint("HOOK_FEE_MODE_FLAGS") & (uint256(1) << mode)) == 0) continue;
            (LaunchReceiptV1 memory receipt,,) = _launchWithPolicy(mode, 3_300_001 + mode,
                launchScenario.minimumHookFeePips, launchScenario.maximumHookFeePips,
                launchScenario.feeSensitivityPipsSecondsPerTick, true);
            assertLt(ILaunchSupplyFork(receipt.token).totalSupply(), launchScenario.tokenSupply);
        }
    }
    function testDynamicExampleTracksObservedPriceVelocity() public {
        uint8 mode = (vm.envUint("HOOK_FEE_MODE_FLAGS") & 1) != 0 ? 0 : 1;
        Receipts memory received = _scenario(mode, 1_200_001);
        PoolKey memory key = ILaunchHookV1(received.hook).poolKey(received.poolId);
        bool sellBase = Currency.unwrap(key.currency0) == received.token;
        uint24 minimum = PoolBoundLaunchHookBaseV2(received.hook).minimumHookFeePips();
        SwapParams memory preview = SwapParams(sellBase, -int256(1 ether),
            sellBase ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
        uint24 fastRate = IHookFeeRatePreviewFork(received.hook).feeRate(preview);
        assertGt(fastRate, minimum, "observed upward movement raises fees above chosen minimum");
        vm.warp(block.timestamp + 120);
        uint24 idleRate = IHookFeeRatePreviewFork(received.hook).feeRate(preview);
        assertLt(idleRate, fastRate, "without new movement the historical rise must fade");
        assertGe(idleRate, minimum);
        emit log_named_uint("fast upward oracle rate", fastRate);
        emit log_named_uint("idle oracle rate", idleRate);

        // Sell enough base to move the real spot below the lagged truncated tick, but stay
        // inside the funded range. The next swap observes that fall, not its own price impact.
        _sellBelowOracle(key, received.poolId, sellBase);
        for (uint256 i; i < 5; ++i) _trade(key, sellBase, -int256(1e12));
        assertEq(IHookFeeRatePreviewFork(received.hook).feeRate(preview), minimum,
            "falling then flat observed prices use chosen minimum");
        emit log_named_uint("falling and flat oracle rate", minimum);
    }

    function testCreatorConfigurationsChangeActualFeesAndDecayWithWarp() public {
        uint8 mode = (vm.envUint("HOOK_FEE_MODE_FLAGS") & 1) != 0 ? 0 : 1;
        uint24[5] memory minimums = [uint24(250), 750, 250, 0, 500];
        uint24[5] memory maximums = [uint24(10_000), 20_000, 1_000, 10_000, 10_000];
        uint32[5] memory sensitivities = [uint32(1_000), 1_000, 2_000, 3_000, 0];
        uint24[5] memory fastRates = [uint24(958), 1_458, 1_000, 2_125, 500];
        uint24[5] memory idleRates = [uint24(368), 868, 486, 354, 500];
        for (uint256 i; i < minimums.length; ++i) {
            uint256 snapshot = vm.snapshotState();
            Receipts memory received = _scenarioWithPolicy(
                mode, 1_400_001 + i, minimums[i], maximums[i], sensitivities[i]
            );
            PoolKey memory key = ILaunchHookV1(received.hook).poolKey(received.poolId);
            bool buyBase = Currency.unwrap(key.currency0) == address(quote);
            uint24 fast = _trade(key, buyBase, -int256(1 ether));
            vm.warp(block.timestamp + 120);
            uint24 idle = _trade(key, buyBase, -int256(1 ether));
            assertEq(fast, fastRates[i], "chosen policy must determine actual fast-swap charge");
            assertEq(idle, idleRates[i], "idle age must reduce actual charge to the expected rate");
            if (sensitivities[i] == 0) assertEq(idle, fast, "zero sensitivity is constant minimum");
            else assertLt(idle, fast, "actual charged fees must fall after warp");
            emit log_named_uint("creator minimum pips", minimums[i]);
            emit log_named_uint("creator maximum pips", maximums[i]);
            emit log_named_uint("creator sensitivity pips seconds per tick", sensitivities[i]);
            emit log_named_uint("actual fast charged rate", fast);
            emit log_named_uint("actual idle charged rate", idle);
            require(vm.revertToStateAndDelete(snapshot), "restore isolated creator policy scenario");
        }
    }

    struct FeePolicy {
        uint24 minimum;
        uint24 maximum;
        uint32 sensitivity;
    }

    function testActualFeeCurvesBaseline() public {
        _assertPolicyResponse(FeePolicy(750, 10_000, 3_000), 0);
    }

    function testActualFeeCurvesDoubleSensitivity() public {
        _assertPolicyResponse(FeePolicy(750, 10_000, 6_000), 1);
    }

    function testActualFeeCurvesLowerMinimum() public {
        _assertPolicyResponse(FeePolicy(250, 10_000, 3_000), 2);
    }

    function testActualFeeCurvesHigherMaximum() public {
        _assertPolicyResponse(FeePolicy(750, 20_000, 3_000), 3);
    }

    function testActualFeeCurvesLowCeiling() public {
        _assertPolicyResponse(FeePolicy(750, 1_000, 3_000), 4);
    }

    function testActualFeeCurvesZeroSensitivity() public {
        _assertPolicyResponse(FeePolicy(500, 10_000, 0), 5);
    }

    function testActualFeeCurvesZeroMinimum() public {
        _assertPolicyResponse(FeePolicy(0, 10_000, 3_000), 6);
    }

    function testActualFeeCurvesEqualBounds() public {
        _assertPolicyResponse(FeePolicy(750, 750, 6_000), 7);
    }

    function _assertPolicyResponse(FeePolicy memory policy, uint256 nonce) private {
        int24[4] memory rises = [int24(1), 8, 17, 80];
        uint32[3] memory intervals = [uint32(1), 12, 60];
        for (uint8 mode; mode < 2; ++mode) {
            if ((vm.envUint("HOOK_FEE_MODE_FLAGS") & (uint256(1) << mode)) == 0) continue;
            uint256 beforeLaunch = vm.snapshotState();
            (,, PoolKey memory key) = _launchWithPolicy(
                mode, 1_600_001 + mode * 100 + nonce, policy.minimum, policy.maximum, policy.sensitivity, false
            );
            _settleControlledPool(key);
            for (uint256 movement; movement < rises.length; ++movement) {
                for (uint256 interval; interval < intervals.length; ++interval) {
                    uint256 beforeSignal = vm.snapshotState();
                    _prepareRise(key, rises[movement], intervals[interval]);
                    _assertActualFeeCurve(key, rises[movement], intervals[interval]);
                    require(vm.revertToStateAndDelete(beforeSignal), "restore controlled movement");
                }
            }
            require(vm.revertToStateAndDelete(beforeLaunch), "restore independent policy launch");
        }
    }

    function testQuietTradingClearsClampedRiseAndNewRiseReactivatesFees() public {
        for (uint8 mode; mode < 2; ++mode) {
            if ((vm.envUint("HOOK_FEE_MODE_FLAGS") & (uint256(1) << mode)) == 0) continue;
            uint256 snapshot = vm.snapshotState();
            (,, PoolKey memory key) = _launchWithPolicy(mode, 1_700_001 + mode, 750, 10_000, 3_000, false);
            _settleControlledPool(key);
            bool buyBase = Currency.unwrap(key.currency0) == address(quote);
            _prepareRise(key, 80, 12);
            // Flat raw spot does not mean a flat truncated signal: it catches up by 17 ticks.
            uint24[6] memory expected = [uint24(2_875), 2_875, 2_875, 2_875, 2_250, 750];
            for (uint256 i; i < expected.length; ++i) {
                assertEq(_trade(key, buyBase, -int256(1e12)), expected[i],
                    "quiet swaps must expose clamp catch-up, then clear the upward signal");
            }
            assertEq(_tradeAfter(key, buyBase, -int256(1e12), 1 days), 750);
            assertEq(_moveToNormalizedTick(key, 120), 750,
                "a new price-moving swap must not charge for its own impact");
            assertEq(_trade(key, buyBase, -int256(1e12)), 750,
                "the observer updates only after freezing this swap's fee");
            assertEq(_trade(key, buyBase, -int256(1e12)), 1_750,
                "a newly sampled eight-tick rise must reactivate the uplift");
            emit log_named_uint("reactivated actual charged rate", 1_750);
            require(vm.revertToStateAndDelete(snapshot), "restore independent fee mode");
        }
    }

    function _settleControlledPool(PoolKey memory key) private {
        bool buyBase = Currency.unwrap(key.currency0) == address(quote);
        // One-sided launch liquidity starts at a range boundary. Enter it with a real swap.
        assertEq(_trade(key, buyBase, -int256(1e12)),
            PoolBoundLaunchHookBaseV2(address(key.hooks)).minimumHookFeePips(), "genuine warm-up charge");
        _moveToNormalizedTick(key, 32);
        for (uint256 i; i < 3; ++i) _trade(key, buyBase, -int256(1e12));
        (,,, int24 sampledTick,,,,) =
            ILaunchHookOracleV1(address(key.hooks)).oracleState(PoolId.unwrap(key.toId()));
        assertEq(sampledTick, 32, "controlled starting spot and truncated oracle must agree");
    }

    function _prepareRise(PoolKey memory key, int24 rise, uint32 interval) private {
        bool buyBase = Currency.unwrap(key.currency0) == address(quote);
        assertEq(_moveToNormalizedTick(key, 32 + rise),
            PoolBoundLaunchHookBaseV2(address(key.hooks)).minimumHookFeePips(),
            "a quiet price-moving swap charges the minimum, not its own impact");
        assertEq(_tradeAfter(key, buyBase, -int256(1e12), interval),
            PoolBoundLaunchHookBaseV2(address(key.hooks)).minimumHookFeePips(),
            "sampling a rise cannot retroactively change the frozen charge");
        (,,, int24 sampledTick,,,,) =
            ILaunchHookOracleV1(address(key.hooks)).oracleState(PoolId.unwrap(key.toId()));
        assertEq(sampledTick, 32 + (rise > 17 ? int24(17) : rise),
            "real oracle must observe and clamp the chosen rise");
    }

    function _moveToNormalizedTick(PoolKey memory key, int24 normalizedTick) private returns (uint24 rate) {
        bool buyBase = Currency.unwrap(key.currency0) == address(quote);
        int24 rawTick = buyBase ? -normalizedTick : normalizedTick;
        // Mid-tick target avoids a one-tick ambiguity from exact-output integer rounding.
        uint160 target = uint160((uint256(TickMath.getSqrtPriceAtTick(rawTick))
            + TickMath.getSqrtPriceAtTick(rawTick + 1)) / 2);
        (uint160 current,,,) = StateLibrary.getSlot0(manager, key.toId());
        uint128 liquidity = StateLibrary.getLiquidity(manager, key.toId());
        uint256 output = buyBase
            ? SqrtPriceMath.getAmount1Delta(target, current, liquidity, false)
            : SqrtPriceMath.getAmount0Delta(current, target, liquidity, false);
        rate = _trade(key, buyBase, int256(output));
        (, int24 actualTick,,) = StateLibrary.getSlot0(manager, key.toId());
        assertEq(buyBase ? -actualTick : actualTick, normalizedTick,
            "actual swap must create the requested raw normalized price movement");
    }

    function _assertActualFeeCurve(PoolKey memory key, int24 rawRise, uint32 interval) private {
        uint32[11] memory idle = [uint32(1), 5, 12, 30, 60, 120, 300, 900, 3_600, 86_400, 604_800];
        PoolBoundLaunchHookBaseV2 hook = PoolBoundLaunchHookBaseV2(address(key.hooks));
        FeePolicy memory policy = FeePolicy(hook.minimumHookFeePips(),
            hook.poolConfig(PoolId.unwrap(key.toId())).hookFeePips, hook.feeSensitivityPipsSecondsPerTick());
        uint256 movement = uint256(uint24(rawRise > 17 ? int24(17) : rawRise));
        uint256 snapshot = vm.snapshotState();
        uint256[] memory ages = new uint256[](idle.length);
        uint256[] memory rates = new uint256[](idle.length);
        uint256 prior = policy.maximum;
        for (uint256 i; i < idle.length; ++i) {
            // Replay the SAME sampled state, not a chain of swaps that replaces the signal.
            uint256 expected = policy.minimum + uint256(policy.sensitivity) * movement / (uint256(interval) + idle[i]);
            if (expected > policy.maximum) expected = policy.maximum;
            uint24 actual = _assertReplayedCharge(key, snapshot, idle[i], expected);
            assertLe(actual, prior, "idle decay must be monotonic, allowing floor and cap plateaus");
            ages[i] = uint256(interval) + idle[i];
            rates[i] = actual;
            prior = actual;
        }
        assertEq(rates[rates.length - 1], policy.minimum, "one week must floor these policies to their minimum");
        emit log_string("actual fee response curve");
        emit log_named_uint("fee mode", uint256(hook.poolConfig(PoolId.unwrap(key.toId())).feeMode));
        emit log_named_uint("minimum", policy.minimum);
        emit log_named_uint("maximum", policy.maximum);
        emit log_named_uint("sensitivity", policy.sensitivity);
        emit log_named_uint("raw rise ticks", uint256(uint24(rawRise)));
        emit log_named_uint("observed rise ticks", movement);
        emit log_named_uint("sample interval seconds", interval);
        emit log_named_array("total observed age seconds", ages);
        emit log_named_array("actual charged pips", rates);
        require(vm.revertToStateAndDelete(snapshot), "delete curve replay snapshot");
    }

    function _assertReplayedCharge(PoolKey memory key, uint256 snapshot, uint32 idle, uint256 expected)
        private returns (uint24 actual)
    {
        bool buyBase = Currency.unwrap(key.currency0) == address(quote);
        actual = _tradeAfter(key, buyBase, -int256(1e12), idle);
        assertEq(actual, expected, "charged fee must match controlled movement and total elapsed age");
        require(vm.revertToState(snapshot), "replay identical observed signal");
        assertEq(_tradeAfter(key, !buyBase, -int256(1e12), idle), expected,
            "opposite direction and fee asset must obey the same frozen schedule");
        require(vm.revertToState(snapshot), "restore signal after opposite-direction charge");
    }

    function testDenseSecondBySecondBaselineFees() public {
        _assertDenseResponse(FeePolicy(750, 10_000, 3_000), 0);
    }

    function testDenseSecondBySecondLowCeilingFees() public {
        _assertDenseResponse(FeePolicy(750, 1_000, 3_000), 1);
    }

    function testDenseSecondBySecondDoubleSensitivityFees() public {
        _assertDenseResponse(FeePolicy(750, 10_000, 6_000), 2);
    }

    function _assertDenseResponse(FeePolicy memory policy, uint256 nonce) private {
        for (uint8 mode; mode < 2; ++mode) {
            if ((vm.envUint("HOOK_FEE_MODE_FLAGS") & (uint256(1) << mode)) == 0) continue;
            uint256 beforeLaunch = vm.snapshotState();
            (,, PoolKey memory key) = _launchWithPolicy(
                mode, 1_800_001 + mode * 100 + nonce, policy.minimum, policy.maximum, policy.sensitivity, false
            );
            _settleControlledPool(key);
            _prepareRise(key, 17, 1);
            uint256 signal = vm.snapshotState();
            uint256[] memory ages = new uint256[](314);
            uint256[] memory rates = new uint256[](314);
            for (uint256 i; i < 299; ++i) ages[i] = i + 2;
            uint256 numerator = uint256(policy.sensitivity) * 17;
            // Probe exact integer-pip transitions, including the first return to the minimum.
            uint256[3] memory boundaries = [numerator / 100, numerator / 2, numerator];
            for (uint256 boundary; boundary < boundaries.length; ++boundary) {
                for (uint256 offset; offset < 5; ++offset) {
                    ages[299 + boundary * 5 + offset] = boundaries[boundary] - 2 + offset;
                }
            }
            for (uint256 i; i < ages.length; ++i) {
                uint256 expected = policy.minimum + numerator / ages[i];
                if (expected > policy.maximum) expected = policy.maximum;
                rates[i] = _assertReplayedCharge(key, signal, uint32(ages[i] - 1), expected);
                if (i != 0) assertLe(rates[i], rates[i - 1], "dense idle decay and rounding must be monotonic");
            }
            assertEq(rates[rates.length - 3], uint256(policy.minimum) + 1,
                "at numerator seconds the last one-pip uplift must remain");
            assertEq(rates[rates.length - 2], policy.minimum,
                "the very next second must remove the final one-pip uplift");
            emit log_named_uint("dense fee mode", mode);
            emit log_named_uint("dense maximum", policy.maximum);
            emit log_named_uint("dense sensitivity", policy.sensitivity);
            emit log_named_array("dense total ages seconds", ages);
            emit log_named_array("dense actual charged pips", rates);
            require(vm.revertToStateAndDelete(signal), "delete dense signal snapshot");
            require(vm.revertToStateAndDelete(beforeLaunch), "restore dense policy launch");
        }
    }

    function testActualFeeAcrossDustToWholeTokenSwapSizes() public {
        for (uint8 mode; mode < 2; ++mode) {
            if ((vm.envUint("HOOK_FEE_MODE_FLAGS") & (uint256(1) << mode)) == 0) continue;
            uint256 beforeLaunch = vm.snapshotState();
            (,, PoolKey memory key) = _launchWithPolicy(mode, 1_900_001 + mode, 750, 10_000, 3_000, false);
            _settleControlledPool(key);
            _prepareRise(key, 17, 1);
            _assertSwapSizeMatrix(key);
            require(vm.revertToStateAndDelete(beforeLaunch), "restore size matrix fee mode");
        }
    }

    function _assertSwapSizeMatrix(PoolKey memory key) private {
        uint32[9] memory ages = [uint32(1), 4, 5, 6, 203, 204, 205, 51_000, 51_001];
        uint256[6] memory sizes = [uint256(1e6), 1e9, 1e12, 1e15, 1e17, 1 ether];
        uint256 snapshot = vm.snapshotState();
        for (uint256 age; age < ages.length; ++age) {
            uint256 expected = 750 + 51_000 / ages[age];
            if (expected > 10_000) expected = 10_000;
            for (uint256 size; size < sizes.length; ++size) {
                for (uint256 direction; direction < 2; ++direction) {
                    for (uint256 amountMode; amountMode < 2; ++amountMode) {
                        int256 amount = amountMode == 0 ? -int256(sizes[size]) : int256(sizes[size]);
                        assertEq(_tradeAfter(key, direction == 0, amount, ages[age] - 1), expected,
                            "dust/whole-token, exact-input/output and direction must share the frozen rate");
                        require(vm.revertToState(snapshot), "replay fee boundary for independent swap size");
                    }
                }
            }
        }
        emit log_named_uint("size matrix actual swaps per fee mode", 216);
        require(vm.revertToStateAndDelete(snapshot), "delete swap size snapshot");
    }

    function testActualFeeRoundingAtAdjacentRawSwapUnits() public {
        for (uint8 mode; mode < 2; ++mode) {
            if ((vm.envUint("HOOK_FEE_MODE_FLAGS") & (uint256(1) << mode)) == 0) continue;
            uint256 beforeLaunch = vm.snapshotState();
            (,, PoolKey memory key) = _launchWithPolicy(mode, 2_200_001 + mode, 750, 10_000, 3_000, false);
            _settleControlledPool(key);
            _prepareRise(key, 17, 1);
            _assertRawUnitRounding(key);
            require(vm.revertToStateAndDelete(beforeLaunch), "restore raw-unit fee mode");
        }
    }

    function _assertRawUnitRounding(PoolKey memory key) private {
        uint32[4] memory ages = [uint32(1), 6, 51_000, 51_001];
        uint256 snapshot = vm.snapshotState();
        for (uint256 i; i < ages.length; ++i) {
            uint256 rate = 750 + 51_000 / ages[i];
            if (rate > 10_000) rate = 10_000;
            for (uint256 feeUnits = 1; feeUnits <= 2; ++feeUnits) {
                uint256 threshold = (feeUnits * 1_000_000 + rate - 1) / rate;
                for (uint256 offset; offset < 3; ++offset) {
                    _assertRawAmountCharge(key, snapshot, ages[i], threshold - 1 + offset, rate);
                }
            }
        }
        require(vm.revertToStateAndDelete(snapshot), "delete raw-unit rounding snapshot");
    }

    function _assertRawAmountCharge(PoolKey memory key, uint256 snapshot, uint32 age, uint256 quantity, uint256 rate)
        private
    {
        for (uint256 direction; direction < 2; ++direction) {
            for (uint256 amountMode; amountMode < 2; ++amountMode) {
                int256 amount = amountMode == 0 ? -int256(quantity) : int256(quantity);
                SwapParams memory params = SwapParams(direction == 0, amount,
                    direction == 0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
                TradeFee memory beforeFee = _tradeFeeBefore(key, params);
                assertEq(_tradeAfter(key, direction == 0, amount, age - 1), rate,
                    "adjacent raw-unit requests must retain the historical rate");
                if ((amount < 0) == beforeFee.inputCurrency) {
                    uint256 charged = ILaunchHookV1(address(key.hooks)).pendingFees(PoolId.unwrap(key.toId()),
                        beforeFee.asset) - beforeFee.pending;
                    assertEq(charged, quantity * rate / 1_000_000,
                        "specified fee-asset amount must cross the exact integer fee-unit threshold");
                    emit log_named_uint("raw-unit rate", rate);
                    emit log_named_uint("raw-unit requested quantity", quantity);
                    emit log_named_uint("raw-unit actual fee units", charged);
                }
                require(vm.revertToState(snapshot), "replay adjacent-unit request independently");
            }
        }
    }

    function testContinuousMixedSizeTradesAtGranularCadences() public {
        for (uint8 mode; mode < 2; ++mode) {
            if ((vm.envUint("HOOK_FEE_MODE_FLAGS") & (uint256(1) << mode)) == 0) continue;
            uint256 snapshot = vm.snapshotState();
            (,, PoolKey memory key) = _launchWithPolicy(mode, 2_000_001 + mode, 750, 10_000, 3_000, false);
            _settleControlledPool(key);
            _assertContinuousTrades(key);
            require(vm.revertToStateAndDelete(snapshot), "restore continuous fee mode");
        }
    }

    function testSameBlockAndZeroSecondBlocksPreserveGenuineHistory() public {
        for (uint8 mode; mode < 2; ++mode) {
            if ((vm.envUint("HOOK_FEE_MODE_FLAGS") & (uint256(1) << mode)) == 0) continue;
            uint256 snapshot = vm.snapshotState();
            (,, PoolKey memory key) = _launchWithPolicy(mode, 2_100_001 + mode, 750, 10_000, 3_000, false);
            bool buyBase = Currency.unwrap(key.currency0) == address(quote);
            ILaunchHookOracleV1 oracle = ILaunchHookOracleV1(address(key.hooks));
            bytes32 id = PoolId.unwrap(key.toId());
            for (uint256 i; i < 4; ++i) {
                assertEq(_tradeAfter(key, buyBase, -int256(1 ether), 0), 750,
                    "new blocks without elapsed seconds must not invent velocity history");
                (, uint16 cardinality,,,,,,) = oracle.oracleState(id);
                assertEq(cardinality, 1, "zero-time writes must not fabricate a second observation");
            }
            assertEq(_tradeAfter(key, buyBase, -int256(1e12), 1), 750,
                "the first distinct-time observer still freezes the warm-up minimum");
            Receipts memory received;
            received.hook = address(key.hooks);
            received.poolId = id;
            for (uint256 i; i < 2; ++i) {
                assertEq(_sameBlockTradeLeavesOracleUnchanged(received), _referenceRate(key, 0),
                    "same-block price-moving swaps must retain the frozen historical rate");
            }
            uint24 expected = _referenceRate(key, 0);
            assertEq(_tradeAfter(key, buyBase, -int256(1e12), 0), expected,
                "a new block at the same timestamp must price existing genuine history");
            (, uint16 populated,,,,,,) = oracle.oracleState(id);
            assertEq(populated, 2);
            expected = _referenceRate(key, 1);
            assertEq(_tradeAfter(key, buyBase, -int256(1e12), 1), expected,
                "the next elapsed second must resume genuine sampling");
            emit log_named_uint("zero-second resumed actual fee", expected);
            require(vm.revertToStateAndDelete(snapshot), "restore zero-time fee mode");
        }
    }

    function _assertContinuousTrades(PoolKey memory key) private {
        uint256[5] memory sizes = [uint256(1e12), 1e15, 1e17, 1 ether, 5 ether];
        uint32[8] memory delays = [uint32(1), 1, 2, 1, 3, 5, 1, 7];
        bool buyBase = Currency.unwrap(key.currency0) == address(quote);
        uint256[] memory rates = new uint256[](64);
        uint256 rises;
        uint256 falls;
        uint256 quiet;
        for (uint256 i; i < rates.length; ++i) {
            uint32 elapsed = delays[i % delays.length];
            (int256 movement,) = _publicOracleSignal(key, elapsed);
            if (movement > 0) ++rises;
            else if (movement < 0) ++falls;
            else ++quiet;
            int256 amount = int256(sizes[(i / 2) % sizes.length]);
            if ((i / 10) % 2 == 0) amount = -amount;
            uint24 expected = _referenceRate(key, elapsed);
            rates[i] = _tradeAfter(key, i % 2 == 0 ? buyBase : !buyBase, amount, elapsed);
            assertEq(rates[i], expected, "continuous trading must price pre-swap history, not its own impact");
        }
        assertGt(rises, 0, "mixed live history must include upward signals");
        assertGt(falls, 0, "mixed live history must include downward signals");
        assertGt(quiet, 0, "mixed live history must include flat signals");
        emit log_named_array("continuous actual charged pips", rates);
        emit log_named_uint("continuous upward signals", rises);
        emit log_named_uint("continuous downward signals", falls);
        emit log_named_uint("continuous flat signals", quiet);
    }

    function _publicOracleSignal(PoolKey memory key, uint32 secondsLater)
        private view returns (int256 movement, uint32 age)
    {
        ILaunchHookOracleV1 oracle = ILaunchHookOracleV1(address(key.hooks));
        bytes32 id = PoolId.unwrap(key.toId());
        (uint16 index, uint16 cardinality,, int24 tick,,,,) = oracle.oracleState(id);
        if (cardinality < 2) return (0, 0);
        (uint32 latestTime, int56 latestCumulative,,) = oracle.observations(id, index);
        uint256 previous = (uint256(index) + cardinality - 1) % cardinality;
        (uint32 previousTime, int56 previousCumulative,,) = oracle.observations(id, previous);
        uint32 interval;
        int56 difference;
        unchecked {
            interval = latestTime - previousTime;
            difference = latestCumulative - previousCumulative;
            age = uint32(block.timestamp + secondsLater) - previousTime;
        }
        if (interval == 0) return (0, 0);
        movement = int256(tick) - int256(difference) / int256(uint256(interval));
    }

    function _referenceRate(PoolKey memory key, uint32 secondsLater) private view returns (uint24) {
        PoolBoundLaunchHookBaseV2 hook = PoolBoundLaunchHookBaseV2(address(key.hooks));
        uint256 minimum = hook.minimumHookFeePips();
        (int256 movement, uint32 age) = _publicOracleSignal(key, secondsLater);
        if (movement <= 0 || age == 0) return uint24(minimum);
        uint256 rate = minimum + uint256(hook.feeSensitivityPipsSecondsPerTick()) * uint256(movement) / age;
        uint24 maximum = hook.poolConfig(PoolId.unwrap(key.toId())).hookFeePips;
        return rate > maximum ? maximum : uint24(rate);
    }

    function _sellBelowOracle(PoolKey memory key, bytes32 id, bool sellBase) private {
        (,,, int24 normalizedTick,,,,) = ILaunchHookOracleV1(address(key.hooks)).oracleState(id);
        assertGt(normalizedTick, 1);
        int24 targetTick = sellBase ? normalizedTick / 2 : -(normalizedTick / 2);
        (uint160 currentPrice,,,) = StateLibrary.getSlot0(manager, key.toId());
        uint160 targetPrice = TickMath.getSqrtPriceAtTick(targetTick);
        uint128 liquidity = StateLibrary.getLiquidity(manager, key.toId());
        uint256 netInput = sellBase
            ? SqrtPriceMath.getAmount0Delta(targetPrice, currentPrice, liquidity, true)
            : SqrtPriceMath.getAmount1Delta(currentPrice, targetPrice, liquidity, true);
        // Every _trade advances twelve seconds before taking its frozen rate snapshot.
        vm.warp(block.timestamp + 12);
        SwapParams memory preview = SwapParams(sellBase, -int256(netInput),
            sellBase ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
        uint24 rate = IHookFeeRatePreviewFork(address(key.hooks)).feeRate(preview);
        vm.warp(block.timestamp - 12);
        uint256 grossInput = netInput;
        if (vm.envUint("HOOK_FEE_MODE_FLAGS") & 1 != 0) {
            grossInput = FullMath.mulDivRoundingUp(netInput, 1_000_000, 1_000_000 - rate);
        }
        _trade(key, sellBase, -int256(grossInput));
        (, int24 actualTick,,) = StateLibrary.getSlot0(manager, key.toId());
        assertLt(sellBase ? actualTick : -actualTick, normalizedTick);
    }
}
