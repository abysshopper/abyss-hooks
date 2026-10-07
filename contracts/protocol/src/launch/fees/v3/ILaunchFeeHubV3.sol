// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ILaunchFeeHubV2 } from "../v2/ILaunchFeeHubV2.sol";
import { ILaunchRegistryV2 } from "../../lifecycle/v2/ILaunchRegistryV2.sol";

/// @notice Admission-authenticated economics frozen before canonical custody is sealed.
/// @dev An unbound source has the all-zero tuple and no developer allocation. Source identity
///      is authenticated separately by configureSources, after its positions exist.
///      beneficiary is the stable authorId, not a frozen payout destination.
struct SourceTermsV3 {
    address adapter;
    bytes32 profileId;
    bytes32 termsDigest;
    address beneficiary;
    uint16 maximumDeveloperFeeBps;
    uint16 developerFeeBps;
}

/// @notice One isolated fixed-destination author claim outcome from a bounded factory page.
/// @dev status: 0 paid, 1 zero credit, 2 unsupported asset, 3 failed.
struct DeveloperClaimResultV3 {
    address hub;
    address asset;
    uint256 amount;
    uint8 status;
    bytes4 errorSelector;
}

/// @notice Source-attributed developer credits carved out of the post-bounty owner allocation.
/// @dev Retains the ordinary-call lifecycle/V2 collection ABI; V1/V2 hubs do not implement
///      these economics. Neither harvest nor either credit withdrawal consults admission.
interface ILaunchFeeHubV3 is ILaunchFeeHubV2 {
    function economicVersion() external view returns (uint16);
    function implementationRegistry() external view returns (ILaunchRegistryV2);
    function protocolMaximumDeveloperFeeBps() external view returns (uint16);

    /// @notice Only the exact currently admitted adapter can bind frozen source terms once.
    /// @dev The source must already name this hub, but need not yet have sealed positions.
    function bindSourceTerms(
        address source, bytes32 profileId, bytes32 termsDigest, uint16 developerFeeBps
    ) external;

    function sourceTerms(address source) external view returns (SourceTermsV3 memory);
    function claimableDeveloperFees(address authorId, address asset)
        external
        view
        returns (uint256);
    function reservedDeveloperFees(address asset) external view returns (uint256);

    /// @notice Anyone may pay a stable author's reserved credits directly to its live registry payout.
    /// @dev Does not collect, consult admission, change frozen terms or earn a bounty. Zero credit
    ///      returns zero; unsupported assets revert. The caller never receives or redirects funds.
    function claimDeveloperFees(address authorId, address asset) external returns (uint256 amount);
}

/// @notice Canonical hub membership and bounded, permissionless author-wide fixed-payout claims.
interface ILaunchFeeHubFactoryV3 {
    event DeveloperClaimResult(
        address indexed authorId, address indexed hub, address indexed asset,
        uint256 amount, uint8 status, bytes4 errorSelector
    );
    event DeveloperClaimPage(
        address indexed authorId, uint256 offset, uint256 nextOffset, uint256 total
    );

    function isHub(address hub) external view returns (bool);
    /// @dev limit is 1..10 hubs. Explicit assets are sorted, unique, nonzero and at most eight;
    ///      an empty list uses each hub's actual assets. Rows fail independently and cursors advance.
    function claimDeveloperFeesPage(address authorId, uint256 offset, uint256 limit, address[] calldata assets)
        external returns (DeveloperClaimResultV3[] memory results, uint256 nextOffset, uint256 total);
}
