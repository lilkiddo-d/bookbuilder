// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {
    Types,
    IOffering,
    IOfferingEscrow,
    IFactoryConfig,
    IComplianceRegistry,
    IProjectTokenHooks
} from "../interfaces/IBookbuilder.sol";

/// @title OfferingBase
/// @notice Shared state, eligibility checks and allocation caps for every offering type.
///         Offerings hold no funds: all payments flow straight into the paired OfferingEscrow.
abstract contract OfferingBase is Initializable, ReentrancyGuard, IOffering {
    using SafeERC20 for IERC20;

    IFactoryConfig public factory;
    address public issuer;
    address public escrow;
    IComplianceRegistry public compliance;

    Types.CommonParams internal _params;
    uint256 public saleUnit; // 10 ** saleToken.decimals()

    bool public finalized;
    bool public succeeded;

    event OfferingFinalized(bool success, uint256 tokensSold, uint256 grossProceeds);
    event DocsUpdated(string docsCID);

    error ProtocolPaused();
    error NotActive();
    error NotStarted();
    error Ended();
    error NotEnded();
    error NotEligible();
    error PriorityWindow();
    error ExceedsWalletMax();
    error ExceedsSupply();
    error ZeroAmount();
    error AlreadyFinalized();
    error InvalidParams();
    error OnlyIssuer();

    function _initBase(address factory_, address issuer_, address escrow_, Types.CommonParams calldata p)
        internal
        onlyInitializing
    {
        if (p.saleToken == address(0) || p.paymentToken == address(0)) revert InvalidParams();
        if (p.supply == 0 || p.softCap > p.supply) revert InvalidParams();
        if (p.perWalletMax > p.supply) revert InvalidParams();
        if (p.startTime < block.timestamp || p.endTime <= p.startTime) revert InvalidParams();
        if (p.vestingDuration > 0 && p.vestingCliff > p.vestingDuration) revert InvalidParams();
        if (p.priorityWindow > p.endTime - p.startTime) revert InvalidParams();
        uint8 dec = IERC20Metadata(p.saleToken).decimals();
        if (dec > 30) revert InvalidParams();
        factory = IFactoryConfig(factory_);
        issuer = issuer_;
        escrow = escrow_;
        compliance = IComplianceRegistry(IFactoryConfig(factory_).compliance());
        _params = p;
        saleUnit = 10 ** dec;
    }

    // ------------------------------------------------------------------ issuer

    /// @notice Issuer may publish amended offering documents (e.g. supplement). Emitted for indexers.
    function updateDocs(string calldata docsCID) external {
        if (msg.sender != issuer) revert OnlyIssuer();
        _params.docsCID = docsCID;
        emit DocsUpdated(docsCID);
    }

    // ------------------------------------------------------------------ views

    function params() external view returns (Types.CommonParams memory) {
        return _params;
    }

    function stage() public view returns (Types.Stage) {
        return IOfferingEscrow(escrow).stage();
    }

    function kind() external pure virtual returns (Types.OfferingKind);

    /// @notice Can `investor` participate right now (ignoring amounts)?
    function canParticipate(address investor) external view returns (bool) {
        return _eligible(investor) && _priorityOk(investor);
    }

    // ------------------------------------------------------------------ internal

    function _checkParticipation(address investor, uint64 phaseEnd) internal view {
        if (factory.paused()) revert ProtocolPaused();
        if (IOfferingEscrow(escrow).stage() != Types.Stage.Active || finalized) revert NotActive();
        if (block.timestamp < _params.startTime) revert NotStarted();
        if (block.timestamp >= phaseEnd) revert Ended();
        if (!_eligible(investor)) revert NotEligible();
        if (!_priorityOk(investor)) revert PriorityWindow();
    }

    function _eligible(address investor) internal view returns (bool) {
        return compliance.isEligible(investor, _params.compliance);
    }

    /// @dev During the priority window only high-tier (compliance tier) investors or $BOOK stakers may join.
    function _priorityOk(address investor) internal view returns (bool) {
        if (_params.priorityWindow == 0) return true;
        if (block.timestamp >= uint256(_params.startTime) + _params.priorityWindow) return true;
        if (compliance.tierOf(investor) >= _params.priorityTier) return true;
        address h = factory.hooks();
        return h != address(0) && IProjectTokenHooks(h).guaranteedBps(investor) > 0;
    }

    function _checkWalletMax(uint256 newTotal) internal view {
        if (_params.perWalletMax != 0 && newTotal > _params.perWalletMax) revert ExceedsWalletMax();
    }

    function _finalize(bool success, uint256 tokensSold, uint256 gross) internal {
        if (finalized) revert AlreadyFinalized();
        finalized = true;
        succeeded = success;
        emit OfferingFinalized(success, tokensSold, gross);
        IOfferingEscrow(escrow).onFinalized(success, gross, tokensSold);
    }

    /// @dev Move `amount` payment tokens from the caller straight into the escrow, then let the escrow
    ///      verify receipt and record the deposit. Funds never rest in the offering contract.
    function _collect(uint256 amount) internal {
        IERC20(_params.paymentToken).safeTransferFrom(msg.sender, escrow, amount);
        IOfferingEscrow(escrow).recordDeposit(msg.sender, amount);
    }

    /// @dev ceil(a * b / d), 512-bit safe.
    function _mulDivUp(uint256 a, uint256 b, uint256 d) internal pure returns (uint256) {
        return Math.mulDiv(a, b, d, Math.Rounding.Ceil);
    }
}
