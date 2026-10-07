// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Canonical source boundary retained by the current lifecycle fee hubs.
/// @dev The V1 wire version does not imply the frozen V1 fee-hub economics.
interface ILaunchFeeSourceV1 {
    function hub() external view returns (address);
    function assets() external view returns (address[] memory);
    function sourceId() external view returns (bytes32);
    function validateBinding() external view;

    /// @notice Hub-only collection of exact newly accrued fees in ascending assets() order.
    /// @dev Old balances and donations are neither reported nor forwarded.
    function collect() external returns (uint256[] memory amounts);
}
