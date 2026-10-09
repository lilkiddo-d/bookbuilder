import { isAddress, getAddress, type Address } from "viem";

const trim = (v: string | undefined) => (v ?? "").trim();

const projectTokenRaw = trim(process.env.NEXT_PUBLIC_PROJECT_TOKEN);
const forkFlag = trim(process.env.NEXT_PUBLIC_ENABLE_FORK).toLowerCase();

export const env = {
  defaultChainId: Number(trim(process.env.NEXT_PUBLIC_DEFAULT_CHAIN_ID) || "4663"),
  rpcUrl: trim(process.env.NEXT_PUBLIC_RPC_URL) || "https://rpc.mainnet.chain.robinhood.com",
  forkRpcUrl: trim(process.env.NEXT_PUBLIC_FORK_RPC_URL) || "http://127.0.0.1:8545",
  enableFork: forkFlag ? forkFlag === "true" || forkFlag === "1" : process.env.NODE_ENV !== "production",
  walletConnectProjectId: trim(process.env.NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID),
  projectToken: (isAddress(projectTokenRaw) ? getAddress(projectTokenRaw) : undefined) as Address | undefined,
  geoblockCountries: trim(process.env.NEXT_PUBLIC_GEOBLOCK_COUNTRIES)
    .split(",")
    .map((c) => c.trim().toUpperCase())
    .filter((c) => c.length === 2),
  ipfsGateway: (() => {
    const g = trim(process.env.NEXT_PUBLIC_IPFS_GATEWAY) || "https://ipfs.io/ipfs/";
    return g.endsWith("/") ? g : `${g}/`;
  })(),
} as const;

/** $BOOK features are only rendered when the project token env var is set. */
export const tokenFeaturesConfigured = env.projectToken !== undefined;
