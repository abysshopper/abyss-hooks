// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ERC20 } from "solady/tokens/ERC20.sol";
import { ECDSA } from "solady/utils/ECDSA.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { PoolBoundHookParametersV2 } from "../../src/hooks/v4/PoolBoundHookParametersV2.sol";
import { PoolBoundLaunchHookBaseV2 } from "../../src/hooks/v4/authoring/PoolBoundLaunchHookBaseV2.sol";
import { LaunchHookFeeContextV2 } from "../../src/hooks/v4/authoring/LaunchHookFeeRateV2.sol";

/// @notice Test-only public authority, supplied to prerequisites through its constructor.
contract SignedSwapAuthority {
    using PoolIdLibrary for PoolKey;

    address public immutable signer;
    address public immutable quoteAsset;

    constructor(address signer_, address quoteAsset_) {
        require(signer_ != address(0) && quoteAsset_ != address(0), "test authority required");
        signer = signer_;
        quoteAsset = quoteAsset_;
    }

    function digest(address hook, address sender, PoolKey memory key, SwapParams memory params,
        address payer, uint256 deadline) public view returns (bytes32)
    {
        return keccak256(abi.encode(keccak256("abyss-hooks.test-swap-pass.v1"), block.chainid,
            address(this), hook, sender, PoolId.unwrap(key.toId()), params, payer, deadline));
    }

    function validate(address hook, address sender, PoolKey memory key, SwapParams memory params,
        address payer, uint256 deadline, bytes memory signature) external view returns (bool)
    {
        if (msg.sender != hook || address(key.hooks) != hook || payer == address(0) || block.timestamp > deadline) {
            return false;
        }
        return ECDSA.tryRecover(digest(hook, sender, key, params, payer, deadline), signature) == signer;
    }
}

/// @notice Actual six-decimal test token with an immutable, constructor-provided authority.
contract ConstructorAuthorityQuote is ERC20 {
    SignedSwapAuthority public immutable swapAuthority;
    address private immutable minter;

    constructor(SignedSwapAuthority authority_) {
        require(authority_.quoteAsset() == address(this), "test quote constructor binding");
        swapAuthority = authority_;
        minter = msg.sender;
    }

    function name() public pure override returns (string memory) { return "Constructor authority quote"; }
    function symbol() public pure override returns (string memory) { return "CAQ"; }
    function decimals() public pure override returns (uint8) { return 6; }

    function mint(address recipient, uint256 rawAmount) external {
        require(msg.sender == minter, "test fixture minter only");
        _mint(recipient, rawAmount);
    }
}

/// @notice Maintainer-only custom-data fixture, never a catalogue or production submission.
/// @dev Authenticated final callbacks carry custom data into the existing swap observer seam.
contract RestrictedSignedQuoteHook is PoolBoundLaunchHookBaseV2 {
    error InvalidQuote();
    error InvalidSwapPass();
    error ExactOutputDisabled();

    SignedSwapAuthority public immutable swapAuthority;

    constructor(PoolBoundHookParametersV2 memory parameters) PoolBoundLaunchHookBaseV2(parameters) {
        SignedSwapAuthority selected;
        try ConstructorAuthorityQuote(parameters.quoteCurrency).swapAuthority() returns (SignedSwapAuthority authority_) {
            selected = authority_;
        } catch { revert InvalidQuote(); }
        if (address(selected).code.length == 0 || selected.quoteAsset() != parameters.quoteCurrency) {
            revert InvalidQuote();
        }
        swapAuthority = selected;
    }

    function authorFeeBps() public pure override returns (uint16) { return 500; }
    function swapFeeModel() public pure override returns (SwapFeeModel) { return SwapFeeModel.Dynamic; }

    function _calculateRate(LaunchHookFeeContextV2 memory context) internal pure override returns (uint24) {
        return context.minimumPips;
    }

    function _onBeforeSwap(int24, uint128) internal view override {
        (address sender, PoolKey memory key, SwapParams memory params, bytes memory hookData) =
            abi.decode(msg.data[4:], (address, PoolKey, SwapParams, bytes));
        if (hookData.length == 0) revert InvalidSwapPass();
        (address payer, uint256 deadline, bytes memory signature) = abi.decode(hookData, (address, uint256, bytes));
        if (!swapAuthority.validate(address(this), sender, key, params, payer, deadline, signature)) {
            revert InvalidSwapPass();
        }
        if (params.amountSpecified > 0) revert ExactOutputDisabled();
    }
}
