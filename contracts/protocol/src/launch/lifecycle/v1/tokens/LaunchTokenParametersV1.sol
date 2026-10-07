// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { TokenKindV1, RewardModeV1, TokenConfigV1 } from "../LaunchTypesV1.sol";

/// @notice Constructor and CREATE2 prediction use exactly the same token-parameter admission.
library LaunchTokenParametersV1 {
    error InvalidTokenConfiguration();

    uint256 internal constant MAX_NFTS = 10_000;
    // Matches the largest decimal reward magnitude in MultiAssetStreamV1. At this bound every
    // unresolved global reward residue is <1 raw asset unit, including divisor decreases.
    uint256 internal constant MAX_REWARD_ERC20_SUPPLY = 1e77;

    function validate(TokenConfigV1 memory config) internal pure {
        if (config.inventoryRecipient == address(0) || config.supply == 0
            || bytes(config.name).length == 0 || bytes(config.symbol).length == 0) {
            revert InvalidTokenConfiguration();
        }
        if (config.kind == TokenKindV1.ERC20) {
            if ((config.rewardMode != RewardModeV1.None && config.supply > MAX_REWARD_ERC20_SUPPLY)
                || config.nftUnit != 0 || bytes(config.metadataURI).length != 0) {
                revert InvalidTokenConfiguration();
            }
        } else {
            if (config.supply > type(uint96).max || config.nftUnit < 1 ether
                || config.nftUnit > type(uint96).max) revert InvalidTokenConfiguration();
            uint256 nftCount = config.supply / config.nftUnit;
            if (nftCount == 0 || nftCount > MAX_NFTS) revert InvalidTokenConfiguration();
        }
    }
}
