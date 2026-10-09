// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OfferingBase} from "./OfferingBase.sol";
import {Types, IOfferingEscrow, IProjectTokenHooks} from "../interfaces/IBookbuilder.sol";

/// @title BatchAuction
/// @notice Sealed-bid uniform-price auction with commit-reveal.
///
///  Commit phase: bidders post keccak(chainid, auction, bidder, tick, qty, salt) plus a payment deposit
///                (deposit may exceed the bid to hide its size). Commits inside the anti-snipe window
///                extend the commit end (capped by `maxEndTime`).
///  Reveal phase: bidders reveal (tick, qty, salt). The deposit must cover qty * price(tick).
///                Unrevealed commitments lose `nonRevealPenaltyBps` of their deposit (anti-griefing).
///  Clearing:     bids live on a bounded price grid of `numTicks` ticks, so demand is aggregated per tick
///                and clearing is a single bounded walk from the top tick down (no per-bid loops).
///                Clearing price = the lowest price that still fills the offering, i.e. the highest tick
///                whose cumulative demand (at or above it) reaches supply. Everyone pays that price.
///                Bids above clear fully; bids at the clearing tick are filled pro-rata. If $BOOK staking
///                is live, each marginal bid's guaranteed slot (bps of supply by staking tier) is filled first.
///                If undersubscribed, every revealed bid fills at the lowest revealed tick.
contract BatchAuction is OfferingBase {
    uint16 public constant MAX_TICKS = 400;
    uint16 public constant MAX_PENALTY_BPS = 2_000;

    struct Bid {
        bytes32 commitment;
        uint128 qty;
        uint128 guaranteed;
        uint16 tick;
        bool revealed;
    }

    // config
    uint256 public minPrice;
    uint256 public tickSize;
    uint16 public numTicks;
    uint64 public revealDuration;
    uint32 public antiSnipeWindow;
    uint32 public antiSnipeExtension;
    uint64 public maxEndTime;
    uint16 public nonRevealPenaltyBps;
    uint32 public maxBidders;

    // state
    uint64 public commitEnd;
    uint32 public bidderCount;
    uint32 public revealedCount;
    uint256 public totalDemand;
    mapping(address => Bid) public bids;
    mapping(uint256 => uint256) public demandAtTick;
    mapping(uint256 => uint256) public guaranteedAtTick;
    mapping(uint256 => uint256) public bidsAtTick;

    // clearing result
    bool public oversubscribed;
    uint16 public clearingTick;
    uint256 public clearingPrice;
    uint256 public tokensSold;
    uint256 public marginalSupply; // R: supply left for the clearing tick
    uint256 public marginalDemand; // M: demand at the clearing tick
    uint256 public marginalGuaranteed; // G: guaranteed demand at the clearing tick

    event Committed(address indexed bidder, bytes32 commitment, uint256 depositAdded, uint64 commitEnd);
    event CommitWindowExtended(uint64 newCommitEnd);
    event Revealed(address indexed bidder, uint16 tick, uint256 price, uint256 qty, uint256 guaranteed);
    event Cleared(uint16 clearingTick, uint256 clearingPrice, uint256 tokensSold, bool oversubscribed);

    error BadCommitment();
    error TooManyBidders();
    error NotRevealPhase();
    error AlreadyRevealed();
    error InsufficientDeposit();
    error BadTick();

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address factory_,
        address issuer_,
        address escrow_,
        Types.CommonParams calldata p,
        Types.BatchAuctionParams calldata bp
    ) external initializer {
        _initBase(factory_, issuer_, escrow_, p);
        if (bp.minPrice == 0 || bp.numTicks == 0 || bp.numTicks > MAX_TICKS) revert InvalidParams();
        if (bp.numTicks > 1 && bp.tickSize == 0) revert InvalidParams();
        if (bp.revealDuration < 1 hours || bp.revealDuration > 30 days) revert InvalidParams();
        if (bp.maxEndTime < p.endTime) revert InvalidParams();
        if (bp.nonRevealPenaltyBps > MAX_PENALTY_BPS || bp.maxBidders == 0) revert InvalidParams();
        minPrice = bp.minPrice;
        tickSize = bp.tickSize;
        numTicks = bp.numTicks;
        revealDuration = bp.revealDuration;
        antiSnipeWindow = bp.antiSnipeWindow;
        antiSnipeExtension = bp.antiSnipeExtension;
        maxEndTime = bp.maxEndTime;
        nonRevealPenaltyBps = bp.nonRevealPenaltyBps;
        maxBidders = bp.maxBidders;
        commitEnd = p.endTime;
    }

    function kind() external pure override returns (Types.OfferingKind) {
        return Types.OfferingKind.BatchAuction;
    }

    // ------------------------------------------------------------------ commit

    /// @notice Commit (or replace) a sealed bid and optionally add to the deposit.
    function commit(bytes32 commitment, uint256 depositAmount) external nonReentrant {
        _checkParticipation(msg.sender, commitEnd);
        if (commitment == bytes32(0)) revert BadCommitment();
        Bid storage b = bids[msg.sender];
        if (b.commitment == bytes32(0)) {
            if (bidderCount >= maxBidders) revert TooManyBidders();
            bidderCount += 1;
        }
        b.commitment = commitment;

        // anti-sniping: late commits push the deadline out, never beyond maxEndTime
        uint64 end = commitEnd;
        if (antiSnipeWindow > 0 && end - block.timestamp <= antiSnipeWindow) {
            uint64 newEnd = end + antiSnipeExtension;
            if (newEnd > maxEndTime) newEnd = maxEndTime;
            if (newEnd > end) {
                commitEnd = newEnd;
                emit CommitWindowExtended(newEnd);
            }
        }

        if (depositAmount > 0) {
            _collect(depositAmount);
        } else if (IOfferingEscrow(escrow).depositOf(msg.sender) == 0) {
            revert InsufficientDeposit();
        }
        emit Committed(msg.sender, commitment, depositAmount, commitEnd);
    }

    // ------------------------------------------------------------------ reveal

    /// @notice Reveal a bid. Anyone holding the preimage may reveal on the bidder's behalf.
    function reveal(address bidder, uint16 tick, uint256 qty, bytes32 salt) external nonReentrant {
        if (block.timestamp < commitEnd || block.timestamp >= revealEnd()) revert NotRevealPhase();
        if (finalized || IOfferingEscrow(escrow).stage() != Types.Stage.Active) revert NotActive();
        Bid storage b = bids[bidder];
        if (b.revealed) revert AlreadyRevealed();
        if (b.commitment == bytes32(0) || b.commitment != commitmentHash(bidder, tick, qty, salt)) {
            revert BadCommitment();
        }
        if (tick >= numTicks) revert BadTick();
        if (qty == 0) revert ZeroAmount();
        if (qty > _params.supply) revert ExceedsSupply();
        _checkWalletMax(qty);
        uint256 price = priceAt(tick);
        if (_mulDivUp(qty, price, saleUnit) > IOfferingEscrow(escrow).depositOf(bidder)) {
            revert InsufficientDeposit();
        }

        uint256 g = 0;
        address h = factory.hooks();
        if (h != address(0)) {
            uint256 bps = IProjectTokenHooks(h).guaranteedBps(bidder);
            if (bps > 0) {
                g = (_params.supply * bps) / 10_000;
                if (g > qty) g = qty;
            }
        }

        b.revealed = true;
        b.tick = tick;
        b.qty = uint128(qty); // qty <= supply; supply fits (checked in reveal bounds)
        b.guaranteed = uint128(g);
        demandAtTick[tick] += qty;
        guaranteedAtTick[tick] += g;
        bidsAtTick[tick] += 1;
        totalDemand += qty;
        revealedCount += 1;
        emit Revealed(bidder, tick, price, qty, g);
    }

    // ------------------------------------------------------------------ clearing

    function canFinalize() public view returns (bool) {
        return !finalized && IOfferingEscrow(escrow).stage() == Types.Stage.Active && block.timestamp >= revealEnd();
    }

    /// @notice Compute the clearing price and close the book. Permissionless (keeper calls it).
    function finalize() external nonReentrant {
        if (!canFinalize()) revert NotEnded();
        uint256 supply = _params.supply;
        uint256 cum = 0;
        uint256 lowest = type(uint256).max;
        bool found = false;
        uint256 i = numTicks;
        while (i > 0) {
            --i;
            uint256 d = demandAtTick[i];
            if (d == 0) continue;
            if (cum + d >= supply) {
                found = true;
                break;
            }
            cum += d;
            lowest = i;
        }

        uint256 sold = 0;
        uint256 conservative = 0; // lower bound on sum of individual fills, used for issuer proceeds
        if (found) {
            uint256 r = supply - cum;
            uint256 m = demandAtTick[i];
            oversubscribed = true;
            clearingTick = uint16(i);
            marginalSupply = r;
            marginalDemand = m;
            marginalGuaranteed = guaranteedAtTick[i];
            sold = supply;
            // each pro-rata fill rounds down by < 1 unit
            uint256 dust = r < m ? bidsAtTick[i] : 0;
            conservative = cum + (r > dust ? r - dust : 0);
        } else if (lowest != type(uint256).max) {
            clearingTick = uint16(lowest);
            sold = cum;
            conservative = cum;
        }

        if (sold == 0) {
            _finalize(false, 0, 0);
            emit Cleared(0, 0, 0, false);
            return;
        }

        uint256 p = priceAt(clearingTick);
        clearingPrice = p;
        tokensSold = sold;
        bool ok = sold >= _params.softCap;
        emit Cleared(clearingTick, p, sold, oversubscribed);
        _finalize(ok, ok ? sold : 0, ok ? (conservative * p) / saleUnit : 0);
    }

    // ------------------------------------------------------------------ settlement

    function settlementOf(address investor) external view returns (uint256 tokens, uint256 cost, uint256 penalty) {
        if (!finalized) return (0, 0, 0);
        Bid storage b = bids[investor];
        if (!b.revealed) {
            penalty = (IOfferingEscrow(escrow).depositOf(investor) * nonRevealPenaltyBps) / 10_000;
            return (0, 0, penalty);
        }
        if (!succeeded) return (0, 0, 0);
        tokens = fillOf(investor);
        cost = _mulDivUp(tokens, clearingPrice, saleUnit);
    }

    /// @notice Tokens allocated to `investor` after clearing.
    function fillOf(address investor) public view returns (uint256) {
        Bid storage b = bids[investor];
        if (!finalized || !b.revealed || tokensSold == 0) return 0;
        uint256 q = b.qty;
        if (b.tick > clearingTick) return q;
        if (b.tick < clearingTick) return 0;
        if (!oversubscribed) return q;
        uint256 r = marginalSupply;
        uint256 m = marginalDemand;
        if (r >= m) return q;
        uint256 gTot = marginalGuaranteed;
        uint256 g = b.guaranteed;
        if (r >= gTot) {
            uint256 rest = m - gTot; // > 0 because r < m and r >= gTot
            return g + ((q - g) * (r - gTot)) / rest;
        }
        return (g * r) / gTot; // gTot > r >= 0
    }

    // ------------------------------------------------------------------ views

    function priceAt(uint256 tick) public view returns (uint256) {
        return minPrice + tick * tickSize;
    }

    function revealEnd() public view returns (uint64) {
        return commitEnd + revealDuration;
    }

    function commitmentHash(address bidder, uint16 tick, uint256 qty, bytes32 salt) public view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, address(this), bidder, tick, qty, salt));
    }

    /// @notice Revealed demand per tick in [from, to) for the live demand curve (bounded by MAX_TICKS).
    function demandCurve(uint16 from, uint16 to) external view returns (uint256[] memory demand) {
        if (to > numTicks) to = numTicks;
        if (from >= to) return new uint256[](0);
        demand = new uint256[](to - from);
        for (uint256 t = from; t < to; ++t) {
            demand[t - from] = demandAtTick[t];
        }
    }

    /// @notice 0 = before start, 1 = commit, 2 = reveal, 3 = awaiting finalize, 4 = finalized
    function phase() external view returns (uint8) {
        if (finalized) return 4;
        if (block.timestamp < _params.startTime) return 0;
        if (block.timestamp < commitEnd) return 1;
        if (block.timestamp < revealEnd()) return 2;
        return 3;
    }
}
