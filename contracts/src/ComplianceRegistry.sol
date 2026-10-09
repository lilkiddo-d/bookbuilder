// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IComplianceRegistry, Types} from "./interfaces/IBookbuilder.sol";

/// @title ComplianceRegistry
/// @notice On-chain investor eligibility attestations written by approved KYC/KYB attestors.
///         Stores no personal data: only a tier, an accreditation flag, an ISO-3166 country code
///         and an expiry. Offerings check it on every participation (ON by default).
contract ComplianceRegistry is AccessControl, IComplianceRegistry {
    bytes32 public constant ATTESTOR_ROLE = keccak256("ATTESTOR_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    struct Attestation {
        uint8 tier; // 0 = none, 1 = basic KYC, 2 = enhanced, 3 = institutional ...
        bool accredited;
        bool frozen; // set by guardian/attestor on sanctions hits etc.
        bytes2 country; // ISO-3166 alpha-2, e.g. "US"
        uint64 expiry;
    }

    mapping(address => Attestation) private _attestations;
    mapping(bytes2 => bool) public blockedCountry;

    event Attested(address indexed investor, uint8 tier, bool accredited, bytes2 country, uint64 expiry, address attestor);
    event Revoked(address indexed investor, address by);
    event FrozenSet(address indexed investor, bool frozen, address by);
    event CountryBlocked(bytes2 indexed country, bool blocked);

    error ZeroAddress();
    error BadExpiry();
    error LengthMismatch();

    constructor(address admin, address guardian) {
        if (admin == address(0) || guardian == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GUARDIAN_ROLE, guardian);
    }

    function attest(address investor, uint8 tier, bool accredited, bytes2 country, uint64 expiry)
        public
        onlyRole(ATTESTOR_ROLE)
    {
        if (investor == address(0)) revert ZeroAddress();
        if (expiry <= block.timestamp) revert BadExpiry();
        Attestation storage a = _attestations[investor];
        a.tier = tier;
        a.accredited = accredited;
        a.country = country;
        a.expiry = expiry;
        emit Attested(investor, tier, accredited, country, expiry, msg.sender);
    }

    /// @notice Batch attestation, bounded by calldata size.
    function attestBatch(
        address[] calldata investors,
        uint8[] calldata tiers,
        bool[] calldata accredited,
        bytes2[] calldata countries,
        uint64 expiry
    ) external onlyRole(ATTESTOR_ROLE) {
        uint256 n = investors.length;
        if (tiers.length != n || accredited.length != n || countries.length != n) revert LengthMismatch();
        for (uint256 k; k < n; ++k) {
            attest(investors[k], tiers[k], accredited[k], countries[k], expiry);
        }
    }

    function revoke(address investor) external onlyRole(ATTESTOR_ROLE) {
        delete _attestations[investor];
        emit Revoked(investor, msg.sender);
    }

    /// @notice Guardian (or attestor) can freeze instantly, e.g. on a sanctions match.
    function setFrozen(address investor, bool frozen) external {
        if (!hasRole(GUARDIAN_ROLE, msg.sender) && !hasRole(ATTESTOR_ROLE, msg.sender)) {
            revert AccessControlUnauthorizedAccount(msg.sender, GUARDIAN_ROLE);
        }
        _attestations[investor].frozen = frozen;
        emit FrozenSet(investor, frozen, msg.sender);
    }

    function setCountryBlocked(bytes2 country, bool blocked) external onlyRole(DEFAULT_ADMIN_ROLE) {
        blockedCountry[country] = blocked;
        emit CountryBlocked(country, blocked);
    }

    // ---------------------------------------------------------------- views

    function isEligible(address investor, Types.ComplianceRules calldata rules) external view returns (bool) {
        if (!rules.enabled) return true;
        Attestation storage a = _attestations[investor];
        if (a.frozen || a.tier == 0 || a.expiry < block.timestamp) return false;
        if (blockedCountry[a.country]) return false;
        if (a.tier < rules.minTier) return false;
        if (rules.requireAccredited && !a.accredited) return false;
        return true;
    }

    function tierOf(address investor) external view returns (uint8) {
        Attestation storage a = _attestations[investor];
        if (a.frozen || a.expiry < block.timestamp) return 0;
        return a.tier;
    }

    function attestationOf(address investor) external view returns (Attestation memory) {
        return _attestations[investor];
    }
}
