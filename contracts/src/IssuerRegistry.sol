// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IIssuerRegistry} from "./interfaces/IBookbuilder.sol";

/// @title IssuerRegistry
/// @notice Registry of RWA issuers approved by governance (the 48h Timelock).
///         Each issuer record holds the legal entity reference, the offering documents CID
///         and the RWA token the issuer will deliver to investors.
contract IssuerRegistry is AccessControl, IIssuerRegistry {
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    enum Status {
        None,
        Approved,
        Suspended,
        Revoked
    }

    struct Issuer {
        Status status;
        uint64 approvedAt;
        address deliveryToken;
        string legalEntityRef; // e.g. "Acme Property SPV I LLC, Delaware #1234567" or LEI
        string docsCID; // IPFS CID of issuer-level documents (formation docs, PPM, audits)
    }

    mapping(address => Issuer) private _issuers;
    mapping(address => bool) private _approved; // mirrors status == Approved for cheap checks
    address[] private _issuerList;

    event IssuerApproved(address indexed issuer, address indexed deliveryToken, string legalEntityRef, string docsCID);
    event IssuerUpdated(address indexed issuer, address indexed deliveryToken, string legalEntityRef, string docsCID);
    event IssuerDocsUpdated(address indexed issuer, string docsCID);
    event IssuerStatusChanged(address indexed issuer, Status status);

    error ZeroAddress();
    error AlreadyRegistered();
    error NotRegistered();
    error EmptyField();
    error InvalidStatus();

    constructor(address admin, address guardian) {
        if (admin == address(0) || guardian == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GUARDIAN_ROLE, guardian);
    }

    // ---------------------------------------------------------------- governance

    /// @notice Approve a new issuer. Admin = Timelock, so every approval is public for 48h first.
    function approveIssuer(
        address issuer,
        address deliveryToken,
        string calldata legalEntityRef,
        string calldata docsCID
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (issuer == address(0) || deliveryToken == address(0)) revert ZeroAddress();
        if (bytes(legalEntityRef).length == 0 || bytes(docsCID).length == 0) revert EmptyField();
        Issuer storage i = _issuers[issuer];
        if (i.status != Status.None) revert AlreadyRegistered();
        i.status = Status.Approved;
        i.approvedAt = uint64(block.timestamp);
        i.deliveryToken = deliveryToken;
        i.legalEntityRef = legalEntityRef;
        i.docsCID = docsCID;
        _approved[issuer] = true;
        _issuerList.push(issuer);
        emit IssuerApproved(issuer, deliveryToken, legalEntityRef, docsCID);
    }

    /// @notice Change an issuer's legal reference or delivery token (governance only).
    function updateIssuer(
        address issuer,
        address deliveryToken,
        string calldata legalEntityRef,
        string calldata docsCID
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (deliveryToken == address(0)) revert ZeroAddress();
        if (bytes(legalEntityRef).length == 0 || bytes(docsCID).length == 0) revert EmptyField();
        Issuer storage i = _issuers[issuer];
        if (i.status == Status.None) revert NotRegistered();
        i.deliveryToken = deliveryToken;
        i.legalEntityRef = legalEntityRef;
        i.docsCID = docsCID;
        emit IssuerUpdated(issuer, deliveryToken, legalEntityRef, docsCID);
    }

    /// @notice Governance can set any status (re-approve, suspend, revoke).
    function setStatus(address issuer, Status status) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (status == Status.None) revert InvalidStatus();
        _setStatus(issuer, status);
    }

    /// @notice Guardian can only suspend, immediately, to stop new offerings during an incident.
    function suspend(address issuer) external onlyRole(GUARDIAN_ROLE) {
        _setStatus(issuer, Status.Suspended);
    }

    // ---------------------------------------------------------------- issuer

    /// @notice Issuers may publish updated issuer-level documents (e.g. new annual report).
    function updateDocs(string calldata docsCID) external {
        if (!_approved[msg.sender]) revert NotRegistered();
        Issuer storage i = _issuers[msg.sender];
        if (bytes(docsCID).length == 0) revert EmptyField();
        i.docsCID = docsCID;
        emit IssuerDocsUpdated(msg.sender, docsCID);
    }

    // ---------------------------------------------------------------- views

    function isApprovedIssuer(address issuer) external view returns (bool) {
        return _approved[issuer];
    }

    function deliveryTokenOf(address issuer) external view returns (address) {
        return _issuers[issuer].deliveryToken;
    }

    function getIssuer(address issuer) external view returns (Issuer memory) {
        return _issuers[issuer];
    }

    function issuerCount() external view returns (uint256) {
        return _issuerList.length;
    }

    /// @notice Paged listing for frontends (bounded by `limit`).
    function issuers(uint256 offset, uint256 limit) external view returns (address[] memory out) {
        uint256 n = _issuerList.length;
        if (offset >= n) return new address[](0);
        uint256 end = offset + limit > n ? n : offset + limit;
        out = new address[](end - offset);
        for (uint256 k = offset; k < end; ++k) {
            out[k - offset] = _issuerList[k];
        }
    }

    function _setStatus(address issuer, Status status) internal {
        Issuer storage i = _issuers[issuer];
        if (i.status == Status.None) revert NotRegistered();
        i.status = status;
        _approved[issuer] = status == Status.Approved;
        emit IssuerStatusChanged(issuer, status);
    }
}
