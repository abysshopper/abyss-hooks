// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Minimal dynamic fee-owner lookup consumed by fee routers.
interface ILaunchFeeOwnerRegistry {
    function feeOwner(address launch) external view returns (address);
}
