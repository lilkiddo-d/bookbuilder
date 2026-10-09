// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Types} from "./interfaces/IBookbuilder.sol";

/// @title Refunds
/// @notice Pure refund arithmetic + per-investor bookkeeping shared by OfferingEscrow.
/// @dev Kept separate so the refund rules are reviewable in one place:
///      - Failed offering:   refund = deposit - penalty
///      - Succeeded/Delivered: refund = deposit - cost - penalty
///      Refunds are paid at most once per investor; `refunded` records what was paid so that
///      a later transition Succeeded -> Failed (missed delivery) refunds the remaining `cost`.
abstract contract Refunds {
    struct Position {
        uint128 deposit; // payment tokens deposited
        uint128 refunded; // payment tokens already returned
        bool penaltyTaken; // non-reveal penalty already moved to the fee collector
        bool tokensClaimed; // sale tokens already sent / vested
        bool done; // fully settled (counted in settledCount)
    }

    mapping(address => Position) internal _positions;

    event RefundPaid(address indexed investor, uint256 amount);
    event PenaltyTaken(address indexed investor, uint256 amount);

    error NothingToRefund();

    /// @dev Total refund entitlement in a given stage, before subtracting what was already paid.
    function _refundEntitlement(Types.Stage stage, uint256 deposit, uint256 cost, uint256 penalty)
        internal
        pure
        returns (uint256)
    {
        uint256 keep = penalty;
        if (stage == Types.Stage.Succeeded || stage == Types.Stage.Delivered) keep += cost;
        return deposit > keep ? deposit - keep : 0;
    }

    /// @dev Outstanding refund = entitlement - already refunded (never negative).
    function _refundOutstanding(Position storage p, Types.Stage stage, uint256 cost, uint256 penalty)
        internal
        view
        returns (uint256)
    {
        uint256 ent = _refundEntitlement(stage, p.deposit, cost, penalty);
        return ent > p.refunded ? ent - p.refunded : 0;
    }
}
