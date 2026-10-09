"use client";

import Link from "next/link";
import { useState } from "react";
import type { Address } from "viem";
import { fixedPriceOfferingAbi, offeringEscrowAbi } from "@/abi";
import { useTx } from "@/hooks/useTx";
import { fmtDate, fmtUnits, pct } from "@/lib/format";
import { soldOf, type OfferingSummary } from "@/lib/offerings";
import { Stage } from "@/lib/types";
import { BalanceLine, TxStatusLine } from "../participation/common";
import { Countdown, KindBadge, Notice, ProgressBar, StageBadge } from "../ui";

export function IssuerOfferingRow({ o, account, chainId, now }: { o: OfferingSummary; account: Address; chainId: number; now: number }) {
  const tx = useTx();
  const [docs, setDocs] = useState("");
  const e = o.escrowInfo;
  const n = BigInt(now || 0);
  const canDeliver = e.stage === Stage.Succeeded && now > 0 && n <= e.deliveryDeadline;
  const canCancel = e.stage === Stage.Active;
  const canSweep = (e.stage === Stage.Delivered || e.stage === Stage.Failed) && e.settledCount === e.participants;
  const sold = soldOf(o);

  const onDeliver = async () => {
    const ok = await tx.ensureAllowance(o.saleToken.address, o.escrow, e.tokensToDeliver, o.saleToken.symbol);
    if (!ok) return;
    await tx.run(`Deliver ${fmtUnits(e.tokensToDeliver, o.saleToken.decimals)} ${o.saleToken.symbol}`, () =>
      tx.writeContractAsync({ address: o.escrow, abi: offeringEscrowAbi, functionName: "deliver", chainId }),
    );
  };

  return (
    <div className="card space-y-3">
      <div className="flex flex-wrap items-start justify-between gap-2">
        <div>
          <Link href={`/offering/${o.address}`} className="font-semibold hover:underline">
            {o.saleToken.symbol} · {o.address.slice(0, 10)}…
          </Link>
          <p className="text-xs text-muted">
            {fmtDate(o.params.startTime)} → {fmtDate(o.batch ? o.batch.revealEnd : o.params.endTime)}
          </p>
        </div>
        <div className="flex gap-1">
          <KindBadge kind={o.kind} />
          <StageBadge stage={e.stage} cancelled={e.cancelled} />
        </div>
      </div>
      <ProgressBar
        value={pct(sold, o.params.supply)}
        marker={pct(o.params.softCap, o.params.supply)}
        label={`${fmtUnits(sold, o.saleToken.decimals, 2)} / ${fmtUnits(o.params.supply, o.saleToken.decimals, 2)} ${o.saleToken.symbol} · deposits ${fmtUnits(
          e.totalDeposited,
          o.paymentToken.decimals,
          2,
        )} ${o.paymentToken.symbol}`}
      />

      {e.stage === Stage.Succeeded && (
        <div className="space-y-2 rounded-lg bg-surface-2 p-3 text-sm">
          <p>
            Deliver <strong>{fmtUnits(e.tokensToDeliver, o.saleToken.decimals)} {o.saleToken.symbol}</strong> to release{" "}
            {fmtUnits(e.grossProceeds, o.paymentToken.decimals)} {o.paymentToken.symbol} (minus protocol fee).
          </p>
          <p className="text-xs">
            Deadline {fmtDate(e.deliveryDeadline)} · <Countdown to={e.deliveryDeadline} now={now} prefix="time left" />
          </p>
          <BalanceLine token={o.saleToken} account={account} chainId={chainId} />
          {!canDeliver && <Notice tone="error">The delivery deadline has passed. Investors can now trigger full refunds.</Notice>}
          <button className="btn btn-primary w-full" disabled={!canDeliver || tx.busy} onClick={onDeliver}>
            Approve & deliver tokens
          </button>
        </div>
      )}

      <div className="flex flex-wrap gap-2">
        {o.canFinalize && (
          <button
            className="btn btn-secondary"
            disabled={tx.busy}
            onClick={() =>
              tx.run("Finalize offering", () =>
                tx.writeContractAsync({ address: o.address, abi: fixedPriceOfferingAbi, functionName: "finalize", chainId }),
              )
            }
          >
            Finalize
          </button>
        )}
        {canCancel && (
          <button
            className="btn btn-danger"
            disabled={tx.busy}
            onClick={() => {
              if (!window.confirm("Cancel this offering? All investors will be refunded in full. This cannot be undone.")) return;
              void tx.run("Cancel offering", () =>
                tx.writeContractAsync({ address: o.escrow, abi: offeringEscrowAbi, functionName: "cancel", chainId }),
              );
            }}
          >
            Cancel offering
          </button>
        )}
        {(e.stage === Stage.Delivered || e.stage === Stage.Failed) && (
          <button
            className="btn btn-secondary"
            disabled={!canSweep || tx.busy}
            title={canSweep ? "Return rounding dust to the issuer" : "Available after every participant has settled"}
            onClick={() =>
              tx.run("Sweep dust", () => tx.writeContractAsync({ address: o.escrow, abi: offeringEscrowAbi, functionName: "sweep", chainId }))
            }
          >
            Sweep ({e.settledCount.toString()}/{e.participants.toString()} settled)
          </button>
        )}
      </div>

      <div className="flex gap-2">
        <input className="input" placeholder="New documents CID (amendment)" value={docs} onChange={(ev) => setDocs(ev.target.value)} />
        <button
          className="btn btn-secondary shrink-0"
          disabled={!docs.trim() || tx.busy}
          onClick={async () => {
            const ok = await tx.run("Update offering documents", () =>
              tx.writeContractAsync({ address: o.address, abi: fixedPriceOfferingAbi, functionName: "updateDocs", args: [docs.trim()], chainId }),
            );
            if (ok) setDocs("");
          }}
        >
          Update docs
        </button>
      </div>
      <TxStatusLine status={tx.status} error={tx.error} />
    </div>
  );
}
