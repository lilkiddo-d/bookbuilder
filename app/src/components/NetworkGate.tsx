"use client";

import type { ReactNode } from "react";
import { useSwitchChain } from "wagmi";
import { useProtocol } from "@/hooks/useProtocol";
import { chainById, supportedChains } from "@/lib/chains";
import { Notice, Spinner } from "./ui";
import type { Deployment } from "@/lib/types";

/** Banner prompting a network switch when the wallet is on an unsupported chain. */
export function WrongNetworkBanner() {
  const { wrongNetwork } = useProtocol();
  const { switchChain, isPending } = useSwitchChain();
  if (!wrongNetwork) return null;
  return (
    <div className="border-b border-amber-500/40 bg-amber-500/10">
      <div className="mx-auto flex max-w-6xl flex-wrap items-center justify-between gap-2 px-4 py-2 text-sm">
        <span>Your wallet is connected to an unsupported network. Switch to continue.</span>
        <div className="flex gap-2">
          {supportedChains.map((c) => (
            <button key={c.id} className="btn btn-secondary py-1" disabled={isPending} onClick={() => switchChain({ chainId: c.id })}>
              Switch to {c.name}
            </button>
          ))}
        </div>
      </div>
    </div>
  );
}

/** Renders children only when the protocol deployment for the current chain is available. */
export function DeploymentGate({ children }: { children: (d: Deployment) => ReactNode }) {
  const { deployment, deploymentLoading, chainId } = useProtocol();
  if (deploymentLoading) {
    return (
      <div className="card">
        <Spinner label="Loading protocol deployment…" />
      </div>
    );
  }
  if (!deployment) {
    return (
      <div className="card">
        <h2 className="text-lg font-semibold">Protocol not deployed on this network yet</h2>
        <p className="mt-2 text-sm text-muted">
          No Bookbuilder deployment was found for {chainById(chainId)?.name ?? `chain ${chainId}`} (chain id {chainId}).
          Switch to another network, or check back once the protocol has been deployed.
        </p>
        {supportedChains.length > 1 && (
          <div className="mt-3">
            <Notice>Tip: use the network selector in the header (or your wallet) to change networks.</Notice>
          </div>
        )}
      </div>
    );
  }
  return <>{children(deployment)}</>;
}
