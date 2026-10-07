// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { DN404Mirror } from "../../../../../lib/dn404/src/DN404Mirror.sol";

/// @notice Standard ERC7631 mirror. The base authenticates every NFT transfer's actual operator.
/// @dev Immutable launch metadata needs no mutable mirror owner or administrative refresh path.
contract LaunchDN404MirrorV1 is DN404Mirror {
    constructor(address deployer) DN404Mirror(deployer) { }
}
