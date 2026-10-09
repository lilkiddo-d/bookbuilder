import type { Address, ContractFunctionParameters, PublicClient } from "viem";
import {
  batchAuctionAbi,
  dutchAuctionAbi,
  erc20Abi,
  fixedPriceOfferingAbi,
  offeringEscrowAbi,
  offeringFactoryAbi,
} from "@/abi";
import { OfferingKind, type CommonParams } from "./types";

type Call = ContractFunctionParameters;

/** Run a heterogeneous multicall with allowFailure, returning `undefined` for failed calls. */
async function mc(client: PublicClient, calls: Call[]): Promise<unknown[]> {
  if (calls.length === 0) return [];
  const res = await client.multicall({ contracts: calls, allowFailure: true });
  return res.map((r) => (r.status === "success" ? r.result : undefined));
}

export interface TokenMeta {
  address: Address;
  symbol: string;
  decimals: number;
}

export interface BatchInfo {
  phase: number;
  minPrice: bigint;
  tickSize: bigint;
  numTicks: number;
  commitEnd: bigint;
  revealEnd: bigint;
  revealDuration: bigint;
  maxEndTime: bigint;
  antiSnipeWindow: number;
  antiSnipeExtension: number;
  nonRevealPenaltyBps: number;
  maxBidders: number;
  bidderCount: number;
  revealedCount: number;
  totalDemand: bigint;
  clearingPrice: bigint;
  clearingTick: number;
  tokensSold: bigint;
  oversubscribed: boolean;
}

export interface DutchInfo {
  startPrice: bigint;
  floorPrice: bigint;
  decayDuration: bigint;
  currentPrice: bigint;
  lastPrice: bigint;
  totalSold: bigint;
  totalCost: bigint;
}

export interface FixedInfo {
  price: bigint;
  totalSold: bigint;
  totalCost: bigint;
}

export interface EscrowInfo {
  stage: number;
  cancelled: boolean;
  deliveryDeadline: bigint;
  finalizedAt: bigint;
  deliveredAt: bigint;
  totalDeposited: bigint;
  grossProceeds: bigint;
  tokensToDeliver: bigint;
  participants: bigint;
  settledCount: bigint;
  feeBps: number;
  deliveryWindow: number;
}

export interface OfferingSummary {
  address: Address;
  kind: OfferingKind;
  issuer: Address;
  escrow: Address;
  params: CommonParams;
  finalized: boolean;
  succeeded: boolean;
  canFinalize: boolean;
  saleToken: TokenMeta;
  paymentToken: TokenMeta;
  escrowInfo: EscrowInfo;
  fixed?: FixedInfo;
  dutch?: DutchInfo;
  batch?: BatchInfo;
}

export async function loadOfferingAddresses(client: PublicClient, factory: Address): Promise<Address[]> {
  const count = (await client.readContract({
    address: factory,
    abi: offeringFactoryAbi,
    functionName: "offeringCount",
  })) as bigint;
  const out: Address[] = [];
  const PAGE = 100n;
  for (let offset = 0n; offset < count; offset += PAGE) {
    const page = (await client.readContract({
      address: factory,
      abi: offeringFactoryAbi,
      functionName: "offerings",
      args: [offset, PAGE],
    })) as readonly Address[];
    out.push(...page);
  }
  return out;
}

const BASE_FNS = ["kind", "params", "finalized", "succeeded", "escrow", "issuer", "canFinalize"] as const;

const FIXED_FNS = ["price", "totalSold", "totalCost"] as const;
const DUTCH_FNS = ["startPrice", "floorPrice", "decayDuration", "currentPrice", "lastPrice", "totalSold", "totalCost"] as const;
const BATCH_FNS = [
  "phase",
  "minPrice",
  "tickSize",
  "numTicks",
  "commitEnd",
  "revealEnd",
  "revealDuration",
  "maxEndTime",
  "antiSnipeWindow",
  "antiSnipeExtension",
  "nonRevealPenaltyBps",
  "maxBidders",
  "bidderCount",
  "revealedCount",
  "totalDemand",
  "clearingPrice",
  "clearingTick",
  "tokensSold",
  "oversubscribed",
] as const;
const ESCROW_FNS = [
  "stage",
  "cancelled",
  "deliveryDeadline",
  "finalizedAt",
  "deliveredAt",
  "totalDeposited",
  "grossProceeds",
  "tokensToDeliver",
  "participants",
  "settledCount",
  "feeBps",
  "deliveryWindow",
] as const;

