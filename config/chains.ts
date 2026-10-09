/**
 * Robinhood Chain network constants used by the app, the keeper and docs.
 * Every value below was read from official docs and checked on-chain (eth_chainId,
 * symbol()/decimals(), Chainlink description()/latestRoundData()) on 2026-10-08.
 *
 * Sources:
 *  - Network (chain ID, RPCs, explorer): https://docs.robinhood.com/chain/connecting
 *  - Gas token (ETH), Arbitrum Orbit L2:  https://docs.robinhood.com/chain/
 *  - Token contracts (WETH, USDG):       https://docs.robinhood.com/chain/contracts
 *  - Protocol contracts (bridge, Multicall, Permit2): https://docs.robinhood.com/chain/protocol-contracts
 *  - Contract verification (Blockscout): https://docs.robinhood.com/chain/deploy-smart-contracts
 *  - Oracles -> Chainlink is the source of truth: https://docs.robinhood.com/chain/oracles-and-price-feeds/
 *      feed list: https://docs.chain.link/data-feeds/price-feeds/addresses?network=robinhood
 *      (machine-readable: https://reference-data-directory.vercel.app/feeds-robinhood-mainnet.json)
 */

export type Address = `0x${string}`;

export const robinhoodMainnet = {
  id: 4663,
  name: "Robinhood Chain",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: {
    public: "https://rpc.mainnet.chain.robinhood.com",
    // Alchemy (recommended provider in the docs): https://robinhood-mainnet.g.alchemy.com/v2/{API_KEY}
    alchemyTemplate: "https://robinhood-mainnet.g.alchemy.com/v2/{API_KEY}",
  },
  explorer: {
    name: "Blockscout",
    url: "https://robinhoodchain.blockscout.com",
    verifierUrl: "https://robinhoodchain.blockscout.com/api/",
    verifier: "blockscout",
  },
  tokens: {
    /** Paxos Global Dollar - the chain's official stablecoin partner. 6 decimals. Used as default payment token. */
    USDG: { address: "0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168" as Address, decimals: 6, symbol: "USDG" },
    /** Canonical L2 WETH (also listed as "L2 Weth" in protocol contracts). */
    WETH: { address: "0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73" as Address, decimals: 18, symbol: "WETH" },
  },
  /** Chainlink USD price feeds (proxy addresses), 8 decimals, 24h heartbeat. */
  chainlinkFeeds: {
    "USDG/USD": "0x61B7e5650328764B076A108EFF5fa7282a1B9aD2" as Address,
    "ETH/USD": "0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9" as Address,
    "USDC/USD": "0x9e6f4605992a899eE2999999F3Ec80C41F452546" as Address,
  },
  protocol: {
    multicall: "0x2cAC2D899eCC914d704FeaAE33ac1bF36277DaD1" as Address,
    permit2: "0x000000000022D473030F116dDEE9F6B43aC78BA3" as Address,
  },
} as const;

/** Local anvil fork of mainnet. Uses chain id 31337 so wallets never confuse it with real mainnet. */
export const robinhoodFork = {
  ...robinhoodMainnet,
  id: 31337,
  name: "Robinhood Chain (local fork)",
  rpcUrls: { public: "http://127.0.0.1:8545", alchemyTemplate: "" },
  explorer: { ...robinhoodMainnet.explorer, url: "" },
} as const;

/**
 * Gaps (see DECISIONS.md):
 *  - The official token list documents USDG and WETH only. USDC/USDT Chainlink feeds exist, but no
 *    official USDC/USDT token address is published in Robinhood's docs, so none is configured.
 *  - No Chainlink feeds exist for arbitrary RWA delivery tokens; OracleAdapter supports a governance-set
 *    manual NAV price flagged as `manual`.
 */
export const chains = { [robinhoodMainnet.id]: robinhoodMainnet, [robinhoodFork.id]: robinhoodFork } as const;
