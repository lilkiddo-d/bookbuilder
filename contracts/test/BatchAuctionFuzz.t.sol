// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Base} from "./utils/Base.t.sol";
import {Types} from "../src/interfaces/IBookbuilder.sol";
import {BatchAuction} from "../src/offerings/BatchAuction.sol";
import {OfferingEscrow} from "../src/OfferingEscrow.sol";
import {ProjectTokenHooks} from "../src/ProjectTokenHooks.sol";

/// @notice Property tests: clearing price vs a brute-force O(n^2) reference on random bid sets,
///         investors never pay more than their bid price, allocations never exceed supply, and the
///         escrow stays solvent through full settlement.
contract BatchAuctionFuzzTest is Base {
    uint256 constant MAX_BIDDERS = 14;
    uint16 constant TICKS = 40;

    struct RefBid {
        address who;
        uint16 tick;
        uint256 qty;
        bool reveal;
    }

    function _bidders(uint256 n) internal returns (address[] memory a) {
        a = new address[](n);
        for (uint256 k; k < n; ++k) {
            a[k] = address(uint160(0xB1D000 + k));
            vm.prank(attestor);
            compliance.attest(a[k], 1, false, "SG", uint64(block.timestamp + 365 days));
            usd.mint(a[k], 1e30);
        }
    }

    function _makeAuction(uint256 supply, uint256 saleDecimalsUnit) internal returns (BatchAuction o, OfferingEscrow e) {
        saleDecimalsUnit; // 18-decimals delivery token in this suite
        Types.CommonParams memory p = _common(supply, 0);
        Types.BatchAuctionParams memory bp = _batchParams();
        bp.numTicks = TICKS;
        bp.minPrice = 1e6;
        bp.tickSize = 37_123; // odd tick size to stress rounding
        (o, e) = _createBatch(p, bp);
    }

    /// Reference: highest price at which cumulative demand (bids priced >= p) reaches supply, else the lowest bid.
    function _refClearing(RefBid[] memory bids, uint256 supply)
        internal
        pure
        returns (bool found, uint16 clearTick, uint256 above, uint256 atClear)
    {
        // candidates: every revealed tick, scanned from highest to lowest via brute force
        uint16 best;
        bool any;
        uint16 lowest = type(uint16).max;
        for (uint256 i; i < bids.length; ++i) {
            if (!bids[i].reveal) continue;
            if (bids[i].tick < lowest) lowest = bids[i].tick;
            uint256 d;
            for (uint256 j; j < bids.length; ++j) {
                if (bids[j].reveal && bids[j].tick >= bids[i].tick) d += bids[j].qty;
            }
            if (d >= supply && (!any || bids[i].tick > best)) {
                best = bids[i].tick;
                any = true;
            }
        }
        if (!any) return (false, lowest, 0, 0);
        for (uint256 j; j < bids.length; ++j) {
            if (!bids[j].reveal) continue;
            if (bids[j].tick > best) above += bids[j].qty;
            else if (bids[j].tick == best) atClear += bids[j].qty;
        }
        return (true, best, above, atClear);
    }

    // fuzz-run state (kept in storage to avoid stack-too-deep)
    BatchAuction internal fo;
    OfferingEscrow internal fe;
    uint256 internal fSupply;
    address[] internal fWho;
    RefBid[] internal fBids;
    bool internal refFound;
    uint16 internal refTick;
    uint256 internal refAbove;
    uint256 internal refAt;

    function testFuzz_clearingMatchesReference(uint256 seed, uint8 nRaw, uint256 supplyRaw) public {
        uint256 n = bound(nRaw, 1, MAX_BIDDERS);
        fSupply = bound(supplyRaw, 1e18, 5_000e18);
        fWho = _bidders(n);
        (fo, fe) = _makeAuction(fSupply, 1e18);
        uint256 revealed = _placeBids(seed, n);
        vm.warp(fo.revealEnd());
        fo.finalize();
        if (revealed == 0) {
            assertFalse(fo.succeeded());
            return;
        }
        RefBid[] memory bids = fBids;
        (refFound, refTick, refAbove, refAt) = _refClearing(bids, fSupply);
        assertEq(fo.oversubscribed(), refFound, "oversubscribed flag");
        assertEq(fo.clearingTick(), refTick, "clearing tick");
        assertEq(fo.clearingPrice(), fo.priceAt(refTick), "clearing price");
        if (refFound) {
            assertEq(fo.marginalSupply(), fSupply - refAbove, "R");
            assertEq(fo.marginalDemand(), refAt, "M");
        }
        uint256 sumFill;
        for (uint256 k; k < n; ++k) {
            sumFill += _checkBidder(k);
        }
        assertLe(sumFill, fSupply, "sum fills <= supply");
        assertLe(sumFill, fo.tokensSold());
        _settleAll(n);
    }

    function _placeBids(uint256 seed, uint256 n) internal returns (uint256 revealed) {
        delete fBids;
        vm.warp(fo.params().startTime);
        for (uint256 k; k < n; ++k) {
            uint256 r = uint256(keccak256(abi.encode(seed, k)));
            fBids.push(
                RefBid({who: fWho[k], tick: uint16(r % TICKS), qty: bound(r >> 32, 1, fSupply), reveal: (r >> 200) % 7 != 0})
            );
            _commit(fo, fe, fWho[k], fBids[k].tick, fBids[k].qty, _extra(r));
        }
        vm.warp(fo.commitEnd());
        for (uint256 k; k < n; ++k) {
            if (!fBids[k].reveal) continue;
            revealed++;
            uint256 r = uint256(keccak256(abi.encode(seed, k)));
            _reveal(fo, fWho[k], fBids[k].tick, fBids[k].qty, _extra(r));
        }
    }

    function _extra(uint256 r) internal pure returns (uint256) {
        return (r >> 100) % 3 == 0 ? (r >> 120) % 1_000e6 : 0;
    }

    function _checkBidder(uint256 k) internal view returns (uint256 f) {
        RefBid memory b = fBids[k];
        f = fo.fillOf(b.who);
        (uint256 tokens, uint256 cost,) = fo.settlementOf(b.who);
        assertEq(tokens, f);
        if (!b.reveal) {
            assertEq(f, 0);
            return f;
        }
        assertLe(f, b.qty, "fill <= qty");
        uint256 bidPrice = fo.priceAt(b.tick);
        // never pays more than its bid price for what it receives (cost rounded up by < 1 unit)
        assertLe(cost, _ceil(f * bidPrice, 1e18), "paid above bid price");
        if (f > 0) assertLe(fo.clearingPrice(), bidPrice, "clearing above bid");
        uint256 refFill;
        if (b.tick > refTick) {
            refFill = b.qty;
        } else if (b.tick == refTick) {
            refFill = !refFound || fSupply - refAbove >= refAt ? b.qty : (b.qty * (fSupply - refAbove)) / refAt;
        }
        assertEq(f, refFill, "fill vs reference");
    }

    function _settleAll(uint256 n) internal {
        if (fo.succeeded()) {
            rwa.mint(issuer, fe.tokensToDeliver());
            _deliver(fe);
        }
        for (uint256 k; k < n; ++k) {
            assertEq(fe.heldPayment(), usd.balanceOf(address(fe)), "held == balance");
            fe.settle(fWho[k]);
        }
        assertLe(usd.balanceOf(address(fe)), n, "payment dust bounded by bidder count");
        fe.sweep();
        assertEq(usd.balanceOf(address(fe)), 0);
    }

    function testFuzz_withGuarantees_neverOverAllocates(uint256 seed, uint8 nRaw) public {
        vm.startPrank(gov);
        hooks.setProjectToken(address(book));
        ProjectTokenHooks.Tier[] memory tiers = new ProjectTokenHooks.Tier[](2);
        tiers[0] = ProjectTokenHooks.Tier({minStake: 1e18, guaranteedBps: 100});
        tiers[1] = ProjectTokenHooks.Tier({minStake: 10e18, guaranteedBps: 500});
        hooks.setTiers(tiers);
        vm.stopPrank();

        uint256 n = bound(nRaw, 2, MAX_BIDDERS);
        address[] memory who = _bidders(n);
        for (uint256 k; k < n; ++k) {
            uint256 stakeAmt = (uint256(keccak256(abi.encode(seed, "s", k))) % 3) * 5e18;
            if (stakeAmt == 0) continue;
            book.mint(who[k], stakeAmt);
            vm.startPrank(who[k]);
            book.approve(address(hooks), stakeAmt);
            hooks.stake(stakeAmt);
            vm.stopPrank();
        }
        vm.warp(block.timestamp + 3 days);
        uint256 supply = 100e18;
        Types.CommonParams memory p = _common(supply, 0);
        Types.BatchAuctionParams memory bp = _batchParams();
        bp.numTicks = 5;
        bp.maxEndTime = uint64(block.timestamp + 1 hours + 4 days);
        (BatchAuction o, OfferingEscrow e) = _createBatch(p, bp);
        vm.warp(p.startTime);
        uint256[] memory q = new uint256[](n);
        uint16[] memory t = new uint16[](n);
        for (uint256 k; k < n; ++k) {
            uint256 r = uint256(keccak256(abi.encode(seed, k)));
            t[k] = uint16(r % 5);
            q[k] = bound(r >> 16, 1, 60e18);
            _commit(o, e, who[k], t[k], q[k], 0);
        }
        vm.warp(o.commitEnd());
        for (uint256 k; k < n; ++k) {
            _reveal(o, who[k], t[k], q[k], 0);
        }
        vm.warp(o.revealEnd());
        o.finalize();
        uint256 sum;
        for (uint256 k; k < n; ++k) {
            uint256 f = o.fillOf(who[k]);
            assertLe(f, q[k]);
            (, uint256 cost,) = o.settlementOf(who[k]);
            assertLe(cost, _ceil(f * o.priceAt(t[k]), 1e18));
            sum += f;
        }
        assertLe(sum, supply);
        if (o.succeeded()) {
            rwa.mint(issuer, e.tokensToDeliver());
            _deliver(e);
            for (uint256 k; k < n; ++k) {
                e.settle(who[k]);
            }
            e.sweep();
            assertEq(usd.balanceOf(address(e)), 0);
        }
    }
}
