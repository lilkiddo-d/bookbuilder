"use client";

import Link from "next/link";
import { useRiskAck } from "@/hooks/useRiskAck";

/** Checkbox gating participation transactions on reading the risk disclosure. */
export function RiskAck() {
  const [acked, setAcked] = useRiskAck();
  return (
    <label className={`flex items-start gap-2 rounded-lg border p-3 text-sm ${acked ? "border-line" : "border-amber-500/50 bg-amber-500/5"}`}>
      <input type="checkbox" className="mt-0.5" checked={acked} onChange={(e) => setAcked(e.target.checked)} />
      <span>
        I have read the{" "}
        <Link href="/risk" className="text-accent underline" target="_blank">
          risk disclosure
        </Link>{" "}
        and understand that participating may result in loss of funds, delays, or lockups.
      </span>
    </label>
  );
}
