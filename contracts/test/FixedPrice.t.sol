// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Base} from "./utils/Base.t.sol";
import {Types} from "../src/interfaces/IBookbuilder.sol";
import {OfferingBase} from "../src/offerings/OfferingBase.sol";
import {FixedPriceOffering} from "../src/offerings/FixedPriceOffering.sol";
import {OfferingEscrow} from "../src/OfferingEscrow.sol";
import {OfferingFactory} from "../src/OfferingFactory.sol";
import {Refunds} from "../src/Refunds.sol";
import {DeliveryVesting} from "../src/DeliveryVesting.sol";

contract FixedPriceTest is Base {
    FixedPriceOffering o;
    OfferingEscrow e;
    uint256 constant PRICE = 10e6; // 10 USDG per token

    function setUp() public override {
        super.setUp();
        Types.CommonParams memory p = _common(1_000e18, 400e18);
        p.perWalletMax = 600e18;
        (o, e) = _createFixed(p, PRICE);
        _approve(alice, address(o));
        _approve(bob, address(o));
        _approve(carol, address(o));
        _approve(eve, address(o));
    }

    function _start() internal {
        vm.warp(o.params().startTime);
    }

    function test_happyPath_buyFinalizeDeliverClaim() public {
        _start();
        vm.prank(alice);
        uint256 cost = o.buy(300e18);
        assertEq(cost, 3_000e6);
        vm.prank(bob);
        o.buy(200e18);
        assertEq(usd.balanceOf(address(e)), 5_000e6);
        assertEq(e.heldPayment(), 5_000e6);
        assertEq(uint8(o.stage()), uint8(Types.Stage.Active));

        vm.expectRevert(OfferingEscrow.WrongStage.selector); // nothing to settle before finalization
        e.settle(alice);

        vm.expectRevert(OfferingBase.NotEnded.selector);
        o.finalize();
        vm.warp(o.params().endTime);
        o.finalize();
        assertTrue(o.succeeded());
        assertEq(e.tokensToDeliver(), 500e18);
        assertEq(e.grossProceeds(), 5_000e6);

        uint256 issuerBefore = usd.balanceOf(issuer);
        _deliver(e);
        assertEq(usd.balanceOf(issuer) - issuerBefore, 4_950e6);
        assertEq(usd.balanceOf(address(fees)), 50e6);
        assertEq(usd.balanceOf(address(e)), 0);

        e.settle(alice);
        e.settle(bob);
        assertEq(rwa.balanceOf(alice), 300e18);
        assertEq(rwa.balanceOf(bob), 200e18);
        assertEq(e.settledCount(), e.participants());
        e.sweep();
    }

    function test_softCapMissed_fullRefund() public {
        _start();
        vm.prank(alice);
        o.buy(100e18);
        vm.warp(o.params().endTime);
        o.finalize();
        assertFalse(o.succeeded());
        assertEq(uint8(e.stage()), uint8(Types.Stage.Failed));
        uint256 before = usd.balanceOf(alice);
        e.settle(alice);
        assertEq(usd.balanceOf(alice) - before, 1_000e6);
        vm.expectRevert(Refunds.NothingToRefund.selector);
        e.settle(alice);
        // issuer cannot deliver into a failed offering
        vm.prank(issuer);
        vm.expectRevert(OfferingEscrow.WrongStage.selector);
        e.deliver();
    }

    function test_noBuyers_fails() public {
        vm.warp(o.params().endTime);
        o.finalize();
        assertFalse(o.succeeded());
    }

    function test_soldOut_finalizesEarly() public {
        _start();
        vm.prank(alice);
        o.buy(600e18);
        vm.prank(carol);
        o.buy(400e18);
        assertTrue(o.canFinalize());
        o.finalize();
        assertTrue(o.succeeded());
    }

    function test_caps() public {
        _start();
        vm.prank(alice);
        vm.expectRevert(OfferingBase.ExceedsWalletMax.selector);
        o.buy(601e18);
        vm.prank(alice);
        o.buy(600e18);
        vm.prank(bob);
        vm.expectRevert(OfferingBase.ExceedsSupply.selector);
        o.buy(401e18);
        vm.prank(bob);
        vm.expectRevert(OfferingBase.ZeroAmount.selector);
        o.buy(0);
    }

    function test_timing() public {
        vm.prank(alice);
        vm.expectRevert(OfferingBase.NotStarted.selector);
        o.buy(1e18);
        vm.warp(o.params().endTime);
        vm.prank(alice);
        vm.expectRevert(OfferingBase.Ended.selector);
        o.buy(1e18);
    }

    function test_compliance_blocksUnverified() public {
        _start();
        vm.prank(eve);
        vm.expectRevert(OfferingBase.NotEligible.selector);
        o.buy(1e18);
        assertFalse(o.canParticipate(eve));
        assertTrue(o.canParticipate(alice));
    }

    function test_compliance_frozenAndExpiredAndBlockedCountry() public {
        _start();
        vm.prank(guardian);
        compliance.setFrozen(alice, true);
        vm.prank(alice);
        vm.expectRevert(OfferingBase.NotEligible.selector);
        o.buy(1e18);

        vm.prank(gov);
        compliance.setCountryBlocked("GB", true);
        vm.prank(bob);
        vm.expectRevert(OfferingBase.NotEligible.selector);
        o.buy(1e18);
    }

    function test_accreditedOnlyOffering() public {
        Types.CommonParams memory p = _common(1_000e18, 0);
        p.compliance.requireAccredited = true;
        p.compliance.minTier = 2;
        (FixedPriceOffering o2, OfferingEscrow e2) = _createFixed(p, PRICE);
        _approve(carol, address(o2));
        vm.warp(p.startTime);
        vm.prank(alice);
        vm.expectRevert(OfferingBase.NotEligible.selector);
        o2.buy(1e18);
        vm.prank(carol);
        o2.buy(1e18);
    }

    function test_priorityWindow() public {
        Types.CommonParams memory p = _common(1_000e18, 0);
        p.priorityTier = 2;
        p.priorityWindow = 1 days;
        (FixedPriceOffering o2, OfferingEscrow e2) = _createFixed(p, PRICE);
        _approve(alice, address(o2));
        _approve(carol, address(o2));
        vm.warp(p.startTime);
        vm.prank(alice);
        vm.expectRevert(OfferingBase.PriorityWindow.selector);
        o2.buy(1e18);
        vm.prank(carol);
        o2.buy(1e18);
        vm.warp(p.startTime + 1 days);
        vm.prank(alice);
        o2.buy(1e18);
    }

    function test_pause_blocksBuysNotRefunds() public {
        _start();
        vm.prank(alice);
        o.buy(100e18);
        vm.prank(guardian);
        factory.pause();
        vm.prank(bob);
        vm.expectRevert(OfferingBase.ProtocolPaused.selector);
        o.buy(1e18);
        vm.warp(o.params().endTime);
        o.finalize(); // soft cap missed
        e.settle(alice); // refunds still work while paused
        assertEq(usd.balanceOf(address(e)), 0);
        vm.prank(guardian);
        vm.expectRevert();
        factory.unpause(); // only governance unpauses
        vm.prank(gov);
        factory.unpause();
    }

    function test_deliveryDeadlineMissed_refunds() public {
        _start();
        vm.prank(alice);
        o.buy(500e18);
        vm.warp(o.params().endTime);
        o.finalize();
        vm.expectRevert(OfferingEscrow.DeadlineNotReached.selector);
        e.markDeliveryFailed();
        vm.warp(e.deliveryDeadline() + 1);
        vm.startPrank(issuer);
        rwa.approve(address(e), 500e18);
        vm.expectRevert(OfferingEscrow.DeadlinePassed.selector);
        e.deliver();
        vm.stopPrank();
        e.markDeliveryFailed();
        uint256 before = usd.balanceOf(alice);
        e.settle(alice);
        assertEq(usd.balanceOf(alice) - before, 5_000e6);
        vm.expectRevert(OfferingEscrow.WrongStage.selector);
        e.markDeliveryFailed();
    }

    function test_onlyIssuerDelivers() public {
        _start();
        vm.prank(alice);
        o.buy(500e18);
        vm.warp(o.params().endTime);
        o.finalize();
        vm.prank(alice);
        vm.expectRevert(OfferingEscrow.NotAuthorized.selector);
        e.deliver();
    }

    function test_cancel_paths() public {
        _start();
        vm.prank(alice);
        o.buy(500e18);
        vm.prank(alice);
        vm.expectRevert(OfferingEscrow.NotAuthorized.selector);
        e.cancel();
        vm.prank(issuer);
        e.cancel();
        assertTrue(e.cancelled());
        vm.prank(bob);
        vm.expectRevert(OfferingBase.NotActive.selector);
        o.buy(1e18);
        vm.warp(o.params().endTime);
        vm.expectRevert(OfferingBase.NotEnded.selector);
        o.finalize();
        e.settle(alice);
        assertEq(usd.balanceOf(address(e)), 0);
    }

    function test_guardianCancelAfterSuccess_refundsEverything() public {
        _start();
        vm.prank(alice);
        o.buy(500e18);
        vm.warp(o.params().endTime);
        o.finalize();
        vm.prank(issuer);
        vm.expectRevert(OfferingEscrow.WrongStage.selector);
        e.cancel(); // issuer can no longer cancel after finalize
        vm.prank(guardian);
        e.cancel();
        e.settle(alice);
        assertEq(usd.balanceOf(address(e)), 0);
        _deliverReverts();
    }

    function _deliverReverts() internal {
        vm.prank(issuer);
        vm.expectRevert(OfferingEscrow.WrongStage.selector);
        e.deliver();
    }

    function test_guardianCannotCancelAfterDelivery() public {
        _start();
        vm.prank(alice);
        o.buy(500e18);
        vm.warp(o.params().endTime);
        o.finalize();
        _deliver(e);
        vm.prank(guardian);
        vm.expectRevert(OfferingEscrow.WrongStage.selector);
        e.cancel();
    }

    function test_sweepRequiresAllSettled() public {
        _start();
        vm.prank(alice);
        o.buy(300e18);
        vm.prank(bob);
        o.buy(200e18);
        vm.warp(o.params().endTime);
        o.finalize();
        _deliver(e);
        e.settle(alice);
        vm.expectRevert(OfferingEscrow.NotFullySettled.selector);
        e.sweep();
        e.settle(bob);
        e.sweep();
    }

    function test_vestingOnClaim() public {
        Types.CommonParams memory p = _common(1_000e18, 0);
        p.vestingCliff = 30 days;
        p.vestingDuration = 360 days;
        (FixedPriceOffering o2, OfferingEscrow e2) = _createFixed(p, PRICE);
        _approve(alice, address(o2));
        vm.warp(p.startTime);
        vm.prank(alice);
        o2.buy(360e18);
        vm.warp(p.endTime);
        o2.finalize();
        _deliver(e2);
        e2.settle(alice);
        assertEq(rwa.balanceOf(alice), 0);
        uint256[] memory ids = vesting.schedulesOf(alice);
        assertEq(ids.length, 1);
        assertEq(vesting.releasable(ids[0]), 0);
        vm.expectRevert(DeliveryVesting.NothingToRelease.selector);
        vesting.release(ids[0]);
        vm.warp(block.timestamp + 30 days);
        assertEq(vesting.releasable(ids[0]), 30e18);
        vesting.release(ids[0]);
        assertEq(rwa.balanceOf(alice), 30e18);
        vm.warp(block.timestamp + 400 days);
        vesting.release(ids[0]);
        assertEq(rwa.balanceOf(alice), 360e18);
        assertEq(vesting.vestedAmount(ids[0]), 360e18);
        assertEq(vesting.getSchedule(ids[0]).released, 360e18);
        assertEq(vesting.scheduleCount(), 1);
    }

    function test_vesting_onlyEscrow() public {
        vm.expectRevert(DeliveryVesting.OnlyEscrow.selector);
        vesting.createSchedule(alice, address(rwa), 1, 0, 0, 1);
    }

    function test_previewSettle() public {
        _start();
        vm.prank(alice);
        o.buy(500e18);
        (uint256 r, uint256 t, uint256 pen) = e.previewSettle(alice);
        assertEq(r + t + pen, 0);
        vm.warp(o.params().endTime);
        o.finalize();
        (r, t, pen) = e.previewSettle(alice);
        assertEq(r, 0);
        assertEq(t, 0); // not delivered yet
        _deliver(e);
        (r, t, pen) = e.previewSettle(alice);
        assertEq(t, 500e18);
        assertEq(e.positionOf(alice).deposit, 5_000e6);
    }

    function test_quoteRoundsUp() public view {
        // 1 wei of token at 10 USDG/token costs 1 micro-USDG (rounded up), never 0
        assertEq(o.quote(1), 1);
        assertEq(o.quote(1e18), PRICE);
    }

    function test_updateDocs() public {
        vm.prank(alice);
        vm.expectRevert(OfferingBase.OnlyIssuer.selector);
        o.updateDocs("x");
        vm.prank(issuer);
        o.updateDocs("bafynew");
        assertEq(o.params().docsCID, "bafynew");
    }

    function test_kind() public view {
        assertEq(uint8(o.kind()), uint8(Types.OfferingKind.FixedPrice));
    }

    function test_settleRevertsForNonParticipant() public {
        vm.warp(o.params().endTime);
        o.finalize();
        vm.expectRevert(Refunds.NothingToRefund.selector);
        e.settle(dave);
    }

    function test_escrowOnlyOffering() public {
        vm.expectRevert(OfferingEscrow.OnlyOffering.selector);
        e.recordDeposit(alice, 1);
        vm.expectRevert(OfferingEscrow.OnlyOffering.selector);
        e.onFinalized(true, 0, 0);
    }

    function test_initializersLocked() public {
        Types.CommonParams memory p = _common(1, 0);
        vm.expectRevert();
        o.initialize(address(factory), issuer, address(e), p, Types.FixedPriceParams(1));
        vm.expectRevert();
        e.initialize(address(factory), address(o), issuer, address(usd), address(rwa), 0, 1 days, 0, 0);
    }
}
