// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Refunds} from "./Refunds.sol";
import {Types, IOffering, IOfferingEscrow, IFactoryConfig, IDeliveryVesting} from "./interfaces/IBookbuilder.sol";

/// @title OfferingEscrow
/// @notice Holds investor payments for exactly one offering until the issuer delivers the RWA tokens.
///         - Funds never reach the issuer before the full token amount is delivered into this escrow.
///         - If the issuer misses the delivery deadline, anyone can flip the escrow to Failed and every
///           investor gets a full refund (minus a non-reveal penalty, if any).
///         Deployed as an EIP-1167 clone per offering by the OfferingFactory.
contract OfferingEscrow is Initializable, ReentrancyGuard, Refunds, IOfferingEscrow {
    using SafeERC20 for IERC20;

    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    uint256 public constant BPS = 10_000;

    IFactoryConfig public factory;
    address public offering;
    address public issuer;
    IERC20 public paymentToken;
    IERC20 public saleToken;
    uint16 public feeBps;
    uint32 public deliveryWindow;
    uint64 public vestingCliff;
    uint64 public vestingDuration;

    Types.Stage public stage;
    bool public cancelled;
    bool public penaltiesWaived; // only when cancelled before finalization
    uint64 public finalizedAt;
    uint64 public deliveryDeadline;
    uint64 public deliveredAt;

    uint256 public grossProceeds; // payment owed to issuer (+fee) on delivery
    uint256 public tokensToDeliver; // sale tokens the issuer must deliver

    uint256 public totalDeposited;
    uint256 public totalRefunded;
    uint256 public totalPenalties;
    uint256 public releasedToIssuer; // includes protocol fee
    uint256 public tokensClaimedTotal;

    uint256 public participants;
    uint256 public settledCount;

    event Deposited(address indexed investor, uint256 amount, uint256 newDeposit);
    event Finalized(bool success, uint256 grossProceeds, uint256 tokensToDeliver, uint64 deliveryDeadline);
    event Delivered(address indexed issuer, uint256 tokens, uint256 issuerProceeds, uint256 fee);
    event DeliveryFailed(uint64 deadline);
    event Cancelled(address indexed by);
    event TokensClaimed(address indexed investor, uint256 tokens, uint256 vestingId, bool vested);
    event Settled(address indexed investor);
    event Swept(uint256 paymentDust, uint256 saleDust);

    error OnlyOffering();
    error WrongStage();
    error TransferAmountMismatch();
    error DeadlineNotReached();
    error DeadlinePassed();
    error NotAuthorized();
    error NotFullySettled();
    error ZeroAmount();

    modifier onlyOffering() {
        if (msg.sender != offering) revert OnlyOffering();
        _;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address factory_,
        address offering_,
        address issuer_,
        address paymentToken_,
        address saleToken_,
        uint16 feeBps_,
        uint32 deliveryWindow_,
        uint64 vestingCliff_,
        uint64 vestingDuration_
    ) external initializer {
        factory = IFactoryConfig(factory_);
        offering = offering_;
        issuer = issuer_;
        paymentToken = IERC20(paymentToken_);
        saleToken = IERC20(saleToken_);
        feeBps = feeBps_;
        deliveryWindow = deliveryWindow_;
        vestingCliff = vestingCliff_;
        vestingDuration = vestingDuration_;
        stage = Types.Stage.Active;
    }

    // ------------------------------------------------------------------ offering hooks

    /// @notice Record `amount` payment tokens that the offering just transferred from `investor` into
    ///         this escrow (investors approve the offering, which pulls from msg.sender only).
    /// @dev Verifies the tokens actually arrived: fee-on-transfer / rebasing payment tokens are rejected.
    function recordDeposit(address investor, uint256 amount) external onlyOffering nonReentrant {
        if (stage != Types.Stage.Active) revert WrongStage();
        if (amount == 0) revert ZeroAmount();
        if (paymentToken.balanceOf(address(this)) < heldPayment() + amount) revert TransferAmountMismatch();
        Position storage p = _positions[investor];
        if (p.deposit == 0) participants += 1;
        p.deposit += SafeCast.toUint128(amount);
        totalDeposited += amount;
        emit Deposited(investor, amount, p.deposit);
    }

    function onFinalized(bool success, uint256 grossProceeds_, uint256 tokensToDeliver_) external onlyOffering {
        if (stage != Types.Stage.Active) revert WrongStage();
        finalizedAt = uint64(block.timestamp);
        if (success) {
            stage = Types.Stage.Succeeded;
            grossProceeds = grossProceeds_;
            tokensToDeliver = tokensToDeliver_;
            deliveryDeadline = uint64(block.timestamp) + deliveryWindow;
        } else {
            stage = Types.Stage.Failed;
        }
        emit Finalized(success, grossProceeds_, tokensToDeliver_, deliveryDeadline);
    }

    // ------------------------------------------------------------------ issuer

    /// @notice Issuer delivers the full token amount; payment (minus protocol fee) is released atomically.
    function deliver() external nonReentrant {
        if (msg.sender != issuer) revert NotAuthorized();
        if (stage != Types.Stage.Succeeded) revert WrongStage();
        if (block.timestamp > deliveryDeadline) revert DeadlinePassed();

        uint256 tokens = tokensToDeliver;
        uint256 gross = grossProceeds;
        uint256 fee = (gross * feeBps) / BPS;

        // effects
        stage = Types.Stage.Delivered;
        deliveredAt = uint64(block.timestamp);
        releasedToIssuer = gross;

        // interactions: pull tokens first and verify the exact amount arrived
        uint256 before = saleToken.balanceOf(address(this));
        saleToken.safeTransferFrom(msg.sender, address(this), tokens);
        if (saleToken.balanceOf(address(this)) - before != tokens) revert TransferAmountMismatch();

        if (fee > 0) paymentToken.safeTransfer(factory.feeCollector(), fee);
        paymentToken.safeTransfer(issuer, gross - fee);
        emit Delivered(issuer, tokens, gross - fee, fee);
    }

    // ------------------------------------------------------------------ failure paths

    /// @notice Anyone can trigger refunds once the delivery deadline has passed without delivery.
    function markDeliveryFailed() external {
        if (stage != Types.Stage.Succeeded) revert WrongStage();
        if (block.timestamp <= deliveryDeadline) revert DeadlineNotReached();
        stage = Types.Stage.Failed;
        emit DeliveryFailed(deliveryDeadline);
    }

    /// @notice Cancel before delivery. Issuer: only while the offering is still Active.
    ///         Guardian / governance: any time before delivery (fraud, compliance incident).
    ///         Cancelling before finalization waives non-reveal penalties.
    function cancel() external {
        bool privileged = factory.hasRole(GUARDIAN_ROLE, msg.sender) || factory.hasRole(0x00, msg.sender);
        if (privileged) {
            if (stage != Types.Stage.Active && stage != Types.Stage.Succeeded) revert WrongStage();
        } else if (msg.sender == issuer) {
            if (stage != Types.Stage.Active) revert WrongStage();
        } else {
            revert NotAuthorized();
        }
        if (stage == Types.Stage.Active) penaltiesWaived = true;
        stage = Types.Stage.Failed;
        cancelled = true;
        emit Cancelled(msg.sender);
    }

    // ------------------------------------------------------------------ investors

    /// @notice Settle whatever is currently available for `investor`: refunds of excess / failed
    ///         deposits, non-reveal penalties, and (after delivery) the sale tokens.
    ///         Callable by anyone; assets only ever move to the investor (or fee collector for penalties).
    function settle(address investor) external nonReentrant {
        Types.Stage s = stage;
        if (s == Types.Stage.Active) revert WrongStage();
        Position storage p = _positions[investor];
        if (p.deposit == 0 || p.done) revert NothingToRefund();

        (uint256 tokens, uint256 cost, uint256 penalty) = IOffering(offering).settlementOf(investor);
        if (penaltiesWaived) penalty = 0;

        uint256 refund = _refundOutstanding(p, s, cost, penalty);
        uint256 penaltyDue = (!p.penaltyTaken && penalty > 0) ? penalty : 0;
        bool giveTokens = s == Types.Stage.Delivered && !p.tokensClaimed && tokens > 0;
        bool nowDone = s == Types.Stage.Failed || s == Types.Stage.Delivered;

        if (refund == 0 && penaltyDue == 0 && !giveTokens && !nowDone) revert NothingToRefund();

        // effects
        if (refund > 0) {
            p.refunded += SafeCast.toUint128(refund);
            totalRefunded += refund;
        }
        if (penaltyDue > 0) {
            p.penaltyTaken = true;
            totalPenalties += penaltyDue;
        }
        if (giveTokens) {
            p.tokensClaimed = true;
            tokensClaimedTotal += tokens;
        }
        if (nowDone) {
            p.done = true;
            settledCount += 1;
            emit Settled(investor);
        }

        // interactions
        if (penaltyDue > 0) {
            paymentToken.safeTransfer(factory.feeCollector(), penaltyDue);
            emit PenaltyTaken(investor, penaltyDue);
        }
        if (refund > 0) {
            paymentToken.safeTransfer(investor, refund);
            emit RefundPaid(investor, refund);
        }
        if (giveTokens) _sendTokens(investor, tokens);
    }

    /// @notice After every participant has settled, return rounding dust to the issuer.
    function sweep() external nonReentrant {
        Types.Stage s = stage;
        if (s != Types.Stage.Delivered && s != Types.Stage.Failed) revert WrongStage();
        if (settledCount != participants) revert NotFullySettled();
        uint256 payDust = paymentToken.balanceOf(address(this));
        uint256 saleDust = saleToken.balanceOf(address(this));
        if (payDust > 0) paymentToken.safeTransfer(issuer, payDust);
        if (saleDust > 0) saleToken.safeTransfer(issuer, saleDust);
        emit Swept(payDust, saleDust);
    }

    // ------------------------------------------------------------------ views

    function depositOf(address investor) external view returns (uint256) {
        return _positions[investor].deposit;
    }

    function positionOf(address investor) external view returns (Position memory) {
        return _positions[investor];
    }

    /// @notice Payment tokens the escrow must hold according to its own accounting.
    function heldPayment() public view returns (uint256) {
        return totalDeposited - totalRefunded - totalPenalties - releasedToIssuer;
    }

    /// @notice Preview what `settle(investor)` would pay right now.
    function previewSettle(address investor) external view returns (uint256 refund, uint256 tokens, uint256 penalty) {
        Position storage p = _positions[investor];
        if (stage == Types.Stage.Active || p.deposit == 0 || p.done) return (0, 0, 0);
        uint256 cost;
        (tokens, cost, penalty) = IOffering(offering).settlementOf(investor);
        if (penaltiesWaived) penalty = 0;
        refund = _refundOutstanding(p, stage, cost, penalty);
        if (p.penaltyTaken) penalty = 0;
        if (stage != Types.Stage.Delivered || p.tokensClaimed) tokens = 0;
    }

    // ------------------------------------------------------------------ internal

    function _sendTokens(address investor, uint256 tokens) internal {
        if (vestingDuration == 0) {
            saleToken.safeTransfer(investor, tokens);
            emit TokensClaimed(investor, tokens, 0, false);
        } else {
            address v = factory.vesting();
            saleToken.forceApprove(v, tokens);
            uint256 id = IDeliveryVesting(v).createSchedule(
                investor, address(saleToken), tokens, deliveredAt, vestingCliff, vestingDuration
            );
            emit TokensClaimed(investor, tokens, id, true);
        }
    }
}
