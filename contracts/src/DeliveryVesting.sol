// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IFactoryConfig, IDeliveryVesting} from "./interfaces/IBookbuilder.sol";

/// @title DeliveryVesting
/// @notice Linear vesting with cliff for delivered RWA tokens when the issuer requires a lockup.
///         Only escrows created by the OfferingFactory can open schedules.
contract DeliveryVesting is ReentrancyGuard, IDeliveryVesting {
    using SafeERC20 for IERC20;

    struct Schedule {
        address beneficiary;
        address token;
        uint64 start;
        uint64 cliff; // seconds after start
        uint64 duration; // seconds after start
        uint256 total;
        uint256 released;
    }

    IFactoryConfig public immutable factory;
    Schedule[] private _schedules;
    mapping(address => uint256[]) private _byBeneficiary;

    event ScheduleCreated(
        uint256 indexed id, address indexed beneficiary, address indexed token, uint256 amount, uint64 start, uint64 cliff, uint64 duration
    );
    event Released(uint256 indexed id, address indexed beneficiary, uint256 amount);

    error OnlyEscrow();
    error BadSchedule();
    error NothingToRelease();
    error TransferAmountMismatch();

    constructor(address factory_) {
        factory = IFactoryConfig(factory_);
    }

    function createSchedule(address beneficiary, address token, uint256 amount, uint64 start, uint64 cliff, uint64 duration)
        external
        nonReentrant
        returns (uint256 id)
    {
        if (!factory.isEscrow(msg.sender)) revert OnlyEscrow();
        if (beneficiary == address(0) || amount == 0 || duration == 0 || cliff > duration) revert BadSchedule();
        id = _schedules.length;
        _schedules.push(Schedule(beneficiary, token, start, cliff, duration, amount, 0));
        _byBeneficiary[beneficiary].push(id);
        uint256 before = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        if (IERC20(token).balanceOf(address(this)) - before != amount) revert TransferAmountMismatch();
        emit ScheduleCreated(id, beneficiary, token, amount, start, cliff, duration);
    }

    /// @notice Release vested tokens of schedule `id` to its beneficiary. Callable by anyone.
    function release(uint256 id) external nonReentrant returns (uint256 amount) {
        Schedule storage s = _schedules[id];
        uint256 vested = _vested(s);
        if (vested <= s.released) revert NothingToRelease();
        amount = vested - s.released;
        s.released += amount;
        IERC20(s.token).safeTransfer(s.beneficiary, amount);
        emit Released(id, s.beneficiary, amount);
    }

    function releasable(uint256 id) external view returns (uint256) {
        Schedule storage s = _schedules[id];
        return _vested(s) - s.released;
    }

    function vestedAmount(uint256 id) external view returns (uint256) {
        return _vested(_schedules[id]);
    }

    function getSchedule(uint256 id) external view returns (Schedule memory) {
        return _schedules[id];
    }

    function scheduleCount() external view returns (uint256) {
        return _schedules.length;
    }

    function schedulesOf(address beneficiary) external view returns (uint256[] memory) {
        return _byBeneficiary[beneficiary];
    }

    function _vested(Schedule storage s) internal view returns (uint256) {
        if (block.timestamp < uint256(s.start) + s.cliff) return 0;
        uint256 elapsed = block.timestamp - s.start;
        if (elapsed >= s.duration) return s.total;
        return (s.total * elapsed) / s.duration;
    }
}
