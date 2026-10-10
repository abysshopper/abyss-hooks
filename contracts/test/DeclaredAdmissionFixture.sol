// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { SignatureCheckerLib } from "solady/utils/SignatureCheckerLib.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { PoolBoundHookParametersV2 } from "../src/hooks/v4/PoolBoundHookParametersV2.sol";
import { PoolBoundLaunchHookBaseV2 } from "../src/hooks/v4/authoring/PoolBoundLaunchHookBaseV2.sol";

/// @notice Qualification fixture, not a catalogue submission. It exercises the optional
///         admission declarations through the real launch and pool callbacks, in the boundary
///         case a catalogue hook may not cover: the declared required quote IS wrapped native.
///         Buys after opening need the CONTRIBUTING SwapPass (EIP-712 domain name = this
///         contract's name, version "1"). Both declarations are constructor-independent `pure`.
contract DeclaredAdmissionFixtureHook is PoolBoundLaunchHookBaseV2 {
    error QuoteMustBeRequired();
    error SwapPassRequired();
    error SwapPassExpired();
    error SwapPassAmount();
    error SwapPassUsed();
    error SwapPassInvalid();

    /// @dev Robinhood Chain wrapped native, as pinned in contracts/config/robinhood.json.
    address public constant REQUIRED_QUOTE = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    /// @dev Fixture authority without a known key; qualification etches a test-key verifier here.
    address public constant SWAP_PASS_SIGNER = 0x5A55a55A55a55a55a55a55a55a55a55A55a55a55;
    uint256 private constant _UNBOUNDED = type(uint256).max;
    bytes32 private constant _SWAP_PASS_TYPEHASH =
        keccak256("SwapPass(address buyer,uint256 maxQuoteIn,bytes32 nonce,uint256 deadline)");
    bytes32 private constant _DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    bool private immutable _quoteIsCurrency0;
    mapping(bytes32 nonce => bool) public swapPassUsed;

    constructor(PoolBoundHookParametersV2 memory parameters) PoolBoundLaunchHookBaseV2(parameters) {
        if (parameters.quoteCurrency != REQUIRED_QUOTE) revert QuoteMustBeRequired();
        _quoteIsCurrency0 = parameters.quoteCurrency < parameters.token;
    }

    function authorFeeBps() public pure override returns (uint16) {
        return 500;
    }

    function requiredQuoteCurrency() external pure returns (address) {
        return REQUIRED_QUOTE;
    }

    function swapPassSigner() external pure returns (address) {
        return SWAP_PASS_SIGNER;
    }

    function _onBeforeSwap(int24, uint128) internal override {
        if (msg.sig != IHooks.beforeSwap.selector) return;
        (,, SwapParams memory params, bytes memory hookData) =
            abi.decode(msg.data[4:], (address, PoolKey, SwapParams, bytes));
        if (params.zeroForOne != _quoteIsCurrency0) return;
        if (this.openingCompletedAt(boundPoolId) == 0) return;
        if (hookData.length == 0) revert SwapPassRequired();
        (uint256 maxQuoteIn, bytes32 nonce, uint256 deadline, bytes memory signature) =
            abi.decode(hookData, (uint256, bytes32, uint256, bytes));
        if (block.timestamp > deadline) revert SwapPassExpired();
        if (maxQuoteIn != _UNBOUNDED
            && (params.amountSpecified >= 0 || uint256(-params.amountSpecified) > maxQuoteIn)) revert SwapPassAmount();
        if (swapPassUsed[nonce]) revert SwapPassUsed();
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01",
            keccak256(abi.encode(_DOMAIN_TYPEHASH, keccak256("DeclaredAdmissionFixtureHook"), keccak256("1"),
                block.chainid, address(this))),
            keccak256(abi.encode(_SWAP_PASS_TYPEHASH, tx.origin, maxQuoteIn, nonce, deadline))));
        if (!SignatureCheckerLib.isValidSignatureNow(SWAP_PASS_SIGNER, digest, signature)) revert SwapPassInvalid();
        swapPassUsed[nonce] = true;
    }
}
