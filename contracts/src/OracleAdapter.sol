// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IPriceOracle} from "./interfaces/IBookbuilder.sol";

interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @title OracleAdapter
/// @notice Display-pricing adapter (USD, 18 decimals) over Chainlink feeds on Robinhood Chain.
///         Used by the frontend only; no settlement logic depends on it. Swappable on the factory.
///         Tokens without a feed (most RWA tokens) can be given a governance-set fallback price
///         (e.g. last published NAV) which is clearly flagged as `manual`.
contract OracleAdapter is AccessControl, IPriceOracle {
    struct Feed {
        address aggregator;
        uint32 maxStaleness;
    }

    struct ManualPrice {
        uint256 price; // 18 decimals
        uint64 updatedAt;
    }

    mapping(address => Feed) public feeds;
    mapping(address => ManualPrice) public manualPrices;

    event FeedSet(address indexed token, address aggregator, uint32 maxStaleness);
    event ManualPriceSet(address indexed token, uint256 price);

    error NoPrice();
    error StalePrice();
    error BadAnswer();

    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function setFeed(address token, address aggregator, uint32 maxStaleness) external onlyRole(DEFAULT_ADMIN_ROLE) {
        feeds[token] = Feed(aggregator, maxStaleness);
        emit FeedSet(token, aggregator, maxStaleness);
    }

    function setManualPrice(address token, uint256 price) external onlyRole(DEFAULT_ADMIN_ROLE) {
        manualPrices[token] = ManualPrice(price, uint64(block.timestamp));
        emit ManualPriceSet(token, price);
    }

    function getPrice(address token) external view returns (uint256 price, uint256 updatedAt) {
        Feed memory f = feeds[token];
        if (f.aggregator != address(0)) {
            (uint80 roundId, int256 answer, uint256 startedAt, uint256 ts, uint80 answeredInRound) =
                AggregatorV3Interface(f.aggregator).latestRoundData();
            if (answer <= 0 || startedAt > ts || answeredInRound < roundId) revert BadAnswer();
            if (block.timestamp - ts > f.maxStaleness) revert StalePrice();
            uint8 dec = AggregatorV3Interface(f.aggregator).decimals();
            price = dec <= 18 ? uint256(answer) * 10 ** (18 - dec) : uint256(answer) / 10 ** (dec - 18);
            return (price, ts);
        }
        ManualPrice memory m = manualPrices[token];
        if (m.price > 0) return (m.price, m.updatedAt);
        revert NoPrice();
    }

    /// @notice Non-reverting variant for UIs. `source`: 0 none, 1 chainlink, 2 manual, 3 stale chainlink.
    function tryGetPrice(address token) external view returns (uint256 price, uint256 updatedAt, uint8 source) {
        Feed memory f = feeds[token];
        if (f.aggregator != address(0)) {
            try AggregatorV3Interface(f.aggregator).latestRoundData() returns (
                uint80 roundId, int256 answer, uint256 startedAt, uint256 ts, uint80 answeredInRound
            ) {
                if (answer > 0 && startedAt <= ts && answeredInRound >= roundId) {
                    uint8 dec = AggregatorV3Interface(f.aggregator).decimals();
                    price = dec <= 18 ? uint256(answer) * 10 ** (18 - dec) : uint256(answer) / 10 ** (dec - 18);
                    return (price, ts, block.timestamp - ts > f.maxStaleness ? 3 : 1);
                }
            } catch {}
        }
        ManualPrice memory m = manualPrices[token];
        if (m.price > 0) return (m.price, m.updatedAt, 2);
        return (0, 0, 0);
    }
}
