# Bookbuilder contracts

```bash
pnpm install            # OpenZeppelin v5 via node_modules
forge build
forge test              # unit, fuzz, invariant, and mainnet-fork tests (fork RPC: $ROBINHOOD_RPC_URL)
forge test --no-match-path "test/fork/*"     # offline subset
forge coverage --report summary --no-match-coverage "(test|script)"
slither . --config-file slither.config.json
node tools/export-abis.mjs                   # refresh app/ and scripts/ ABIs after changes
```

| Test file | Covers |
|---|---|
| `FixedPrice.t.sol` | caps, soft cap refunds, delivery and fee, deadline failure, cancel paths, compliance, priority window, pause, vesting |
| `BatchAuction.t.sol` | commit/reveal, clearing (over/under/exact), pro-rata, penalties, anti-sniping, staker guarantees |
| `BatchAuctionFuzz.t.sol` | clearing vs brute-force reference, never pay above bid, Σ fills ≤ supply, solvency through settlement |
| `DutchAuction.t.sol` | decay, slippage, lifecycle, monotonic price fuzz |
| `EscrowInvariant.t.sol` | balance == held, balance == raised until release/refund, no release before delivery, token coverage |
| `Admin.t.sol` | factory validation, registries, fee collector, $BOOK hooks, oracle, Timelock-governed `setProjectToken`, reentrancy, fee-on-transfer rejection |
| `fork/Fork.t.sol` | Deploy script on a live mainnet fork, real USDG + Chainlink, admin handoff, full lifecycles |

Deployment: see `../DEPLOY.md`. `script/SeedFork.s.sol` refuses to run on any chain other than 31337.
