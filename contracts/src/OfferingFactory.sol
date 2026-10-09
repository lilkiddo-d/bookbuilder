// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Types, IIssuerRegistry} from "./interfaces/IBookbuilder.sol";
import {OfferingEscrow} from "./OfferingEscrow.sol";
import {FixedPriceOffering} from "./offerings/FixedPriceOffering.sol";
import {BatchAuction} from "./offerings/BatchAuction.sol";
import {DutchAuction} from "./offerings/DutchAuction.sol";

/// @title OfferingFactory
/// @notice Deploys offerings (+ their escrows) as EIP-1167 clones for approved issuers, and is the single
///         source of protocol configuration that offerings read (pause flag, compliance, fee collector,
///         vesting, $BOOK hooks, oracle).
///         Admin = Timelock (48h). Guardian may pause instantly; only governance unpauses.
contract OfferingFactory is AccessControl, Pausable, ReentrancyGuard {
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    uint16 public constant MAX_FEE_BPS = 500; // 5%
    uint32 public constant MIN_DELIVERY_WINDOW = 1 days;
    uint32 public constant MAX_DELIVERY_WINDOW = 180 days;
    uint64 public constant MAX_OFFERING_DURATION = 180 days;

    IIssuerRegistry public immutable issuerRegistry;

    address public compliance;
    address public feeCollector;
    address public vesting;
    address public hooks; // ProjectTokenHooks ($BOOK staking); inert until the token is set
    address public oracle; // swappable display-price oracle adapter

    address public escrowImpl;
    address public fixedPriceImpl;
    address public batchAuctionImpl;
    address public dutchAuctionImpl;

    uint16 public feeBps;
    bool public complianceMandatory = true;
    mapping(address => bool) public allowedPaymentToken;

    address[] private _offerings;
    mapping(address => bool) public isOffering;
    mapping(address => bool) public isEscrow;
    mapping(address => address[]) private _offeringsByIssuer;

    event OfferingCreated(
        address indexed offering,
        address indexed escrow,
        address indexed issuer,
        Types.OfferingKind kind,
        address saleToken,
        address paymentToken
    );
    event ConfigUpdated(bytes32 indexed key, address value);
    event FeeUpdated(uint16 feeBps);
    event PaymentTokenAllowed(address indexed token, bool allowed);
    event ComplianceMandatorySet(bool mandatory);
    event ImplementationsUpdated(address escrow, address fixedPrice, address batchAuction, address dutchAuction);

    error ZeroAddress();
    error NotApprovedIssuer();
    error PaymentTokenNotAllowed();
    error WrongSaleToken();
    error ComplianceRequired();
    error BadDeliveryWindow();
    error BadDuration();
    error FeeTooHigh();

    struct Config {
        address admin;
        address guardian;
        address issuerRegistry;
        address compliance;
        address feeCollector;
        address vesting;
        address hooks;
        address oracle;
        uint16 feeBps;
        address escrowImpl;
        address fixedPriceImpl;
        address batchAuctionImpl;
        address dutchAuctionImpl;
    }

    constructor(Config memory c) {
        if (
            c.admin == address(0) || c.guardian == address(0) || c.issuerRegistry == address(0)
                || c.compliance == address(0) || c.feeCollector == address(0) || c.vesting == address(0)
        ) revert ZeroAddress();
        if (c.feeBps > MAX_FEE_BPS) revert FeeTooHigh();
        _grantRole(DEFAULT_ADMIN_ROLE, c.admin);
        _grantRole(GUARDIAN_ROLE, c.guardian);
        issuerRegistry = IIssuerRegistry(c.issuerRegistry);
        compliance = c.compliance;
        feeCollector = c.feeCollector;
        vesting = c.vesting;
        hooks = c.hooks;
        oracle = c.oracle;
        feeBps = c.feeBps;
        _setImplementations(c.escrowImpl, c.fixedPriceImpl, c.batchAuctionImpl, c.dutchAuctionImpl);
    }

    // ------------------------------------------------------------------ create

    function createFixedPrice(Types.CommonParams calldata p, Types.FixedPriceParams calldata fp)
        external
        whenNotPaused
        nonReentrant
        returns (address offering, address escrow)
    {
        _validate(p);
        (offering, escrow) = _clonePair(fixedPriceImpl, p);
        FixedPriceOffering(offering).initialize(address(this), msg.sender, escrow, p, fp);
        _record(offering, escrow, Types.OfferingKind.FixedPrice, p);
    }

    function createBatchAuction(Types.CommonParams calldata p, Types.BatchAuctionParams calldata bp)
        external
        whenNotPaused
        nonReentrant
        returns (address offering, address escrow)
    {
        _validate(p);
        (offering, escrow) = _clonePair(batchAuctionImpl, p);
        BatchAuction(offering).initialize(address(this), msg.sender, escrow, p, bp);
        _record(offering, escrow, Types.OfferingKind.BatchAuction, p);
    }

    function createDutchAuction(Types.CommonParams calldata p, Types.DutchAuctionParams calldata dp)
        external
        whenNotPaused
        nonReentrant
        returns (address offering, address escrow)
    {
        _validate(p);
        (offering, escrow) = _clonePair(dutchAuctionImpl, p);
        DutchAuction(offering).initialize(address(this), msg.sender, escrow, p, dp);
        _record(offering, escrow, Types.OfferingKind.DutchAuction, p);
    }

    // ------------------------------------------------------------------ guardian / governance

    function pause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    function setFeeBps(uint16 newFeeBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newFeeBps > MAX_FEE_BPS) revert FeeTooHigh();
        feeBps = newFeeBps;
        emit FeeUpdated(newFeeBps);
    }

    function setPaymentToken(address token, bool allowed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        allowedPaymentToken[token] = allowed;
        emit PaymentTokenAllowed(token, allowed);
    }

    function setComplianceMandatory(bool mandatory) external onlyRole(DEFAULT_ADMIN_ROLE) {
        complianceMandatory = mandatory;
        emit ComplianceMandatorySet(mandatory);
    }

    function setCompliance(address v) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (v == address(0)) revert ZeroAddress();
        compliance = v;
        emit ConfigUpdated("compliance", v);
    }

    function setFeeCollector(address v) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (v == address(0)) revert ZeroAddress();
        feeCollector = v;
        emit ConfigUpdated("feeCollector", v);
    }

    function setVesting(address v) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (v == address(0)) revert ZeroAddress();
        vesting = v;
        emit ConfigUpdated("vesting", v);
    }

    /// @notice Hooks may be set to address(0) to switch all $BOOK features off.
    function setHooks(address v) external onlyRole(DEFAULT_ADMIN_ROLE) {
        hooks = v;
        emit ConfigUpdated("hooks", v);
    }

    function setOracle(address v) external onlyRole(DEFAULT_ADMIN_ROLE) {
        oracle = v;
        emit ConfigUpdated("oracle", v);
    }

    /// @notice Only affects offerings created afterwards.
    function setImplementations(address escrow_, address fixed_, address batch_, address dutch_)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _setImplementations(escrow_, fixed_, batch_, dutch_);
    }

    // ------------------------------------------------------------------ views

    function paused() public view override returns (bool) {
        return super.paused();
    }

    function offeringCount() external view returns (uint256) {
        return _offerings.length;
    }

    function offerings(uint256 offset, uint256 limit) external view returns (address[] memory out) {
        uint256 n = _offerings.length;
        if (offset >= n) return new address[](0);
        uint256 end = offset + limit > n ? n : offset + limit;
        out = new address[](end - offset);
        for (uint256 k = offset; k < end; ++k) {
            out[k - offset] = _offerings[k];
        }
    }

    function offeringsOf(address issuer) external view returns (address[] memory) {
        return _offeringsByIssuer[issuer];
    }

    // ------------------------------------------------------------------ internal

    function _validate(Types.CommonParams calldata p) internal view {
        if (!issuerRegistry.isApprovedIssuer(msg.sender)) revert NotApprovedIssuer();
        if (!allowedPaymentToken[p.paymentToken]) revert PaymentTokenNotAllowed();
        if (p.saleToken != issuerRegistry.deliveryTokenOf(msg.sender)) revert WrongSaleToken();
        if (complianceMandatory && !p.compliance.enabled) revert ComplianceRequired();
        if (p.deliveryWindow < MIN_DELIVERY_WINDOW || p.deliveryWindow > MAX_DELIVERY_WINDOW) {
            revert BadDeliveryWindow();
        }
        if (p.endTime <= p.startTime || p.endTime - p.startTime > MAX_OFFERING_DURATION) revert BadDuration();
    }

    function _clonePair(address impl, Types.CommonParams calldata p)
        internal
        returns (address offering, address escrow)
    {
        offering = Clones.clone(impl);
        escrow = Clones.clone(escrowImpl);
        OfferingEscrow(escrow).initialize(
            address(this),
            offering,
            msg.sender,
            p.paymentToken,
            p.saleToken,
            feeBps,
            p.deliveryWindow,
            p.vestingCliff,
            p.vestingDuration
        );
    }

    function _record(address offering, address escrow, Types.OfferingKind kind, Types.CommonParams calldata p)
        internal
    {
        _offerings.push(offering);
        isOffering[offering] = true;
        isEscrow[escrow] = true;
        _offeringsByIssuer[msg.sender].push(offering);
        emit OfferingCreated(offering, escrow, msg.sender, kind, p.saleToken, p.paymentToken);
    }

    function _setImplementations(address escrow_, address fixed_, address batch_, address dutch_) internal {
        if (escrow_ == address(0) || fixed_ == address(0) || batch_ == address(0) || dutch_ == address(0)) {
            revert ZeroAddress();
        }
        escrowImpl = escrow_;
        fixedPriceImpl = fixed_;
        batchAuctionImpl = batch_;
        dutchAuctionImpl = dutch_;
        emit ImplementationsUpdated(escrow_, fixed_, batch_, dutch_);
    }
}
