"use client";

import { connectorsForWallets } from "@rainbow-me/rainbowkit";
import {
  coinbaseWallet,
  injectedWallet,
  metaMaskWallet,
  rainbowWallet,
  walletConnectWallet,
} from "@rainbow-me/rainbowkit/wallets";
import { createConfig, http, type Transport } from "wagmi";
import { env } from "./env";
import { supportedChains, mainnetChain, forkChain } from "./chains";

const hasWc = env.walletConnectProjectId.length > 0;

const connectors = connectorsForWallets(
  [
    {
      groupName: "Wallets",
      wallets: hasWc
        ? [injectedWallet, metaMaskWallet, coinbaseWallet, rainbowWallet, walletConnectWallet]
        : [injectedWallet, metaMaskWallet, coinbaseWallet],
    },
  ],
  {
    appName: "Bookbuilder",
    // RainbowKit requires a string; it is only used by WalletConnect-based wallets, which are omitted without an id.
    projectId: hasWc ? env.walletConnectProjectId : "00000000000000000000000000000000",
  },
);

const transports: Record<number, Transport> = {
  [mainnetChain.id]: http(env.rpcUrl),
  [forkChain.id]: http(env.forkRpcUrl),
};

export const wagmiConfig = createConfig({
  chains: supportedChains,
  connectors,
  transports,
  ssr: true,
});

declare module "wagmi" {
  interface Register {
    config: typeof wagmiConfig;
  }
}
