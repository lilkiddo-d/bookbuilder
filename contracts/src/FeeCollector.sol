// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IProjectTokenHooks} from "./interfaces/IBookbuilder.sol";

/// @title FeeCollector
/// @notice Receives protocol fees and non-reveal penalties. `distribute` is permissionless:
///         when $BOOK staking is live, `stakerShareBps` of the hooks' reward token goes to stakers,
///         everything else to the treasury. Until the project token is set, 100% goes to the treasury.
contract FeeCollector is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint16 public constant MAX_STAKER_SHARE_BPS = 8_000;

    address public treasury;
    IProjectTokenHooks public hooks;
    uint16 public stakerShareBps;

    event Distributed(address indexed token, uint256 toTreasury, uint256 toStakers);
    event TreasurySet(address treasury);
    event HooksSet(address hooks);
    event StakerShareSet(uint16 bps);

    error ZeroAddress();
    error ShareTooHigh();

    constructor(address admin, address treasury_, uint16 stakerShareBps_) {
        if (admin == address(0) || treasury_ == address(0)) revert ZeroAddress();
        if (stakerShareBps_ > MAX_STAKER_SHARE_BPS) revert ShareTooHigh();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        treasury = treasury_;
        stakerShareBps = stakerShareBps_;
    }

    function distribute(address token) external nonReentrant {
        uint256 bal = IERC20(token).balanceOf(address(this));
        uint256 toStakers = 0;
        IProjectTokenHooks h = hooks;
        if (
            address(h) != address(0) && h.isEnabled() && token == h.rewardToken() && h.totalStaked() > 0
                && stakerShareBps > 0
        ) {
            toStakers = (bal * stakerShareBps) / 10_000;
        }
        uint256 toTreasury = bal - toStakers;
        if (toStakers > 0) {
            IERC20(token).forceApprove(address(h), toStakers);
            h.notifyRewardAmount(toStakers);
        }
        if (toTreasury > 0) IERC20(token).safeTransfer(treasury, toTreasury);
        emit Distributed(token, toTreasury, toStakers);
    }

    function setTreasury(address t) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (t == address(0)) revert ZeroAddress();
        treasury = t;
        emit TreasurySet(t);
    }

    function setHooks(address h) external onlyRole(DEFAULT_ADMIN_ROLE) {
        hooks = IProjectTokenHooks(h);
        emit HooksSet(h);
    }

    function setStakerShareBps(uint16 bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bps > MAX_STAKER_SHARE_BPS) revert ShareTooHigh();
        stakerShareBps = bps;
        emit StakerShareSet(bps);
    }
}
