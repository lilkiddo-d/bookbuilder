# @bookbuilder/app

Next.js (App Router) frontend for Bookbuilder: offerings calendar, offering detail with live demand curve,
participation (fixed price, Dutch auction, sealed-bid batch auction), portfolio & vesting, issuer console,
optional $BOOK staking, risk disclosure and geoblocking.

Stack: Next.js 16, React 19, wagmi v2, viem v2, RainbowKit v2, TanStack Query v5, Tailwind CSS v4.

## Environment

Copy `.env.example` to `.env.local`:

| Variable | Default | Purpose |
| --- | --- | --- |
| `NEXT_PUBLIC_DEFAULT_CHAIN_ID` | `4663` | Read chain when no wallet is connected (`4663` mainnet, `31337` local fork) |
| `NEXT_PUBLIC_RPC_URL` | public Robinhood Chain RPC | Mainnet RPC |
| `NEXT_PUBLIC_FORK_RPC_URL` | `http://127.0.0.1:8545` | Local anvil fork RPC |
| `NEXT_PUBLIC_ENABLE_FORK` | `true` in dev, `false` in prod | Show the fork chain in network lists |
| `NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID` | empty | Optional; empty = injected / MetaMask / Coinbase wallets only |
| `NEXT_PUBLIC_PROJECT_TOKEN` | empty | $BOOK address; empty hides every token feature |
| `NEXT_PUBLIC_GEOBLOCK_COUNTRIES` | empty | Comma-separated ISO-2 codes redirected to `/blocked` |
| `NEXT_PUBLIC_IPFS_GATEWAY` | `https://ipfs.io/ipfs/` | Gateway for document links |

Contract addresses are **not** baked in. They are fetched at runtime from `public/deployments/<chainId>.json`,
written by the Foundry deploy script. If the file for the active chain is missing, the UI shows
"Protocol not deployed on this network yet".

## Develop

```bash
pnpm install                              # from the repo root
pnpm --filter @bookbuilder/app dev        # http://localhost:3000
```

For a local fork: run anvil on 8545 forking Robinhood Chain with `--chain-id 31337`, deploy with the Foundry
script (it writes `app/public/deployments/31337.json`), then add the network `31337` / `http://127.0.0.1:8545` to your wallet.

## Build / check

```bash
pnpm --filter @bookbuilder/app typecheck
pnpm --filter @bookbuilder/app build
pnpm --filter @bookbuilder/app start
```

## Deploy on Vercel

- Root directory: `app`
- Framework preset: Next.js
- Install command: `pnpm install` (Vercel detects the pnpm workspace from the repo root lockfile)
- Build command: `pnpm build`
- Environment variables: `NEXT_PUBLIC_DEFAULT_CHAIN_ID=4663`, `NEXT_PUBLIC_RPC_URL`, `NEXT_PUBLIC_ENABLE_FORK=false`,
  optionally `NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID`, `NEXT_PUBLIC_PROJECT_TOKEN`, `NEXT_PUBLIC_GEOBLOCK_COUNTRIES`, `NEXT_PUBLIC_IPFS_GATEWAY`.
- Commit `public/deployments/4663.json` (or add it before building) so the production site finds the contracts.
  Geoblocking uses the `x-vercel-ip-country` header (or `cf-ipcountry` behind Cloudflare).
