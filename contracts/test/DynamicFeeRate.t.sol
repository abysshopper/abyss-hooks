// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { DynamicFeeHookRate } from "../../hooks/dynamic-fee/DynamicFeeHook.sol";
import { LaunchHookFeeRateV2, LaunchHookFeeContextV2 } from "../src/hooks/v4/authoring/LaunchHookFeeRateV2.sol";
import { ILaunchHookV1 } from "../src/hooks/v4/authoring/ILaunchHookV1.sol";

contract DynamicFeeHookRateHarness is LaunchHookFeeRateV2 {
    int256 private tickChange;
    uint32 private elapsed;

    function setSignal(int256 change, uint32 age) external {
        tickChange = change;
        elapsed = age;
    }

    function swapFeeModel() public pure override returns (SwapFeeModel) {
        return SwapFeeModel.Dynamic;
    }

    function rate(LaunchHookFeeContextV2 memory context) external view returns (uint24) {
        return _boundedRate(context);
    }

    function _calculateRate(LaunchHookFeeContextV2 memory context) internal view override returns (uint24) {
        return DynamicFeeHookRate.calculate(
            context.minimumPips, context.maximumPips, context.feeSensitivityPipsSecondsPerTick,
            tickChange, elapsed
        );
    }
}

contract MutatingMinimumRateHarness is LaunchHookFeeRateV2 {
    function swapFeeModel() public pure override returns (SwapFeeModel) {
        return SwapFeeModel.Dynamic;
    }

    function rate(LaunchHookFeeContextV2 memory context) external view returns (uint24) {
        return _boundedRate(context);
    }

    function _calculateRate(LaunchHookFeeContextV2 memory context) internal pure override returns (uint24) {
        context.minimumPips = 0;
        return 0;
    }
}

