// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { HookSmokeTest } from "../../../contracts/test/HookSmokeTest.sol";
import { DynamicFeeHook } from "../DynamicFeeHook.sol";

contract DynamicFeeHookSmokeTest is HookSmokeTest {
    constructor() HookSmokeTest("hooks/dynamic-fee/DynamicFeeHook.sol:DynamicFeeHook") { }
}
