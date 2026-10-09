// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Types} from "../../src/interfaces/IBookbuilder.sol";
import {IssuerRegistry} from "../../src/IssuerRegistry.sol";
import {ComplianceRegistry} from "../../src/ComplianceRegistry.sol";
import {OfferingFactory} from "../../src/OfferingFactory.sol";
import {OfferingEscrow} from "../../src/OfferingEscrow.sol";
import {FixedPriceOffering} from "../../src/offerings/FixedPriceOffering.sol";
import {BatchAuction} from "../../src/offerings/BatchAuction.sol";
import {DutchAuction} from "../../src/offerings/DutchAuction.sol";
import {DeliveryVesting} from "../../src/DeliveryVesting.sol";
import {FeeCollector} from "../../src/FeeCollector.sol";
import {ProjectTokenHooks} from "../../src/ProjectTokenHooks.sol";
import {OracleAdapter} from "../../src/OracleAdapter.sol";
import {MockERC20} from "../mocks/Mocks.sol";

/// @notice Deploys the full protocol with `gov` standing in for the Timelock (Timelock covered separately).
abstract contract Base is Test {
    address internal gov = makeAddr("gov");
    address internal guardian = makeAddr("guardian");
    address internal treasury = makeAddr("treasury");
    address internal attestor = makeAddr("attestor");
    address internal issuer = makeAddr("issuer");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave");
    address internal eve = makeAddr("eve"); // never KYC'd

    MockERC20 internal usd; // 6 decimals, stands in for USDG
    MockERC20 internal rwa; // 18 decimals delivery token
    MockERC20 internal book; // mock $BOOK (tests only)

    IssuerRegistry internal issuers;
    ComplianceRegistry internal compliance;
    OfferingFactory internal factory;
    DeliveryVesting internal vesting;
    FeeCollector internal fees;
    ProjectTokenHooks internal hooks;
    OracleAdapter internal oracle;

    uint16 internal constant FEE_BPS = 100;
    uint256 internal constant UNIT = 1e18;

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        usd = new MockERC20("Global Dollar", "USDG", 6);
        rwa = new MockERC20("Acme Property SPV I", "ACME1", 18);
        book = new MockERC20("Mock BOOK", "mBOOK", 18);

        issuers = new IssuerRegistry(gov, guardian);
        compliance = new ComplianceRegistry(gov, guardian);
        fees = new FeeCollector(gov, treasury, 5_000);
        hooks = new ProjectTokenHooks(gov, guardian, address(usd), 7 days, 3 days);
        oracle = new OracleAdapter(gov);

        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 5);
        vesting = new DeliveryVesting(predicted);
        address escrowImpl = address(new OfferingEscrow());
        address fixedImpl = address(new FixedPriceOffering());
        address batchImpl = address(new BatchAuction());
        address dutchImpl = address(new DutchAuction());
        factory = new OfferingFactory(
            OfferingFactory.Config({
                admin: gov,
                guardian: guardian,
                issuerRegistry: address(issuers),
                compliance: address(compliance),
                feeCollector: address(fees),
                vesting: address(vesting),
                hooks: address(hooks),
                oracle: address(oracle),
                feeBps: FEE_BPS,
                escrowImpl: escrowImpl,
                fixedPriceImpl: fixedImpl,
                batchAuctionImpl: batchImpl,
                dutchAuctionImpl: dutchImpl
            })
        );
        require(address(factory) == predicted, "factory prediction");

        vm.startPrank(gov);
        factory.setPaymentToken(address(usd), true);
        fees.setHooks(address(hooks));
        compliance.grantRole(compliance.ATTESTOR_ROLE(), attestor);
        issuers.approveIssuer(issuer, address(rwa), "Acme Property SPV I LLC (DE 1234567)", "bafyissuerdocs");
        vm.stopPrank();

        _kyc(alice, 1, false);
        _kyc(bob, 1, false);
        _kyc(carol, 2, true);
        _kyc(dave, 3, true);

        address[5] memory investors = [alice, bob, carol, dave, eve];
        for (uint256 k; k < investors.length; ++k) {
            usd.mint(investors[k], 10_000_000e6);
        }
        rwa.mint(issuer, 100_000_000e18);
    }

    // ------------------------------------------------------------------ helpers

    function _kyc(address who, uint8 tier, bool accredited) internal {
        vm.prank(attestor);
        compliance.attest(who, tier, accredited, "GB", uint64(block.timestamp + 365 days));
    }

    function _common(uint256 supply, uint256 softCap) internal view returns (Types.CommonParams memory p) {
        p.saleToken = address(rwa);
        p.paymentToken = address(usd);
        p.supply = supply;
        p.softCap = softCap;
        p.perWalletMax = 0;
        p.startTime = uint64(block.timestamp + 1 hours);
        p.endTime = uint64(block.timestamp + 1 hours + 3 days);
        p.deliveryWindow = 7 days;
        p.compliance = Types.ComplianceRules({enabled: true, minTier: 1, requireAccredited: false});
        p.docsCID = "bafyofferingdocs";
    }

    function _createFixed(Types.CommonParams memory p, uint256 price)
        internal
        returns (FixedPriceOffering o, OfferingEscrow e)
    {
        vm.prank(issuer);
        (address oa, address ea) = factory.createFixedPrice(p, Types.FixedPriceParams({price: price}));
        o = FixedPriceOffering(oa);
        e = OfferingEscrow(ea);
    }

    function _batchParams() internal view returns (Types.BatchAuctionParams memory bp) {
        bp.minPrice = 1e6; // 1.00 USDG per token
        bp.tickSize = 1e4; // 0.01 USDG
        bp.numTicks = 200;
        bp.revealDuration = 1 days;
        bp.antiSnipeWindow = 10 minutes;
        bp.antiSnipeExtension = 10 minutes;
        bp.maxEndTime = uint64(block.timestamp + 1 hours + 4 days);
        bp.nonRevealPenaltyBps = 500;
        bp.maxBidders = 1000;
    }

    function _createBatch(Types.CommonParams memory p, Types.BatchAuctionParams memory bp)
        internal
        returns (BatchAuction o, OfferingEscrow e)
    {
        vm.prank(issuer);
        (address oa, address ea) = factory.createBatchAuction(p, bp);
        o = BatchAuction(oa);
        e = OfferingEscrow(ea);
    }

    function _createDutch(Types.CommonParams memory p, Types.DutchAuctionParams memory dp)
        internal
        returns (DutchAuction o, OfferingEscrow e)
    {
        vm.prank(issuer);
        (address oa, address ea) = factory.createDutchAuction(p, dp);
        o = DutchAuction(oa);
        e = OfferingEscrow(ea);
    }

    function _approve(address who, address spender) internal {
        vm.prank(who);
        usd.approve(spender, type(uint256).max);
    }

    function _commit(BatchAuction o, OfferingEscrow e, address who, uint16 tick, uint256 qty, uint256 extra)
        internal
        returns (bytes32 salt)
    {
        salt = keccak256(abi.encode(who, tick, qty, extra));
        bytes32 h = o.commitmentHash(who, tick, qty, salt);
        uint256 dep = _ceil(qty * o.priceAt(tick), UNIT) + extra;
        _approve(who, address(o));
        vm.prank(who);
        o.commit(h, dep);
    }

    function _reveal(BatchAuction o, address who, uint16 tick, uint256 qty, uint256 extra) internal {
        bytes32 salt = keccak256(abi.encode(who, tick, qty, extra));
        vm.prank(who);
        o.reveal(who, tick, qty, salt);
    }

    function _deliver(OfferingEscrow e) internal {
        uint256 t = e.tokensToDeliver();
        vm.startPrank(issuer);
        rwa.approve(address(e), t);
        e.deliver();
        vm.stopPrank();
    }

    function _ceil(uint256 a, uint256 d) internal pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / d + 1;
    }
}
