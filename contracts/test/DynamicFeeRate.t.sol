// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { DynamicFeeHookRate } from "../../hooks/dynamic-fee/DynamicFeeHook.sol";
import { LaunchHookFeeRateV2, LaunchHookFeeContextV2 } from "../src/hooks/v4/authoring/LaunchHookFeeRateV2.sol";
import { ILaunchHookV1 } from "../src/hooks/v4/authoring/ILaunchHookV1.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";

// Exercise the production arithmetic and final signed-request/bounds guard without a pool constructor.
contract DynamicFeeHookRateHarness is LaunchHookFeeRateV2 {
    function swapFeeModel() public pure override returns (SwapFeeModel) {
        return SwapFeeModel.Dynamic;
    }

    function rate(LaunchHookFeeContextV2 memory context) external pure returns (uint24) {
        return _boundedRate(context);
    }

    function _calculateRate(LaunchHookFeeContextV2 memory context) internal pure override returns (uint24) {
        return DynamicFeeHookRate.calculate(context);
    }
}

contract DynamicFeeRateTest is Test {
    uint160 private constant Q96 = uint160(1 << 96);
    DynamicFeeHookRateHarness private harness;

    function setUp() public {
        harness = new DynamicFeeHookRateHarness();
    }

    function testDirectionSelectsInputVirtualReserve() public view {
        LaunchHookFeeContextV2 memory context = _context(-600);
        context.sqrtPriceX96 = 2 * Q96;
        context.activeLiquidity = 1_200;
        // At this price the input reserves are 600 token0 units and 2,400 token1 units.
        assertEq(harness.rate(context), 6_000);
        context.zeroForOne = false;
        assertEq(harness.rate(context), 3_600);
    }

    function testHalfReserveMidpointAndLargeVolume() public view {
        LaunchHookFeeContextV2 memory context = _context(-500);
        assertEq(harness.rate(context), 4_666);
        context.amountSpecified = -1_000;
        assertEq(harness.rate(context), 6_000);
        context.amountSpecified = -999_000;
        assertEq(harness.rate(context), 9_992);
        context.amountSpecified = -type(int256).max;
        assertEq(harness.rate(context), 9_999);
    }

    function testReserveAndUpliftFloorRatherThanRoundUp() public view {
        LaunchHookFeeContextV2 memory context = _context(-2);
        context.sqrtPriceX96 = 2 * Q96;
        context.activeLiquidity = 5;
        // Token0 reserve floors from 2.5 to 2; token1 reserve is 10.
        assertEq(harness.rate(context), 6_000);
        context.zeroForOne = false;
        assertEq(harness.rate(context), 3_333);

        context = _context(-1);
        context.activeLiquidity = 3;
        context.maximumPips = 13;
        assertEq(harness.rate(context), 4);
        context.amountSpecified = -3;
        assertEq(harness.rate(context), 7);
    }

    function testZeroInputAndSmallMaximumBaselineFloor() public view {
        LaunchHookFeeContextV2 memory context = _context(0);
        assertEq(harness.rate(context), 2_000);
        context.maximumPips = 13;
        assertEq(harness.rate(context), 2);
        context.maximumPips = 4;
        assertEq(harness.rate(context), 0);
        context.activeLiquidity = 1;
        context.amountSpecified = -1;
        assertEq(harness.rate(context), 2);
    }

    function testZeroMaximumTakesPrecedenceOverFallbacks() public view {
        LaunchHookFeeContextV2 memory context = _context(-1_000);
        context.maximumPips = 0;
        assertEq(harness.rate(context), 0);
        context.amountSpecified = type(int256).max;
        assertEq(harness.rate(context), 0);
        context.amountSpecified = -1;
        context.activeLiquidity = 0;
        assertEq(harness.rate(context), 0);
        context.activeLiquidity = 1;
        context.sqrtPriceX96 = 0;
        assertEq(harness.rate(context), 0);
        context.sqrtPriceX96 = 2 * Q96;
        assertEq(harness.rate(context), 0);
    }

    function testConservativeFallbacksInBothDirections() public view {
        for (uint256 direction; direction < 2; ++direction) {
            LaunchHookFeeContextV2 memory context = _context(1);
            context.zeroForOne = direction == 0;
            assertEq(harness.rate(context), 10_000);
            context.amountSpecified = type(int256).max;
            assertEq(harness.rate(context), 10_000);

            context.amountSpecified = -1;
            context.activeLiquidity = 0;
            assertEq(harness.rate(context), 10_000);
            context.activeLiquidity = 1_000;
            context.sqrtPriceX96 = 0;
            assertEq(harness.rate(context), 10_000);

            // A positive liquidity and price can still floor the directional reserve to zero.
            context.activeLiquidity = 1;
            context.sqrtPriceX96 = direction == 0 ? 2 * Q96 : Q96 / 2;
            assertEq(harness.rate(context), 10_000);
            context.amountSpecified = 0;
            assertEq(harness.rate(context), 10_000);
        }
    }

    function testMonotonicityAndBoundsAcrossSignedRequestLimits() public view {
        uint24[7] memory maxima = [uint24(0), 1, 4, 5, 13, 10_000, 999_999];
        int256[10] memory requests = [
            int256(0), -1, -2, -499, -500, -999, -1_000, -999_000,
            -int256(type(int128).max), -type(int256).max
        ];
        for (uint256 mode; mode < 2; ++mode) {
            for (uint256 direction; direction < 2; ++direction) {
                for (uint256 m; m < maxima.length; ++m) {
                    LaunchHookFeeContextV2 memory context = _context(0);
                    context.maximumPips = maxima[m];
                    context.feeMode = ILaunchHookV1.FeeMode(mode);
                    context.zeroForOne = direction == 0;
                    context.sqrtPriceX96 = 2 * Q96;
                    context.activeLiquidity = 1_200;
                    uint24 previous;
                    for (uint256 i; i < requests.length; ++i) {
                        context.amountSpecified = requests[i];
                        uint24 current = harness.rate(context);
                        assertGe(current, previous);
                        assertLe(current, maxima[m]);
                        previous = current;
                    }
                    assertEq(previous, maxima[m] == 0 ? 0 : maxima[m] - 1);
                    context.amountSpecified = type(int256).max;
                    assertEq(harness.rate(context), maxima[m]);
                }
            }
        }
    }

    function testExtremePricesLiquidityAndInputUseFullPrecision() public view {
        for (uint256 direction; direction < 2; ++direction) {
            LaunchHookFeeContextV2 memory context = _context(-1);
            context.zeroForOne = direction == 0;
            context.activeLiquidity = type(uint128).max;
            context.sqrtPriceX96 = direction == 0 ? TickMath.MIN_SQRT_PRICE : TickMath.MAX_SQRT_PRICE - 1;
            assertEq(harness.rate(context), 2_000);
            // Reserve and input remain addable; intermediate products need full precision.
            context.amountSpecified = -type(int256).max;
            assertEq(harness.rate(context), 9_999);
        }
    }

    function testSignedMinimumIsRejectedEvenWithZeroMaximum() public {
        LaunchHookFeeContextV2 memory context = _context(type(int256).min);
        vm.expectRevert(LaunchHookFeeRateV2.FeeTooLarge.selector);
        harness.rate(context);
        context.maximumPips = 0;
        vm.expectRevert(LaunchHookFeeRateV2.FeeTooLarge.selector);
        harness.rate(context);
    }

    function _context(int256 amountSpecified) private pure returns (LaunchHookFeeContextV2 memory context) {
        context.sqrtPriceX96 = Q96;
        context.activeLiquidity = 1_000;
        context.amountSpecified = amountSpecified;
        context.zeroForOne = true;
        context.maximumPips = 10_000;
        context.feeMode = ILaunchHookV1.FeeMode.InputToken;
    }
}
