// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Base} from "./utils/Base.t.sol";
import {Types} from "../src/interfaces/IBookbuilder.sol";
import {OfferingBase} from "../src/offerings/OfferingBase.sol";
import {DutchAuction} from "../src/offerings/DutchAuction.sol";
import {OfferingEscrow} from "../src/OfferingEscrow.sol";

contract DutchAuctionTest is Base {
    DutchAuction o;
    OfferingEscrow e;
    Types.CommonParams p;

    function setUp() public override {
        super.setUp();
        p = _common(1_000e18, 0);
        (o, e) = _createDutch(p, Types.DutchAuctionParams({startPrice: 20e6, floorPrice: 10e6, decayDuration: 2 days}));
        _approve(alice, address(o));
        _approve(bob, address(o));
    }

    function test_priceDecaysToFloor() public {
        assertEq(o.currentPrice(), 20e6);
        vm.warp(p.startTime);
        assertEq(o.currentPrice(), 20e6);
        vm.warp(p.startTime + 1 days);
        assertEq(o.currentPrice(), 15e6);
        vm.warp(p.startTime + 2 days);
        assertEq(o.currentPrice(), 10e6);
        vm.warp(p.startTime + 3 days - 1);
        assertEq(o.currentPrice(), 10e6);
    }

    function test_buyAtCurrentPrice_soldOut_settle() public {
        vm.warp(p.startTime + 1 days);
        vm.prank(alice);
        uint256 c1 = o.buy(400e18, type(uint256).max);
        assertEq(c1, 6_000e6);
        assertEq(o.lastPrice(), 15e6);
        vm.warp(p.startTime + 2 days);
        assertEq(o.quote(600e18), 6_000e6);
        vm.prank(bob);
        o.buy(600e18, 6_000e6);
        assertTrue(o.canFinalize());
        o.finalize();
        assertEq(e.grossProceeds(), 12_000e6);
        _deliver(e);
        e.settle(alice);
        e.settle(bob);
        assertEq(rwa.balanceOf(alice), 400e18);
        assertEq(rwa.balanceOf(bob), 600e18);
        assertEq(usd.balanceOf(address(e)), 0);
        (uint256 t, uint256 c, uint256 pen) = o.settlementOf(alice);
        assertEq(t, 400e18);
        assertEq(c, 6_000e6);
        assertEq(pen, 0);
    }

    function test_slippageGuard() public {
        vm.warp(p.startTime);
        vm.prank(alice);
        vm.expectRevert(DutchAuction.SlippageExceeded.selector);
        o.buy(1e18, 19e6);
    }

    function test_guards() public {
        vm.warp(p.startTime);
        vm.startPrank(alice);
        vm.expectRevert(OfferingBase.ZeroAmount.selector);
        o.buy(0, 1);
        vm.expectRevert(OfferingBase.ExceedsSupply.selector);
        o.buy(1_001e18, type(uint256).max);
        vm.stopPrank();
        vm.expectRevert(OfferingBase.NotEnded.selector);
        o.finalize();
        vm.warp(p.endTime);
        o.finalize();
        assertFalse(o.succeeded()); // nothing sold
        assertEq(uint8(o.kind()), uint8(Types.OfferingKind.DutchAuction));
    }

    function test_invalidParams() public {
        vm.startPrank(issuer);
        vm.expectRevert(OfferingBase.InvalidParams.selector);
        factory.createDutchAuction(p, Types.DutchAuctionParams(10e6, 20e6, 1 days));
        vm.expectRevert(OfferingBase.InvalidParams.selector);
        factory.createDutchAuction(p, Types.DutchAuctionParams(10e6, 0, 1 days));
        vm.expectRevert(OfferingBase.InvalidParams.selector);
        factory.createDutchAuction(p, Types.DutchAuctionParams(20e6, 10e6, 0));
        vm.expectRevert(OfferingBase.InvalidParams.selector);
        factory.createDutchAuction(p, Types.DutchAuctionParams(20e6, 10e6, 4 days));
        vm.stopPrank();
    }

    function testFuzz_priceMonotonic(uint256 t1, uint256 t2) public {
        t1 = bound(t1, 0, 4 days);
        t2 = bound(t2, t1, 4 days);
        vm.warp(p.startTime + t1);
        uint256 a = o.currentPrice();
        vm.warp(p.startTime + t2);
        uint256 b = o.currentPrice();
        assertLe(b, a);
        assertGe(b, 10e6);
        assertLe(a, 20e6);
    }
}
