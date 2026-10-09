// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {Types} from "../src/interfaces/IBookbuilder.sol";
import {Timelock} from "../src/Timelock.sol";
import {IssuerRegistry} from "../src/IssuerRegistry.sol";
import {ComplianceRegistry} from "../src/ComplianceRegistry.sol";
import {OfferingFactory} from "../src/OfferingFactory.sol";
import {FixedPriceOffering} from "../src/offerings/FixedPriceOffering.sol";
import {BatchAuction} from "../src/offerings/BatchAuction.sol";
import {MockERC20} from "../test/mocks/Mocks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice LOCAL FORK ONLY (chain 31337). Seeds demo data so the frontend can be exercised end-to-end.
///         Never runs on mainnet: no real issuer is approved and no real offering created by this repo.
///         Driven by scripts/seed-fork.sh, which advances anvil time past the 48h Timelock delay.
contract SeedFork is Script {
    // anvil's well-known default accounts (public addresses only; anvil keeps them unlocked)
    address constant GOV = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266; // deployer = proposer = guardian = attestor
    address constant ISSUER = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    address constant INVESTOR_A = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;
    address constant INVESTOR_B = 0x90F79bf6EB2c4f870365E785982E1f101E93b906;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    error OnlyLocalFork();

    modifier onlyFork() {
        if (block.chainid != 31337) revert OnlyLocalFork();
        _;
    }

    function _addr(string memory key) internal view returns (address) {
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/../deployments/31337.json"));
        return vm.parseJsonAddress(json, string.concat(".contracts.", key));
    }

    function _demoToken() internal view returns (address) {
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/../deployments/31337.demo.json"));
        return vm.parseJsonAddress(json, ".demoRwa");
    }

    function _approveData(address rwa) internal pure returns (bytes memory) {
        return abi.encodeCall(
            IssuerRegistry.approveIssuer,
            (ISSUER, rwa, "Demo Harbor Street SPV I LLC (Delaware, demo only)", "bafybeidemoissuerdocsharborstreetspv")
        );
    }

    /// Step 1 (sender GOV): deploy a demo RWA token and schedule the issuer approval on the Timelock.
    function schedule() external onlyFork {
        vm.startBroadcast(GOV);
        MockERC20 rwa = new MockERC20("Harbor Street SPV I (demo)", "HSPV1", 18);
        rwa.mint(ISSUER, 10_000_000e18);
        Timelock(payable(_addr("Timelock"))).schedule(
            _addr("IssuerRegistry"), 0, _approveData(address(rwa)), bytes32(0), bytes32("seed"), 48 hours
        );
        vm.stopBroadcast();
        vm.writeJson(
            vm.serializeAddress("demo", "demoRwa", address(rwa)),
            string.concat(vm.projectRoot(), "/../deployments/31337.demo.json")
        );
        console2.log("demo RWA", address(rwa));
    }

    /// Step 2 (sender GOV, after 48h): execute the approval and KYC the demo investors.
    function execute() external onlyFork {
        address rwa = _demoToken();
        vm.startBroadcast(GOV);
        Timelock(payable(_addr("Timelock"))).execute(
            _addr("IssuerRegistry"), 0, _approveData(rwa), bytes32(0), bytes32("seed")
        );
        ComplianceRegistry c = ComplianceRegistry(_addr("ComplianceRegistry"));
        uint64 exp = uint64(block.timestamp + 365 days);
        c.attest(INVESTOR_A, 2, true, "SG", exp);
        c.attest(INVESTOR_B, 1, false, "GB", exp);
        vm.stopBroadcast();
    }

    /// Step 3 (sender ISSUER): create one offering of each kind.
    function offerings() external onlyFork {
        address rwa = _demoToken();
        OfferingFactory f = OfferingFactory(_addr("OfferingFactory"));
        Types.CommonParams memory p;
        p.saleToken = rwa;
        p.paymentToken = USDG;
        p.supply = 100_000e18;
        p.softCap = 10_000e18;
        p.perWalletMax = 50_000e18;
        p.startTime = uint64(block.timestamp + 1 hours); // margin: broadcast may land minutes after simulation
        p.endTime = uint64(block.timestamp + 7 days);
        p.deliveryWindow = 14 days;
        p.compliance = Types.ComplianceRules(true, 1, false);
        p.docsCID = "bafybeidemoofferingmemorandumharbor";

        vm.startBroadcast(ISSUER);
        f.createFixedPrice(p, Types.FixedPriceParams({price: 10e6}));
        f.createBatchAuction(
            p,
            Types.BatchAuctionParams({
                minPrice: 9e6,
                tickSize: 0.05e6,
                numTicks: 60,
                revealDuration: 2 days,
                antiSnipeWindow: 15 minutes,
                antiSnipeExtension: 15 minutes,
                maxEndTime: p.endTime + 1 days,
                nonRevealPenaltyBps: 300,
                maxBidders: 10_000
            })
        );
        Types.CommonParams memory d = p;
        d.startTime = uint64(block.timestamp + 3 days); // upcoming
        d.endTime = uint64(block.timestamp + 10 days);
        d.vestingCliff = 30 days;
        d.vestingDuration = 180 days;
        f.createDutchAuction(d, Types.DutchAuctionParams({startPrice: 15e6, floorPrice: 8e6, decayDuration: 5 days}));
        vm.stopBroadcast();
    }

    /// Step 4 (sender INVESTOR_A, after start): some live demand.
    function activity() external onlyFork {
        OfferingFactory f = OfferingFactory(_addr("OfferingFactory"));
        address[] memory list = f.offerings(0, 3);
        FixedPriceOffering fixedO = FixedPriceOffering(list[0]);
        BatchAuction batch = BatchAuction(list[1]);
        vm.startBroadcast(INVESTOR_A);
        IERC20(USDG).approve(address(fixedO), 120_000e6);
        fixedO.buy(12_000e18);
        bytes32 salt = keccak256("demo-salt-investor-a");
        bytes32 h = batch.commitmentHash(INVESTOR_A, 30, 20_000e18, salt); // 20k @ 10.50
        IERC20(USDG).approve(address(batch), 210_000e6);
        batch.commit(h, 210_000e6);
        vm.stopBroadcast();
    }
}
