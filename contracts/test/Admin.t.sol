// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Base} from "./utils/Base.t.sol";
import {Types} from "../src/interfaces/IBookbuilder.sol";
import {OfferingBase} from "../src/offerings/OfferingBase.sol";
import {FixedPriceOffering} from "../src/offerings/FixedPriceOffering.sol";
import {OfferingEscrow} from "../src/OfferingEscrow.sol";
import {OfferingFactory} from "../src/OfferingFactory.sol";
import {IssuerRegistry} from "../src/IssuerRegistry.sol";
import {ComplianceRegistry} from "../src/ComplianceRegistry.sol";
import {FeeCollector} from "../src/FeeCollector.sol";
import {ProjectTokenHooks} from "../src/ProjectTokenHooks.sol";
import {OracleAdapter} from "../src/OracleAdapter.sol";
import {Timelock} from "../src/Timelock.sol";
import {MockERC20, MockFeeToken, MockAggregator, MockReentrantToken} from "./mocks/Mocks.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract FactoryTest is Base {
    function test_onlyApprovedIssuerCreates() public {
        Types.CommonParams memory p = _common(100e18, 0);
        vm.prank(alice);
        vm.expectRevert(OfferingFactory.NotApprovedIssuer.selector);
        factory.createFixedPrice(p, Types.FixedPriceParams(1e6));
        vm.prank(guardian);
        issuers.suspend(issuer);
        vm.prank(issuer);
        vm.expectRevert(OfferingFactory.NotApprovedIssuer.selector);
        factory.createFixedPrice(p, Types.FixedPriceParams(1e6));
    }

    function test_validation() public {
        Types.CommonParams memory p = _common(100e18, 0);
        vm.startPrank(issuer);
        p.paymentToken = address(rwa);
        vm.expectRevert(OfferingFactory.PaymentTokenNotAllowed.selector);
        factory.createFixedPrice(p, Types.FixedPriceParams(1e6));
        p = _common(100e18, 0);
        p.saleToken = address(usd);
        vm.expectRevert(OfferingFactory.WrongSaleToken.selector);
        factory.createFixedPrice(p, Types.FixedPriceParams(1e6));
        p = _common(100e18, 0);
        p.compliance.enabled = false;
        vm.expectRevert(OfferingFactory.ComplianceRequired.selector);
        factory.createFixedPrice(p, Types.FixedPriceParams(1e6));
        p = _common(100e18, 0);
        p.deliveryWindow = 1 hours;
        vm.expectRevert(OfferingFactory.BadDeliveryWindow.selector);
        factory.createFixedPrice(p, Types.FixedPriceParams(1e6));
        p = _common(100e18, 0);
        p.endTime = p.startTime + 181 days;
        vm.expectRevert(OfferingFactory.BadDuration.selector);
        factory.createFixedPrice(p, Types.FixedPriceParams(1e6));
        p = _common(100e18, 0);
        vm.expectRevert(OfferingBase.InvalidParams.selector);
        factory.createFixedPrice(p, Types.FixedPriceParams(0));
        p = _common(100e18, 200e18);
        vm.expectRevert(OfferingBase.InvalidParams.selector);
        factory.createFixedPrice(p, Types.FixedPriceParams(1e6));
        p = _common(100e18, 0);
        p.startTime = uint64(block.timestamp - 1);
        vm.expectRevert(OfferingBase.InvalidParams.selector);
        factory.createFixedPrice(p, Types.FixedPriceParams(1e6));
        p = _common(100e18, 0);
        p.vestingDuration = 10;
        p.vestingCliff = 11;
        vm.expectRevert(OfferingBase.InvalidParams.selector);
        factory.createFixedPrice(p, Types.FixedPriceParams(1e6));
        p = _common(100e18, 0);
        p.perWalletMax = 101e18;
        vm.expectRevert(OfferingBase.InvalidParams.selector);
        factory.createFixedPrice(p, Types.FixedPriceParams(1e6));
        p = _common(100e18, 0);
        p.priorityWindow = 4 days;
        vm.expectRevert(OfferingBase.InvalidParams.selector);
        factory.createFixedPrice(p, Types.FixedPriceParams(1e6));
        vm.stopPrank();
    }

    function test_complianceOptionalOnlyIfGovernanceAllows() public {
        vm.prank(gov);
        factory.setComplianceMandatory(false);
        Types.CommonParams memory p = _common(100e18, 0);
        p.compliance.enabled = false;
        (FixedPriceOffering o, OfferingEscrow e) = _createFixed(p, 1e6);
        _approve(eve, address(o));
        vm.warp(p.startTime);
        vm.prank(eve);
        o.buy(1e18);
    }

    function test_listing() public {
        Types.CommonParams memory p = _common(100e18, 0);
        (FixedPriceOffering o,) = _createFixed(p, 1e6);
        _createBatch(p, _batchParams());
        _createDutch(p, Types.DutchAuctionParams(2e6, 1e6, 1 days));
        assertEq(factory.offeringCount(), 3);
        address[] memory list = factory.offerings(0, 10);
        assertEq(list.length, 3);
        assertEq(list[0], address(o));
        assertEq(factory.offerings(1, 1).length, 1);
        assertEq(factory.offerings(5, 1).length, 0);
        assertEq(factory.offeringsOf(issuer).length, 3);
        assertTrue(factory.isOffering(address(o)));
        assertTrue(factory.isEscrow(o.escrow()));
    }

    function test_pauseBlocksCreation() public {
        vm.prank(guardian);
        factory.pause();
        vm.prank(issuer);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        factory.createFixedPrice(_common(100e18, 0), Types.FixedPriceParams(1e6));
        assertTrue(factory.paused());
    }

    function test_adminSetters() public {
        vm.startPrank(gov);
        factory.setFeeBps(250);
        vm.expectRevert(OfferingFactory.FeeTooHigh.selector);
        factory.setFeeBps(501);
        factory.setCompliance(address(1));
        factory.setFeeCollector(address(2));
        factory.setVesting(address(3));
        factory.setHooks(address(0));
        factory.setOracle(address(4));
        factory.setImplementations(address(5), address(6), address(7), address(8));
        vm.expectRevert(OfferingFactory.ZeroAddress.selector);
        factory.setImplementations(address(0), address(6), address(7), address(8));
        vm.expectRevert(OfferingFactory.ZeroAddress.selector);
        factory.setCompliance(address(0));
        vm.expectRevert(OfferingFactory.ZeroAddress.selector);
        factory.setFeeCollector(address(0));
        vm.expectRevert(OfferingFactory.ZeroAddress.selector);
        factory.setVesting(address(0));
        vm.expectRevert(OfferingFactory.ZeroAddress.selector);
        factory.setPaymentToken(address(0), true);
        vm.stopPrank();
        assertEq(factory.feeBps(), 250);
        assertEq(factory.oracle(), address(4));

        vm.prank(alice);
        vm.expectRevert();
        factory.setFeeBps(1);
    }

    function test_constructorGuards() public {
        OfferingFactory.Config memory c;
        vm.expectRevert(OfferingFactory.ZeroAddress.selector);
        new OfferingFactory(c);
        c = OfferingFactory.Config(
            gov, guardian, address(issuers), address(compliance), address(fees), address(vesting), address(0), address(0), 501,
            address(1), address(2), address(3), address(4)
        );
        vm.expectRevert(OfferingFactory.FeeTooHigh.selector);
        new OfferingFactory(c);
    }

    function test_feeOnTransferPaymentToken_rejected() public {
        MockFeeToken fee = new MockFeeToken();
        vm.prank(gov);
        factory.setPaymentToken(address(fee), true);
        Types.CommonParams memory p = _common(100e18, 0);
        p.paymentToken = address(fee);
        (FixedPriceOffering o, OfferingEscrow e) = _createFixed(p, 1e18);
        fee.mint(alice, 100e18);
        vm.prank(alice);
        fee.approve(address(o), type(uint256).max);
        vm.warp(p.startTime);
        vm.prank(alice);
        vm.expectRevert(OfferingEscrow.TransferAmountMismatch.selector);
        o.buy(1e18);
    }

    function test_feeOnTransferSaleToken_deliveryRejected() public {
        MockFeeToken feeRwa = new MockFeeToken();
        address issuer2 = makeAddr("issuer2");
        vm.prank(gov);
        issuers.approveIssuer(issuer2, address(feeRwa), "Fee SPV", "cid");
        Types.CommonParams memory p = _common(100e18, 0);
        p.saleToken = address(feeRwa);
        vm.prank(issuer2);
        (address oa, address ea) = factory.createFixedPrice(p, Types.FixedPriceParams(1e6));
        _approve(alice, oa);
        vm.warp(p.startTime);
        vm.prank(alice);
        FixedPriceOffering(oa).buy(100e18);
        FixedPriceOffering(oa).finalize();
        feeRwa.mint(issuer2, 1_000e18);
        vm.startPrank(issuer2);
        feeRwa.approve(ea, type(uint256).max);
        vm.expectRevert(OfferingEscrow.TransferAmountMismatch.selector);
        OfferingEscrow(ea).deliver();
        vm.stopPrank();
    }

    function test_reentrantSaleToken_cannotDoubleClaim() public {
        MockReentrantToken evil = new MockReentrantToken();
        address issuer4 = makeAddr("issuer4");
        vm.prank(gov);
        issuers.approveIssuer(issuer4, address(evil), "Evil SPV", "cid");
        Types.CommonParams memory p = _common(100e18, 0);
        p.saleToken = address(evil);
        vm.prank(issuer4);
        (address oa, address ea) = factory.createFixedPrice(p, Types.FixedPriceParams(1e6));
        _approve(alice, oa);
        vm.warp(p.startTime);
        vm.prank(alice);
        FixedPriceOffering(oa).buy(100e18);
        FixedPriceOffering(oa).finalize();
        evil.mint(issuer4, 100e18);
        vm.startPrank(issuer4);
        evil.approve(ea, type(uint256).max);
        OfferingEscrow(ea).deliver();
        vm.stopPrank();
        evil.arm(ea, alice); // on transfer out of the escrow, re-enter settle(alice)
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        OfferingEscrow(ea).settle(alice);
        evil.arm(address(0), address(0));
        OfferingEscrow(ea).settle(alice);
        assertEq(evil.balanceOf(alice), 100e18);
    }

    function test_zeroDecimalRwaToken() public {
        // ERC-3643 style tokens often use 0 decimals; price is per whole token
        MockERC20 whole = new MockERC20("Whole", "WHL", 0);
        address issuer3 = makeAddr("issuer3");
        vm.prank(gov);
        issuers.approveIssuer(issuer3, address(whole), "Whole SPV", "cid");
        Types.CommonParams memory p = _common(100, 0);
        p.saleToken = address(whole);
        vm.prank(issuer3);
        (address oa, address ea) = factory.createFixedPrice(p, Types.FixedPriceParams(1_000e6));
        _approve(alice, oa);
        vm.warp(p.startTime);
        vm.prank(alice);
        assertEq(FixedPriceOffering(oa).buy(3), 3_000e6);
    }
}

