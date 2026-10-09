# DECISIONS

Each entry gives the choice made and one line of reasoning.

## Chain and addresses
- **Target: Robinhood Chain mainnet, chain ID 4663, gas token ETH.** Taken from docs.robinhood.com/chain/connecting and confirmed with `eth_chainId` = `0x1237`.
- **Payment token: USDG (`0x5fc5…d168`, 6 decimals).** It is the only stablecoin in Robinhood's official token list; `symbol()` and `decimals()` were checked on-chain.
- **USDC/USDT are not configured.** Chainlink has USDC/USD and USDT/USD feeds on the chain, but Robinhood's docs publish no official token address for either, so none was guessed (`OfferingFactory.setPaymentToken` can add one later through the Timelock).
- **Oracle: Chainlink.** It is the provider named in Robinhood's docs. Feed proxies come from Chainlink's directory and were checked with `description()` and `latestRoundData()`.
- **Gap: there are no oracle feeds for arbitrary RWA tokens.** `OracleAdapter` takes a governance-set manual NAV price, flagged `source = 2`, and is display-only.
- **Contract verification: Blockscout** (`--verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/`), as documented in deploy-smart-contracts.
- **EVM version: `cancun`.** Robinhood Chain is an Arbitrum Orbit chain with Cancun support; this avoids depending on newer opcodes.
- **Local fork uses chain ID 31337, not 4663.** Wallets and deployment files then can't confuse fork addresses with real mainnet addresses.

## Architecture
- **Offerings and escrows are EIP-1167 clones.** This gives cheap per-offering deployment and keeps the factory under the size limit; implementations are passed into the factory constructor to stay under the initcode limit.
- **One escrow per offering; offerings never hold funds.** This isolates offerings from each other and makes the "balance == raised funds" invariant checkable per escrow.
- **Investors approve the *offering*, which pulls from `msg.sender` into the escrow; the escrow checks receipt (`recordDeposit`).** This fixes Slither's arbitrary-`from` finding structurally; issuers still approve the escrow for `deliver()`.
- **Fee-on-transfer and rebasing tokens are rejected (exact-receipt checks).** Accounting is exact, and an RWA token that taxes transfers would break investor entitlements.
- **`Refunds` is a separate abstract module that `OfferingEscrow` inherits, not a standalone contract.** Refund rules live in one reviewable place without another trust boundary or extra token hops.
- **Payment and delivery are atomic in `deliver()`.** The issuer receives USDG in the same transaction that the full token amount lands in escrow, so delivery and payment cannot happen one without the other.
- **The investor can claim refunds of excess deposit right after finalization; tokens are claimable after delivery.** Over-bidders don't wait out the delivery window to get unused funds back.
- **`settle(investor)` is permissionless.** Assets only ever go to the investor (or penalties to the fee collector), so the keeper can push refunds.
- **`sweep()` sends rounding dust to the issuer only after every participant has settled.** It is bounded and can't touch funds that are still owed.

## Auction mechanics
- **Bids use a bounded price-tick grid (≤ 400 ticks) instead of off-chain sorted hints.** Clearing is one bounded loop over ticks with no per-bid loops, so the number of bidders is unbounded for gas purposes (capped by `maxBidders` only to limit state growth).
- **Clearing price = the highest tick whose cumulative demand (at or above it) reaches supply** (the lowest price that fills the book). If undersubscribed, the clearing price is the lowest revealed tick. This is standard uniform-price practice, and the fuzz tests check it against a brute-force reference.
- **Pro-rata at the margin rounds down per bid.** Issuer proceeds use a conservative lower bound (one unit subtracted per marginal bid), which keeps the escrow provably solvent; dust is swept.
- **One sealed bid per wallet, replaceable during the commit window.** This keeps per-wallet caps simple; deposits can exceed the bid to hide its size.
- **The commit hash binds `chainid`, the auction address and the bidder.** Commitments can't be replayed across auctions, chains or wallets.
- **Non-reveal penalty: `nonRevealPenaltyBps` (≤ 20%) of the deposit goes to the fee collector, and the rest is refunded.** It deters griefing without confiscating funds; it is waived if the offering is cancelled before finalization.
- **Anti-sniping: a commit inside the last `antiSnipeWindow` extends the commit end, up to a hard `maxEndTime`.** The extension is bounded so the auction always ends.
- **Dutch auction: price decays linearly to the floor over `decayDuration`, then holds; buyers pay the current price** (pay-as-you-go, with a `maxCost` slippage guard). Allocation is exact and immediate, which avoids clearing rounding entirely.
- **Fixed price: first-come-first-served up to the hard cap (= supply).** If the soft cap is missed, everyone gets a full refund.
- **Prices are expressed as payment units per 1 whole sale token (`10**decimals`)**, with cost rounded up. This works for 0-decimal ERC-3643 tokens as well as 18-decimal tokens.

