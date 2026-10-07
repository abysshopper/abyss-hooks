// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { DynamicFeeHookRate } from "../../hooks/dynamic-fee/DynamicFeeHook.sol";
import { LaunchHookFeeRateV2, LaunchHookFeeContextV2 } from "../src/hooks/v4/authoring/LaunchHookFeeRateV2.sol";
import { ILaunchHookV1 } from "../src/hooks/v4/authoring/ILaunchHookV1.sol";

// Exercise production signal arithmetic and the final request/bounds guard without a pool constructor.
contract DynamicFeeHookRateHarness is LaunchHookFeeRateV2 {
    int256 private tickChange;
    uint32 private elapsed;
    uint24 private maximumMove;

    function setSignal(int256 change, uint32 age, uint24 move) external {
        tickChange = change;
        elapsed = age;
        maximumMove = move;
    }

    function swapFeeModel() public pure override returns (SwapFeeModel) {
        return SwapFeeModel.Dynamic;
    }

    function rate(LaunchHookFeeContextV2 memory context) external view returns (uint24) {
        return _boundedRate(context);
    }

    function _calculateRate(LaunchHookFeeContextV2 memory context) internal view override returns (uint24) {
        return DynamicFeeHookRate.calculate(context.maximumPips, tickChange, elapsed, maximumMove);
    }
}

