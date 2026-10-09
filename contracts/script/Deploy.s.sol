// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

import {Timelock} from "../src/Timelock.sol";
import {IssuerRegistry} from "../src/IssuerRegistry.sol";
import {ComplianceRegistry} from "../src/ComplianceRegistry.sol";
import {OfferingFactory} from "../src/OfferingFactory.sol";
import {OfferingEscrow} from "../src/OfferingEscrow.sol";
import {FixedPriceOffering} from "../src/offerings/FixedPriceOffering.sol";
import {BatchAuction} from "../src/offerings/BatchAuction.sol";
import {DutchAuction} from "../src/offerings/DutchAuction.sol";
import {DeliveryVesting} from "../src/DeliveryVesting.sol";
import {FeeCollector} from "../src/FeeCollector.sol";
import {ProjectTokenHooks} from "../src/ProjectTokenHooks.sol";
import {OracleAdapter} from "../src/OracleAdapter.sol";

/// @notice Robinhood Chain mainnet constants. Sources in config/chains.ts.
library RobinhoodChain {
    uint256 internal constant CHAIN_ID = 4663;
    /// Paxos Global Dollar (USDG), 6 decimals - https://docs.robinhood.com/chain/contracts
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    /// Canonical L2 WETH - https://docs.robinhood.com/chain/contracts
    address internal constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    /// Chainlink proxies - https://docs.chain.link/data-feeds/price-feeds/addresses?network=robinhood
    address internal constant FEED_USDG_USD = 0x61B7e5650328764B076A108EFF5fa7282a1B9aD2;
    address internal constant FEED_ETH_USD = 0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9;
}

