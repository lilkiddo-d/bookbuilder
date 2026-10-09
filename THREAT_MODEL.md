# Threat model

## Assets
- Investor payment tokens (USDG) held in each `OfferingEscrow`.
- RWA tokens delivered by issuers into escrow / `DeliveryVesting`.
- Protocol fees and penalties in `FeeCollector`; $BOOK stakes and rewards in `ProjectTokenHooks`.
- Protocol configuration: every admin role is held by the 48h `Timelock`.

## Actors and trust
| Actor | Trust | Powers |
|---|---|---|
| Governance (Timelock, proposers = Safe multisig) | Trusted, but delayed 48h | Approve or suspend issuers, set fees (≤5%), set implementations for *future* offerings, unpause, grant attestors, set the project token once. **Cannot move escrowed funds.** |
| Guardian (Safe multisig) | Semi-trusted, acts instantly | Pause new money-in, suspend issuers, freeze investors, cancel an offering before delivery (which triggers refunds). **Cannot move funds or unpause.** |
| KYC attestor | Semi-trusted | Write or revoke eligibility attestations. A rogue attestor can admit ineligible wallets; it can't touch funds. |
| Issuer | Untrusted beyond its approval | Create offerings for its registered token, deliver, cancel while live, update docs. |
| Investors, keeper, anyone | Untrusted | Participate; anyone may finalize, mark delivery failed, `settle(investor)` (pays only the investor), sweep. |

## Top risks and mitigations

### 1. Issuer rug: raise, then no delivery
- **No payment before delivery.** USDG is released only inside `deliver()`, in the same transaction where the escrow receives the *full* `tokensToDeliver`, checked by exact balance delta. The invariant test `invariant_noReleaseBeforeDelivery` proves `releasedToIssuer == 0` until stage `Delivered`.
- **Hard delivery deadline.** `deliveryDeadline = finalizedAt + deliveryWindow` (1–180 days). After it passes, *anyone* (the keeper does this automatically) calls `markDeliveryFailed()` and every investor can `settle()` for a full refund. Partial early refunds of excess are reconciled exactly (`Refunds`).
- **Guardian cancel.** If fraud is discovered before delivery, the guardian cancels instantly, without waiting 48h, and refunds open.
- **Issuer vetting.** Only governance-approved issuers (with a public 48h window to object) can create offerings. The sale token must equal the token recorded in `IssuerRegistry`. The guardian can suspend an issuer immediately.
- **Fake-delivery tokens.** Fee-on-transfer or short-transferring tokens can't satisfy the exact-delta check (tested). A worthless token that *is* delivered is outside on-chain control; that is covered by issuer due diligence, the legal documents (CIDs on-chain) and the risk disclosure.
- **Residual risk.** After a legitimate delivery, the RWA token's off-chain backing is the issuer's legal obligation. ERC-3643 tokens can be frozen by their agent; the issuer must whitelist the escrow and vesting contracts, otherwise delivery reverts and refunds follow.

### 2. Bid manipulation and non-reveal griefing (batch auction)
- **Sealed bids.** Commitments are `keccak(chainid, auction, bidder, tick, qty, salt)`: they can't be replayed across chains, auctions or bidders. Deposits may exceed the bid to hide its size.
- **Non-reveal griefing.** Committing to inflate apparent demand and then withholding costs `nonRevealPenaltyBps` (≤20%) of the deposit, paid to the fee collector. Unrevealed bids never count toward clearing, so they can't move the price. The penalty is waived only on a cancellation before finalization, which isn't the bidder's fault.
- **Under-collateralized bids.** At reveal, the deposit must cover `qty × price(tick)`, so a revealed bid is always fully funded.
- **Sniping.** Commits in the last `antiSnipeWindow` extend the commit end, capped by `maxEndTime`, so the auction always ends.
- **Clearing correctness.** A single bounded walk over ≤400 ticks; fuzzed against a brute-force O(n²) reference on random bid sets (`testFuzz_clearingMatchesReference`, 512 runs/CI 5000).
- **Never pay above your bid.** Clearing tick ≤ your tick, and cost = ceil(fill × clearingPrice) ≤ ceil(fill × bidPrice) (fuzz property).
- **Rounding insolvency.** Marginal fills round down and issuer proceeds use a conservative lower bound, so Σ costs ≥ proceeds. Full-settlement fuzzing shows escrow dust ≤ number of bidders, swept to the issuer only after everyone has settled.
- **Reveal-phase pause.** Pause never blocks reveal, settle or refunds, so a pause can't push anyone into a penalty.

### 3. Sybil allocation farming
- **KYC gate on by default.** Every buy and commit checks `ComplianceRegistry` (tier, expiry, freeze, blocked country, accreditation). Splitting across wallets needs a separate verified identity per wallet; attestors must enforce one person per identity.
- **Per-wallet cap** (`perWalletMax`) on purchases and on revealed bid size.
- **$BOOK guarantees can't be farmed.** Stake must age 3 days before it counts, and any top-up restarts the clock. Unstaking starts a 7-day cooldown and drops the tier *immediately*, so the same tokens can't back two wallets in one auction. Guarantees are bps of supply per wallet (≤5%), shared pro-rata if they exceed the marginal supply. Splitting a stake across wallets lands in lower tiers, and each wallet still needs KYC.
- **Priority window** limits early access to higher-tier investors and stakers.

## Other risks
| Risk | Mitigation |
|---|---|
| Reentrancy (malicious ERC-20 / ERC-3643 hooks) | `nonReentrant` on every state-changing entrypoint (escrow, offerings, factory create, vesting, hooks, fee collector), CEI ordering; tested with a token that re-enters `settle`. |
| Unbounded loops / DoS | Clearing loops over ≤400 ticks; listings are paginated; per-investor settlement is O(1); bidders capped by `maxBidders`. Keeper work is per-tx bounded (`KEEPER_MAX_TX`). |
| Admin key compromise | 48h Timelock on every admin action; the guardian can only pause or cancel (both favour refunds); governance can't withdraw escrow funds; new implementations only affect future offerings. |
| Guardian compromise | Worst case: pausing new offerings or cancelling not-yet-delivered offerings (investors are refunded). Governance replaces the guardian. |
| Oracle manipulation | `OracleAdapter` is display-only. No settlement path reads it. Staleness and round-completeness checks; a stale feed is flagged in `tryGetPrice`. |
| Payment token depeg or blacklist | USDG (Paxos) can freeze addresses. A frozen escrow would trap funds: an issuer-independent, off-chain risk, disclosed. The allow-list keeps payment tokens to vetted stablecoins. |
| Timestamp manipulation | Arbitrum sequencer timestamps drift by seconds; every window is hours or days. |
| Initializer front-running | Clones are created and initialized in one factory transaction; implementations call `_disableInitializers()` (tested). |
| Front-running buys (fixed / Dutch) | Fixed price is FCFS by design; Dutch has a `maxCost` slippage guard. |
| Loss of bid salt | Frontend stores the secret before sending the commit and offers a JSON backup; the penalty is bounded at ≤20%. |

## Static analysis
- Slither 0.11.6 with all 102 detectors: **0 high, 0 medium**. The remaining low/informational items (timestamp comparisons, event-after-call ordering in factory create, zero-checks on intentionally nullable `setHooks`/`setOracle`) were reviewed and accepted. Run it with `pnpm --filter @bookbuilder/contracts slither`.

## Out of scope / residual
- Legal enforceability of the RWA claim, issuer solvency, NAV accuracy and the KYC provider's quality.
- Not audited by a third party. Get an independent audit before real capital is raised.
