// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Deploy, RobinhoodChain} from "../../script/Deploy.s.sol";
import {Types} from "../../src/interfaces/IBookbuilder.sol";
import {FixedPriceOffering} from "../../src/offerings/FixedPriceOffering.sol";
import {BatchAuction} from "../../src/offerings/BatchAuction.sol";
import {OfferingEscrow} from "../../src/OfferingEscrow.sol";
import {IssuerRegistry} from "../../src/IssuerRegistry.sol";
import {ComplianceRegistry} from "../../src/ComplianceRegistry.sol";
import {MockERC20} from "../mocks/Mocks.sol";

/// @notice Fork tests against Robinhood Chain mainnet (chain 4663) with real USDG and Chainlink feeds.
///         RPC: $ROBINHOOD_RPC_URL, falling back to the official public RPC.
contract ForkTest is Test {
    Deploy internal script;
    Deploy.Params internal p;
    Deploy.Deployment internal d;
    IERC20 internal usdg = IERC20(RobinhoodChain.USDG);
    MockERC20 internal rwa; // test-only stand-in for an issuer's RWA token
    address internal attestor = makeAddr("attestor");
    address internal issuer = makeAddr("issuer");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        string memory rpc = vm.envOr("ROBINHOOD_RPC_URL", string("https://rpc.mainnet.chain.robinhood.com"));
        vm.createSelectFork(rpc);
        assertEq(block.chainid, 4663);
        script = new Deploy();
        p = script.loadParams(address(script));
        p.attestor = attestor;
        d = script.deploy(p);
        rwa = new MockERC20("Fork SPV Token", "FSPV", 18);
    }

    function test_fork_realTokensAndFeeds() public view {
        assertEq(IERC20Metadata(RobinhoodChain.USDG).symbol(), "USDG");
        assertEq(IERC20Metadata(RobinhoodChain.USDG).decimals(), 6);
        assertEq(IERC20Metadata(RobinhoodChain.WETH).symbol(), "WETH");
        (uint256 px,) = d.oracle.getPrice(RobinhoodChain.USDG);
        assertApproxEqRel(px, 1e18, 0.02e18); // USDG ~ $1
        (uint256 eth,) = d.oracle.getPrice(RobinhoodChain.WETH);
        assertGt(eth, 100e18);
        assertTrue(d.factory.allowedPaymentToken(RobinhoodChain.USDG));
    }

    function test_fork_adminHandedToTimelock() public view {
        address tl = address(d.timelock);
        address[6] memory cs = [
            address(d.issuerRegistry),
            address(d.compliance),
            address(d.feeCollector),
            address(d.hooks),
            address(d.oracle),
            address(d.factory)
        ];
        for (uint256 k; k < cs.length; ++k) {
            assertTrue(AccessControl(cs[k]).hasRole(0x00, tl), "timelock admin");
            assertFalse(AccessControl(cs[k]).hasRole(0x00, address(script)), "deployer renounced");
        }
        assertEq(d.timelock.getMinDelay(), 48 hours);
        assertEq(d.factory.offeringCount(), 0); // no offerings created at deploy
        assertEq(d.issuerRegistry.issuerCount(), 0); // no issuers approved at deploy
        assertFalse(d.hooks.isEnabled()); // $BOOK not wired
        assertEq(d.feeCollector.treasury(), tl);
        assertTrue(d.compliance.blockedCountry("KP"));
    }

    function _govExecute(address target, bytes memory data) internal {
        bytes32 salt = keccak256(data);
        vm.prank(p.proposer);
        d.timelock.schedule(target, 0, data, bytes32(0), salt, 48 hours);
        vm.warp(block.timestamp + 48 hours);
        d.timelock.execute(target, 0, data, bytes32(0), salt);
    }

    function _approveIssuer() internal {
        _govExecute(
            address(d.issuerRegistry),
            abi.encodeCall(IssuerRegistry.approveIssuer, (issuer, address(rwa), "Fork SPV LLC", "bafyforkdocs"))
        );
        assertTrue(d.issuerRegistry.isApprovedIssuer(issuer));
        vm.startPrank(attestor);
        d.compliance.attest(alice, 1, true, "SG", uint64(block.timestamp + 365 days));
        d.compliance.attest(bob, 1, true, "SG", uint64(block.timestamp + 365 days));
        vm.stopPrank();
        deal(RobinhoodChain.USDG, alice, 1_000_000e6);
        deal(RobinhoodChain.USDG, bob, 1_000_000e6);
        rwa.mint(issuer, 1_000_000e18);
    }

    function _common() internal view returns (Types.CommonParams memory c) {
        c.saleToken = address(rwa);
        c.paymentToken = RobinhoodChain.USDG;
        c.supply = 10_000e18;
        c.softCap = 1_000e18;
        c.startTime = uint64(block.timestamp + 1 hours);
        c.endTime = uint64(block.timestamp + 2 days);
        c.deliveryWindow = 14 days;
        c.compliance = Types.ComplianceRules(true, 1, false);
        c.docsCID = "bafyforkoffering";
    }

    function test_fork_fixedPriceLifecycleWithRealUSDG() public {
        _approveIssuer();
        Types.CommonParams memory c = _common();
        vm.prank(issuer);
        (address oa, address ea) = d.factory.createFixedPrice(c, Types.FixedPriceParams(25e6));
        FixedPriceOffering o = FixedPriceOffering(oa);
        OfferingEscrow e = OfferingEscrow(ea);
        vm.warp(c.startTime);
        vm.startPrank(alice);
        usdg.approve(oa, type(uint256).max);
        o.buy(2_000e18);
        vm.stopPrank();
        assertEq(usdg.balanceOf(ea), 50_000e6);
        vm.warp(c.endTime);
        o.finalize();
        vm.startPrank(issuer);
        rwa.approve(ea, e.tokensToDeliver());
        uint256 before = usdg.balanceOf(issuer);
        e.deliver();
        vm.stopPrank();
        assertEq(usdg.balanceOf(issuer) - before, 49_500e6); // 1% protocol fee
        assertEq(usdg.balanceOf(address(d.feeCollector)), 500e6);
        e.settle(alice);
        assertEq(rwa.balanceOf(alice), 2_000e18);
        d.feeCollector.distribute(RobinhoodChain.USDG); // token not set -> all to treasury (Timelock)
        assertEq(usdg.balanceOf(address(d.timelock)), 500e6);
    }

    function test_fork_batchAuctionWithRealUSDG() public {
        _approveIssuer();
        Types.CommonParams memory c = _common();
        Types.BatchAuctionParams memory bp = Types.BatchAuctionParams({
            minPrice: 10e6,
            tickSize: 0.1e6,
            numTicks: 100,
            revealDuration: 1 days,
            antiSnipeWindow: 10 minutes,
            antiSnipeExtension: 10 minutes,
            maxEndTime: c.endTime + 1 days,
            nonRevealPenaltyBps: 300,
            maxBidders: 5_000
        });
        vm.prank(issuer);
        (address oa, address ea) = d.factory.createBatchAuction(c, bp);
        BatchAuction o = BatchAuction(oa);
        vm.warp(c.startTime);
        bytes32 sa = keccak256("a");
        bytes32 sb = keccak256("b");
        bytes32 ha = o.commitmentHash(alice, 50, 8_000e18, sa);
        bytes32 hb = o.commitmentHash(bob, 20, 8_000e18, sb);
        vm.startPrank(alice);
        usdg.approve(oa, type(uint256).max);
        o.commit(ha, 8_000 * 15e6);
        vm.stopPrank();
        vm.startPrank(bob);
        usdg.approve(oa, type(uint256).max);
        o.commit(hb, 8_000 * 12e6);
        vm.stopPrank();
        vm.warp(o.commitEnd());
        o.reveal(alice, 50, 8_000e18, sa);
        o.reveal(bob, 20, 8_000e18, sb);
        vm.warp(o.revealEnd());
        o.finalize();
        assertEq(o.clearingPrice(), 12e6);
        assertEq(o.fillOf(alice), 8_000e18);
        assertEq(o.fillOf(bob), 2_000e18);
        OfferingEscrow e = OfferingEscrow(ea);
        vm.startPrank(issuer);
        rwa.approve(ea, e.tokensToDeliver());
        e.deliver();
        vm.stopPrank();
        e.settle(alice);
        e.settle(bob);
        e.sweep();
        assertEq(usdg.balanceOf(ea), 0);
        assertEq(rwa.balanceOf(bob), 2_000e18);
    }
}
