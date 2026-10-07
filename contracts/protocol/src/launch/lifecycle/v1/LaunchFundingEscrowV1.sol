// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { AssetFundingV1, FundingKindV1 } from "./LaunchTypesV1.sol";
import { ILaunchImplementationRegistryV1 } from "./ILaunchLifecycleV1.sol";

interface ILaunchWrappedNativeV1 { function deposit() external payable; }

/// @notice Per-launch ERC20 escrow with exact pulls, native wrapping and approved conversions.
/// @dev Only core may move recorded balances. Donations are never credited or swept. Conversions
///      use an exact temporary allowance and output/input deltas, not executor-wide balances.
contract LaunchFundingEscrowV1 {
    error Unauthorized();
    error InvalidFunding();
    error InexactTransfer();
    error InsufficientEscrow();
    error ConversionFailed(bytes reason);

    event Funded(bytes32 indexed launchId, address indexed asset, uint256 amount);
    event Refunded(bytes32 indexed launchId, address indexed asset, address indexed creator, uint256 amount);

    address public immutable core;
    ILaunchImplementationRegistryV1 public immutable registry;
    address public immutable wrappedNative;
    mapping(bytes32 => address) public creatorOf;
    mapping(bytes32 => mapping(address => uint256)) public balanceOf;
    mapping(address => uint256) public totalEscrow;
    mapping(bytes32 => address[]) private _assets;

    constructor(address core_, ILaunchImplementationRegistryV1 registry_, address wrappedNative_) {
        if (core_ == address(0) || address(registry_).code.length == 0 || registry_.core() != core_ || (wrappedNative_ != address(0) && wrappedNative_.code.length == 0)) revert InvalidFunding();
        core = core_;
        registry = registry_;
        wrappedNative = wrappedNative_;
    }

    modifier onlyCore() { if (msg.sender != core) revert Unauthorized(); _; }

    function fund(bytes32 launchId, address creator, AssetFundingV1[] calldata funding) external payable onlyCore {
        if (creator == address(0) || creatorOf[launchId] != address(0) || funding.length > 8) revert InvalidFunding();
        uint256 nativeRequired;
        for (uint256 i; i < funding.length; ++i) {
            if (funding[i].kind == FundingKindV1.NativeWrap || (funding[i].kind == FundingKindV1.Swap && funding[i].inputAsset == address(0))) nativeRequired += funding[i].inputAmount;
        }
        if (msg.value != nativeRequired) revert InvalidFunding();
        creatorOf[launchId] = creator;
        address previous;
        for (uint256 i; i < funding.length; ++i) {
            AssetFundingV1 calldata request = funding[i];
            if (request.asset <= previous || request.amount == 0 || request.asset.code.length == 0) revert InvalidFunding();
            previous = request.asset;
            uint256 beforeOutput = SafeTransferLib.balanceOf(request.asset, address(this));
            if (request.kind == FundingKindV1.ERC20) {
                if (request.inputAsset != request.asset || request.inputAmount != request.amount || request.target != address(0) || request.data.length != 0) revert InvalidFunding();
                _pullExact(request.asset, creator, request.amount);
            } else if (request.kind == FundingKindV1.NativeWrap) {
                if (request.asset != wrappedNative || request.inputAsset != request.asset || request.inputAmount != request.amount || request.target != address(0) || request.data.length != 0) revert InvalidFunding();
                ILaunchWrappedNativeV1(wrappedNative).deposit{value: request.amount}();
            } else {
                _convert(request, creator);
            }
            uint256 afterOutput = SafeTransferLib.balanceOf(request.asset, address(this));
            if (afterOutput < beforeOutput || afterOutput - beforeOutput < request.amount) revert InvalidFunding();
            uint256 received = afterOutput - beforeOutput;
            if (request.kind != FundingKindV1.Swap && received != request.amount) revert InexactTransfer();
            balanceOf[launchId][request.asset] = received;
            totalEscrow[request.asset] += received;
            _assets[launchId].push(request.asset);
            emit Funded(launchId, request.asset, received);
        }
    }

    function pay(bytes32 launchId, address asset, address recipient, uint256 amount) external onlyCore {
        uint256 balance = balanceOf[launchId][asset];
        if (creatorOf[launchId] == address(0) || amount > balance || recipient == address(0)) revert InsufficientEscrow();
        balanceOf[launchId][asset] = balance - amount;
        totalEscrow[asset] -= amount;
        _sendExact(asset, recipient, amount);
    }

    /// @dev Core has independently verified this exact transfer to escrow before crediting it.
    function creditRefund(bytes32 launchId, address asset, uint256 amount) external onlyCore {
        if (creatorOf[launchId] == address(0) || SafeTransferLib.balanceOf(asset, address(this)) < totalEscrow[asset] + amount) revert InexactTransfer();
        balanceOf[launchId][asset] += amount;
        totalEscrow[asset] += amount;
    }

    function refund(bytes32 launchId) external onlyCore returns (address[] memory assetsList, uint256[] memory amounts) {
        address creator = creatorOf[launchId];
        if (creator == address(0)) revert InvalidFunding();
        assetsList = _assets[launchId];
        amounts = new uint256[](assetsList.length);
        for (uint256 i; i < assetsList.length; ++i) {
            uint256 amount = balanceOf[launchId][assetsList[i]];
            amounts[i] = amount;
            if (amount == 0) continue;
            delete balanceOf[launchId][assetsList[i]];
            totalEscrow[assetsList[i]] -= amount;
            _sendExact(assetsList[i], creator, amount);
            emit Refunded(launchId, assetsList[i], creator, amount);
        }
    }

    function assets(bytes32 launchId) external view returns (address[] memory) { return _assets[launchId]; }

    function _convert(AssetFundingV1 calldata request, address creator) private {
        (address spender, bytes32 codeHash, bool enabled) = registry.fundingTarget(request.target);
        if (
            !enabled || spender == address(0) || request.target.codehash != codeHash || request.inputAmount == 0
                || request.inputAsset == request.asset || request.data.length == 0 || request.data.length > 16_384
        ) revert InvalidFunding();
        uint256 inputBefore;
        uint256 nativeBefore = address(this).balance;
        uint256 value;
        if (request.inputAsset == address(0)) {
            value = request.inputAmount;
            nativeBefore -= value;
        } else {
            if (!registry.fundingInputAllowed(request.inputAsset)) revert InvalidFunding();
            inputBefore = SafeTransferLib.balanceOf(request.inputAsset, address(this));
            _pullExact(request.inputAsset, creator, request.inputAmount);
            SafeTransferLib.safeApproveWithRetry(request.inputAsset, spender, request.inputAmount);
        }
        (bool success, bytes memory reason) = request.target.call{value: value}(request.data);
        if (!success) revert ConversionFailed(reason);
        if (request.inputAsset != address(0)) {
            SafeTransferLib.safeApproveWithRetry(request.inputAsset, spender, 0);
            uint256 inputAfter = SafeTransferLib.balanceOf(request.inputAsset, address(this));
            if (inputAfter < inputBefore || inputAfter - inputBefore > request.inputAmount) revert InexactTransfer();
            if (inputAfter != inputBefore) _sendExact(request.inputAsset, creator, inputAfter - inputBefore);
        }
        if (address(this).balance < nativeBefore || address(this).balance - nativeBefore > request.inputAmount) revert InexactTransfer();
        if (address(this).balance != nativeBefore) SafeTransferLib.safeTransferETH(creator, address(this).balance - nativeBefore);
    }

    function _pullExact(address asset, address creator, uint256 amount) private {
        uint256 beforeBalance = SafeTransferLib.balanceOf(asset, address(this));
        uint256 payerBefore = SafeTransferLib.balanceOf(asset, creator);
        SafeTransferLib.safeTransferFrom(asset, creator, address(this), amount);
        if (SafeTransferLib.balanceOf(asset, address(this)) != beforeBalance + amount || SafeTransferLib.balanceOf(asset, creator) + amount != payerBefore) revert InexactTransfer();
    }

    function _sendExact(address asset, address recipient, uint256 amount) private {
        if (amount == 0) return;
        uint256 beforeBalance = SafeTransferLib.balanceOf(asset, address(this));
        uint256 recipientBefore = SafeTransferLib.balanceOf(asset, recipient);
        SafeTransferLib.safeTransfer(asset, recipient, amount);
        if (SafeTransferLib.balanceOf(asset, address(this)) + amount != beforeBalance || SafeTransferLib.balanceOf(asset, recipient) != recipientBefore + amount) revert InexactTransfer();
    }

    receive() external payable { }
}