contract RegistryTest is Base {
    function test_issuerLifecycle() public {
        address i2 = makeAddr("i2");
        vm.prank(alice);
        vm.expectRevert();
        issuers.approveIssuer(i2, address(rwa), "x", "y");
        vm.startPrank(gov);
        vm.expectRevert(IssuerRegistry.ZeroAddress.selector);
        issuers.approveIssuer(address(0), address(rwa), "x", "y");
        vm.expectRevert(IssuerRegistry.EmptyField.selector);
        issuers.approveIssuer(i2, address(rwa), "", "y");
        issuers.approveIssuer(i2, address(rwa), "Legal", "cid");
        vm.expectRevert(IssuerRegistry.AlreadyRegistered.selector);
        issuers.approveIssuer(i2, address(rwa), "Legal", "cid");
        issuers.updateIssuer(i2, address(usd), "Legal2", "cid2");
        vm.expectRevert(IssuerRegistry.NotRegistered.selector);
        issuers.updateIssuer(alice, address(usd), "Legal2", "cid2");
        vm.expectRevert(IssuerRegistry.ZeroAddress.selector);
        issuers.updateIssuer(i2, address(0), "Legal2", "cid2");
        vm.expectRevert(IssuerRegistry.EmptyField.selector);
        issuers.updateIssuer(i2, address(usd), "", "cid2");
        vm.expectRevert(IssuerRegistry.InvalidStatus.selector);
        issuers.setStatus(i2, IssuerRegistry.Status.None);
        issuers.setStatus(i2, IssuerRegistry.Status.Revoked);
        vm.stopPrank();
        assertFalse(issuers.isApprovedIssuer(i2));
        assertEq(issuers.deliveryTokenOf(i2), address(usd));
        assertEq(issuers.getIssuer(i2).legalEntityRef, "Legal2");
        assertEq(issuers.issuerCount(), 2);
        assertEq(issuers.issuers(0, 10).length, 2);
        assertEq(issuers.issuers(1, 10).length, 1);
        assertEq(issuers.issuers(5, 10).length, 0);

        vm.prank(i2);
        vm.expectRevert(IssuerRegistry.NotRegistered.selector);
        issuers.updateDocs("new");
        vm.startPrank(issuer);
        vm.expectRevert(IssuerRegistry.EmptyField.selector);
        issuers.updateDocs("");
        issuers.updateDocs("newdocs");
        vm.stopPrank();
        assertEq(issuers.getIssuer(issuer).docsCID, "newdocs");

        vm.prank(guardian);
        vm.expectRevert(IssuerRegistry.NotRegistered.selector);
        issuers.suspend(alice);
        vm.expectRevert(IssuerRegistry.ZeroAddress.selector);
        new IssuerRegistry(address(0), guardian);
    }

    function test_compliance() public {
        vm.prank(alice);
        vm.expectRevert();
        compliance.attest(alice, 1, false, "US", uint64(block.timestamp + 1));
        vm.startPrank(attestor);
        vm.expectRevert(ComplianceRegistry.BadExpiry.selector);
        compliance.attest(alice, 1, false, "US", uint64(block.timestamp));
        vm.expectRevert(ComplianceRegistry.ZeroAddress.selector);
        compliance.attest(address(0), 1, false, "US", uint64(block.timestamp + 1));
        address[] memory a = new address[](2);
        a[0] = makeAddr("x1");
        a[1] = makeAddr("x2");
        uint8[] memory t = new uint8[](2);
        t[0] = 1;
        t[1] = 2;
        bool[] memory acc = new bool[](2);
        bytes2[] memory c = new bytes2[](2);
        c[0] = "DE";
        c[1] = "FR";
        compliance.attestBatch(a, t, acc, c, uint64(block.timestamp + 10 days));
        vm.expectRevert(ComplianceRegistry.LengthMismatch.selector);
        compliance.attestBatch(a, new uint8[](1), acc, c, uint64(block.timestamp + 10 days));
        compliance.revoke(alice);
        compliance.setFrozen(bob, true);
        vm.stopPrank();
        assertEq(compliance.tierOf(a[1]), 2);
        assertEq(compliance.tierOf(alice), 0);
        assertEq(compliance.tierOf(bob), 0);
        assertEq(compliance.attestationOf(a[0]).country, bytes2("DE"));
        Types.ComplianceRules memory r = Types.ComplianceRules(true, 1, false);
        assertTrue(compliance.isEligible(a[0], r));
        assertFalse(compliance.isEligible(alice, r));
        r.enabled = false;
        assertTrue(compliance.isEligible(alice, r));
        vm.warp(block.timestamp + 11 days);
        assertEq(compliance.tierOf(a[0]), 0);
        r.enabled = true;
        assertFalse(compliance.isEligible(a[0], r));
        vm.prank(eve);
        vm.expectRevert();
        compliance.setFrozen(alice, true);
        vm.expectRevert(ComplianceRegistry.ZeroAddress.selector);
        new ComplianceRegistry(gov, address(0));
    }
}

