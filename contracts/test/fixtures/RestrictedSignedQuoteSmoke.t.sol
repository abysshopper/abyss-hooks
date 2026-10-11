// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { HookSmokeTest } from "../HookSmokeTest.sol";
import { LaunchScenario, PoolKey, SwapParams, Currency, PoolBoundHookParametersV2, LaunchPlanV1 } from "../HookLaunchFixture.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { CustomRevert } from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import { RestrictedSignedQuoteHook, SignedSwapAuthority, ConstructorAuthorityQuote } from "./RestrictedSignedQuoteHook.sol";

/// @notice Maintainer check of test-side prerequisites, raw units, actual signed data and refusals.
contract RestrictedSignedQuoteHookSmokeTest is HookSmokeTest {
    uint256 private testSignerKey;
    SignedSwapAuthority private authority;
    ConstructorAuthorityQuote private fixtureQuote;

    constructor() HookSmokeTest("contracts/test/fixtures/RestrictedSignedQuoteHook.sol:RestrictedSignedQuoteHook") { }

    function _setUpPrerequisites() internal override {
        // The runner supplies a disposable PUBLIC test key, never a wallet or production key.
        testSignerKey = vm.envUint("HOOK_TEST_SIGNER_KEY");
        require(testSignerKey != 0, "public test signer key required");
        address predictedQuote = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        authority = new SignedSwapAuthority(vm.addr(testSignerKey), predictedQuote);
        fixtureQuote = new ConstructorAuthorityQuote(authority);
        assertEq(address(fixtureQuote), predictedQuote);
        assertNotEq(address(fixtureQuote), address(wrappedNative));
    }

    function _configureScenario() internal view override returns (LaunchScenario memory selected) {
        selected = _defaultScenario();
        selected.quoteAsset = address(fixtureQuote);
        selected.quoteFunding = 2_000_000_000;
        selected.launchFunding = 497_000_000;
        selected.tokenSupply = 3_100_000_000;
        selected.liquidity = 1_000_000_000;
        // The native opening-buy actor has no custom-data API. Buy through the real trader instead.
        selected.openingBuyQuote = 0;
        selected.buyExactInputQuote = 10_000_000;
        selected.sellExactInputBase = 5_000_000;
        selected.buyExactOutputBase = 1_000_000;
        selected.sellExactOutputQuote = 1_000_000;
    }

    function _fundQuote(address payer, uint256 rawAmount) internal override {
        fixtureQuote.mint(payer, rawAmount);
    }

    function _swapHookData(PoolKey memory key, SwapParams memory params, address payer)
        internal override returns (bytes memory)
    {
        return _signedData(key, params, payer, testSignerKey);
    }

    function _expectedSwapRevert(PoolKey memory key, SwapParams memory params, address)
        internal pure override returns (bytes memory)
    {
        if (params.amountSpecified > 0) {
            return _wrappedHookRevert(key, RestrictedSignedQuoteHook.ExactOutputDisabled.selector);
        }
        return "";
    }

    function _signedData(PoolKey memory key, SwapParams memory params, address payer, uint256 signerKey)
        private returns (bytes memory)
    {
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = authority.digest(address(key.hooks), address(trader), key, params, payer, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        return abi.encode(payer, deadline, abi.encodePacked(r, s, v));
    }

    function _wrappedHookRevert(PoolKey memory key, bytes4 reason) private pure returns (bytes memory) {
        return abi.encodeWithSelector(CustomRevert.WrappedError.selector, address(key.hooks), IHooks.beforeSwap.selector,
            abi.encodePacked(reason), abi.encodePacked(Hooks.HookCallFailed.selector));
    }

    function testPolicySignedPassRejectsMissingOrWrongAuthority() public {
        (,, PoolKey memory key) = _launchWithPolicy(_firstFeeMode(), 3_000_001,
            launchScenario.minimumHookFeePips, launchScenario.maximumHookFeePips,
            launchScenario.feeSensitivityPipsSecondsPerTick, false);
        assertEq(address(RestrictedSignedQuoteHook(address(key.hooks)).swapAuthority()), address(authority));
        assertEq(authority.signer(), vm.addr(testSignerKey));
        SwapParams memory params = _swapParams(Currency.unwrap(key.currency0) == address(quote),
            -int256(launchScenario.buyExactInputQuote));
        bytes32 runtimeHash = address(key.hooks).codehash;
        assertEq(RestrictedSignedQuoteHook(address(key.hooks)).feeRate(params), launchScenario.minimumHookFeePips);
        _successfulSwap(key, params, creator);
        bytes memory reason = _wrappedHookRevert(key, RestrictedSignedQuoteHook.InvalidSwapPass.selector);
        _assertRejectedSwap(key, params, creator, "", reason);
        uint256 wrongKey = testSignerKey > 1 ? testSignerKey - 1 : testSignerKey + 1;
        assertNotEq(vm.addr(wrongKey), authority.signer());
        _assertRejectedSwap(key, params, creator, _signedData(key, params, creator, wrongKey), reason);
        _successfulSwap(key, params, creator);
        assertEq(address(key.hooks).codehash, runtimeHash, "signed-data checks must not rewrite the hook runtime");
        assertEq(deployer.deployedCodeHash(address(key.hooks)), runtimeHash);
    }

    function testPolicySignedPassBindsOriginalRequest() public {
        (,, PoolKey memory key) = _launchWithPolicy(_firstFeeMode(), 3_100_001,
            launchScenario.minimumHookFeePips, launchScenario.maximumHookFeePips,
            launchScenario.feeSensitivityPipsSecondsPerTick, false);
        SwapParams memory params = _swapParams(Currency.unwrap(key.currency0) == address(quote),
            -int256(launchScenario.buyExactInputQuote));
        bytes memory pass = _signedData(key, params, creator, testSignerKey);
        params.amountSpecified -= 1;
        _assertRejectedSwap(key, params, creator, pass,
            _wrappedHookRevert(key, RestrictedSignedQuoteHook.InvalidSwapPass.selector));
        _successfulSwap(key, params, creator);
    }

    function testPolicyConstructorRejectsUnapprovedQuote() public {
        LaunchPlanV1 memory plan = _planWithFees(_firstFeeMode(), 3_200_001,
            developerBps, launchScenario.maximumHookFeePips);
        (PoolBoundHookParametersV2 memory parameters,) = adapter.collectorFactory()
            .poolBoundHookParameters(address(adapter), core.predictToken(plan), plan.markets[0]);
        parameters.quoteCurrency = address(wrappedNative);
        bytes32 salt = _mine(address(deployer), deployer.initCodeHash(parameters));
        vm.expectRevert(RestrictedSignedQuoteHook.InvalidQuote.selector);
        deployer.deploy(parameters, salt);
    }
}
