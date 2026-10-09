"use client";

import type { ReactNode } from "react";
import { fmtDuration } from "@/lib/format";
import { stageLabel, kindLabel } from "@/lib/types";
import { explorerAddressUrl } from "@/lib/chains";
import { shortAddr } from "@/lib/format";

export function Spinner({ label }: { label?: string }) {
  return (
    <span className="inline-flex items-center gap-2 text-sm text-muted">
      <span className="spinner" aria-hidden /> {label ?? "Loading…"}
    </span>
  );
}

export function EmptyState({ title, children }: { title: string; children?: ReactNode }) {
  return (
    <div className="card text-center">
      <p className="font-medium">{title}</p>
      {children && <div className="mt-2 text-sm text-muted">{children}</div>}
    </div>
  );
}

export function Notice({ tone = "info", children }: { tone?: "info" | "warn" | "error" | "success"; children: ReactNode }) {
  const cls =
    tone === "warn"
      ? "border-amber-500/40 bg-amber-500/10"
      : tone === "error"
        ? "border-red-500/40 bg-red-500/10"
        : tone === "success"
          ? "border-emerald-500/40 bg-emerald-500/10"
          : "border-line bg-surface-2";
  return <div className={`rounded-lg border p-3 text-sm ${cls}`}>{children}</div>;
}

const stageCls: Record<number, string> = {
  0: "border-blue-500/40 text-blue-600 dark:text-blue-300",
  1: "border-amber-500/40 text-amber-700 dark:text-amber-300",
  2: "border-emerald-500/40 text-emerald-700 dark:text-emerald-300",
  3: "border-red-500/40 text-red-600 dark:text-red-300",
};

export function StageBadge({ stage, cancelled }: { stage: number; cancelled?: boolean }) {
  return (
    <span className={`badge ${stageCls[stage] ?? "border-line"}`}>
      {cancelled && stage === 3 ? "Cancelled" : (stageLabel[stage] ?? "Unknown")}
    </span>
  );
}

export function KindBadge({ kind }: { kind: number }) {
  return <span className="badge border-line text-muted">{kindLabel[kind] ?? "Offering"}</span>;
}

export function Countdown({ to, now, prefix }: { to: bigint; now: number; prefix?: string }) {
  if (!now) return <span className="text-muted">—</span>;
  const diff = Number(to) - now;
  if (diff <= 0) return <span className="text-muted">{prefix ? `${prefix} ` : ""}passed</span>;
  return (
    <span className="tabular-nums">
      {prefix ? `${prefix} ` : ""}
      {fmtDuration(diff)}
    </span>
  );
}

export function ProgressBar({ value, label, marker }: { value: number; label?: string; marker?: number }) {
  return (
    <div>
      <div className="relative h-2.5 w-full overflow-hidden rounded-full bg-surface-2">
        <div className="h-full rounded-full bg-accent transition-all" style={{ width: `${Math.min(100, value)}%` }} />
        {marker !== undefined && marker > 0 && marker < 100 && (
          <div className="absolute top-0 h-full w-0.5 bg-amber-500" style={{ left: `${marker}%` }} title="Soft cap" />
        )}
      </div>
      {label && <p className="mt-1 text-xs text-muted">{label}</p>}
    </div>
  );
}

export function Stat({ label, value, sub }: { label: string; value: ReactNode; sub?: ReactNode }) {
  return (
    <div>
      <p className="text-xs uppercase tracking-wide text-muted">{label}</p>
      <p className="mt-0.5 text-lg font-semibold tabular-nums">{value}</p>
      {sub && <p className="text-xs text-muted">{sub}</p>}
    </div>
  );
}

export function Kv({ k, children }: { k: ReactNode; children: ReactNode }) {
  return (
    <div className="kv">
      <span>{k}</span>
      <span>{children}</span>
    </div>
  );
}

export function AddressLink({ chainId, address }: { chainId: number; address: string | undefined }) {
  if (!address) return <span>—</span>;
  const href = explorerAddressUrl(chainId, address);
  return href ? (
    <a href={href} target="_blank" rel="noreferrer" className="font-mono text-accent hover:underline" title={address}>
      {shortAddr(address)}
    </a>
  ) : (
    <span className="font-mono" title={address}>
      {shortAddr(address)}
    </span>
  );
}

export function SectionTitle({ children, right }: { children: ReactNode; right?: ReactNode }) {
  return (
    <div className="mb-3 flex items-center justify-between gap-2">
      <h2 className="text-base font-semibold">{children}</h2>
      {right}
    </div>
  );
}
