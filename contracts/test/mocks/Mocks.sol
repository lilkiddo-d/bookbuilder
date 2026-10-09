// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice TEST-ONLY token. Used as payment token, RWA delivery token and mock $BOOK in tests.
contract MockERC20 is ERC20 {
    uint8 private immutable _dec;

    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) {
        _dec = d;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice TEST-ONLY fee-on-transfer token (1% burn) to prove such tokens are rejected.
contract MockFeeToken is MockERC20 {
    constructor() MockERC20("Fee", "FEE", 18) {}

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = value / 100;
            super._update(from, address(0), fee);
            value -= fee;
        }
        super._update(from, to, value);
    }
}

/// @notice TEST-ONLY Chainlink-style aggregator.
contract MockAggregator {
    int256 public answer;
    uint256 public updatedAt;
    uint8 public decimals;

    constructor(int256 a, uint8 d) {
        answer = a;
        decimals = d;
        updatedAt = block.timestamp;
    }

    function set(int256 a, uint256 ts) external {
        answer = a;
        updatedAt = ts;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, updatedAt, updatedAt, 1);
    }
}

/// @notice TEST-ONLY token that tries to re-enter the escrow on transfer.
interface IReenterTarget {
    function settle(address) external;
}

contract MockReentrantToken is MockERC20 {
    address public target;
    address public victim;

    constructor() MockERC20("Re", "RE", 18) {}

    function arm(address t, address v) external {
        target = t;
        victim = v;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (target != address(0) && from == target) {
            address t = target;
            target = address(0);
            IReenterTarget(t).settle(victim);
        }
    }
}
