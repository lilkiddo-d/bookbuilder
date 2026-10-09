import { formatUnits, parseUnits } from "viem";

/** Format base units with thousands separators, trimming to `maxFrac` fraction digits. BigInt-safe. */
export function fmtUnits(value: bigint | undefined, decimals: number | undefined, maxFrac = 4): string {
  if (value === undefined || decimals === undefined) return "—";
  const s = formatUnits(value, decimals);
  const neg = s.startsWith("-");
  const [intRaw, fracRaw = ""] = (neg ? s.slice(1) : s).split(".");
  const int = intRaw.replace(/\B(?=(\d{3})+(?!\d))/g, ",");
  const frac = fracRaw.slice(0, maxFrac).replace(/0+$/, "");
  return `${neg ? "-" : ""}${int}${frac ? `.${frac}` : ""}`;
}

/** Parse a human-entered decimal string into base units; returns undefined on invalid input. */
export function safeParseUnits(value: string, decimals: number | undefined): bigint | undefined {
  if (decimals === undefined) return undefined;
  const v = value.trim().replace(/,/g, "");
  if (!v || !/^\d*\.?\d*$/.test(v) || v === ".") return undefined;
  const frac = v.split(".")[1] ?? "";
  if (frac.length > decimals) return undefined;
  try {
    return parseUnits(v, decimals);
  } catch {
    return undefined;
  }
}

export function shortAddr(a: string | undefined): string {
  if (!a) return "—";
  return `${a.slice(0, 6)}…${a.slice(-4)}`;
}

export function fmtDuration(seconds: number | bigint): string {
  let s = Math.max(0, Math.floor(Number(seconds)));
  const d = Math.floor(s / 86400);
  s -= d * 86400;
  const h = Math.floor(s / 3600);
  s -= h * 3600;
  const m = Math.floor(s / 60);
  s -= m * 60;
  if (d > 0) return `${d}d ${h}h ${m}m`;
  if (h > 0) return `${h}h ${m}m ${s}s`;
  if (m > 0) return `${m}m ${s}s`;
  return `${s}s`;
}

export function fmtDate(ts: number | bigint | undefined): string {
  if (ts === undefined) return "—";
  const n = Number(ts);
  if (!n) return "—";
  return new Date(n * 1000).toLocaleString(undefined, {
    year: "numeric",
    month: "short",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  });
}

export function fmtBps(bps: number | bigint): string {
  const v = Number(bps) / 100;
  return `${Number.isInteger(v) ? v : v.toFixed(2)}%`;
}

/** ceil(a*b/d) for bigints (matches the contracts' _mulDivUp). */
export function mulDivUp(a: bigint, b: bigint, d: bigint): bigint {
  const p = a * b;
  return p === 0n ? 0n : (p - 1n) / d + 1n;
}

/** Ratio 0..100 as a number for progress bars, BigInt-safe. */
export function pct(part: bigint | undefined, whole: bigint | undefined): number {
  if (part === undefined || whole === undefined || whole === 0n) return 0;
  const r = Number((part * 10000n) / whole) / 100;
  return Math.max(0, Math.min(100, r));
}

/** Lossy bigint -> float for charting only (never for amounts sent on-chain). */
export function toFloat(value: bigint, decimals: number): number {
  return Number(formatUnits(value, decimals));
}

export function errorMessage(e: unknown): string {
  if (!e) return "";
  const err = e as { shortMessage?: string; message?: string; cause?: { shortMessage?: string } };
  return err.shortMessage || err.cause?.shortMessage || err.message?.split("\n")[0] || String(e);
}