contract DynamicFeeRateTest is Test {
    DynamicFeeHookRateHarness private harness;

    function setUp() public {
        harness = new DynamicFeeHookRateHarness();
    }

    function testAbsentHistoryAndUnavailableCapacityUseBaseline() public {
        assertEq(harness.rate(_context(-1)), 2_000);
        // Missing history is reported as a zero-length signal by the oracle measurement seam.
        assertEq(_rate(100, 0, 100, 10_000), 2_000);
        assertEq(_rate(100, 30, 0, 10_000), 2_000);
    }

    function testFlatAndFallingPricesUseBaseline() public {
        assertEq(_rate(0, 30, 100, 10_000), 2_000);
        assertEq(_rate(-1, 30, 100, 10_000), 2_000);
        assertEq(_rate(-100, 30, 100, 10_000), 2_000);
        assertEq(_rate(type(int256).min, 30, 100, 10_000), 2_000);
    }

    function testFullAllowedMoveHasThirtySecondResponse() public {
        assertEq(_rate(100, 29, 100, 10_000), 10_000);
        assertEq(_rate(100, 30, 100, 10_000), 10_000);
        assertEq(_rate(100, 31, 100, 10_000), 9_741);
        assertEq(_rate(100, 60, 100, 10_000), 6_000);
    }

    function testFasterUpwardMovementRaisesRate() public {
        assertEq(_rate(25, 30, 100, 10_000), 4_000);
        assertEq(_rate(50, 30, 100, 10_000), 6_000);
        assertEq(_rate(75, 30, 100, 10_000), 8_000);
        assertEq(_rate(100, 30, 100, 10_000), 10_000);
        // Equal movement at half the speed produces only half the uplift above baseline.
        assertEq(_rate(50, 60, 100, 10_000), 4_000);
        assertEq(_rate(100, 120, 100, 10_000), 4_000);
    }

    function testIdleAgeDecaysRateWithoutNewMovement() public {
        assertEq(_rate(100, 30, 100, 10_000), 10_000);
        assertEq(_rate(100, 60, 100, 10_000), 6_000);
        assertEq(_rate(100, 120, 100, 10_000), 4_000);
        assertEq(_rate(100, type(uint32).max, 100, 10_000), 2_000);
    }

    function testBaselineAndUpliftFloorForSmallMaximum() public {
        assertEq(_rate(0, 30, 3, 13), 2);
        assertEq(_rate(1, 30, 3, 13), 5);
        assertEq(_rate(2, 30, 3, 13), 9);
        assertEq(_rate(3, 30, 3, 13), 13);
        assertEq(_rate(0, 30, 3, 4), 0);
        assertEq(_rate(1, 30, 3, 4), 1);
        assertEq(_rate(1, 30, 3, 1), 0);
        assertEq(_rate(3, 30, 3, 1), 1);
    }

    function testSaturationThresholdRoundsUp() public {
        // Capacity 3,100 requires ceil(3,100 / 30) = 104 ticks, not 103.
        assertEq(_rate(103, 31, 100, 10_000), 9_974);
        assertEq(_rate(104, 31, 100, 10_000), 10_000);
        assertEq(_rate(105, 31, 100, 10_000), 10_000);
        assertEq(_rate(1, 1, 1, 10_000), 10_000);
    }

    function testExtremeSignalsSaturateBeforeMultiplication() public {
        uint24 maximum = type(uint24).max;
        uint32 age = type(uint32).max;
        uint24 move = type(uint24).max;
        assertEq(_rate(type(int256).max, age, move, maximum), maximum);
        assertEq(_rate(type(int256).min, age, move, maximum), maximum / 5);
        assertEq(_rate(1, age, move, maximum), maximum / 5);

        uint256 capacity = uint256(move) * age;
        int256 threshold = int256((capacity + 29) / 30);
        assertEq(_rate(threshold - 1, age, move, maximum), maximum - 1);
        assertEq(_rate(threshold, age, move, maximum), maximum);
        assertEq(_rate(threshold + 1, age, move, maximum), maximum);
    }

    function testZeroMaximumUsesZeroAcrossSignalExtremes() public {
        assertEq(_rate(type(int256).max, type(uint32).max, type(uint24).max, 0), 0);
        assertEq(_rate(type(int256).min, type(uint32).max, type(uint24).max, 0), 0);
        assertEq(_rate(0, 0, 0, 0), 0);
    }

    function testRateIsIndependentOfRequestDirectionSizeModeAndPoolReserves() public {
        harness.setSignal(50, 30, 100);
        int256[5] memory requests = [-type(int256).max, int256(-1), 0, 1, type(int256).max];
        for (uint256 mode; mode < 2; ++mode) {
            for (uint256 direction; direction < 2; ++direction) {
                for (uint256 reserves; reserves < 2; ++reserves) {
                    LaunchHookFeeContextV2 memory context = _context(0);
                    context.feeMode = ILaunchHookV1.FeeMode(mode);
                    context.zeroForOne = direction == 0;
                    context.activeLiquidity = reserves == 0 ? 0 : type(uint128).max;
                    context.sqrtPriceX96 = reserves == 0 ? 0 : type(uint160).max;
                    for (uint256 i; i < requests.length; ++i) {
                        context.amountSpecified = requests[i];
                        assertEq(harness.rate(context), 6_000);
                    }
                }
            }
        }
    }

    function testSignedMinimumIsRejectedEvenWithZeroMaximum() public {
        harness.setSignal(type(int256).max, 1, 1);
        LaunchHookFeeContextV2 memory context = _context(type(int256).min);
        vm.expectRevert(LaunchHookFeeRateV2.FeeTooLarge.selector);
        harness.rate(context);
        context.maximumPips = 0;
        vm.expectRevert(LaunchHookFeeRateV2.FeeTooLarge.selector);
        harness.rate(context);
    }

    function testFuzzRateStaysBetweenBaselineAndMaximum(
        int256 change, uint32 age, uint24 move, uint24 maximum
    ) public {
        uint24 rate = _rate(change, age, move, maximum);
        assertGe(rate, maximum / 5);
        assertLe(rate, maximum);
        if (change <= 0 || age == 0 || move == 0) assertEq(rate, maximum / 5);
    }

    function _rate(int256 change, uint32 age, uint24 move, uint24 maximum) private returns (uint24) {
        harness.setSignal(change, age, move);
        LaunchHookFeeContextV2 memory context = _context(-1);
        context.maximumPips = maximum;
        return harness.rate(context);
    }

    function _context(int256 amountSpecified) private pure returns (LaunchHookFeeContextV2 memory context) {
        context.sqrtPriceX96 = uint160(1 << 96);
        context.activeLiquidity = 1_000;
        context.amountSpecified = amountSpecified;
        context.zeroForOne = true;
        context.maximumPips = 10_000;
        context.feeMode = ILaunchHookV1.FeeMode.InputToken;
    }
}
