// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

library V4HookFlags {
    uint160 internal constant AFTER_INITIALIZE_FLAG = 1 << 12;
    uint160 internal constant BEFORE_ADD_LIQUIDITY_FLAG = 1 << 11;
    uint160 internal constant BEFORE_REMOVE_LIQUIDITY_FLAG = 1 << 9;
    uint160 internal constant BEFORE_SWAP_FLAG = 1 << 7;
    uint160 internal constant AFTER_SWAP_FLAG = 1 << 6;
    uint160 internal constant BEFORE_SWAP_RETURNS_DELTA_FLAG = 1 << 3;
    uint160 internal constant AFTER_SWAP_RETURNS_DELTA_FLAG = 1 << 2;
    uint160 internal constant BEFORE_DONATE_FLAG = 1 << 5;
    uint160 internal constant ALL_HOOK_MASK = (1 << 14) - 1;

    uint160 internal constant AFTER_DONATE_FLAG = 1 << 4;

    uint160 internal constant ABYSS_STATIC_FEE_PERMISSIONS = AFTER_INITIALIZE_FLAG
        | BEFORE_ADD_LIQUIDITY_FLAG | BEFORE_REMOVE_LIQUIDITY_FLAG | BEFORE_SWAP_FLAG
        | AFTER_SWAP_FLAG | BEFORE_SWAP_RETURNS_DELTA_FLAG | AFTER_SWAP_RETURNS_DELTA_FLAG;

    /// @dev V2 lifecycle root profile: donate custody checkpoints on top of the static-fee set.
    ///      Historical `ABYSS_STATIC_FEE_PERMISSIONS` deployments keep their original 0x1acc mask.
    uint160 internal constant SHARED_LAUNCH_V2_PERMISSIONS =
        ABYSS_STATIC_FEE_PERMISSIONS | BEFORE_DONATE_FLAG | AFTER_DONATE_FLAG;

    function hasStaticFeePermissions(address hook) internal pure returns (bool) {
        return uint160(hook) & ALL_HOOK_MASK == ABYSS_STATIC_FEE_PERMISSIONS;
    }

    function hasSharedLaunchV2Permissions(address hook) internal pure returns (bool) {
        return uint160(hook) & ALL_HOOK_MASK == SHARED_LAUNCH_V2_PERMISSIONS;
    }
}
