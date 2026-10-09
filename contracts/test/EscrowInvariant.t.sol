// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Base} from "./utils/Base.t.sol";
import {Types} from "../src/interfaces/IBookbuilder.sol";
import {FixedPriceOffering} from "../src/offerings/FixedPriceOffering.sol";
import {BatchAuction} from "../src/offerings/BatchAuction.sol";
import {OfferingEscrow} from "../src/OfferingEscrow.sol";
import {MockERC20} from "./mocks/Mocks.sol";

/// @notice Drives a fixed-price offering and a batch auction through random lifecycles.
contract Handler is Test {
    FixedPriceOffering public fo;
    OfferingEscrow public fe;
    BatchAuction public bo;
    OfferingEscrow public be;
    MockERC20 public usd;
    MockERC20 public rwa;
    address public issuer;
    address public guardian;
    address[] public actors;

    // ghost accounting
    uint256 public ghostDepositedF;
    uint256 public ghostDepositedB;
    mapping(address => bool) public committed;
    mapping(address => uint16) public bidTick;
    mapping(address => uint256) public bidQty;

    constructor(
        FixedPriceOffering fo_,
        OfferingEscrow fe_,
        BatchAuction bo_,
        OfferingEscrow be_,
        MockERC20 usd_,
        MockERC20 rwa_,
        address issuer_,
        address guardian_,
        address[] memory actors_
    ) {
        fo = fo_;
        fe = fe_;
        bo = bo_;
        be = be_;
        usd = usd_;
        rwa = rwa_;
        issuer = issuer_;
        guardian = guardian_;
        actors = actors_;
    }

    function _actor(uint256 s) internal view returns (address) {
        return actors[s % actors.length];
    }

    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 1, 2 days));
    }

    function buy(uint256 a, uint256 qty) external {
        address who = _actor(a);
        qty = bound(qty, 1, 300e18);
        vm.prank(who);
        try fo.buy(qty) returns (uint256 cost) {
            ghostDepositedF += cost;
        } catch {}
    }

    function commit(uint256 a, uint256 tick, uint256 qty, uint256 extra) external {
        address who = _actor(a);
        if (committed[who]) return;
        uint16 t = uint16(bound(tick, 0, 19));
        qty = bound(qty, 1, 400e18);
        extra = bound(extra, 0, 50e6);
        bytes32 h = bo.commitmentHash(who, t, qty, bytes32(uint256(uint160(who))));
        uint256 dep = (qty * bo.priceAt(t) - 1) / 1e18 + 1 + extra;
        vm.prank(who);
        try bo.commit(h, dep) {
            committed[who] = true;
            bidTick[who] = t;
            bidQty[who] = qty;
            ghostDepositedB += dep;
        } catch {}
    }

    function reveal(uint256 a) external {
        address who = _actor(a);
        if (!committed[who]) return;
        try bo.reveal(who, bidTick[who], bidQty[who], bytes32(uint256(uint160(who)))) {} catch {}
    }

    function finalize(uint256 which) external {
        if (which % 2 == 0) {
            try fo.finalize() {} catch {}
        } else {
            try bo.finalize() {} catch {}
        }
    }

    function deliver(uint256 which) external {
        OfferingEscrow e = which % 2 == 0 ? fe : be;
        if (e.stage() != Types.Stage.Succeeded) return;
        uint256 t = e.tokensToDeliver();
        rwa.mint(issuer, t);
        vm.startPrank(issuer);
        rwa.approve(address(e), t);
        try e.deliver() {} catch {}
        vm.stopPrank();
    }

    function settle(uint256 which, uint256 a) external {
        OfferingEscrow e = which % 2 == 0 ? fe : be;
        try e.settle(_actor(a)) {} catch {}
    }

    function markFailed(uint256 which) external {
        OfferingEscrow e = which % 2 == 0 ? fe : be;
        try e.markDeliveryFailed() {} catch {}
    }

    function guardianCancel(uint256 which, uint256 roll) external {
        if (roll % 20 != 0) return; // rare
        OfferingEscrow e = which % 2 == 0 ? fe : be;
        vm.prank(guardian);
        try e.cancel() {} catch {}
    }
}

contract EscrowInvariantTest is Base {
    Handler h;
    FixedPriceOffering fo;
    OfferingEscrow fe;
    BatchAuction bo;
    OfferingEscrow be;

    function setUp() public override {
        super.setUp();
        Types.CommonParams memory p = _common(1_000e18, 300e18);
        (fo, fe) = _createFixed(p, 3_333_333); // odd price for rounding
        Types.BatchAuctionParams memory bp = _batchParams();
        bp.numTicks = 20;
        bp.tickSize = 77_777;
        (bo, be) = _createBatch(p, bp);

        address[] memory actors = new address[](4);
        actors[0] = alice;
        actors[1] = bob;
        actors[2] = carol;
        actors[3] = dave;
        for (uint256 k; k < 4; ++k) {
            _approve(actors[k], address(fo));
            _approve(actors[k], address(bo));
        }
        h = new Handler(fo, fe, bo, be, usd, rwa, issuer, guardian, actors);
        vm.warp(p.startTime);
        targetContract(address(h));
    }

    /// Escrow token balance always equals its internal accounting of held funds.
    function invariant_balanceEqualsHeld() public view {
        assertEq(usd.balanceOf(address(fe)), fe.heldPayment());
        assertEq(usd.balanceOf(address(be)), be.heldPayment());
    }

    /// Until release (delivery) or any refund, the escrow holds exactly what was raised.
    function invariant_balanceEqualsRaisedUntilReleaseOrRefund() public view {
        if (fe.releasedToIssuer() == 0 && fe.totalRefunded() == 0 && fe.totalPenalties() == 0) {
            assertEq(usd.balanceOf(address(fe)), h.ghostDepositedF());
            assertEq(fe.totalDeposited(), h.ghostDepositedF());
        }
        if (be.releasedToIssuer() == 0 && be.totalRefunded() == 0 && be.totalPenalties() == 0) {
            assertEq(usd.balanceOf(address(be)), h.ghostDepositedB());
            assertEq(be.totalDeposited(), h.ghostDepositedB());
        }
    }

    /// Nothing reaches the issuer before delivery.
    function invariant_noReleaseBeforeDelivery() public view {
        if (fe.stage() != Types.Stage.Delivered) assertEq(fe.releasedToIssuer(), 0);
        if (be.stage() != Types.Stage.Delivered) assertEq(be.releasedToIssuer(), 0);
    }

    /// Delivered escrows always hold enough sale tokens for unclaimed allocations.
    function invariant_tokensCoverClaims() public view {
        if (fe.stage() == Types.Stage.Delivered) {
            assertGe(rwa.balanceOf(address(fe)) + fe.tokensClaimedTotal(), fe.tokensToDeliver());
        }
        if (be.stage() == Types.Stage.Delivered) {
            assertGe(rwa.balanceOf(address(be)) + be.tokensClaimedTotal(), be.tokensToDeliver());
        }
    }

    /// Sold never exceeds supply.
    function invariant_noOverAllocation() public view {
        assertLe(fo.totalSold(), fo.params().supply);
        assertLe(bo.tokensSold(), bo.params().supply);
        assertLe(fe.settledCount(), fe.participants());
    }
}
