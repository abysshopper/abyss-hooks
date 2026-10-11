// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { HookLaunchFixture, LaunchReceiptV1, ILaunchSupplyFork } from "../../../contracts/test/HookLaunchFixture.sol";
import { ReferenceBoundHook } from "../ReferenceBoundHook.sol";

contract ReferenceBoundHookPolicyTest is HookLaunchFixture {
    constructor() HookLaunchFixture("hooks/reference-bound/ReferenceBoundHook.sol:ReferenceBoundHook") { }

    function testPolicyLaunchBurnsUnusedInventory() public {
        for (uint8 mode; mode < 2; ++mode) {
            if ((vm.envUint("HOOK_FEE_MODE_FLAGS") & (uint256(1) << mode)) == 0) continue;
            (LaunchReceiptV1 memory receipt,,) = _launchWithPolicy(mode, 3_300_001 + mode,
                launchScenario.minimumHookFeePips, launchScenario.maximumHookFeePips,
                launchScenario.feeSensitivityPipsSecondsPerTick, true);
            assertLt(ILaunchSupplyFork(receipt.token).totalSupply(), launchScenario.tokenSupply);
        }
    }
}
