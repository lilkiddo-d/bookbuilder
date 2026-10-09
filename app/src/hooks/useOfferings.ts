"use client";

import { useQuery } from "@tanstack/react-query";
import { usePublicClient } from "wagmi";
import type { Address } from "viem";
import { useProtocol } from "./useProtocol";
import { loadOfferingAddresses, loadOfferingSummaries, type OfferingSummary } from "@/lib/offerings";

/** All offerings created by the factory on the current read chain. */
export function useAllOfferings() {
  const { chainId, deployment } = useProtocol();
  const client = usePublicClient({ chainId });
  const factory = deployment?.contracts.OfferingFactory;
  return useQuery({
    queryKey: ["offerings", chainId, factory],
    enabled: !!client && !!factory,
    refetchInterval: 15_000,
    queryFn: async (): Promise<OfferingSummary[]> => {
      if (!client || !factory) return [];
      const addrs = await loadOfferingAddresses(client, factory);
      return loadOfferingSummaries(client, addrs);
    },
  });
}

/** Summaries for an explicit list of offering addresses. */
export function useOfferingSummaries(addresses: readonly Address[] | undefined) {
  const { chainId } = useProtocol();
  const client = usePublicClient({ chainId });
  return useQuery({
    queryKey: ["offeringSummaries", chainId, (addresses ?? []).join(",")],
    enabled: !!client && !!addresses,
    refetchInterval: 15_000,
    queryFn: async () => (client && addresses ? loadOfferingSummaries(client, addresses) : []),
  });
}

/** Single offering summary (refreshes every 8s). */
export function useOffering(address: Address | undefined) {
  const { chainId } = useProtocol();
  const client = usePublicClient({ chainId });
  return useQuery({
    queryKey: ["offering", chainId, address],
    enabled: !!client && !!address,
    refetchInterval: 8_000,
    queryFn: async (): Promise<OfferingSummary | null> => {
      if (!client || !address) return null;
      const [o] = await loadOfferingSummaries(client, [address]);
      return o ?? null;
    },
  });
}