function abiFor(kind: number) {
  return kind === OfferingKind.BatchAuction
    ? batchAuctionAbi
    : kind === OfferingKind.DutchAuction
      ? dutchAuctionAbi
      : fixedPriceOfferingAbi;
}

function fnsFor(kind: number): readonly string[] {
  return kind === OfferingKind.BatchAuction ? BATCH_FNS : kind === OfferingKind.DutchAuction ? DUTCH_FNS : FIXED_FNS;
}

function toObj(fns: readonly string[], values: unknown[]): Record<string, unknown> {
  const o: Record<string, unknown> = {};
  fns.forEach((f, i) => {
    o[f] = values[i];
  });
  return o;
}

const big = (v: unknown): bigint => (typeof v === "bigint" ? v : typeof v === "number" ? BigInt(v) : 0n);
const num = (v: unknown): number => (typeof v === "number" ? v : typeof v === "bigint" ? Number(v) : 0);
const bool = (v: unknown): boolean => v === true;

/** Load full summaries for a list of offerings in three multicall rounds. Offerings that fail to load are skipped. */
export async function loadOfferingSummaries(client: PublicClient, addresses: readonly Address[]): Promise<OfferingSummary[]> {
  if (addresses.length === 0) return [];

  // round 1: base views (all kinds share OfferingBase; use fixed ABI for shared fns, batch ABI for canFinalize is identical)
  const baseCalls: Call[] = addresses.flatMap((address) =>
    BASE_FNS.map((functionName) => ({ address, abi: fixedPriceOfferingAbi, functionName }) as Call),
  );
  const baseRes = await mc(client, baseCalls);
  const bases: (Record<string, unknown> & { address: Address })[] = addresses.map((address, i) => ({
    address,
    ...toObj(BASE_FNS, baseRes.slice(i * BASE_FNS.length, (i + 1) * BASE_FNS.length)),
  }));
  const valid = bases.filter((b) => b.params !== undefined && b.escrow !== undefined && b.kind !== undefined);

  // round 2: kind-specific + escrow + token metadata
  const tokens = new Set<Address>();
  for (const b of valid) {
    const p = b.params as CommonParams;
    tokens.add(p.saleToken);
    tokens.add(p.paymentToken);
  }
  const tokenList = [...tokens];
  const calls: Call[] = [];
  for (const b of valid) {
    const k = num(b.kind);
    for (const functionName of fnsFor(k)) calls.push({ address: b.address, abi: abiFor(k), functionName } as Call);
    for (const functionName of ESCROW_FNS)
      calls.push({ address: b.escrow as Address, abi: offeringEscrowAbi, functionName } as Call);
  }
  for (const t of tokenList) {
    calls.push({ address: t, abi: erc20Abi, functionName: "symbol" } as Call);
    calls.push({ address: t, abi: erc20Abi, functionName: "decimals" } as Call);
  }
  const res = await mc(client, calls);

  let cursor = 0;
  const take = (n: number) => {
    const s = res.slice(cursor, cursor + n);
    cursor += n;
    return s;
  };
  const perOffering = valid.map((b) => {
    const k = num(b.kind);
    const kindVals = toObj(fnsFor(k), take(fnsFor(k).length));
    const escVals = toObj(ESCROW_FNS, take(ESCROW_FNS.length));
    return { b, k, kindVals, escVals };
  });
  const meta = new Map<string, TokenMeta>();
  for (const t of tokenList) {
    const [sym, dec] = take(2);
    meta.set(t.toLowerCase(), {
      address: t,
      symbol: typeof sym === "string" ? sym : "TOKEN",
      decimals: typeof dec === "number" ? dec : 18,
    });
  }

  return perOffering.map(({ b, k, kindVals: v, escVals: e }) => {
    const params = b.params as CommonParams;
    const summary: OfferingSummary = {
      address: b.address,
      kind: k as OfferingKind,
      issuer: b.issuer as Address,
      escrow: b.escrow as Address,
      params,
      finalized: bool(b.finalized),
      succeeded: bool(b.succeeded),
      canFinalize: bool(b.canFinalize),
      saleToken: meta.get(params.saleToken.toLowerCase()) ?? { address: params.saleToken, symbol: "TOKEN", decimals: 18 },
      paymentToken: meta.get(params.paymentToken.toLowerCase()) ?? {
        address: params.paymentToken,
        symbol: "TOKEN",
        decimals: 18,
      },
      escrowInfo: {
        stage: num(e.stage),
        cancelled: bool(e.cancelled),
        deliveryDeadline: big(e.deliveryDeadline),
        finalizedAt: big(e.finalizedAt),
        deliveredAt: big(e.deliveredAt),
        totalDeposited: big(e.totalDeposited),
        grossProceeds: big(e.grossProceeds),
        tokensToDeliver: big(e.tokensToDeliver),
        participants: big(e.participants),
        settledCount: big(e.settledCount),
        feeBps: num(e.feeBps),
        deliveryWindow: num(e.deliveryWindow),
      },
    };
    if (k === OfferingKind.FixedPrice) {
      summary.fixed = { price: big(v.price), totalSold: big(v.totalSold), totalCost: big(v.totalCost) };
    } else if (k === OfferingKind.DutchAuction) {
      summary.dutch = {
        startPrice: big(v.startPrice),
        floorPrice: big(v.floorPrice),
        decayDuration: big(v.decayDuration),
        currentPrice: big(v.currentPrice),
        lastPrice: big(v.lastPrice),
        totalSold: big(v.totalSold),
        totalCost: big(v.totalCost),
      };
    } else {
      summary.batch = {
        phase: num(v.phase),
        minPrice: big(v.minPrice),
        tickSize: big(v.tickSize),
        numTicks: num(v.numTicks),
        commitEnd: big(v.commitEnd),
        revealEnd: big(v.revealEnd),
        revealDuration: big(v.revealDuration),
        maxEndTime: big(v.maxEndTime),
        antiSnipeWindow: num(v.antiSnipeWindow),
        antiSnipeExtension: num(v.antiSnipeExtension),
        nonRevealPenaltyBps: num(v.nonRevealPenaltyBps),
        maxBidders: num(v.maxBidders),
        bidderCount: num(v.bidderCount),
        revealedCount: num(v.revealedCount),
        totalDemand: big(v.totalDemand),
        clearingPrice: big(v.clearingPrice),
        clearingTick: num(v.clearingTick),
        tokensSold: big(v.tokensSold),
        oversubscribed: bool(v.oversubscribed),
      };
    }
    return summary;
  });
}

/** Participation end (commit end for batch auctions). */
export function participationEnd(o: OfferingSummary): bigint {
  return o.batch ? o.batch.commitEnd : o.params.endTime;
}

/** Last moment the book can be active (reveal end for batch auctions). */
export function bookEnd(o: OfferingSummary): bigint {
  return o.batch ? o.batch.revealEnd : o.params.endTime;
}

export type Bucket = "upcoming" | "live" | "closed";

export function bucketOf(o: OfferingSummary, nowSec: number): Bucket {
  const now = BigInt(nowSec);
  if (o.finalized || o.escrowInfo.stage !== 0) return "closed";
  if (now < o.params.startTime) return "upcoming";
  if (now < bookEnd(o)) return "live";
  return "closed";
}

/** Tokens sold / committed so far (best on-chain proxy per kind). */
export function soldOf(o: OfferingSummary): bigint {
  if (o.fixed) return o.fixed.totalSold;
  if (o.dutch) return o.dutch.totalSold;
  if (o.batch) return o.finalized ? o.batch.tokensSold : o.batch.totalDemand;
  return 0n;
}

export function priceAtTick(b: BatchInfo, tick: number): bigint {
  return b.minPrice + BigInt(tick) * b.tickSize;
}
