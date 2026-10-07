// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Immutable author economics and swap-rate model for contributed launch hooks.
/// @dev The developer rate is required, not a creator-reducible ceiling. The existing V3 hub
///      pays the registered author from the post-bounty owner allocation; hooks name no payee.
interface ILaunchHookAuthorTerms {
    enum SwapFeeModel {
        Static,
        Dynamic
    }

    function authorFeeBps() external pure returns (uint16);
    function swapFeeModel() external pure returns (SwapFeeModel);
}
