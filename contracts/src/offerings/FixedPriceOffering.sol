// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OfferingBase} from "./OfferingBase.sol";
import {Types, IOfferingEscrow} from "../interfaces/IBookbuilder.sol";

/// @title FixedPriceOffering
/// @notice First-come-first-served sale at a fixed price, with soft cap (refund if missed) and hard cap (= supply).
contract FixedPriceOffering is OfferingBase {
    uint256 public price; // payment units per whole sale token

    uint256 public totalSold;
    uint256 public totalCost;
    mapping(address => uint256) public purchased;
    mapping(address => uint256) public costOf;

    event Purchased(address indexed investor, uint256 tokens, uint256 cost);

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address factory_,
        address issuer_,
        address escrow_,
        Types.CommonParams calldata p,
        Types.FixedPriceParams calldata fp
    ) external initializer {
        _initBase(factory_, issuer_, escrow_, p);
        if (fp.price == 0) revert InvalidParams();
        price = fp.price;
    }

    function kind() external pure override returns (Types.OfferingKind) {
        return Types.OfferingKind.FixedPrice;
    }

    /// @notice Buy `tokens` (sale-token base units). Cost is rounded up in the issuer's favour by < 1 payment unit.
    function buy(uint256 tokens) external nonReentrant returns (uint256 cost) {
        _checkParticipation(msg.sender, _params.endTime);
        if (tokens == 0) revert ZeroAmount();
        if (totalSold + tokens > _params.supply) revert ExceedsSupply();
        uint256 newTotal = purchased[msg.sender] + tokens;
        _checkWalletMax(newTotal);
        cost = quote(tokens); // >= 1 since tokens > 0 and price > 0 (rounded up)

        purchased[msg.sender] = newTotal;
        costOf[msg.sender] += cost;
        totalSold += tokens;
        totalCost += cost;

        _collect(cost);
        emit Purchased(msg.sender, tokens, cost);
    }

    function quote(uint256 tokens) public view returns (uint256) {
        return _mulDivUp(tokens, price, saleUnit);
    }

    function canFinalize() public view returns (bool) {
        return !finalized && IOfferingEscrow(escrow).stage() == Types.Stage.Active
            && (block.timestamp >= _params.endTime || totalSold == _params.supply);
    }

    /// @notice Permissionless once the sale ended or sold out.
    function finalize() external nonReentrant {
        if (!canFinalize()) revert NotEnded();
        bool ok = totalSold > 0 && totalSold >= _params.softCap;
        _finalize(ok, ok ? totalSold : 0, ok ? totalCost : 0);
    }

    function settlementOf(address investor) external view returns (uint256 tokens, uint256 cost, uint256 penalty) {
        return (purchased[investor], costOf[investor], 0);
    }
}
