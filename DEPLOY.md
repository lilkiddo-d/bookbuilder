# DEPLOY

Everything below is run from the repo root unless a `cd` is shown. Network: **Robinhood Chain mainnet (4663)**.
No private key or seed phrase is ever printed, stored in a file or passed on a command line. Signing goes only through Foundry's encrypted keystore.

> **Windows note:** Windows *Smart App Control* temporarily blocked `cast.exe` on the build machine (it later ran normally). If you see "An Application Control policy has blocked this file", run the `cast` commands from WSL, or allow `cast.exe` in Windows Security.

## 0. Prerequisites (once)
```bash
curl -L https://foundry.paradigm.xyz | bash && foundryup   # forge/cast/anvil >= 1.x
npm i -g pnpm@12 && pnpm install                          # from repo root
```
Recommended: an archive-capable RPC for forks (the public RPC keeps only ~10–30 min of state). `https://robinhood.drpc.org` works, as does Alchemy `https://robinhood-mainnet.g.alchemy.com/v2/<KEY>`.

## 1. Import the deployer key into the Foundry keystore
```bash
cast wallet import bookbuilder-deployer --interactive
```
Paste the key at the hidden prompt and pick a keystore password. Then fund the address with ~0.005 ETH on Robinhood Chain (the dry run estimated ≈0.0011 ETH).
```bash
cast wallet address --account bookbuilder-deployer
```
For the keeper (step 6), do the same once: `cast wallet import bookbuilder-keeper --interactive`, and fund it with a little ETH.

## 2. Deploy + verify (one command)
Set the governance addresses first (strongly recommended: Safe multisigs). If any are unset they default to the deployer and the script prints a warning.
```bash
cd contracts
export ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com
export GOV_PROPOSER=0xYourGovernanceSafe      # proposes Timelock operations (48h delay)
export GUARDIAN=0xYourGuardianSafe            # can pause / suspend / cancel instantly; cannot move funds
export KYC_ATTESTOR=0xYourKycProviderSigner   # optional; can also be granted later via Timelock
export TREASURY=0xYourTreasurySafe            # optional; default = Timelock
# optional: FEE_BPS=100  STAKER_SHARE_BPS=5000  TIMELOCK_DELAY=172800
```
```bash
forge script script/Deploy.s.sol --rpc-url robinhood --account bookbuilder-deployer --sender $(cast wallet address --account bookbuilder-deployer) --broadcast --verify --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/
```
This deploys and wires all contracts, gives every admin role to the 48h Timelock (the deployer renounces), verifies on Blockscout, and writes:
- `deployments/4663.json`
- `app/public/deployments/4663.json` (frontend config; commit it)

Then record the real L2 deploy block (the keeper uses it to find deposits; Foundry reports an L1-style block number on Arbitrum chains):
```bash
cd .. && node scripts/record-deploy-block.mjs 4663
```

It creates **no offerings and approves no issuers**. If verification hiccups, rerun with `--resume --verify …` (same flags, without `--broadcast`).

Rehearse first if you like (no key needed):
```bash
forge script script/Deploy.s.sol --rpc-url robinhood --sender 0x000000000000000000000000000000000000b00c
```

## 3. Set the project token later ($BOOK, once, via Timelock)
See TOKEN_INTEGRATION.md. In short, from the `GOV_PROPOSER` account (or the same calls through the Safe UI):
```bash
D=deployments/4663.json; HOOKS=$(jq -r .contracts.ProjectTokenHooks $D); TL=$(jq -r .contracts.Timelock $D)
BOOK=0xYourBookToken; DATA=$(cast calldata "setProjectToken(address)" $BOOK); SALT=$(cast keccak set-book); Z=0x0000000000000000000000000000000000000000000000000000000000000000
cast send $TL "schedule(address,uint256,bytes,bytes32,bytes32,uint256)" $HOOKS 0 $DATA $Z $SALT 172800 --account bookbuilder-deployer --rpc-url https://rpc.mainnet.chain.robinhood.com
# >= 48h later (anyone):
cast send $TL "execute(address,uint256,bytes,bytes32,bytes32)" $HOOKS 0 $DATA $Z $SALT --account bookbuilder-deployer --rpc-url https://rpc.mainnet.chain.robinhood.com
```
Then set `NEXT_PUBLIC_PROJECT_TOKEN=$BOOK` in Vercel and redeploy the app.

