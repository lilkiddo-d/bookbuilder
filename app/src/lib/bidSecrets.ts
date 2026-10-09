import type { Address, Hex } from "viem";
import { isAddress, isHex } from "viem";

/** Everything needed to reveal a sealed batch-auction bid. Losing this means a non-reveal penalty. */
export interface BidSecret {
  version: 1;
  chainId: number;
  offering: Address;
  bidder: Address;
  tick: number;
  /** sale-token base units, decimal string */
  qty: string;
  salt: Hex;
  /** payment-token base units deposited with this commit, decimal string */
  deposit: string;
  commitment: Hex;
  createdAt: number;
}

const key = (chainId: number, offering: string, bidder: string) =>
  `bookbuilder:bid:${chainId}:${offering.toLowerCase()}:${bidder.toLowerCase()}`;

export function saveBidSecret(s: BidSecret): boolean {
  try {
    localStorage.setItem(key(s.chainId, s.offering, s.bidder), JSON.stringify(s));
    return true;
  } catch {
    return false;
  }
}

export function loadBidSecret(chainId: number, offering: string, bidder: string): BidSecret | null {
  try {
    const raw = localStorage.getItem(key(chainId, offering, bidder));
    return raw ? parseBidSecret(raw) : null;
  } catch {
    return null;
  }
}

export function parseBidSecret(raw: string): BidSecret | null {
  try {
    const o = JSON.parse(raw) as Partial<BidSecret>;
    if (
      typeof o.chainId !== "number" ||
      typeof o.offering !== "string" ||
      !isAddress(o.offering) ||
      typeof o.bidder !== "string" ||
      !isAddress(o.bidder) ||
      typeof o.tick !== "number" ||
      !Number.isInteger(o.tick) ||
      o.tick < 0 ||
      typeof o.qty !== "string" ||
      !/^\d+$/.test(o.qty) ||
      typeof o.salt !== "string" ||
      !isHex(o.salt) ||
      o.salt.length !== 66
    ) {
      return null;
    }
    return {
      version: 1,
      chainId: o.chainId,
      offering: o.offering,
      bidder: o.bidder,
      tick: o.tick,
      qty: o.qty,
      salt: o.salt,
      deposit: typeof o.deposit === "string" && /^\d+$/.test(o.deposit) ? o.deposit : "0",
      commitment: (typeof o.commitment === "string" && isHex(o.commitment) ? o.commitment : "0x") as Hex,
      createdAt: typeof o.createdAt === "number" ? o.createdAt : 0,
    };
  } catch {
    return null;
  }
}

export function downloadBidSecret(s: BidSecret): void {
  const blob = new Blob([JSON.stringify(s, null, 2)], { type: "application/json" });
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = `bookbuilder-bid-${s.chainId}-${s.offering.slice(0, 10)}-${s.bidder.slice(0, 8)}.json`;
  document.body.appendChild(a);
  a.click();
  a.remove();
  URL.revokeObjectURL(url);
}

export function randomSalt(): Hex {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return `0x${Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("")}` as Hex;
}
