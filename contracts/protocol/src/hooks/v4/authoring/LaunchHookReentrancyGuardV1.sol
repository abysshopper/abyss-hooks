// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @dev Versioned copy of Solady ReentrancyGuard's storage-slot and assembly semantics, with
///      nonvirtual modifiers. Otherwise an author could override an inherited virtual modifier
///      and remove the outer accounting/callback guard despite nonvirtual function entrypoints.
///      This prevents that provided extension, not malicious assembly in a derived runtime.
abstract contract LaunchHookReentrancyGuardV1 {
    error Reentrancy();

    uint256 private constant _REENTRANCY_GUARD_SLOT = 0x929eee149b4bd21268;

    modifier nonReentrant() {
        assembly ("memory-safe") {
            if eq(sload(_REENTRANCY_GUARD_SLOT), address()) {
                mstore(0x00, 0xab143c06) // Reentrancy().
                revert(0x1c, 0x04)
            }
            sstore(_REENTRANCY_GUARD_SLOT, address())
        }
        _;
        assembly ("memory-safe") {
            sstore(_REENTRANCY_GUARD_SLOT, codesize())
        }
    }

    modifier nonReadReentrant() {
        assembly ("memory-safe") {
            if eq(sload(_REENTRANCY_GUARD_SLOT), address()) {
                mstore(0x00, 0xab143c06) // Reentrancy().
                revert(0x1c, 0x04)
            }
        }
        _;
    }
}
