import { isAddress } from "viem";
import type { Deployment } from "./types";

const REQUIRED = ["IssuerRegistry", "ComplianceRegistry", "OfferingFactory", "DeliveryVesting"] as const;

/** Fetch `/deployments/<chainId>.json`. Returns null when the protocol is not deployed on that chain. */
export async function fetchDeployment(chainId: number): Promise<Deployment | null> {
  let res: Response;
  try {
    res = await fetch(`/deployments/${chainId}.json`, { cache: "no-store" });
  } catch {
    return null;
  }
  if (!res.ok) return null;
  let data: Partial<Deployment>;
  try {
    data = (await res.json()) as Partial<Deployment>;
  } catch {
    return null;
  }
  if (!data || typeof data !== "object" || !data.contracts) return null;
  for (const k of REQUIRED) {
    const a = data.contracts[k];
    if (!a || !isAddress(a)) return null;
  }
  const paymentTokens: Record<string, `0x${string}`> = {};
  for (const [sym, addr] of Object.entries(data.paymentTokens ?? {})) {
    if (isAddress(addr)) paymentTokens[sym] = addr;
  }
  return {
    chainId: Number(data.chainId ?? chainId),
    network: data.network ?? String(chainId),
    blockNumber: data.blockNumber,
    contracts: data.contracts,
    paymentTokens,
    guardian: data.guardian,
    treasury: data.treasury,
    timelockDelay: data.timelockDelay,
  };
}

/** Treat the zero address as "not configured". */
export function nonZero(a: `0x${string}` | undefined): `0x${string}` | undefined {
  return a && !/^0x0{40}$/i.test(a) ? a : undefined;
}
