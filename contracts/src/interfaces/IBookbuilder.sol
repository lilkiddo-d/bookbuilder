// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Shared types used across Bookbuilder contracts.
library Types {
    enum OfferingKind {
        FixedPrice,
        BatchAuction,
        DutchAuction
    }

    /// @dev Lifecycle of an offering + its escrow.
    enum Stage {
        Active, // accepting participation (or awaiting start / reveal)
        Succeeded, // finalized successfully, awaiting issuer delivery
        Delivered, // issuer delivered tokens, payment released, investors may claim tokens
        Failed // soft cap missed, cancelled, or delivery deadline missed: full refunds
    }

    /// @notice Investor-eligibility rules an issuer picks per offering. ON by default.
    struct ComplianceRules {
        bool enabled; // must be true unless governance has disabled the mandatory flag on the factory
        uint8 minTier; // minimum ComplianceRegistry tier (1 = basic KYC)
        bool requireAccredited; // require accredited / professional investor flag
    }

    /// @notice Parameters common to every offering kind.
    struct CommonParams {
        address saleToken; // RWA token the issuer delivers (ERC-20 / ERC-3643 style)
        address paymentToken; // currency investors pay with (e.g. USDG)
        uint256 supply; // max tokens sold (sale-token base units) = hard cap
        uint256 softCap; // min tokens that must sell (sale-token base units); 0 = none
        uint256 perWalletMax; // max tokens per wallet (sale-token base units); 0 = no limit
        uint64 startTime;
        uint64 endTime; // end of participation (commit end for batch auctions)
        uint32 deliveryWindow; // seconds after finalization the issuer has to deliver
        uint64 vestingCliff; // seconds; vesting only if vestingDuration > 0
        uint64 vestingDuration; // seconds; 0 = tokens delivered liquid on claim
        uint8 priorityTier; // during the priority window only investors with tier >= priorityTier may join
        uint32 priorityWindow; // seconds from startTime; 0 = no priority window
        ComplianceRules compliance;
        string docsCID; // offering documents (IPFS CID)
    }

    struct FixedPriceParams {
        uint256 price; // payment-token base units per 1 whole sale token (10**saleDecimals units)
    }

    struct BatchAuctionParams {
        uint256 minPrice; // price of tick 0 (payment units per whole token); also the reserve
        uint256 tickSize; // price increment per tick
        uint16 numTicks; // number of price levels (bounded: <= MAX_TICKS)
        uint64 revealDuration; // reveal window length after commit end
        uint32 antiSnipeWindow; // commits in the last N seconds extend the commit end
        uint32 antiSnipeExtension; // by this many seconds
        uint64 maxEndTime; // hard ceiling for extensions
        uint16 nonRevealPenaltyBps; // slashed from deposits that are never revealed
        uint32 maxBidders; // bound on bidder count
    }

    struct DutchAuctionParams {
        uint256 startPrice; // payment units per whole token at startTime
        uint256 floorPrice; // price never drops below this
        uint64 decayDuration; // seconds from startTime until the floor is hit (<= endTime - startTime)
    }
}

interface IComplianceRegistry {
    function isEligible(address investor, Types.ComplianceRules calldata rules) external view returns (bool);
    function tierOf(address investor) external view returns (uint8);
}

interface IIssuerRegistry {
    function isApprovedIssuer(address issuer) external view returns (bool);
    function deliveryTokenOf(address issuer) external view returns (address);
}

interface IProjectTokenHooks {
    function isEnabled() external view returns (bool);
    /// @return bps of an auction's supply guaranteed to `account` at the clearing margin (0 when token features are off)
    function guaranteedBps(address account) external view returns (uint16);
    function notifyRewardAmount(uint256 amount) external;
    function rewardToken() external view returns (address);
    function totalStaked() external view returns (uint256);
}

interface IFactoryConfig {
    function paused() external view returns (bool);
    function compliance() external view returns (address);
    function feeCollector() external view returns (address);
    function vesting() external view returns (address);
    function hooks() external view returns (address);
    function isOffering(address) external view returns (bool);
    function isEscrow(address) external view returns (bool);
    function hasRole(bytes32 role, address account) external view returns (bool);
}

/// @notice What an escrow asks its offering at settlement time.
interface IOffering {
    function issuer() external view returns (address);
    function escrow() external view returns (address);
    /// @return tokens sale tokens owed to the investor
    /// @return cost payment tokens kept from the investor's deposit
    /// @return penalty payment tokens slashed (non-reveal); sent to the fee collector
    function settlementOf(address investor) external view returns (uint256 tokens, uint256 cost, uint256 penalty);
}

interface IOfferingEscrow {
    function recordDeposit(address investor, uint256 amount) external;
    function onFinalized(bool success, uint256 grossProceeds, uint256 tokensToDeliver) external;
    function depositOf(address investor) external view returns (uint256);
    function stage() external view returns (Types.Stage);
}

interface IDeliveryVesting {
    function createSchedule(
        address beneficiary,
        address token,
        uint256 amount,
        uint64 start,
        uint64 cliff,
        uint64 duration
    ) external returns (uint256 id);
}

interface IPriceOracle {
    /// @return price USD price with 18 decimals
    /// @return updatedAt timestamp of the underlying observation
    function getPrice(address token) external view returns (uint256 price, uint256 updatedAt);
}
