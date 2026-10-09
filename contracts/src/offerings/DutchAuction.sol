// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OfferingBase} from "./OfferingBase.sol";
import {Types, IOfferingEscrow} from "../interfaces/IBookbuilder.sol";

/// @title DutchAuction
/// @notice Descending-price sale: the price falls linearly from `startPrice` to `floorPrice` over
///         `decayDuration`, then holds at the floor until `endTime`. Buyers pay the current price at
///         purchase time (bounded by a `maxCost` slippage guard). Ends when sold out or at `endTime`.
contract DutchAuction is OfferingBase {
    uint256 public startPrice;
    uint256 public floorPrice;
    uint64 public decayDuration;

    uint256 public totalSold;
    uint256 public totalCost;
    uint256 public lastPrice;
    mapping(address => uint256) public purchased;
    mapping(address => uint256) public costOf;

    event Purchased(address indexed investor, uint256 tokens, uint256 cost, uint256 price);

    error SlippageExceeded();

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address factory_,
        address issuer_,
        address escrow_,
        Types.CommonParams calldata p,
        Types.DutchAuctionParams calldata dp
    ) external initializer {
        _initBase(factory_, issuer_, escrow_, p);
        if (dp.floorPrice == 0 || dp.startPrice < dp.floorPrice) revert InvalidParams();
        if (dp.decayDuration == 0 || dp.decayDuration > p.endTime - p.startTime) revert InvalidParams();
        startPrice = dp.startPrice;
        floorPrice = dp.floorPrice;
        decayDuration = dp.decayDuration;
    }

    function kind() external pure override returns (Types.OfferingKind) {
        return Types.OfferingKind.DutchAuction;
    }

    /// @notice Current price per whole token.
    function currentPrice() public view returns (uint256) {
        uint256 start = _params.startTime;
        if (block.timestamp <= start) return startPrice;
        uint256 elapsed = block.timestamp - start;
        if (elapsed >= decayDuration) return floorPrice;
        return startPrice - ((startPrice - floorPrice) * elapsed) / decayDuration;
    }

    function quote(uint256 tokens) public view returns (uint256) {
        return _mulDivUp(tokens, currentPrice(), saleUnit);
    }

    function buy(uint256 tokens, uint256 maxCost) external nonReentrant returns (uint256 cost) {
        _checkParticipation(msg.sender, _params.endTime);
        if (tokens == 0) revert ZeroAmount();
        if (totalSold + tokens > _params.supply) revert ExceedsSupply();
        uint256 newTotal = purchased[msg.sender] + tokens;
        _checkWalletMax(newTotal);
        uint256 p = currentPrice();
        cost = _mulDivUp(tokens, p, saleUnit); // >= 1 since tokens > 0 and price >= floor > 0
        if (cost > maxCost) revert SlippageExceeded();

        purchased[msg.sender] = newTotal;
        costOf[msg.sender] += cost;
        totalSold += tokens;
        totalCost += cost;
        lastPrice = p;

        _collect(cost);
        emit Purchased(msg.sender, tokens, cost, p);
    }

    function canFinalize() public view returns (bool) {
        return !finalized && IOfferingEscrow(escrow).stage() == Types.Stage.Active
            && (block.timestamp >= _params.endTime || totalSold == _params.supply);
    }

    function finalize() external nonReentrant {
        if (!canFinalize()) revert NotEnded();
        bool ok = totalSold > 0 && totalSold >= _params.softCap;
        _finalize(ok, ok ? totalSold : 0, ok ? totalCost : 0);
    }

    function settlementOf(address investor) external view returns (uint256 tokens, uint256 cost, uint256 penalty) {
        return (purchased[investor], costOf[investor], 0);
    }
}
