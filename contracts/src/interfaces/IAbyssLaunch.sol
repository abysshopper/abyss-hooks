// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Canonical oracle configuration authority consumed by lifecycle hooks.
/// @dev Deliberately excludes legacy Abyss launch, token, router and position APIs.
interface IAbyssLaunchFactory {
    function oracleConfigs(bytes32 id)
        external
        view
        returns (uint24 maxAbsTickMove, uint16 cardinality);
}