/// @title Deploy
/// @notice Deploys and wires the whole protocol, hands every admin role to the 48h Timelock,
///         and writes deployments/<chainId>.json + app/public/deployments/<chainId>.json.
///         Creates NO offerings and approves NO issuers.
///
///  Mainnet:  forge script script/Deploy.s.sol --rpc-url robinhood --account bookbuilder-deployer \
///              --sender <deployer> --broadcast --verify --verifier blockscout \
///              --verifier-url https://robinhoodchain.blockscout.com/api/
///  Optional env: GOV_PROPOSER, GUARDIAN, TREASURY, KYC_ATTESTOR, FEE_BPS, STAKER_SHARE_BPS, TIMELOCK_DELAY
contract Deploy is Script {
    struct Params {
        address deployer;
        address proposer; // may schedule Timelock operations (use a Safe multisig)
        address guardian; // may pause / suspend / cancel instantly (use a Safe multisig)
        address treasury; // receives protocol fees
        address attestor; // optional KYC attestor granted at deploy (address(0) = none)
        address paymentToken; // USDG
        address weth;
        address feedPayment;
        address feedWeth;
        uint16 feeBps;
        uint16 stakerShareBps;
        uint256 timelockDelay;
    }

    struct Deployment {
        Timelock timelock;
        IssuerRegistry issuerRegistry;
        ComplianceRegistry compliance;
        OfferingFactory factory;
        DeliveryVesting vesting;
        FeeCollector feeCollector;
        ProjectTokenHooks hooks;
        OracleAdapter oracle;
        address escrowImpl;
        address fixedImpl;
        address batchImpl;
        address dutchImpl;
    }

    error UnsupportedChain(uint256 chainId);
    error PaymentTokenMissing();
    error PredictionMismatch();

    function run() external returns (Deployment memory d) {
        Params memory p = loadParams(msg.sender);
        vm.startBroadcast(p.deployer);
        d = deploy(p);
        vm.stopBroadcast();
        _log(d, p);
        _write(d, p);
    }

    function loadParams(address deployer) public view returns (Params memory p) {
        uint256 id = block.chainid;
        // 4663 = Robinhood Chain mainnet; 31337 = local anvil fork of mainnet (same contract state)
        if (id != RobinhoodChain.CHAIN_ID && id != 31337) revert UnsupportedChain(id);
        if (RobinhoodChain.USDG.code.length == 0) revert PaymentTokenMissing(); // anvil must be a mainnet fork
        p.deployer = deployer;
        p.proposer = vm.envOr("GOV_PROPOSER", deployer);
        p.guardian = vm.envOr("GUARDIAN", deployer);
        p.attestor = vm.envOr("KYC_ATTESTOR", address(0));
        p.paymentToken = RobinhoodChain.USDG;
        p.weth = RobinhoodChain.WETH;
        p.feedPayment = RobinhoodChain.FEED_USDG_USD;
        p.feedWeth = RobinhoodChain.FEED_ETH_USD;
        p.feeBps = uint16(vm.envOr("FEE_BPS", uint256(100)));
        p.stakerShareBps = uint16(vm.envOr("STAKER_SHARE_BPS", uint256(5_000)));
        p.timelockDelay = vm.envOr("TIMELOCK_DELAY", uint256(48 hours));
        p.treasury = vm.envOr("TREASURY", address(0)); // 0 => Timelock-controlled treasury (FeeCollector -> Timelock)
    }

    /// @dev All calls here are broadcast by the deployer. Public so fork tests can reuse it under vm.prank.
    function deploy(Params memory p) public returns (Deployment memory d) {
        address dep = p.deployer;

        address[] memory proposers = new address[](1);
        proposers[0] = p.proposer;
        address[] memory executors = new address[](1);
        executors[0] = address(0); // anyone may execute a matured operation
        d.timelock = new Timelock(p.timelockDelay, proposers, executors);
        address treasury = p.treasury == address(0) ? address(d.timelock) : p.treasury;

        d.issuerRegistry = new IssuerRegistry(dep, p.guardian);
        d.compliance = new ComplianceRegistry(dep, p.guardian);
        d.feeCollector = new FeeCollector(dep, treasury, p.stakerShareBps);
        d.hooks = new ProjectTokenHooks(dep, p.guardian, p.paymentToken, 7 days, 3 days);
        d.oracle = new OracleAdapter(dep);

        d.escrowImpl = address(new OfferingEscrow());
        d.fixedImpl = address(new FixedPriceOffering());
        d.batchImpl = address(new BatchAuction());
        d.dutchImpl = address(new DutchAuction());

        // vesting needs the factory address and the factory needs vesting: predict the factory address
        address predictedFactory = vm.computeCreateAddress(dep, vm.getNonce(dep) + 1);
        d.vesting = new DeliveryVesting(predictedFactory);
        d.factory = new OfferingFactory(
            OfferingFactory.Config({
                admin: dep,
                guardian: p.guardian,
                issuerRegistry: address(d.issuerRegistry),
                compliance: address(d.compliance),
                feeCollector: address(d.feeCollector),
                vesting: address(d.vesting),
                hooks: address(d.hooks),
                oracle: address(d.oracle),
                feeBps: p.feeBps,
                escrowImpl: d.escrowImpl,
                fixedPriceImpl: d.fixedImpl,
                batchAuctionImpl: d.batchImpl,
                dutchAuctionImpl: d.dutchImpl
            })
        );
        if (address(d.factory) != predictedFactory) revert PredictionMismatch();

        // ---- wiring (done by deployer before handoff)
        d.factory.setPaymentToken(p.paymentToken, true);
        d.feeCollector.setHooks(address(d.hooks));
        d.oracle.setFeed(p.paymentToken, p.feedPayment, 25 hours);
        d.oracle.setFeed(p.weth, p.feedWeth, 25 hours);

        ProjectTokenHooks.Tier[] memory tiers = new ProjectTokenHooks.Tier[](3);
        tiers[0] = ProjectTokenHooks.Tier({minStake: 1_000e18, guaranteedBps: 25});
        tiers[1] = ProjectTokenHooks.Tier({minStake: 10_000e18, guaranteedBps: 75});
        tiers[2] = ProjectTokenHooks.Tier({minStake: 100_000e18, guaranteedBps: 200});
        d.hooks.setTiers(tiers);

        // comprehensively sanctioned jurisdictions blocked by default (governance can change)
        d.compliance.setCountryBlocked("CU", true);
        d.compliance.setCountryBlocked("IR", true);
        d.compliance.setCountryBlocked("KP", true);
        d.compliance.setCountryBlocked("SY", true);
        if (p.attestor != address(0)) d.compliance.grantRole(d.compliance.ATTESTOR_ROLE(), p.attestor);

        // ---- hand every admin role to the Timelock, then renounce
        _handoff(AccessControl(address(d.issuerRegistry)), address(d.timelock), dep);
        _handoff(AccessControl(address(d.compliance)), address(d.timelock), dep);
        _handoff(AccessControl(address(d.feeCollector)), address(d.timelock), dep);
        _handoff(AccessControl(address(d.hooks)), address(d.timelock), dep);
        _handoff(AccessControl(address(d.oracle)), address(d.timelock), dep);
        _handoff(AccessControl(address(d.factory)), address(d.timelock), dep);
    }

    function _handoff(AccessControl c, address timelock, address dep) internal {
        c.grantRole(0x00, timelock);
        c.renounceRole(0x00, dep);
    }

    // ------------------------------------------------------------------ output

    function _log(Deployment memory d, Params memory p) internal pure {
        console2.log("Timelock          ", address(d.timelock));
        console2.log("IssuerRegistry    ", address(d.issuerRegistry));
        console2.log("ComplianceRegistry", address(d.compliance));
        console2.log("OfferingFactory   ", address(d.factory));
        console2.log("DeliveryVesting   ", address(d.vesting));
        console2.log("FeeCollector      ", address(d.feeCollector));
        console2.log("ProjectTokenHooks ", address(d.hooks));
        console2.log("OracleAdapter     ", address(d.oracle));
        console2.log("Guardian          ", p.guardian);
        console2.log("Gov proposer      ", p.proposer);
        if (p.proposer == p.deployer || p.guardian == p.deployer) {
            console2.log("WARNING: proposer/guardian default to the deployer. Set GOV_PROPOSER / GUARDIAN to Safe multisigs.");
        }
    }

    function _write(Deployment memory d, Params memory p) internal {
        string memory c = "contracts";
        vm.serializeAddress(c, "Timelock", address(d.timelock));
        vm.serializeAddress(c, "IssuerRegistry", address(d.issuerRegistry));
        vm.serializeAddress(c, "ComplianceRegistry", address(d.compliance));
        vm.serializeAddress(c, "OfferingFactory", address(d.factory));
        vm.serializeAddress(c, "DeliveryVesting", address(d.vesting));
        vm.serializeAddress(c, "FeeCollector", address(d.feeCollector));
        vm.serializeAddress(c, "ProjectTokenHooks", address(d.hooks));
        vm.serializeAddress(c, "OracleAdapter", address(d.oracle));
        vm.serializeAddress(c, "OfferingEscrowImpl", d.escrowImpl);
        vm.serializeAddress(c, "FixedPriceOfferingImpl", d.fixedImpl);
        vm.serializeAddress(c, "BatchAuctionImpl", d.batchImpl);
        string memory contractsJson = vm.serializeAddress(c, "DutchAuctionImpl", d.dutchImpl);

        string memory pt = "paymentTokens";
        string memory paymentJson = vm.serializeAddress(pt, "USDG", p.paymentToken);

        string memory r = "root";
        vm.serializeUint(r, "chainId", block.chainid);
        vm.serializeString(r, "network", block.chainid == RobinhoodChain.CHAIN_ID ? "robinhood-mainnet" : "robinhood-fork");
        vm.serializeUint(r, "blockNumber", vm.getBlockNumber()); // block.number is L1-style on Arbitrum chains
        vm.serializeAddress(r, "deployer", p.deployer);
        vm.serializeAddress(r, "guardian", p.guardian);
        vm.serializeAddress(r, "govProposer", p.proposer);
        vm.serializeAddress(r, "treasury", d.feeCollector.treasury());
        vm.serializeUint(r, "timelockDelay", p.timelockDelay);
        vm.serializeString(r, "paymentTokens", paymentJson);
        string memory json = vm.serializeString(r, "contracts", contractsJson);

        string memory id = vm.toString(block.chainid);
        if (vm.isContext(VmSafe.ForgeContext.ScriptDryRun)) {
            // simulation only: never overwrite real deployment files with simulated addresses
            vm.writeJson(json, string.concat(vm.projectRoot(), "/../deployments/", id, ".dryrun.json"));
            console2.log("Dry run: wrote deployments/", string.concat(id, ".dryrun.json"));
            return;
        }
        vm.writeJson(json, string.concat(vm.projectRoot(), "/../deployments/", id, ".json"));
        vm.writeJson(json, string.concat(vm.projectRoot(), "/../app/public/deployments/", id, ".json"));
        console2.log("Wrote deployments/<chainId>.json and app/public/deployments/<chainId>.json for chain", block.chainid);
    }
}
