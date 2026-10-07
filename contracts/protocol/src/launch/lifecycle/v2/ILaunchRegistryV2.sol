// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ILaunchImplementationRegistryV1 } from "../v1/ILaunchLifecycleV1.sol";
import { LaunchHookTopologyV1, ProfileRegistrationV1 } from "../v1/LaunchTypesV1.sol";

/// @notice Executable configuration bounds, not claims of runtime safety.
struct LaunchBoundsV2 {
    int24 minimumTickSpacing;
    int24 maximumTickSpacing;
    uint16 maximumPositions;
    uint16 maximumOracleCardinality;
    uint8 feeModeFlags;
}

/// @notice Exact admitted deployment graph. Bound instance runtime is authenticated by
///         the immutable deployer's recorded deployment and exact constructor commitment.
struct LaunchGraphV2 {
    address manager;
    address hookRoot;
    address oracleFactory;
    address locker;
    address collectorFactory;
    address collectorDeployer;
    address hookDeployer;
    bytes32 coreCodeHash;
    bytes32 managerCodeHash;
    bytes32 hookRuntimeCodeHash;
    bytes32 oracleFactoryCodeHash;
    bytes32 lockerCodeHash;
    bytes32 collectorFactoryCodeHash;
    bytes32 collectorDeployerCodeHash;
    bytes32 hookDeployerCodeHash;
    bytes32 hookCreationCodeHash;
    address codeChunk0;
    bytes32 codeChunk0Hash;
    address codeChunk1;
    bytes32 codeChunk1Hash;
    bytes32 sharedHookSalt;
}

/// @notice Frozen admission for one exact artifact/version in this registry domain.
/// @dev flags is reserved and must be zero. Callback declarations and inheritance do not
///      sandbox arbitrary Solidity: governance must review the entire executable graph.
struct LaunchEnvelopeV2 {
    bytes32 artifactDigest;
    bytes32 reviewManifestDigest;
    bytes32 configBoundsDigest;
    bytes32 termsDigest;
    LaunchHookTopologyV1 topology;
    uint32 configVersion;
    uint32 economicVersion;
    uint64 capabilities;
    uint64 flags;
    uint16 callbackFlags;
    uint16 callbackMask;
    address protocolTreasury;
    uint8 protocolFeeDenominator;
    address beneficiary;
    uint16 maximumDeveloperFeeBps;
    LaunchBoundsV2 bounds;
    LaunchGraphV2 graph;
}

interface ILaunchRegistryV2 is ILaunchImplementationRegistryV1 {
    event AuthorPayoutUpdated(
        address indexed authorId, address indexed previousPayout, address indexed newPayout, address operator
    );
    event AuthorHubRegistered(address indexed authorId, address indexed hub, uint256 index);

    /// @notice Live payout/controller for a stable admitted beneficiary identity; zero if unknown.
    /// @dev The envelope/config beneficiary remains the authorId. Retirement never changes routing.
    function authorPayout(address authorId) external view returns (address);
    /// @notice The registry admin or current payout/controller may update a known author's route.
    function setAuthorPayout(address authorId, address payout) external;

    /// @notice Canonical hubs self-register after finalizing nonzero-rate source terms.
    /// @dev Authentication is anchored to this registry's immutable core and its canonical factory.
    function registerAuthorHub(address authorId) external;
    function authorHubCount(address authorId) external view returns (uint256);
    /// @notice Append-only, deduplicated author hubs, including retired profiles' hubs.
    /// @dev limit is 1..100 and offset may not exceed total; offset == total returns an empty page.
    function authorHubs(address authorId, uint256 offset, uint256 limit)
        external view returns (address[] memory hubs, uint256 nextOffset, uint256 total);

    function protocolMaximumDeveloperFeeBps() external view returns (uint16);
    /// @dev Frozen terms plus current admission eligibility. Active fee paths must never
    ///      call this getter; eligibility is only a new/pending source binding boundary.
    function developerTerms(bytes32 profileId) external view returns (
        address adapter,
        address beneficiary,
        uint16 maximumDeveloperFeeBps,
        bytes32 termsDigest,
        bool enabled
    );
    function profileEnvelope(bytes32 profileId) external view returns (LaunchEnvelopeV2 memory);
    function profileId(LaunchEnvelopeV2 calldata envelope) external pure returns (bytes32);
    /// @notice Admission nonce keyed by the stable envelope beneficiary, not the current payout.
    function beneficiaryNonces(address authorId) external view returns (uint256);
    function authorizationDigest(
        bytes32 profileId,
        ProfileRegistrationV1 calldata registration,
        LaunchEnvelopeV2 calldata envelope,
        uint256 nonce,
        uint256 deadline
    ) external view returns (bytes32);
    /// @notice Admit one unchanged canonical Abyss variant (0..3), with no author economics.
    /// @dev Admin-only; the ID is derived from the adapter and the complete live graph is certified.
    function registerAbyssProfile(uint8 variant, ProfileRegistrationV1 calldata registration)
        external;
    function registerProfile(
        bytes32 profileId,
        ProfileRegistrationV1 calldata registration,
        LaunchEnvelopeV2 calldata envelope,
        uint256 nonce,
        uint256 deadline,
        bytes calldata authorization
    ) external;
}
