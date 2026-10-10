// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { PoolHookDeployerV1 } from "../src/hooks/v4/authoring/PoolHookDeployerV1.sol";
import { PoolBoundHookParametersV2 } from "../src/hooks/v4/PoolBoundHookParametersV2.sol";

contract PoolHookDeployerTest is Test {
    function testActualEncodedParametersDetermineInitcodeLimit() public {
        PoolBoundHookParametersV2 memory parameters;
        bytes memory arguments = abi.encode(parameters);
        bytes memory creation = new bytes(49_152 - arguments.length);
        PoolHookDeployerV1 holder = new PoolHookDeployerV1(creation);
        assertEq(holder.initCodeHash(parameters), keccak256(bytes.concat(creation, arguments)));

        holder = new PoolHookDeployerV1(new bytes(creation.length + 1));
        vm.expectRevert(PoolHookDeployerV1.InitCodeTooLarge.selector);
        holder.initCodeHash(parameters);
    }
}
