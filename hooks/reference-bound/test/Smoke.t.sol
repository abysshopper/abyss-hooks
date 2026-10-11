// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { HookSmokeTest } from "../../../contracts/test/HookSmokeTest.sol";
import { ReferenceBoundHook } from "../ReferenceBoundHook.sol";

contract ReferenceBoundHookSmokeTest is HookSmokeTest {
    constructor() HookSmokeTest("hooks/reference-bound/ReferenceBoundHook.sol:ReferenceBoundHook") { }
}