## Allocation, compliance, Sybil resistance
- **Compliance is on by default and enforced by the factory (`complianceMandatory = true`).** Only governance can turn it off; the issuer picks `minTier` and accredited-only.
- **`ComplianceRegistry` stores only tier, accreditation flag, country code and expiry, with no PII.** Attestations come from KYC-provider attestors.
- **Comprehensively sanctioned jurisdictions (CU, IR, KP, SY) are blocked at deploy.** This is a sane default that governance can change.
- **Allowlist tiers are implemented as a priority window.** For the first `priorityWindow` seconds, only investors with compliance tier ≥ `priorityTier` or a $BOOK stake can participate.
- **Staking guarantees are a bps-of-supply slot per wallet at the clearing margin,** filled before the pro-rata remainder. Stake must age 3 days, and unstaking has a 7-day cooldown with immediate tier loss, so stake can't be flash-staked or re-used across wallets.

## Governance and safety
- **All admin roles go to a `Timelock` (OZ TimelockController) with a 48h minimum enforced in its constructor.** This was required by the spec, and every change becomes visible before it executes.
- **Timelock executors are open (`address(0)`).** Matured operations can't be blocked by a missing executor; proposers are the gate.
- **Guardian can pause instantly; only governance unpauses.** A compromised guardian can delay new activity but can't keep it frozen.
- **Pause blocks money-in (create, buy, commit) but never refunds, settlement or reveals.** Investors can always exit, and pausing during the reveal window can't trigger penalties.
- **Guardian/governance can cancel an offering any time before delivery (refunds); the issuer can cancel only while it is live.** This is the emergency tool against issuer fraud.
- **"Owner" in `setProjectToken` means `DEFAULT_ADMIN_ROLE` (the Timelock).** Every contract uses AccessControl consistently.
- **The deploy script defaults the proposer, guardian and attestor to the deployer when the env vars are unset, and prints a loud warning.** This keeps a one-command deploy possible; DEPLOY.md tells you to set Safe multisigs.
- **Treasury defaults to the Timelock.** Fees then need a governance action to move.
- **Default fee is 1% (max 5%), with a 50% staker share once $BOOK is live (max 80%).**

## Tooling
- **OpenZeppelin is installed through pnpm (`node_modules`) instead of git submodules.** It fits the pnpm monorepo, and the repo had no git history when it was created.
- **The keeper signs through `cast send --account bookbuilder-keeper`**, so the process never holds key material. `KEEPER_SIGNER=dry` is the default.
- **Fork rehearsals sign with anvil's unlocked default accounts (`--unlocked --sender`).** No private key is typed, read or stored anywhere.
- **The deploy script detects dry runs (`vm.isContext(ScriptDryRun)`) and writes `deployments/<id>.dryrun.json` instead of the real file.** Simulations never overwrite real deployment records.
- **The frontend loads deployment addresses at runtime from `app/public/deployments/<chainId>.json`, which the deploy script writes.** Redeploying needs no rebuild of the app.
- **Fork rehearsal ran on port 8546.** Port 8545 was already used by another local node on this machine; the port is configurable through `FORK_PORT`.

## Frontend (from the frontend build)
- **Next.js 16 (App Router) + wagmi v2 + viem + RainbowKit + Tailwind.** It is the current stable stack.
- **`src/middleware.ts` is kept for the geoblock (Next 16 prefers `proxy.ts`).** The spec asked for middleware and it works.
- **Optional `@x402/*` packages are added as explicit dependencies.** wagmi's Base Account connector imports them, and Turbopack fails without them.
- **Multicall3 at its canonical address `0xcA11…CA11`, which is deployed on 4663.** viem's default batching expects it.
- **Without `NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID`, only injected, MetaMask and Coinbase wallets are offered.** The app still builds and works.
- **Approvals are for the exact amount, never unlimited.** This is the safer default for investors.
- **The bid secret is saved to localStorage before the commit transaction is sent, plus a downloadable backup.** Losing the salt costs the non-reveal penalty.
- **The risk acknowledgment gates buy and commit only; reveal, settle, finalize and mark-failed are never gated.** Users can never be locked into a penalty or out of a refund.
- **$BOOK UI needs both `NEXT_PUBLIC_PROJECT_TOKEN` set and on-chain `isEnabled()`.** Both the env switch and the chain state must agree.
