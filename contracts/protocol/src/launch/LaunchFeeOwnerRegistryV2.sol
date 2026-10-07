// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Global fee ownership for launch fee-routing boundaries, with two-step and batched
///         transfers.
/// @dev Transfers are two-step (propose, then accept by the new owner) so a mistyped address
///      can never capture fees. Every entry point takes arrays so one transaction moves many
///      launches. Only future distributions follow a new owner.
contract LaunchFeeOwnerRegistryV2 {
    error ZeroAddress();
    error Unauthorized();
    error AlreadyConfigured();
    error InvalidLauncher();
    error InvalidLaunch();
    error AlreadyRegistered();
    error UnregisteredLaunch();
    error SameOwner();
    error InvalidSplitter();
    error AlreadyBound();
    error SplitterCannotOwnFees();
    error NoPendingTransfer();

    event LauncherConfigured(address indexed launcher);
    event LaunchRegistered(address indexed launch, address indexed feeOwner);
    event FeeOwnershipTransferStarted(
        address indexed launch, address indexed currentOwner, address indexed pendingOwner
    );
    event FeeOwnershipTransferCancelled(address indexed launch, address indexed pendingOwner);
    event FeeOwnershipTransferred(
        address indexed launch, address indexed previousOwner, address indexed newOwner
    );
    event FeeSplitterBound(address indexed launch, address indexed splitter);

    address public immutable protocolAdmin;
    address public launcher;
    mapping(address launch => address owner) public feeOwner;
    mapping(address launch => address pending) public pendingFeeOwner;
    mapping(address launch => address splitter) public feeSplitter;

    constructor(address protocolAdmin_) {
        if (protocolAdmin_ == address(0)) revert ZeroAddress();
        protocolAdmin = protocolAdmin_;
    }

    /// @notice Irrevocably binds the sole launch registrar.
    function setLauncher(address launcher_) external {
        if (msg.sender != protocolAdmin) revert Unauthorized();
        if (launcher != address(0)) revert AlreadyConfigured();
        if (launcher_ == address(0) || launcher_.code.length == 0) revert InvalidLauncher();
        launcher = launcher_;
        emit LauncherConfigured(launcher_);
    }

    /// @notice Records the launch creator as its initial fee owner exactly once.
    function registerLaunch(address launch, address initialOwner) external {
        if (msg.sender != launcher) revert Unauthorized();
        if (launch == address(0) || launch.code.length == 0) revert InvalidLaunch();
        if (initialOwner == address(0)) revert ZeroAddress();
        if (feeOwner[launch] != address(0)) revert AlreadyRegistered();
        feeOwner[launch] = initialOwner;
        emit LaunchRegistered(launch, initialOwner);
    }

    /// @notice Irrevocably binds a launch to its fee splitter.
    function bindSplitter(address launch, address splitter) external {
        if (msg.sender != launcher) revert Unauthorized();
        if (feeOwner[launch] == address(0)) revert UnregisteredLaunch();
        if (splitter == address(0) || splitter.code.length == 0) revert InvalidSplitter();
        if (feeSplitter[launch] != address(0)) revert AlreadyBound();
        if (feeOwner[launch] == splitter) revert SplitterCannotOwnFees();
        feeSplitter[launch] = splitter;
        emit FeeSplitterBound(launch, splitter);
    }

    /// @notice Proposes `newOwner` for every listed launch the caller owns. Passing the zero
    ///         address cancels pending proposals.
    function transferFeeOwnership(address[] calldata launches, address newOwner) external {
        for (uint256 i; i < launches.length; ++i) {
            address launch = launches[i];
            address currentOwner = feeOwner[launch];
            if (currentOwner == address(0)) revert UnregisteredLaunch();
            if (msg.sender != currentOwner) revert Unauthorized();
            if (newOwner == address(0)) {
                address pending = pendingFeeOwner[launch];
                if (pending == address(0)) revert NoPendingTransfer();
                delete pendingFeeOwner[launch];
                emit FeeOwnershipTransferCancelled(launch, pending);
                continue;
            }
            if (newOwner == currentOwner) revert SameOwner();
            if (newOwner == feeSplitter[launch]) revert SplitterCannotOwnFees();
            pendingFeeOwner[launch] = newOwner;
            emit FeeOwnershipTransferStarted(launch, currentOwner, newOwner);
        }
    }

    /// @notice Accepts every listed launch proposed to the caller.
    function acceptFeeOwnership(address[] calldata launches) external {
        for (uint256 i; i < launches.length; ++i) {
            address launch = launches[i];
            if (pendingFeeOwner[launch] != msg.sender) revert NoPendingTransfer();
            delete pendingFeeOwner[launch];
            address previousOwner = feeOwner[launch];
            feeOwner[launch] = msg.sender;
            emit FeeOwnershipTransferred(launch, previousOwner, msg.sender);
        }
    }

    /// @notice Protocol-admin override for community takeovers (CTO) of abandoned launches.
    /// @dev Immediate by design; clears any pending proposal. Fees already paid or credited to
    ///      the previous owner remain theirs.
    function overrideFeeOwner(address[] calldata launches, address newOwner) external {
        if (msg.sender != protocolAdmin) revert Unauthorized();
        if (newOwner == address(0)) revert ZeroAddress();
        for (uint256 i; i < launches.length; ++i) {
            address launch = launches[i];
            address currentOwner = feeOwner[launch];
            if (currentOwner == address(0)) revert UnregisteredLaunch();
            if (newOwner == currentOwner) revert SameOwner();
            if (newOwner == feeSplitter[launch]) revert SplitterCannotOwnFees();
            delete pendingFeeOwner[launch];
            feeOwner[launch] = newOwner;
            emit FeeOwnershipTransferred(launch, currentOwner, newOwner);
        }
    }
}
