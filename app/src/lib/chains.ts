import { defineChain, type Chain } from "viem";
import { robinhoodMainnet, robinhoodFork } from "@bookbuilder/config";
import { env } from "./env";

/** Canonical Multicall3 (verified deployed on Robinhood Chain mainnet; present on forks too). */
const MULTICALL3 = "0xcA11bde05977b3631167028862bE2a173976CA11" as const;

export const mainnetChain = defineChain({
  id: robinhoodMainnet.id,
  name: robinhoodMainnet.name,
  nativeCurrency: robinhoodMainnet.nativeCurrency,
  rpcUrls: { default: { http: [env.rpcUrl] } },
  blockExplorers: { default: { name: robinhoodMainnet.explorer.name, url: robinhoodMainnet.explorer.url } },
  contracts: { multicall3: { address: MULTICALL3 } },
});

export const forkChain = defineChain({
  id: robinhoodFork.id,
  name: robinhoodFork.name,
  nativeCurrency: robinhoodFork.nativeCurrency,
  rpcUrls: { default: { http: [env.forkRpcUrl] } },
  contracts: { multicall3: { address: MULTICALL3 } },
  testnet: true,
});

export const supportedChains: readonly [Chain, ...Chain[]] = env.enableFork ? [mainnetChain, forkChain] : [mainnetChain];

export const supportedChainIds = supportedChains.map((c) => c.id);

export function isSupportedChain(id: number | undefined): id is number {
  return id !== undefined && supportedChainIds.includes(id);
}

export const defaultChainId: number = isSupportedChain(env.defaultChainId) ? env.defaultChainId : mainnetChain.id;

export function chainById(id: number): Chain | undefined {
  return supportedChains.find((c) => c.id === id);
}

export function explorerAddressUrl(chainId: number, address: string): string | undefined {
  const url = chainById(chainId)?.blockExplorers?.default.url;
  return url ? `${url}/address/${address}` : undefined;
}

export function explorerTxUrl(chainId: number, hash: string): string | undefined {
  const url = chainById(chainId)?.blockExplorers?.default.url;
  return url ? `${url}/tx/${hash}` : undefined;
}
