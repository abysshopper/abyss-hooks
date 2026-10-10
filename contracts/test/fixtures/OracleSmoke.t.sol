// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { HookSmokeTest } from "../HookSmokeTest.sol";
import { StaticOracleHook } from "../TruncatedOracleComposition.t.sol";

contract StaticOracleHookSmokeTest is HookSmokeTest {
    constructor() HookSmokeTest("contracts/test/TruncatedOracleComposition.t.sol:StaticOracleHook") { }
}