## 4. Approve a real issuer (via Timelock)
Do this only after legal/KYB due diligence. Pin the issuer's documents to IPFS first.
```bash
D=deployments/4663.json; REG=$(jq -r .contracts.IssuerRegistry $D); TL=$(jq -r .contracts.Timelock $D); Z=0x0000000000000000000000000000000000000000000000000000000000000000
ISSUER=0xIssuerWallet; RWA=0xIssuerRwaToken
DATA=$(cast calldata "approveIssuer(address,address,string,string)" $ISSUER $RWA "Acme Property SPV I LLC, Delaware #1234567" "bafy...issuerDocsCID")
SALT=$(cast keccak "approve-$ISSUER")
cast send $TL "schedule(address,uint256,bytes,bytes32,bytes32,uint256)" $REG 0 $DATA $Z $SALT 172800 --account bookbuilder-deployer --rpc-url https://rpc.mainnet.chain.robinhood.com
# >= 48h later:
cast send $TL "execute(address,uint256,bytes,bytes32,bytes32)" $REG 0 $DATA $Z $SALT --account bookbuilder-deployer --rpc-url https://rpc.mainnet.chain.robinhood.com
```
Also, if the RWA token is ERC-3643 or permissioned: the issuer must whitelist the offering's **escrow** and the **DeliveryVesting** contract in the token's identity registry, or delivery and claims will revert.
Grant a KYC attestor (if not set at deploy) the same way: target `ComplianceRegistry`, calldata `grantRole(bytes32,address)` with `cast keccak ATTESTOR_ROLE`.
The issuer then creates offerings from the app's **Issuer console** (`/issuer`).

## 5. Deploy the app to Vercel
1. Import the repo in Vercel. **Root Directory:** `app`. Framework: Next.js. Install command: `pnpm install`. Build command: `pnpm build`. (`app/vercel.json` already sets these.)
2. Environment variables:
   - `NEXT_PUBLIC_DEFAULT_CHAIN_ID=4663`
   - `NEXT_PUBLIC_RPC_URL=https://rpc.mainnet.chain.robinhood.com` (or your Alchemy URL)
   - `NEXT_PUBLIC_ENABLE_FORK=false`
   - `NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID=<from cloud.reown.com>` (optional)
   - `NEXT_PUBLIC_PROJECT_TOKEN=` (leave empty until step 3)
   - `NEXT_PUBLIC_GEOBLOCK_COUNTRIES=US,CU,IR,KP,SY,…` (optional; your counsel decides)
   - `NEXT_PUBLIC_IPFS_GATEWAY=https://ipfs.io/ipfs/`
3. Make sure `app/public/deployments/4663.json` (written in step 2) is committed, then deploy.

## 6. Start the keeper
It finalizes ended offerings, marks missed deliveries failed, pushes refunds and tokens, and distributes fees. Every action is permissionless; the keeper has no special role.
```bash
cd scripts && cp .env.example .env    # set KEEPER_SIGNER=keystore, CHAIN_ID=4663, RPC_URL
pnpm once                             # one dry-run tick first (KEEPER_SIGNER=dry)
KEEPER_SIGNER=keystore KEEPER_PASSWORD_FILE=/secure/path/keeper.pass pnpm start
```
`KEEPER_PASSWORD_FILE` is optional; without it `cast` prompts. If you use it, keep the file outside the repo with `chmod 600`. Run under systemd/pm2 or as a cron of `pnpm once` every minute.

## Local fork rehearsal (what was run to prove the deploy)
```bash
anvil --fork-url https://robinhood.drpc.org --chain-id 31337 --port 8545
bash scripts/fork-rehearsal.sh          # deploy + 48h-timelock issuer approval + KYC + demo offerings
NEXT_PUBLIC_DEFAULT_CHAIN_ID=31337 pnpm app:dev
```
The rehearsal uses anvil's unlocked default accounts only. In MetaMask, add network `http://127.0.0.1:8545`, chain 31337, and import anvil's documented test account #2 (investor) yourself if you want to click through.
