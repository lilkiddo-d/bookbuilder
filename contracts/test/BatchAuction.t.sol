// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Base} from "./utils/Base.t.sol";
import {Types} from "../src/interfaces/IBookbuilder.sol";
import {OfferingBase} from "../src/offerings/OfferingBase.sol";
import {BatchAuction} from "../src/offerings/BatchAuction.sol";
import {OfferingEscrow} from "../src/OfferingEscrow.sol";
import {ProjectTokenHooks} from "../src/ProjectTokenHooks.sol";

contract BatchAuctionTest is Base {
    BatchAuction o;
    OfferingEscrow e;
    Types.CommonParams p;

    function setUp() public override {
        super.setUp();
        p = _common(1_000e18, 100e18);
        (o, e) = _createBatch(p, _batchParams());
    }

    function _toReveal() internal {
        vm.warp(o.commitEnd());
    }

    function _toFinal() internal {
        vm.warp(o.revealEnd());
    }

    function test_oversubscribed_uniformPrice_proRataAtMargin() public {
        vm.warp(p.startTime);
        // tick 100 = 2.00, tick 50 = 1.50, tick 20 = 1.20
        _commit(o, e, alice, 100, 600e18, 0);
        _commit(o, e, bob, 50, 400e18, 0);
        _commit(o, e, carol, 50, 400e18, 0);
        _commit(o, e, dave, 20, 500e18, 0);
        assertEq(o.phase(), 1);
        _toReveal();
        assertEq(o.phase(), 2);
        _reveal(o, alice, 100, 600e18, 0);
        _reveal(o, bob, 50, 400e18, 0);
        _reveal(o, carol, 50, 400e18, 0);
        _reveal(o, dave, 20, 500e18, 0);
        _toFinal();
        assertEq(o.phase(), 3);
        o.finalize();
        assertEq(o.phase(), 4);

        // demand: 600 @2.00, 800 @1.50 -> cumulative 1400 >= 1000 at 1.50
        assertEq(o.clearingTick(), 50);
        assertEq(o.clearingPrice(), 1.5e6);
        assertTrue(o.oversubscribed());
        assertEq(o.fillOf(alice), 600e18);
        assertEq(o.fillOf(bob), 200e18); // 400 * 400/800
        assertEq(o.fillOf(carol), 200e18);
        assertEq(o.fillOf(dave), 0);

        _deliver(e);
        uint256 aliceBefore = usd.balanceOf(alice);
        e.settle(alice);
        // alice deposited 600*2.00 = 1200, pays 600*1.50 = 900, refund 300
        assertEq(usd.balanceOf(alice) - aliceBefore, 300e6);
        assertEq(rwa.balanceOf(alice), 600e18);
        e.settle(bob);
        e.settle(carol);
        e.settle(dave);
        assertEq(rwa.balanceOf(dave), 0);
        e.sweep();
        assertEq(usd.balanceOf(address(e)), 0);
        assertEq(rwa.balanceOf(address(e)), 0);
    }

    function test_undersubscribed_clearsAtLowestBid() public {
        vm.warp(p.startTime);
        _commit(o, e, alice, 100, 300e18, 0);
        _commit(o, e, bob, 10, 200e18, 0);
        _toReveal();
        _reveal(o, alice, 100, 300e18, 0);
        _reveal(o, bob, 10, 200e18, 0);
        _toFinal();
        o.finalize();
        assertFalse(o.oversubscribed());
        assertEq(o.clearingTick(), 10);
        assertEq(o.tokensSold(), 500e18);
        assertEq(o.fillOf(alice), 300e18);
        assertEq(o.fillOf(bob), 200e18);
        assertEq(e.grossProceeds(), 500 * 1.1e6);
    }

    function test_exactFill_noProRata() public {
        vm.warp(p.startTime);
        _commit(o, e, alice, 30, 500e18, 0);
        _commit(o, e, bob, 30, 500e18, 0);
        _toReveal();
        _reveal(o, alice, 30, 500e18, 0);
        _reveal(o, bob, 30, 500e18, 0);
        _toFinal();
        o.finalize();
        assertEq(o.fillOf(alice), 500e18);
        assertEq(o.fillOf(bob), 500e18);
    }

    function test_softCapMissed() public {
        vm.warp(p.startTime);
        _commit(o, e, alice, 30, 50e18, 0);
        _toReveal();
        _reveal(o, alice, 30, 50e18, 0);
        _toFinal();
        o.finalize();
        assertFalse(o.succeeded());
        uint256 before = usd.balanceOf(alice);
        e.settle(alice);
        assertEq(usd.balanceOf(alice) - before, 50 * 1.3e6);
    }

    function test_noReveals_fails() public {
        vm.warp(p.startTime);
        _commit(o, e, alice, 30, 50e18, 0);
        _toFinal();
        o.finalize();
        assertFalse(o.succeeded());
        // unrevealed -> penalty applies even on failure
        uint256 dep = e.depositOf(alice);
        uint256 before = usd.balanceOf(alice);
        e.settle(alice);
        assertEq(usd.balanceOf(alice) - before, dep - (dep * 500) / 10_000);
        assertEq(usd.balanceOf(address(fees)), (dep * 500) / 10_000);
    }

    function test_nonRevealPenalty_onSuccess() public {
        vm.warp(p.startTime);
        _commit(o, e, alice, 30, 600e18, 0);
        _commit(o, e, bob, 30, 600e18, 0);
        _toReveal();
        _reveal(o, alice, 30, 600e18, 0);
        _toFinal();
        o.finalize();
        assertTrue(o.succeeded());
        (,, uint256 pen) = o.settlementOf(bob);
        assertEq(pen, (e.depositOf(bob) * 500) / 10_000);
        _deliver(e);
        e.settle(bob);
        e.settle(alice);
        e.sweep();
        assertEq(usd.balanceOf(address(e)), 0);
    }

    function test_maskingDeposit_refundsExcess() public {
        vm.warp(p.startTime);
        _commit(o, e, alice, 0, 100e18, 5_000e6); // over-deposit to hide size
        _toReveal();
        _reveal(o, alice, 0, 100e18, 5_000e6);
        _toFinal();
        o.finalize();
        // early refund of excess before delivery
        uint256 before = usd.balanceOf(alice);
        e.settle(alice);
        assertEq(usd.balanceOf(alice) - before, 5_000e6);
        _deliver(e);
        e.settle(alice);
        assertEq(rwa.balanceOf(alice), 100e18);
    }

    function test_reveal_validation() public {
        vm.warp(p.startTime);
        bytes32 salt = keccak256("s");
        _approve(alice, address(o));
        vm.startPrank(alice);
        o.commit(o.commitmentHash(alice, 10, 100e18, salt), 1e6); // deposit too small
        vm.expectRevert(BatchAuction.NotRevealPhase.selector);
        o.reveal(alice, 10, 100e18, salt);
        vm.stopPrank();
        _toReveal();
        vm.startPrank(alice);
        vm.expectRevert(BatchAuction.BadCommitment.selector);
        o.reveal(alice, 11, 100e18, salt);
        vm.expectRevert(BatchAuction.InsufficientDeposit.selector);
        o.reveal(alice, 10, 100e18, salt);
        vm.stopPrank();
        vm.expectRevert(BatchAuction.BadCommitment.selector);
        o.reveal(bob, 10, 100e18, salt);
    }

    function test_reveal_badTickAndQty() public {
        vm.warp(p.startTime);
        _approve(alice, address(o));
        bytes32 s = keccak256("s");
        bytes32 ha = o.commitmentHash(alice, 500, 1e18, s);
        bytes32 hb = o.commitmentHash(bob, 1, 0, s);
        bytes32 hc = o.commitmentHash(carol, 1, 2_000e18, s);
        vm.prank(alice);
        o.commit(ha, 1_000e6);
        _approve(bob, address(o));
        vm.prank(bob);
        o.commit(hb, 1_000e6);
        _approve(carol, address(o));
        vm.prank(carol);
        o.commit(hc, 1_000e6);
        _toReveal();
        vm.expectRevert(BatchAuction.BadTick.selector);
        o.reveal(alice, 500, 1e18, s);
        vm.expectRevert(OfferingBase.ZeroAmount.selector);
        o.reveal(bob, 1, 0, s);
        vm.expectRevert(OfferingBase.ExceedsSupply.selector);
        o.reveal(carol, 1, 2_000e18, s);
    }

    function test_doubleRevealAndLateReveal() public {
        vm.warp(p.startTime);
        _commit(o, e, alice, 10, 100e18, 0);
        _toReveal();
        _reveal(o, alice, 10, 100e18, 0);
        vm.expectRevert(BatchAuction.AlreadyRevealed.selector);
        _reveal(o, alice, 10, 100e18, 0);
        _toFinal();
        vm.expectRevert(BatchAuction.NotRevealPhase.selector);
        _reveal(o, bob, 10, 100e18, 0);
    }

    function test_recommit_replacesHash_andTopsUp() public {
        vm.warp(p.startTime);
        _commit(o, e, alice, 10, 100e18, 0);
        bytes32 s2 = keccak256("new");
        bytes32 h2 = o.commitmentHash(alice, 90, 100e18, s2);
        vm.prank(alice);
        o.commit(h2, 100e6);
        assertEq(o.bidderCount(), 1);
        _toReveal();
        vm.prank(alice);
        o.reveal(alice, 90, 100e18, s2);
        (, uint128 qty,, uint16 tick, bool revealed) = o.bids(alice);
        assertEq(tick, 90);
        assertEq(qty, 100e18);
        assertTrue(revealed);
    }

    function test_commit_zeroDepositNeedsExisting() public {
        vm.warp(p.startTime);
        _approve(alice, address(o));
        vm.startPrank(alice);
        vm.expectRevert(BatchAuction.InsufficientDeposit.selector);
        o.commit(keccak256("x"), 0);
        vm.expectRevert(BatchAuction.BadCommitment.selector);
        o.commit(bytes32(0), 1);
        o.commit(keccak256("x"), 1e6);
        o.commit(keccak256("y"), 0); // replacing hash without new deposit is fine
        vm.stopPrank();
    }

    function test_antiSniping_extendsAndCaps() public {
        uint64 end0 = o.commitEnd();
        vm.warp(end0 - 5 minutes);
        _commit(o, e, alice, 10, 1e18, 0);
        assertEq(o.commitEnd(), end0 + 10 minutes);
        // keep sniping until the cap
        for (uint256 k; k < 200; ++k) {
            uint64 end = o.commitEnd();
            if (end == o.maxEndTime()) break;
            vm.warp(end - 1);
            _commit(o, e, bob, 10, 1e18 + k, 0);
        }
        assertEq(o.commitEnd(), o.maxEndTime());
        vm.warp(o.maxEndTime() - 1);
        _commit(o, e, carol, 10, 1e18, 0);
        assertEq(o.commitEnd(), o.maxEndTime());
        // early commit does not extend
        assertGt(o.commitEnd(), end0);
    }

    function test_maxBidders() public {
        Types.BatchAuctionParams memory bp = _batchParams();
        bp.maxBidders = 1;
        (BatchAuction o2, OfferingEscrow e2) = _createBatch(_common(1_000e18, 0), bp);
        vm.warp(p.startTime);
        _commit(o2, e2, alice, 1, 1e18, 0);
        _approve(bob, address(o2));
        vm.prank(bob);
        vm.expectRevert(BatchAuction.TooManyBidders.selector);
        o2.commit(keccak256("b"), 1e6);
    }

    function test_walletMaxOnReveal() public {
        Types.CommonParams memory p2 = _common(1_000e18, 0);
        p2.perWalletMax = 100e18;
        (BatchAuction o2, OfferingEscrow e2) = _createBatch(p2, _batchParams());
        vm.warp(p2.startTime);
        _commit(o2, e2, alice, 1, 101e18, 0);
        vm.warp(o2.commitEnd());
        vm.expectRevert(OfferingBase.ExceedsWalletMax.selector);
        _reveal(o2, alice, 1, 101e18, 0);
    }

    function test_cancelDuringCommit_waivesPenalties() public {
        vm.warp(p.startTime);
        _commit(o, e, alice, 10, 100e18, 0);
        vm.prank(issuer);
        e.cancel();
        assertTrue(e.penaltiesWaived());
        _toReveal();
        vm.expectRevert(OfferingBase.NotActive.selector);
        _reveal(o, alice, 10, 100e18, 0);
        _toFinal();
        vm.expectRevert(OfferingBase.NotEnded.selector);
        o.finalize();
        uint256 dep = e.depositOf(alice);
        uint256 before = usd.balanceOf(alice);
        e.settle(alice);
        assertEq(usd.balanceOf(alice) - before, dep);
    }

    function test_deliveryFailAfterEarlyRefund_refundsRest() public {
        vm.warp(p.startTime);
        _commit(o, e, alice, 0, 200e18, 1_000e6);
        _commit(o, e, bob, 0, 200e18, 0);
        _toReveal();
        _reveal(o, alice, 0, 200e18, 1_000e6);
        _toFinal();
        o.finalize();
        uint256 depA = e.depositOf(alice);
        uint256 depB = e.depositOf(bob);
        uint256 a0 = usd.balanceOf(alice);
        uint256 b0 = usd.balanceOf(bob);
        e.settle(alice); // excess refund
        e.settle(bob); // non-reveal: refund minus penalty
        vm.warp(e.deliveryDeadline() + 1);
        e.markDeliveryFailed();
        e.settle(alice); // remaining cost refunded
        assertEq(usd.balanceOf(alice) - a0, depA);
        assertEq(usd.balanceOf(bob) - b0, depB - (depB * 500) / 10_000);
        assertEq(e.heldPayment(), usd.balanceOf(address(e)));
        assertEq(usd.balanceOf(address(e)), 0);
    }

    function test_guaranteedSlots_forStakers() public {
        // switch on $BOOK features
        vm.startPrank(gov);
        hooks.setProjectToken(address(book));
        ProjectTokenHooks.Tier[] memory tiers = new ProjectTokenHooks.Tier[](1);
        tiers[0] = ProjectTokenHooks.Tier({minStake: 1_000e18, guaranteedBps: 200}); // 2% of supply = 20 tokens
        hooks.setTiers(tiers);
        vm.stopPrank();
        book.mint(carol, 1_000e18);
        vm.startPrank(carol);
        book.approve(address(hooks), 1_000e18);
        hooks.stake(1_000e18);
        vm.stopPrank();
        vm.warp(block.timestamp + 3 days);
        assertEq(hooks.guaranteedBps(carol), 200);

        Types.CommonParams memory p2 = _common(100e18, 0);
        Types.BatchAuctionParams memory bp = _batchParams();
        bp.maxEndTime = uint64(block.timestamp + 1 hours + 4 days);
        (BatchAuction o2, OfferingEscrow e2) = _createBatch(p2, bp);
        vm.warp(p2.startTime);
        _commit(o2, e2, alice, 5, 100e18, 0);
        _commit(o2, e2, bob, 5, 100e18, 0);
        _commit(o2, e2, carol, 5, 100e18, 0);
        vm.warp(o2.commitEnd());
        _reveal(o2, alice, 5, 100e18, 0);
        _reveal(o2, bob, 5, 100e18, 0);
        _reveal(o2, carol, 5, 100e18, 0);
        vm.warp(o2.revealEnd());
        o2.finalize();
        // R=100, M=300, G=2 -> carol: 2 + 98*98/298, others 100*98/298
        assertEq(o2.marginalGuaranteed(), 2e18);
        uint256 fc = o2.fillOf(carol);
        uint256 fa = o2.fillOf(alice);
        assertGt(fc, fa);
        assertEq(fc, 2e18 + (uint256(98e18) * 98e18) / 298e18);
        assertLe(fa + o2.fillOf(bob) + fc, 100e18);
    }

    function test_guaranteedSlots_exceedRemaining() public {
        vm.startPrank(gov);
        hooks.setProjectToken(address(book));
        ProjectTokenHooks.Tier[] memory tiers = new ProjectTokenHooks.Tier[](1);
        tiers[0] = ProjectTokenHooks.Tier({minStake: 1e18, guaranteedBps: 500}); // 5% = 50 tokens
        hooks.setTiers(tiers);
        vm.stopPrank();
        address[3] memory s = [alice, bob, carol];
        for (uint256 k; k < 3; ++k) {
            book.mint(s[k], 1e18);
            vm.startPrank(s[k]);
            book.approve(address(hooks), 1e18);
            hooks.stake(1e18);
            vm.stopPrank();
        }
        vm.warp(block.timestamp + 3 days);
        Types.CommonParams memory p2 = _common(1_000e18, 0);
        Types.BatchAuctionParams memory bp = _batchParams();
        bp.maxEndTime = uint64(block.timestamp + 1 hours + 4 days);
        (BatchAuction o2, OfferingEscrow e2) = _createBatch(p2, bp);
        vm.warp(p2.startTime);
        _commit(o2, e2, dave, 9, 960e18, 0); // above: leaves R = 40 at tick 5
        _commit(o2, e2, alice, 5, 100e18, 0);
        _commit(o2, e2, bob, 5, 100e18, 0);
        _commit(o2, e2, carol, 5, 100e18, 0);
        vm.warp(o2.commitEnd());
        _reveal(o2, dave, 9, 960e18, 0);
        _reveal(o2, alice, 5, 100e18, 0);
        _reveal(o2, bob, 5, 100e18, 0);
        _reveal(o2, carol, 5, 100e18, 0);
        vm.warp(o2.revealEnd());
        o2.finalize();
        assertEq(o2.marginalSupply(), 40e18);
        assertEq(o2.marginalGuaranteed(), 150e18);
        assertEq(o2.fillOf(alice), (uint256(50e18) * 40e18) / 150e18);
        assertEq(o2.fillOf(dave), 960e18);
    }

    function test_demandCurveAndViews() public {
        vm.warp(p.startTime);
        _commit(o, e, alice, 3, 10e18, 0);
        _toReveal();
        _reveal(o, alice, 3, 10e18, 0);
        uint256[] memory d = o.demandCurve(0, 5);
        assertEq(d.length, 5);
        assertEq(d[3], 10e18);
        assertEq(o.demandCurve(10, 5).length, 0);
        assertEq(o.demandCurve(0, 1000).length, 200);
        assertEq(uint8(o.kind()), uint8(Types.OfferingKind.BatchAuction));
        assertEq(o.phase(), 2);
        (uint256 t, uint256 c, uint256 pen) = o.settlementOf(alice);
        assertEq(t + c + pen, 0); // not finalized
        assertEq(o.fillOf(alice), 0);
    }

    function test_phaseBeforeStart() public view {
        assertEq(o.phase(), 0);
    }

    function test_invalidParams() public {
        Types.BatchAuctionParams memory bp = _batchParams();
        bp.numTicks = 401;
        vm.prank(issuer);
        vm.expectRevert(OfferingBase.InvalidParams.selector);
        factory.createBatchAuction(p, bp);
        bp = _batchParams();
        bp.nonRevealPenaltyBps = 2_001;
        vm.prank(issuer);
        vm.expectRevert(OfferingBase.InvalidParams.selector);
        factory.createBatchAuction(p, bp);
        bp = _batchParams();
        bp.maxEndTime = p.endTime - 1;
        vm.prank(issuer);
        vm.expectRevert(OfferingBase.InvalidParams.selector);
        factory.createBatchAuction(p, bp);
        bp = _batchParams();
        bp.revealDuration = 10;
        vm.prank(issuer);
        vm.expectRevert(OfferingBase.InvalidParams.selector);
        factory.createBatchAuction(p, bp);
        bp = _batchParams();
        bp.tickSize = 0;
        vm.prank(issuer);
        vm.expectRevert(OfferingBase.InvalidParams.selector);
        factory.createBatchAuction(p, bp);
        bp = _batchParams();
        bp.minPrice = 0;
        vm.prank(issuer);
        vm.expectRevert(OfferingBase.InvalidParams.selector);
        factory.createBatchAuction(p, bp);
    }
}
