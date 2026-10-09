# Bookbuilder

Bookbuilder is an on-chain bookbuilding and offering platform on **Robinhood Chain**. Approved RWA issuers (real estate SPVs, private credit funds, tokenized funds) raise capital through transparent auctions, with investor funds escrowed until the issuer actually delivers the tokens.

- **Three offering types:** fixed price (soft/hard cap, refund if the soft cap is missed); uniform-price sealed-bid batch auction (commit–reveal, pro-rata at the margin); Dutch auction (price decays to a floor).
- **Escrow until delivery.** Payment is released to the issuer only atomically with full token delivery. If delivery misses the deadline, every investor is refunded.
- **Vesting and lockups** through `DeliveryVesting`. **Allocation rules:** per-wallet max, compliance tiers and a priority window, anti-sniping extensions, and $BOOK-staker guaranteed slots (inert until the token exists).
- **Compliance on by default:** an on-chain `ComplianceRegistry` with no PII, a 48h `Timelock` over every admin power, a pause guardian, an optional frontend geoblock and a risk disclosure page.

## Repo layout
| Path | What |
|---|---|
| `contracts/` | Foundry project (Solidity 0.8.28, OpenZeppelin v5). `src/` contracts, `test/` unit/fuzz/invariant/fork tests, `script/Deploy.s.sol` (one-shot deploy), `script/SeedFork.s.sol` (fork-only demo data) |
| `app/` | Next.js 16 + wagmi/viem + RainbowKit frontend |
| `scripts/` | Auction-closing keeper (`src/keeper.ts`) and `fork-rehearsal.sh` |
| `config/chains.ts` | Robinhood Chain constants with source links (chain ID, RPCs, explorer, USDG/WETH, Chainlink feeds) |
| `deployments/` | `<chainId>.json` written by the deploy script |
| `docs/` | Architecture notes |

## Contracts
| Contract | Role |
|---|---|
| `Timelock` | OZ TimelockController, ≥48h; holds every admin role |
| `IssuerRegistry` | Governance-approved issuers: legal entity ref, docs CID, delivery token |
| `ComplianceRegistry` | Attestor-written eligibility (tier, accredited, country, expiry, freeze) |
| `OfferingFactory` | Clones offerings + escrows for approved issuers; protocol config; guardian pause |
| `FixedPriceOffering` / `BatchAuction` / `DutchAuction` | Offering logic (never hold funds) |
| `OfferingEscrow` (+ `Refunds`) | Per-offering custody, delivery, refunds, settlement |
| `DeliveryVesting` | Linear vesting with cliff for delivered tokens |
| `FeeCollector` | Fees and penalties → treasury, plus staker share once $BOOK is live |
| `ProjectTokenHooks` | $BOOK staking, tiers and fee sharing; `setProjectToken` once via Timelock |
| `OracleAdapter` | Swappable display-only pricing (Chainlink and manual NAV) |

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the lifecycle, and [THREAT_MODEL.md](THREAT_MODEL.md), [DECISIONS.md](DECISIONS.md), [TOKEN_INTEGRATION.md](TOKEN_INTEGRATION.md) and [DEPLOY.md](DEPLOY.md).

## Quick start
```bash
pnpm install
cd contracts && forge build && forge test          # unit + fuzz + invariant + mainnet-fork tests
forge coverage --report summary --no-match-coverage "(test|script)"
pnpm slither                                        # needs `pip install slither-analyzer`
```
Fork tests use `$ROBINHOOD_RPC_URL` (default: the public RPC).

Run the whole stack locally against a mainnet fork:
```bash
anvil --fork-url https://robinhood.drpc.org --chain-id 31337           # terminal 1
bash scripts/fork-rehearsal.sh                                          # terminal 2
NEXT_PUBLIC_DEFAULT_CHAIN_ID=31337 pnpm app:dev                         # http://localhost:3000
```

## Status
| Check | Result |
|---|---|
| Tests | 86 passing (unit, fuzz 512 runs, invariant 128×64, 4 mainnet-fork tests with real USDG and Chainlink) |
| Coverage, core contracts | 99.88% lines, 98.6% statements |
| Slither | 0 high / 0 medium |
| Anvil fork deploy | succeeded |
| Mainnet dry run | succeeded (≈25.4M gas, ≈0.0011 ETH) |
| Frontend | `next build` and `tsc` pass |

Not audited. Get an independent audit before raising real capital.

## Branding
Bookbuilder is independent. It runs on Robinhood Chain but is not affiliated with or endorsed by Robinhood, and it uses no Robinhood names or logos in its branding.
