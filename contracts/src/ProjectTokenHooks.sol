// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IProjectTokenHooks} from "./interfaces/IBookbuilder.sol";

/// @title ProjectTokenHooks
/// @notice All $BOOK functionality lives here: staking, staking tiers (guaranteed allocation slots in
///         oversubscribed batch auctions + priority-window access) and platform-fee sharing.
///         The project token is NOT deployed by this protocol. Its address is provided once through
///         `setProjectToken`, callable only by the owner (DEFAULT_ADMIN_ROLE = Timelock).
///         Until then `isEnabled()` is false, staking reverts, and `guaranteedBps()` returns 0 for
///         everyone, so the rest of the protocol runs unchanged.
contract ProjectTokenHooks is AccessControl, Pausable, ReentrancyGuard, IProjectTokenHooks {
    using SafeERC20 for IERC20;

    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    uint256 public constant MAX_TIERS = 5;
    uint16 public constant MAX_GUARANTEED_BPS = 500; // 5% of an auction's supply per wallet
    uint256 private constant ACC = 1e36;

    struct Tier {
        uint256 minStake;
        uint16 guaranteedBps;
    }

    struct Account {
        uint256 staked;
        uint256 pendingUnstake;
        uint64 eligibleAt; // stake must age before it counts for tiers (anti flash-stake)
        uint64 unlockAt; // pendingUnstake withdrawable after this
        uint256 rewardDebt;
        uint256 rewardsOwed;
    }

    IERC20 public projectToken;
    address public immutable rewardToken;
    uint64 public unstakeCooldown;
    uint64 public minStakeAge;

    Tier[] private _tiers;
    mapping(address => Account) public accounts;
    uint256 public totalStaked;
    uint256 public accRewardPerShare;

    event ProjectTokenSet(address indexed token);
    event TiersSet(uint256 count);
    event TimingSet(uint64 unstakeCooldown, uint64 minStakeAge);
    event Staked(address indexed account, uint256 amount, uint64 eligibleAt);
    event UnstakeRequested(address indexed account, uint256 amount, uint64 unlockAt);
    event Withdrawn(address indexed account, uint256 amount);
    event RewardNotified(uint256 amount, uint256 accRewardPerShare);
    event RewardClaimed(address indexed account, uint256 amount);

    error TokenNotSet();
    error TokenAlreadySet();
    error ZeroAddress();
    error ZeroAmount();
    error BadTiers();
    error InsufficientStake();
    error Locked();
    error NoStakers();
    error TransferAmountMismatch();

    constructor(address admin, address guardian, address rewardToken_, uint64 cooldown, uint64 stakeAge) {
        if (admin == address(0) || guardian == address(0) || rewardToken_ == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GUARDIAN_ROLE, guardian);
        rewardToken = rewardToken_;
        unstakeCooldown = cooldown;
        minStakeAge = stakeAge;
    }

    // ------------------------------------------------------------------ owner (Timelock)

    /// @notice One-time wiring of the $BOOK token. Irreversible.
    function setProjectToken(address token) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        if (address(projectToken) != address(0)) revert TokenAlreadySet();
        projectToken = IERC20(token);
        emit ProjectTokenSet(token);
    }

    /// @notice Tiers must be strictly ascending in minStake and non-decreasing in guaranteedBps.
    function setTiers(Tier[] calldata tiers_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (tiers_.length > MAX_TIERS) revert BadTiers();
        delete _tiers;
        for (uint256 k; k < tiers_.length; ++k) {
            Tier calldata t = tiers_[k];
            if (t.minStake == 0 || t.guaranteedBps == 0 || t.guaranteedBps > MAX_GUARANTEED_BPS) revert BadTiers();
            if (k > 0 && (t.minStake <= tiers_[k - 1].minStake || t.guaranteedBps < tiers_[k - 1].guaranteedBps)) {
                revert BadTiers();
            }
            _tiers.push(t);
        }
        emit TiersSet(tiers_.length);
    }

    function setTiming(uint64 cooldown, uint64 stakeAge) external onlyRole(DEFAULT_ADMIN_ROLE) {
        unstakeCooldown = cooldown;
        minStakeAge = stakeAge;
        emit TimingSet(cooldown, stakeAge);
    }

    function pause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    // ------------------------------------------------------------------ staking

    function stake(uint256 amount) external nonReentrant whenNotPaused {
        IERC20 token = projectToken;
        if (address(token) == address(0)) revert TokenNotSet();
        if (amount == 0) revert ZeroAmount();
        Account storage a = accounts[msg.sender];
        _accrue(a);
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = token.balanceOf(address(this)) - before;
        if (received != amount) revert TransferAmountMismatch();
        a.staked += amount;
        a.eligibleAt = uint64(block.timestamp) + minStakeAge; // any top-up restarts the aging clock
        totalStaked += amount;
        a.rewardDebt = (a.staked * accRewardPerShare) / ACC;
        emit Staked(msg.sender, amount, a.eligibleAt);
    }

    /// @notice Start the cooldown. Tier benefits drop immediately for the unstaked amount.
    function requestUnstake(uint256 amount) external nonReentrant {
        Account storage a = accounts[msg.sender];
        if (amount == 0) revert ZeroAmount();
        if (amount > a.staked) revert InsufficientStake();
        _accrue(a);
        a.staked -= amount;
        totalStaked -= amount;
        a.pendingUnstake += amount;
        a.unlockAt = uint64(block.timestamp) + unstakeCooldown;
        a.rewardDebt = (a.staked * accRewardPerShare) / ACC;
        emit UnstakeRequested(msg.sender, amount, a.unlockAt);
    }

    function withdraw() external nonReentrant {
        Account storage a = accounts[msg.sender];
        uint256 amount = a.pendingUnstake;
        if (amount == 0) revert ZeroAmount();
        if (block.timestamp < a.unlockAt) revert Locked();
        a.pendingUnstake = 0;
        projectToken.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    // ------------------------------------------------------------------ fee sharing

    /// @notice Pull `amount` reward tokens from the caller (FeeCollector) and share them pro-rata to stakers.
    function notifyRewardAmount(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (totalStaked == 0) revert NoStakers();
        uint256 before = IERC20(rewardToken).balanceOf(address(this));
        IERC20(rewardToken).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(rewardToken).balanceOf(address(this)) - before;
        accRewardPerShare += (received * ACC) / totalStaked;
        emit RewardNotified(received, accRewardPerShare);
    }

    function claimRewards() external nonReentrant returns (uint256 amount) {
        Account storage a = accounts[msg.sender];
        _accrue(a);
        a.rewardDebt = (a.staked * accRewardPerShare) / ACC;
        amount = a.rewardsOwed;
        if (amount == 0) revert ZeroAmount();
        a.rewardsOwed = 0;
        IERC20(rewardToken).safeTransfer(msg.sender, amount);
        emit RewardClaimed(msg.sender, amount);
    }

    // ------------------------------------------------------------------ views

    function isEnabled() public view returns (bool) {
        return address(projectToken) != address(0);
    }

    function tierOf(address account) public view returns (uint256 tier) {
        if (!isEnabled()) return 0;
        Account storage a = accounts[account];
        if (a.staked == 0 || block.timestamp < a.eligibleAt) return 0;
        uint256 n = _tiers.length;
        for (uint256 k = n; k > 0; --k) {
            if (a.staked >= _tiers[k - 1].minStake) return k;
        }
        return 0;
    }

    function guaranteedBps(address account) external view returns (uint16) {
        uint256 t = tierOf(account);
        return t == 0 ? 0 : _tiers[t - 1].guaranteedBps;
    }

    function tiers() external view returns (Tier[] memory) {
        return _tiers;
    }

    function pendingRewards(address account) external view returns (uint256) {
        Account storage a = accounts[account];
        return a.rewardsOwed + (a.staked * accRewardPerShare) / ACC - a.rewardDebt;
    }

    function _accrue(Account storage a) internal {
        uint256 accrued = (a.staked * accRewardPerShare) / ACC;
        if (accrued > a.rewardDebt) a.rewardsOwed += accrued - a.rewardDebt;
        a.rewardDebt = accrued;
    }
}
