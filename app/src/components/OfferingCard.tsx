"use client";

import Link from "next/link";
import { fmtUnits, pct } from "@/lib/format";
import { bookEnd, participationEnd, soldOf, type OfferingSummary } from "@/lib/offerings";
import { batchPhaseLabel } from "@/lib/types";
import { Countdown, KindBadge, ProgressBar, StageBadge } from "./ui";

export function PriceInfo({ o }: { o: OfferingSummary }) {
  const pd = o.paymentToken.decimals;
  const ps = o.paymentToken.symbol;
  if (o.fixed) return <span>{fmtUnits(o.fixed.price, pd)} {ps}</span>;
  if (o.dutch)
    return (
      <span>
        {fmtUnits(o.dutch.currentPrice, pd)} {ps}{" "}
        <span className="text-xs text-muted">
          ({fmtUnits(o.dutch.startPrice, pd)} → {fmtUnits(o.dutch.floorPrice, pd)})
        </span>
      </span>
    );
  if (o.batch) {
    const b = o.batch;
    if (o.finalized && b.clearingPrice > 0n)
      return (
        <span>
          Cleared at {fmtUnits(b.clearingPrice, pd)} {ps}
        </span>
      );
    const max = b.minPrice + BigInt(Math.max(0, b.numTicks - 1)) * b.tickSize;
    return (
      <span>
        {fmtUnits(b.minPrice, pd)} – {fmtUnits(max, pd)} {ps}
      </span>
    );
  }
  return <span>—</span>;
}

function TimeInfo({ o, now }: { o: OfferingSummary; now: number }) {
  const n = BigInt(now || 0);
  if (o.finalized || o.escrowInfo.stage !== 0) return <span className="text-muted">Closed</span>;
  if (n < o.params.startTime) return <Countdown to={o.params.startTime} now={now} prefix="Starts in" />;
  if (o.batch) {
    if (n < o.batch.commitEnd) return <Countdown to={o.batch.commitEnd} now={now} prefix="Commit ends in" />;
    if (n < o.batch.revealEnd) return <Countdown to={o.batch.revealEnd} now={now} prefix="Reveal ends in" />;
    return <span className="text-muted">Awaiting finalize</span>;
  }
  if (n < participationEnd(o)) return <Countdown to={participationEnd(o)} now={now} prefix="Ends in" />;
  return <span className="text-muted">Ended{now >= Number(bookEnd(o)) ? " · awaiting finalize" : ""}</span>;
}

export function OfferingCard({ o, now }: { o: OfferingSummary; now: number }) {
  const sd = o.saleToken.decimals;
  const sold = soldOf(o);
  const isBatchOpen = o.batch && !o.finalized;
  return (
    <Link href={`/offering/${o.address}`} className="card block transition hover:border-accent/60">
      <div className="flex items-start justify-between gap-2">
        <div>
          <p className="text-lg font-semibold">{o.saleToken.symbol}</p>
          <p className="text-xs text-muted">paid in {o.paymentToken.symbol}</p>
        </div>
        <div className="flex flex-col items-end gap-1">
          <StageBadge stage={o.escrowInfo.stage} cancelled={o.escrowInfo.cancelled} />
          <KindBadge kind={o.kind} />
        </div>
      </div>
      <dl className="mt-4 grid grid-cols-2 gap-3 text-sm">
        <div>
          <dt className="text-xs text-muted">Supply</dt>
          <dd className="font-medium tabular-nums">
            {fmtUnits(o.params.supply, sd)} {o.saleToken.symbol}
          </dd>
        </div>
        <div>
          <dt className="text-xs text-muted">{o.batch ? "Price range" : "Price"}</dt>
          <dd className="font-medium tabular-nums">
            <PriceInfo o={o} />
          </dd>
        </div>
        <div>
          <dt className="text-xs text-muted">Timing</dt>
          <dd className="font-medium">
            <TimeInfo o={o} now={now} />
          </dd>
        </div>
        <div>
          <dt className="text-xs text-muted">{o.batch ? "Phase" : "Sold"}</dt>
          <dd className="font-medium tabular-nums">
            {o.batch
              ? `${batchPhaseLabel[o.batch.phase] ?? "—"} · ${o.batch.bidderCount} bidders`
              : `${fmtUnits(sold, sd, 2)} (${pct(sold, o.params.supply).toFixed(1)}%)`}
          </dd>
        </div>
      </dl>
      <div className="mt-4">
        {isBatchOpen ? (
          <p className="text-xs text-muted">Bids are sealed until the reveal phase.</p>
        ) : (
          <ProgressBar value={pct(sold, o.params.supply)} marker={pct(o.params.softCap, o.params.supply)} />
        )}
      </div>
    </Link>
  );
}
