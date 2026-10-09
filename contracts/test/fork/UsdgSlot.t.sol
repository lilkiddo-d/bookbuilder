// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2, stdStorage, StdStorage} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Locates USDG's balance mapping slot (used by scripts/seed-fork.sh to fund fork wallets).
contract UsdgSlotTest is Test {
    using stdStorage for StdStorage;

    function test_fork_usdgBalanceSlot() public {
        vm.createSelectFork(vm.envOr("ROBINHOOD_RPC_URL", string("https://rpc.mainnet.chain.robinhood.com")));
        address usdg = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
        address who = address(0xBEEF);
        uint256 slot = stdstore.target(usdg).sig("balanceOf(address)").with_key(who).find();
        console2.log("slot");
        console2.logBytes32(bytes32(slot));
        for (uint256 i; i < 300; ++i) {
            if (keccak256(abi.encode(who, i)) == bytes32(slot)) {
                console2.log("mapping index", i);
                vm.store(usdg, bytes32(slot), bytes32(uint256(123)));
                assertEq(IERC20(usdg).balanceOf(who), 123);
                return;
            }
        }
        revert("not a simple mapping");
    }
}
