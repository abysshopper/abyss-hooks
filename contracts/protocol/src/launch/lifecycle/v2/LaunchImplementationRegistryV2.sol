// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { EIP712 } from "solady/utils/EIP712.sol";
import { SignatureCheckerLib } from "solady/utils/SignatureCheckerLib.sol";
import { AdapterRegistrationV1, ProfileRegistrationV1, ProfileTopologyV1,
    LaunchCapabilitiesV1 } from "../v1/LaunchTypesV1.sol";
import { ILaunchMarketAdapterV1 } from "../v1/ILaunchLifecycleV1.sol";
import { ILaunchRegistryV2, LaunchEnvelopeV2 } from "./ILaunchRegistryV2.sol";
import { ILaunchFeeHubFactoryV3 } from "../../fees/v3/ILaunchFeeHubV3.sol";
import { LaunchCertificationV2, IAbyssAdapterMetadataV2 } from "./LaunchCertificationV2.sol";

interface IAuthorHubCoreV2 {
    function feeFactory() external view returns (address);
}

/// @notice Admission authority for explicitly approved immutable artifact versions.
/// @dev Governance approves full code and evidence. Certification checks the exact admitted
///      bindings; neither a permission mask nor a signature is a runtime security proof.
contract LaunchImplementationRegistryV2 is ILaunchRegistryV2, EIP712 {
    error Unauthorized();
    error InvalidRegistration();
    error InvalidAuthorization();
    error AlreadyRegistered();
    error IneligibleImplementation();
    error InvalidPage();

    event AdapterRegistered(bytes32 indexed id, address indexed implementation, bytes32 codeHash, uint64 capabilities, uint32 configVersion);
    event ProfileRegistered(bytes32 indexed id, bytes32 indexed adapterId, bytes32 configSchema, bytes32 dependencyDigest);
    event ProfileAdmitted(bytes32 indexed id, address indexed beneficiary, bytes32 indexed reviewManifestDigest,
        bytes32 termsDigest, bytes32 envelopeHash, uint16 maximumDeveloperFeeBps);
    event AdapterDisabled(bytes32 indexed id);
    event ProfileDisabled(bytes32 indexed id);
    event FundingInputAdmissionChanged(address indexed asset, bool allowed);
    event FundingTargetRegistered(address indexed target, address indexed spender, bytes32 codeHash);
    event FundingTargetDisabled(address indexed target);

    struct FundingTarget { address spender; bytes32 codeHash; bool enabled; }

    bytes32 public constant PROFILE_DOMAIN = keccak256("black-market.launch-profile.v2");
    bytes32 public constant BENEFICIARY_AUTHORIZATION_TYPEHASH = keccak256(
        "BeneficiaryAuthorization(bytes32 profileId,bytes32 reviewManifestDigest,bytes32 termsDigest,bytes32 envelopeHash,uint256 nonce,uint256 deadline)"
    );
    address public immutable admin;
    address public immutable override core;
    uint16 public immutable override protocolMaximumDeveloperFeeBps;
    LaunchCertificationV2 public immutable certification;
    mapping(bytes32 => AdapterRegistrationV1) private _adapters;
    mapping(bytes32 => ProfileRegistrationV1) private _profiles;
    mapping(bytes32 => ProfileTopologyV1) private _profileTopologies;
    mapping(bytes32 => LaunchEnvelopeV2) private _envelopes;
    mapping(address => uint256) public override beneficiaryNonces;
    mapping(address => address) public override authorPayout;
    mapping(address => address[]) private _authorHubs;
    mapping(address => mapping(address => bool)) private _authorHubRegistered;
    mapping(address => bool) public override fundingInputAllowed;
    mapping(address => FundingTarget) private _fundingTargets;
    bytes32[] private _adapterIds;
    bytes32[] private _profileIds;

    constructor(address admin_, address core_, uint16 protocolMaximumDeveloperFeeBps_) {
        if (admin_ == address(0) || core_ == address(0) || protocolMaximumDeveloperFeeBps_ >= 10_000)
            revert InvalidRegistration();
        admin = admin_;
        core = core_;
        protocolMaximumDeveloperFeeBps = protocolMaximumDeveloperFeeBps_;
        certification = new LaunchCertificationV2();
    }

    modifier onlyAdmin() { if (msg.sender != admin) revert Unauthorized(); _; }

    function _domainNameAndVersion() internal pure override returns (string memory name, string memory version) {
        name = "Black Market Launch Registry";
        version = "2";
    }

    function registerAdapter(bytes32 id, address implementation, uint64 capabilities, uint32 configVersion) external onlyAdmin {
        if (_adapters[id].implementation != address(0)) revert AlreadyRegistered();
        if (id == bytes32(0) || implementation.code.length == 0 || configVersion == 0
            || (capabilities & LaunchCapabilitiesV1.REQUIRED) != LaunchCapabilitiesV1.REQUIRED
            || ILaunchMarketAdapterV1(implementation).core() != core) revert InvalidRegistration();
        bytes32 codeHash = implementation.codehash;
        _adapters[id] = AdapterRegistrationV1(implementation, codeHash, capabilities, configVersion, true);
        _adapterIds.push(id);
        emit AdapterRegistered(id, implementation, codeHash, capabilities, configVersion);
    }

    function registerAbyssProfile(uint8 variant, ProfileRegistrationV1 calldata registration)
        external override onlyAdmin
    {
        AdapterRegistrationV1 storage adapterRegistration = _adapters[registration.adapterId];
        if (variant > 3 || adapterRegistration.configVersion != 1
            || adapterRegistration.implementation.code.length == 0) revert InvalidRegistration();
        bytes32 id = IAbyssAdapterMetadataV2(adapterRegistration.implementation).profileId(variant);
        AdapterRegistrationV1 memory implementation = _validateRegistration(id, registration);
        _profileTopologies[id] = certification.certifyAbyss(core, id, variant, registration, implementation);
        _storeProfile(id, registration);
    }


    function registerProfile(bytes32 id, ProfileRegistrationV1 calldata registration,
        LaunchEnvelopeV2 calldata envelope, uint256 nonce, uint256 deadline, bytes calldata authorization)
        external override onlyAdmin
    {
        AdapterRegistrationV1 memory implementation = _validateRegistration(id, registration);
        if (id != profileId(envelope)) revert InvalidRegistration();
        _profileTopologies[id] = certification.certify(
            core, id, registration, implementation, envelope, protocolMaximumDeveloperFeeBps
        );
        address payout = authorPayout[envelope.beneficiary];
        address controller = payout == address(0) ? envelope.beneficiary : payout;
        if (nonce != beneficiaryNonces[envelope.beneficiary] || block.timestamp > deadline
            || !SignatureCheckerLib.isValidSignatureNowCalldata(controller,
                authorizationDigest(id, registration, envelope, nonce, deadline), authorization)) revert InvalidAuthorization();
        beneficiaryNonces[envelope.beneficiary] = nonce + 1;
        if (payout == address(0)) {
            authorPayout[envelope.beneficiary] = envelope.beneficiary;
            emit AuthorPayoutUpdated(envelope.beneficiary, address(0), envelope.beneficiary, msg.sender);
        }
        _envelopes[id] = envelope;
        _storeProfile(id, registration);
        emit ProfileAdmitted(id, envelope.beneficiary, envelope.reviewManifestDigest,
            envelope.termsDigest, keccak256(abi.encode(registration, envelope)), envelope.maximumDeveloperFeeBps);
    }

    function profileId(LaunchEnvelopeV2 calldata envelope) public pure override returns (bytes32 id) {
        // Excludes instance addresses/runtime immutables to avoid profile/adapter CREATE cycles.
        // The signature commits those exact graph fields, and this ID can never be rebound.
        bytes32[11] memory identity;
        identity[0] = PROFILE_DOMAIN;
        identity[1] = envelope.artifactDigest;
        identity[2] = envelope.reviewManifestDigest;
        identity[3] = envelope.configBoundsDigest;
        identity[4] = envelope.termsDigest;
        identity[5] = bytes32(uint256(envelope.topology));
        identity[6] = bytes32(uint256(envelope.configVersion));
        identity[7] = bytes32(uint256(envelope.economicVersion));
        identity[8] = bytes32(uint256(uint160(envelope.beneficiary)));
        identity[9] = bytes32(uint256(envelope.maximumDeveloperFeeBps));
        identity[10] = bytes32(uint256(envelope.capabilities));
        assembly ("memory-safe") { id := keccak256(identity, 0x160) }
    }

    function authorizationDigest(bytes32 id, ProfileRegistrationV1 calldata registration,
        LaunchEnvelopeV2 calldata envelope, uint256 nonce, uint256 deadline)
        public view override returns (bytes32)
    {
        return _hashTypedData(keccak256(abi.encode(BENEFICIARY_AUTHORIZATION_TYPEHASH,
            id, envelope.reviewManifestDigest, envelope.termsDigest,
            keccak256(abi.encode(registration, envelope)), nonce, deadline)));
    }

    function _validateRegistration(bytes32 id, ProfileRegistrationV1 calldata registration)
        private view returns (AdapterRegistrationV1 memory implementation)
    {
        if (_profiles[id].adapterId != bytes32(0)) revert AlreadyRegistered();
        implementation = _adapters[registration.adapterId];
        if (id == bytes32(0) || !implementation.enabled || registration.configSchema == bytes32(0)
            || implementation.implementation.code.length == 0
            || implementation.implementation.codehash != implementation.codeHash
            || ILaunchMarketAdapterV1(implementation.implementation).core() != core
            || registration.dependencyDigest == bytes32(0) || !registration.enabled
            || registration.dependencyDigest != ILaunchMarketAdapterV1(implementation.implementation).dependencyDigest()
            || registration.venue.code.length == 0
            || (registration.factory != address(0) && registration.factory.code.length == 0)
            || (registration.hook != address(0) && registration.hook.code.length == 0)
            || (registration.capabilities & LaunchCapabilitiesV1.REQUIRED) != LaunchCapabilitiesV1.REQUIRED
            || (registration.capabilities & implementation.capabilities) != registration.capabilities) revert InvalidRegistration();
    }

    function _storeProfile(bytes32 id, ProfileRegistrationV1 calldata registration) private {
        _profiles[id] = registration;
        _profileIds.push(id);
        emit ProfileRegistered(id, registration.adapterId, registration.configSchema, registration.dependencyDigest);
    }

    function profileEnvelope(bytes32 id) external view override returns (LaunchEnvelopeV2 memory) {
        return _envelopes[id];
    }

    function developerTerms(bytes32 id) external view override returns (
        address implementation, address beneficiary, uint16 maximumDeveloperFeeBps, bytes32 termsDigest, bool enabled
    ) {
        LaunchEnvelopeV2 storage envelope = _envelopes[id];
        if (envelope.economicVersion == 0) return (address(0), address(0), 0, bytes32(0), false);
        ProfileRegistrationV1 storage p = _profiles[id];
        implementation = _adapters[p.adapterId].implementation;
        beneficiary = envelope.beneficiary;
        maximumDeveloperFeeBps = envelope.maximumDeveloperFeeBps;
        termsDigest = envelope.termsDigest;
        // Broken/retired metadata fails closed for pending bindings, without hiding the
        // immutable terms or affecting any active hub's frozen source liabilities.
        try this.requireEligible(p.adapterId, id, envelope.configVersion, envelope.capabilities)
            returns (address admitted) { enabled = admitted == implementation; }
        catch { enabled = false; }
    }

    function setAuthorPayout(address authorId, address payout) external override {
        address previousPayout = authorPayout[authorId];
        if (previousPayout == address(0) || payout == address(0)) revert InvalidRegistration();
        if (msg.sender != admin && msg.sender != previousPayout) revert Unauthorized();
        authorPayout[authorId] = payout;
        emit AuthorPayoutUpdated(authorId, previousPayout, payout, msg.sender);
    }

    function registerAuthorHub(address authorId) external override {
        if (authorPayout[authorId] == address(0)) revert InvalidRegistration();
        if (!_isCanonicalHub(msg.sender)) revert Unauthorized();
        if (_authorHubRegistered[authorId][msg.sender]) return;
        _authorHubRegistered[authorId][msg.sender] = true;
        uint256 index = _authorHubs[authorId].length;
        _authorHubs[authorId].push(msg.sender);
        emit AuthorHubRegistered(authorId, msg.sender, index);
    }

    /// @dev Only the immutable registry core chooses the canonical factory. Fixed-size staticcall
    ///      outputs reject reverting, short, oversized or noncanonical ABI words without copying
    ///      arbitrary returndata. Caller-provided core/factory/registry getters are never trusted.
    function _isCanonicalHub(address hub) private view returns (bool valid) {
        address registryCore = core;
        bytes4 factorySelector = IAuthorHubCoreV2.feeFactory.selector;
        bytes4 hubSelector = ILaunchFeeHubFactoryV3.isHub.selector;
        assembly ("memory-safe") {
            mstore(0, factorySelector)
            let ok := staticcall(gas(), registryCore, 0, 4, 0, 0x20)
            if and(ok, eq(returndatasize(), 0x20)) {
                let factory := mload(0)
                if and(iszero(shr(160, factory)), iszero(iszero(factory))) {
                    mstore(0, hubSelector)
                    mstore(4, hub)
                    ok := staticcall(gas(), factory, 0, 0x24, 0, 0x20)
                    valid := and(and(ok, eq(returndatasize(), 0x20)), eq(mload(0), 1))
                }
            }
        }
    }

    function authorHubCount(address authorId) external view override returns (uint256) {
        return _authorHubs[authorId].length;
    }

    function authorHubs(address authorId, uint256 offset, uint256 limit)
        external view override returns (address[] memory hubs, uint256 nextOffset, uint256 total)
    {
        address[] storage registered = _authorHubs[authorId];
        total = registered.length;
        if (limit == 0 || limit > 100 || offset > total) revert InvalidPage();
        uint256 count = total - offset;
        if (count > limit) count = limit;
        hubs = new address[](count);
        for (uint256 i; i < count; ++i) hubs[i] = registered[offset + i];
        nextOffset = offset + count;
    }

    function disableAdapter(bytes32 id) external onlyAdmin {
        if (!_adapters[id].enabled) revert IneligibleImplementation();
        _adapters[id].enabled = false;
        emit AdapterDisabled(id);
    }
    function disableProfile(bytes32 id) external onlyAdmin {
        if (!_profiles[id].enabled) revert IneligibleImplementation();
        _profiles[id].enabled = false;
        emit ProfileDisabled(id);
    }
    function setFundingInputAllowed(address asset, bool allowed) external onlyAdmin {
        if (asset.code.length == 0) revert InvalidRegistration();
        fundingInputAllowed[asset] = allowed;
        emit FundingInputAdmissionChanged(asset, allowed);
    }
    function registerFundingTarget(address target, address spender) external onlyAdmin {
        if (_fundingTargets[target].spender != address(0)) revert AlreadyRegistered();
        if (target.code.length == 0 || spender.code.length == 0) revert InvalidRegistration();
        _fundingTargets[target] = FundingTarget(spender, target.codehash, true);
        emit FundingTargetRegistered(target, spender, target.codehash);
    }
    function disableFundingTarget(address target) external onlyAdmin {
        if (!_fundingTargets[target].enabled) revert IneligibleImplementation();
        _fundingTargets[target].enabled = false;
        emit FundingTargetDisabled(target);
    }
    function adapter(bytes32 id) external view override returns (AdapterRegistrationV1 memory) { return _adapters[id]; }
    function profile(bytes32 id) external view override returns (ProfileRegistrationV1 memory) { return _profiles[id]; }
    function profileTopology(bytes32 id) external view override returns (ProfileTopologyV1 memory) { return _profileTopologies[id]; }

    function requireEligible(bytes32 adapterId, bytes32 id, uint32 configVersion, uint64 requiredCapabilities)
        external view override returns (address implementation)
    {
        AdapterRegistrationV1 storage a = _adapters[adapterId];
        ProfileRegistrationV1 storage p = _profiles[id];
        implementation = a.implementation;
        if (!a.enabled || !p.enabled || p.adapterId != adapterId || a.configVersion != configVersion
            || implementation.codehash != a.codeHash || implementation.code.length == 0
            || (a.capabilities & requiredCapabilities) != requiredCapabilities
            || (p.capabilities & requiredCapabilities) != requiredCapabilities
            || ILaunchMarketAdapterV1(implementation).core() != core
            || ILaunchMarketAdapterV1(implementation).dependencyDigest() != p.dependencyDigest) revert IneligibleImplementation();
    }
    function fundingTarget(address target) external view override returns (address spender, bytes32 codeHash, bool enabled) {
        FundingTarget storage entry = _fundingTargets[target];
        return (entry.spender, entry.codeHash, entry.enabled);
    }
    function adapterCount() external view returns (uint256) { return _adapterIds.length; }
    function profileCount() external view returns (uint256) { return _profileIds.length; }
    function adapterIds(uint256 offset, uint256 limit) external view returns (bytes32[] memory) { return _page(_adapterIds, offset, limit); }
    function profileIds(uint256 offset, uint256 limit) external view returns (bytes32[] memory) { return _page(_profileIds, offset, limit); }
    function _page(bytes32[] storage ids, uint256 offset, uint256 limit) private view returns (bytes32[] memory values) {
        if (limit > 100) revert InvalidPage();
        uint256 count = offset < ids.length ? ids.length - offset : 0;
        if (count > limit) count = limit;
        values = new bytes32[](count);
        for (uint256 i; i < count; ++i) values[i] = ids[offset + i];
    }
}
