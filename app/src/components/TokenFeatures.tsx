"use client";

import type { Address } from "viem";
import { useReadContract } from "wagmi";
import { projectTokenHooksAbi } from "@/abi";
import { tokenFeaturesConfigured } from "@/lib/env";
import { nonZero } from "@/lib/deployments";
import { fmtBps } from "@/lib/format";
import { useProtocol } from "@/hooks/useProtocol";

/**
 * $BOOK feature switch. Features render only when NEXT_PUBLIC_PROJECT_TOKEN is set AND
 * ProjectTokenHooks.isEnabled() is true on-chain.
 */
export function useProjectToken() {
  const { chainId, deployment } = useProtocol();
  const hooks = nonZero(deployment?.contracts.ProjectTokenHooks);
  const { data: enabled, isLoading } = useReadContract({
    address: hooks,
    abi: projectTokenHooksAbi,
    functionName: "isEnabled",
    chainId,
    query: { enabled: tokenFeaturesConfigured && !!hooks },
  });
  return {
    configured: tokenFeaturesConfigured,
    hooks,
    enabled: tokenFeaturesConfigured && !!hooks && enabled === true,
    loading: isLoading,
    chainId,
  };
}

export function GuaranteedSlotBadge({ account }: { account: Address }) {
  const { enabled, hooks, chainId } = useProjectToken();
  const { data: bps } = useReadContract({
    address: hooks,
    abi: projectTokenHooksAbi,
    functionName: "guaranteedBps",
    args: [account],
    chainId,
    query: { enabled },
  });
  if (!enabled || !bps) return null;
  return (
    <span className="badge border-emerald-500/50 text-emerald-700 dark:text-emerald-300" title="Filled first at the clearing price if the auction is oversubscribed">
      Guaranteed slot · {fmtBps(bps)} of supply
    </span>
  );
}

export function TierBadge({ account }: { account: Address }) {
  const { enabled, hooks, chainId } = useProjectToken();
  const { data: tier } = useReadContract({
    address: hooks,
    abi: projectTokenHooksAbi,
    functionName: "tierOf",
    args: [account],
    chainId,
    query: { enabled },
  });
  if (!enabled || tier === undefined || tier === 0n) return null;
  return <span className="badge border-accent/50 text-accent">Staking tier {tier.toString()}</span>;
}
