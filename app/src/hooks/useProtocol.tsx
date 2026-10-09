"use client";

import { createContext, useContext, useEffect, useMemo, useState, type ReactNode } from "react";
import { useAccount } from "wagmi";
import { useQuery } from "@tanstack/react-query";
import { fetchDeployment } from "@/lib/deployments";
import { defaultChainId, isSupportedChain } from "@/lib/chains";
import type { Deployment } from "@/lib/types";

interface ProtocolState {
  /** chain used for all reads */
  chainId: number;
  deployment: Deployment | null | undefined;
  deploymentLoading: boolean;
  /** wallet connected to a chain this app does not support */
  wrongNetwork: boolean;
  walletChainId: number | undefined;
  /** read chain chosen while no wallet is connected */
  setReadChainId: (id: number) => void;
}

const Ctx = createContext<ProtocolState | null>(null);

const STORAGE_KEY = "bookbuilder:readChain";

export function ProtocolProvider({ children }: { children: ReactNode }) {
  const { chainId: walletChainId, isConnected } = useAccount();
  const [readChainId, setReadChainIdState] = useState<number>(defaultChainId);

  useEffect(() => {
    try {
      const v = Number(localStorage.getItem(STORAGE_KEY));
      if (isSupportedChain(v)) setReadChainIdState(v);
    } catch {
      /* ignore */
    }
  }, []);

  const setReadChainId = (id: number) => {
    if (!isSupportedChain(id)) return;
    setReadChainIdState(id);
    try {
      localStorage.setItem(STORAGE_KEY, String(id));
    } catch {
      /* ignore */
    }
  };

  const wrongNetwork = isConnected && walletChainId !== undefined && !isSupportedChain(walletChainId);
  const chainId = isConnected && isSupportedChain(walletChainId) ? walletChainId : readChainId;

  const { data: deployment, isLoading } = useQuery({
    queryKey: ["deployment", chainId],
    queryFn: () => fetchDeployment(chainId),
    staleTime: 60_000,
    retry: false,
  });

  const value = useMemo<ProtocolState>(
    () => ({
      chainId,
      deployment,
      deploymentLoading: isLoading,
      wrongNetwork,
      walletChainId,
      setReadChainId,
    }),
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [chainId, deployment, isLoading, wrongNetwork, walletChainId],
  );

  return <Ctx.Provider value={value}>{children}</Ctx.Provider>;
}

export function useProtocol(): ProtocolState {
  const v = useContext(Ctx);
  if (!v) throw new Error("useProtocol must be used inside ProtocolProvider");
  return v;
}