contract FeesAndHooksTest is Base {
    function test_projectTokenOffByDefault() public {
        assertFalse(hooks.isEnabled());
        assertEq(hooks.guaranteedBps(alice), 0);
        assertEq(hooks.tierOf(alice), 0);
        vm.prank(alice);
        vm.expectRevert(ProjectTokenHooks.TokenNotSet.selector);
        hooks.stake(1);
        // fees go 100% to treasury while token disabled
        usd.mint(address(fees), 100e6);
        fees.distribute(address(usd));
        assertEq(usd.balanceOf(treasury), 100e6);
        fees.distribute(address(usd)); // zero balance no-op
    }

    function test_setProjectToken_onceByOwnerOnly() public {
        vm.prank(alice);
        vm.expectRevert();
        hooks.setProjectToken(address(book));
        vm.startPrank(gov);
        vm.expectRevert(ProjectTokenHooks.ZeroAddress.selector);
        hooks.setProjectToken(address(0));
        hooks.setProjectToken(address(book));
        vm.expectRevert(ProjectTokenHooks.TokenAlreadySet.selector);
        hooks.setProjectToken(address(usd));
        vm.stopPrank();
        assertTrue(hooks.isEnabled());
    }

    function _enable() internal {
        vm.startPrank(gov);
        hooks.setProjectToken(address(book));
        ProjectTokenHooks.Tier[] memory t = new ProjectTokenHooks.Tier[](2);
        t[0] = ProjectTokenHooks.Tier(100e18, 50);
        t[1] = ProjectTokenHooks.Tier(1_000e18, 200);
        hooks.setTiers(t);
        vm.stopPrank();
    }

    function _stake(address who, uint256 amt) internal {
        book.mint(who, amt);
        vm.startPrank(who);
        book.approve(address(hooks), amt);
        hooks.stake(amt);
        vm.stopPrank();
    }

    function test_stakingTiersAgingAndUnstake() public {
        _enable();
        _stake(alice, 1_000e18);
        assertEq(hooks.tierOf(alice), 0); // not aged yet
        vm.warp(block.timestamp + 3 days);
        assertEq(hooks.tierOf(alice), 2);
        assertEq(hooks.guaranteedBps(alice), 200);
        vm.startPrank(alice);
        hooks.requestUnstake(950e18);
        assertEq(hooks.tierOf(alice), 0); // 50 < 100
        vm.expectRevert(ProjectTokenHooks.Locked.selector);
        hooks.withdraw();
        vm.warp(block.timestamp + 7 days);
        hooks.withdraw();
        vm.expectRevert(ProjectTokenHooks.ZeroAmount.selector);
        hooks.withdraw();
        vm.expectRevert(ProjectTokenHooks.InsufficientStake.selector);
        hooks.requestUnstake(51e18);
        vm.expectRevert(ProjectTokenHooks.ZeroAmount.selector);
        hooks.requestUnstake(0);
        vm.expectRevert(ProjectTokenHooks.ZeroAmount.selector);
        hooks.stake(0);
        vm.stopPrank();
        assertEq(book.balanceOf(alice), 950e18);
        assertEq(hooks.tiers().length, 2);
    }

    function test_feeSharingToStakers() public {
        _enable();
        _stake(alice, 300e18);
        _stake(bob, 100e18);
        usd.mint(address(fees), 1_000e6);
        fees.distribute(address(usd));
        assertEq(usd.balanceOf(treasury), 500e6);
        assertEq(hooks.pendingRewards(alice), 375e6);
        assertEq(hooks.pendingRewards(bob), 125e6);
        vm.prank(alice);
        hooks.claimRewards();
        assertEq(usd.balanceOf(alice), 10_000_000e6 + 375e6);
        vm.prank(alice);
        vm.expectRevert(ProjectTokenHooks.ZeroAmount.selector);
        hooks.claimRewards();
        // non-reward tokens all go to treasury
        rwa.mint(address(fees), 5e18);
        fees.distribute(address(rwa));
        assertEq(rwa.balanceOf(treasury), 5e18);
    }

    function test_notifyRequiresStakers() public {
        _enable();
        usd.mint(address(this), 1e6);
        usd.approve(address(hooks), 1e6);
        vm.expectRevert(ProjectTokenHooks.NoStakers.selector);
        hooks.notifyRewardAmount(1e6);
        vm.expectRevert(ProjectTokenHooks.ZeroAmount.selector);
        hooks.notifyRewardAmount(0);
    }

    function test_tiersValidation_andAdmin() public {
        vm.startPrank(gov);
        ProjectTokenHooks.Tier[] memory t = new ProjectTokenHooks.Tier[](2);
        t[0] = ProjectTokenHooks.Tier(100e18, 50);
        t[1] = ProjectTokenHooks.Tier(100e18, 60);
        vm.expectRevert(ProjectTokenHooks.BadTiers.selector);
        hooks.setTiers(t);
        t[1] = ProjectTokenHooks.Tier(200e18, 40);
        vm.expectRevert(ProjectTokenHooks.BadTiers.selector);
        hooks.setTiers(t);
        t[1] = ProjectTokenHooks.Tier(200e18, 501);
        vm.expectRevert(ProjectTokenHooks.BadTiers.selector);
        hooks.setTiers(t);
        vm.expectRevert(ProjectTokenHooks.BadTiers.selector);
        hooks.setTiers(new ProjectTokenHooks.Tier[](6));
        hooks.setTiming(1 days, 1 hours);
        vm.stopPrank();
        assertEq(hooks.unstakeCooldown(), 1 days);
        vm.prank(guardian);
        hooks.pause();
        vm.prank(gov);
        hooks.setProjectToken(address(book));
        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        hooks.stake(1);
        vm.prank(gov);
        hooks.unpause();
        vm.expectRevert(ProjectTokenHooks.ZeroAddress.selector);
        new ProjectTokenHooks(gov, guardian, address(0), 1, 1);
    }

    function test_stakerPriorityAccess() public {
        _enable();
        _stake(alice, 100e18);
        vm.warp(block.timestamp + 3 days);
        Types.CommonParams memory p = _common(100e18, 0);
        p.priorityTier = 3;
        p.priorityWindow = 1 days;
        (FixedPriceOffering o, OfferingEscrow e) = _createFixed(p, 1e6);
        _approve(alice, address(o));
        _approve(bob, address(o));
        vm.warp(p.startTime);
        vm.prank(alice);
        o.buy(1e18); // tier-1 KYC but $BOOK staker -> priority access
        vm.prank(bob);
        vm.expectRevert(OfferingBase.PriorityWindow.selector);
        o.buy(1e18);
    }

    function test_feeCollectorAdmin() public {
        vm.startPrank(gov);
        vm.expectRevert(FeeCollector.ZeroAddress.selector);
        fees.setTreasury(address(0));
        fees.setTreasury(alice);
        vm.expectRevert(FeeCollector.ShareTooHigh.selector);
        fees.setStakerShareBps(8_001);
        fees.setStakerShareBps(0);
        vm.stopPrank();
        vm.expectRevert(FeeCollector.ShareTooHigh.selector);
        new FeeCollector(gov, treasury, 9_000);
        vm.expectRevert(FeeCollector.ZeroAddress.selector);
        new FeeCollector(gov, address(0), 0);
    }
}