contract DynamicFeeRateTest is Test {
    DynamicFeeHookRateHarness private harness;

    function setUp() public {
        harness = new DynamicFeeHookRateHarness();
    }

    function testWarmupFlatAndFallingUseExplicitMinimum() public {
        assertEq(_rate(100, 0, 750, 10_000, 15_000), 750);
        assertEq(_rate(0, 30, 750, 10_000, 15_000), 750);
        assertEq(_rate(-100, 30, 750, 10_000, 15_000), 750);
        assertEq(_rate(type(int256).min, 30, 750, 10_000, 15_000), 750);
    }

    function testZeroMinimumCanProduceFreeQuietSwaps() public {
        assertEq(_rate(0, 30, 0, 10_000, 15_000), 0);
        assertEq(_rate(-1, 30, 0, 10_000, 15_000), 0);
        assertEq(_rate(1, 30, 0, 10_000, 15_000), 500);
    }

    function testMinimumAndSensitivityAreIndependentOfMaximum() public {
        assertEq(_rate(10, 30, 750, 10_000, 3_000), 1_750);
        assertEq(_rate(10, 30, 750, 20_000, 3_000), 1_750);
        assertEq(_rate(10, 30, 250, 20_000, 3_000), 1_250);
        assertEq(_rate(10, 30, 750, 20_000, 6_000), 2_750);
    }

    function testFasterMovementAndHigherSensitivityIncreaseUplift() public {
        assertEq(_rate(10, 30, 750, 10_000, 3_000), 1_750);
        assertEq(_rate(20, 30, 750, 10_000, 3_000), 2_750);
        assertEq(_rate(10, 15, 750, 10_000, 3_000), 2_750);
        assertEq(_rate(10, 30, 750, 10_000, 6_000), 2_750);
    }

    function testIdleAgeDecaysTowardChosenMinimum() public {
        assertEq(_rate(10, 30, 750, 10_000, 3_000), 1_750);
        assertEq(_rate(10, 60, 750, 10_000, 3_000), 1_250);
        assertEq(_rate(10, 120, 750, 10_000, 3_000), 1_000);
        assertEq(_rate(10, type(uint32).max, 750, 10_000, 3_000), 750);
    }

    function testZeroSensitivityAndEqualBoundsAreConstantFees() public {
        assertEq(_rate(type(int256).max, 1, 750, 10_000, 0), 750);
        assertEq(_rate(type(int256).max, 1, 750, 750, type(uint32).max), 750);
        assertEq(_rate(type(int256).max, 1, 0, 0, type(uint32).max), 0);
    }

    function testFloorRoundingAndCeilingSaturationThreshold() public {
        assertEq(_rate(1, 3, 2, 13, 10), 5);
        assertEq(_rate(2, 3, 2, 13, 10), 8);
        assertEq(_rate(3, 3, 2, 13, 10), 12);
        assertEq(_rate(4, 3, 2, 13, 10), 13);
    }

    function testExtremeSignalsSaturateBeforeMultiplication() public {
        assertEq(_rate(type(int256).max, type(uint32).max, 750, type(uint24).max, type(uint32).max),
            type(uint24).max);
        assertEq(_rate(type(int256).min, type(uint32).max, 750, type(uint24).max, type(uint32).max), 750);
        uint256 capacity = uint256(type(uint24).max - 750) * type(uint32).max;
        int256 threshold = int256((capacity + type(uint32).max - 1) / type(uint32).max);
        assertEq(_rate(threshold - 1, type(uint32).max, 750, type(uint24).max, type(uint32).max),
            type(uint24).max - 1);
        assertEq(_rate(threshold, type(uint32).max, 750, type(uint24).max, type(uint32).max),
            type(uint24).max);
    }

    function testMinimumGuardSurvivesMemoryContextMutation() public {
        MutatingMinimumRateHarness malicious = new MutatingMinimumRateHarness();
        vm.expectRevert(LaunchHookFeeRateV2.FeeBelowMinimum.selector);
        malicious.rate(_context(-1));
    }

    function testSignedMinimumRequestIsRejectedEvenAtZeroFee() public {
        LaunchHookFeeContextV2 memory context = _context(type(int256).min);
        vm.expectRevert(LaunchHookFeeRateV2.FeeTooLarge.selector);
        harness.rate(context);
        context.minimumPips = 0;
        context.maximumPips = 0;
        vm.expectRevert(LaunchHookFeeRateV2.FeeTooLarge.selector);
        harness.rate(context);
    }

    function testDirectionAmountModeAndLiquidityDoNotChooseRate() public {
        harness.setSignal(10, 30);
        int256[5] memory requests = [-type(int256).max, int256(-1), 0, 1, type(int256).max];
        for (uint256 mode; mode < 2; ++mode) {
            for (uint256 direction; direction < 2; ++direction) {
                LaunchHookFeeContextV2 memory context = _context(0);
                context.feeMode = ILaunchHookV1.FeeMode(mode);
                context.zeroForOne = direction == 0;
                context.activeLiquidity = direction == 0 ? 0 : type(uint128).max;
                context.sqrtPriceX96 = direction == 0 ? 0 : type(uint160).max;
                for (uint256 i; i < requests.length; ++i) {
                    context.amountSpecified = requests[i];
                    assertEq(harness.rate(context), 1_750);
                }
            }
        }
    }

    function testFuzzChosenBoundsAlwaysHold(
        int256 change, uint32 age, uint32 sensitivity, uint24 minimumSeed, uint24 maximum
    ) public {
        uint24 minimum = uint24(uint256(minimumSeed) % (uint256(maximum) + 1));
        uint24 rate = _rate(change, age, minimum, maximum, sensitivity);
        assertGe(rate, minimum);
        assertLe(rate, maximum);
        if (change <= 0 || age == 0 || sensitivity == 0) assertEq(rate, minimum);
    }

    function _rate(int256 change, uint32 age, uint24 minimum, uint24 maximum, uint32 sensitivity)
        private returns (uint24)
    {
        harness.setSignal(change, age);
        LaunchHookFeeContextV2 memory context = _context(-1);
        context.minimumPips = minimum;
        context.maximumPips = maximum;
        context.feeSensitivityPipsSecondsPerTick = sensitivity;
        return harness.rate(context);
    }

    function _context(int256 amount) private pure returns (LaunchHookFeeContextV2 memory context) {
        context.sqrtPriceX96 = uint160(1 << 96);
        context.activeLiquidity = 1_000;
        context.amountSpecified = amount;
        context.zeroForOne = true;
        context.minimumPips = 750;
        context.maximumPips = 10_000;
        context.feeSensitivityPipsSecondsPerTick = 3_000;
        context.feeMode = ILaunchHookV1.FeeMode.InputToken;
    }
}
