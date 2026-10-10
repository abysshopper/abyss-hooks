// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { HookSmokeTest } from "../HookSmokeTest.sol";
import { LaunchScenario, LaunchPlanV1, LaunchRefusalStage } from "../HookLaunchFixture.sol";
import { FreeFeeHook, PositiveFeeHook } from "./FeePolicyFixtures.sol";

contract FreeFeeHookSmokeTest is HookSmokeTest {
    constructor() HookSmokeTest("contracts/test/fixtures/FeePolicyFixtures.sol:FreeFeeHook") { }

    function _configureScenario() internal view override returns (LaunchScenario memory selected) {
        selected = _defaultScenario();
        selected.minimumHookFeePips = 0;
        selected.maximumHookFeePips = 0;
        selected.feeSensitivityPipsSecondsPerTick = 0;
    }
}

contract PositiveFeeHookSmokeTest is HookSmokeTest {
    constructor() HookSmokeTest("contracts/test/fixtures/FeePolicyFixtures.sol:PositiveFeeHook") { }

    function _expectedZeroFeeLaunchRevert(LaunchPlanV1 memory)
        internal pure override returns (LaunchRefusalStage stage, bytes memory reason)
    {
        return (LaunchRefusalStage.Prepare, abi.encodePacked(PositiveFeeHook.PositiveFeeRequired.selector));
    }
}