contract OracleTest is Base {
    function test_chainlinkAndManual() public {
        MockAggregator agg = new MockAggregator(1e8, 8);
        vm.startPrank(gov);
        oracle.setFeed(address(usd), address(agg), 1 days);
        oracle.setManualPrice(address(rwa), 105e16);
        vm.stopPrank();
        (uint256 px, uint256 ts) = oracle.getPrice(address(usd));
        assertEq(px, 1e18);
        assertEq(ts, block.timestamp);
        (px,) = oracle.getPrice(address(rwa));
        assertEq(px, 105e16);
        (uint256 p2,, uint8 src) = oracle.tryGetPrice(address(usd));
        assertEq(src, 1);
        assertEq(p2, 1e18);
        (,, src) = oracle.tryGetPrice(address(rwa));
        assertEq(src, 2);
        (,, src) = oracle.tryGetPrice(address(book));
        assertEq(src, 0);
        vm.expectRevert(OracleAdapter.NoPrice.selector);
        oracle.getPrice(address(book));

        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(OracleAdapter.StalePrice.selector);
        oracle.getPrice(address(usd));
        (,, src) = oracle.tryGetPrice(address(usd));
        assertEq(src, 3);

        agg.set(-1, block.timestamp);
        vm.expectRevert(OracleAdapter.BadAnswer.selector);
        oracle.getPrice(address(usd));

        MockAggregator hi = new MockAggregator(1e20, 20);
        vm.prank(gov);
        oracle.setFeed(address(book), address(hi), 1 days);
        (px,) = oracle.getPrice(address(book));
        assertEq(px, 1e18);
        (px,,) = oracle.tryGetPrice(address(book));
        assertEq(px, 1e18);
    }
}

contract TimelockTest is Base {
    function test_minDelayFloor() public {
        address[] memory a = new address[](1);
        a[0] = gov;
        vm.expectRevert(Timelock.DelayTooShort.selector);
        new Timelock(1 days, a, a);
    }

    function test_governedSetProjectTokenThroughTimelock() public {
        address[] memory proposers = new address[](1);
        proposers[0] = gov;
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        Timelock tl = new Timelock(48 hours, proposers, executors);
        ProjectTokenHooks h = new ProjectTokenHooks(address(tl), guardian, address(usd), 7 days, 3 days);
        bytes memory data = abi.encodeCall(ProjectTokenHooks.setProjectToken, (address(book)));
        vm.prank(gov);
        tl.schedule(address(h), 0, data, bytes32(0), bytes32(0), 48 hours);
        vm.expectRevert();
        tl.execute(address(h), 0, data, bytes32(0), bytes32(0));
        vm.warp(block.timestamp + 48 hours);
        tl.execute(address(h), 0, data, bytes32(0), bytes32(0)); // anyone executes
        assertEq(address(h.projectToken()), address(book));
        // direct call by the proposer is not possible
        vm.prank(gov);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, gov, bytes32(0))
        );
        h.setProjectToken(address(usd));
    }
}
