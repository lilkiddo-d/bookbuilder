# $BOOK token integration

**This repository does not write or deploy any ERC-20 for the project.** $BOOK is being launched separately on a launchpad. The protocol runs fully without it; every token feature stays off until governance wires the address in, once.

## Where the token is used
Everything lives in one contract, `ProjectTokenHooks` (`contracts/src/ProjectTokenHooks.sol`):

| Feature | What it does | Before the token is set |
|---|---|---|
| Staking | `stake`, `requestUnstake` (7-day cooldown, tier lost immediately), `withdraw` | `stake` reverts `TokenNotSet()` |
| Staking tiers → guaranteed allocation | In an **oversubscribed batch auction**, each staker's bid at the clearing price gets a guaranteed slot of `guaranteedBps` of supply, filled before the pro-rata remainder. Default tiers: 1k $BOOK → 0.25%, 10k → 0.75%, 100k → 2% (assumes 18 decimals; change via `setTiers`). Stake must age 3 days. | `guaranteedBps()` returns 0 for everyone |
| Priority access | Stakers may join during an offering's priority window | No effect |
| Fee sharing | `FeeCollector.distribute(USDG)` sends `stakerShareBps` (default 50%) of fees to stakers pro-rata (`claimRewards`), the rest to the treasury | 100% to the treasury |

Other contracts only read `factory.hooks()` → `isEnabled()` / `guaranteedBps()`. Governance can also detach the hooks entirely with `factory.setHooks(address(0))`.

## Wiring the token (one time, irreversible)
`setProjectToken(address)` can be called **once**, by the owner (`DEFAULT_ADMIN_ROLE` = the Timelock), so it goes through the 48h delay:

```bash
HOOKS=$(jq -r .contracts.ProjectTokenHooks deployments/4663.json)
TL=$(jq -r .contracts.Timelock deployments/4663.json)
BOOK=0xYourLaunchpadTokenAddress
DATA=$(cast calldata "setProjectToken(address)" $BOOK)

# 1) schedule (from the GOV_PROPOSER account)
cast send $TL "schedule(address,uint256,bytes,bytes32,bytes32,uint256)" $HOOKS 0 $DATA 0x$(printf '0%.0s' {1..64}) $(cast keccak book) 172800 \
  --account bookbuilder-deployer --rpc-url robinhood
# 2) after 48h, anyone executes
cast send $TL "execute(address,uint256,bytes,bytes32,bytes32)" $HOOKS 0 $DATA 0x$(printf '0%.0s' {1..64}) $(cast keccak book) \
  --account bookbuilder-deployer --rpc-url robinhood
```
If GOV_PROPOSER is a Safe, submit the same `schedule` and `execute` calls through the Safe UI's transaction builder.

Before scheduling, check that the token is a plain ERC-20 with no transfer fee or rebasing (staking rejects short transfers), and update the tier thresholds if it doesn't use 18 decimals (`setTiers`, also via the Timelock).

## Frontend
- `NEXT_PUBLIC_PROJECT_TOKEN` empty means all token UI is hidden (no Stake page, badges or fee-share UI).
- When it's set, the UI also checks on-chain `isEnabled()`, and shows "token not yet activated" until the Timelock call executes.
- After activation: the `/stake` page (stake, unstake, withdraw, claim, tier and guaranteed slot) and a "guaranteed slot" badge in the batch-auction bid panel.

## Tests
The test suite uses `MockERC20` ("Mock BOOK") **only in tests** (`test/mocks/Mocks.sol`) to cover enabling, tiers, aging, cooldowns, fee sharing, guaranteed slots in clearing (including fuzzing), the priority window and set-once access control through a real Timelock.
