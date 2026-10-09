"use client";

import type { Address } from "viem";
import { useReadContract } from "wagmi";
import { batchAuctionAbi, offeringEscrowAbi } from "@/abi";
import { useTx } from "@/hooks/useTx";
import { fmtDuration, fmtUnits } from "@/lib/format";
import type { OfferingSummary } from "@/lib/offerings";
import { Stage } from "@/lib/types";
import { Kv, Notice } from "../ui";
import { TxStatusLine } from "./common";

export function useSettlement(o: OfferingSummary, account: Address | undefined, chainId: number) {
  const enabled = !!account;
  const args = account ? ([account] as const) : undefined;
  const deposit = useReadContract({
    address: o.escrow,
    abi: offeringEscrowAbi,
    functionName: "depositOf",
    args,
    chainId,
    query: { enabled, refetchInterval: 10_000 },
  });
  const preview = useReadContract({
    address: o.escrow,
    abi: offeringEscrowAbi,
    functionName: "previewSettle",
    args,
    chainId,
    query: { enabled, refetchInterval: 10_000 },
  });
  const position = useReadContract({
    address: o.escrow,
    abi: offeringEscrowAbi,
    functionName: "positionOf",
    args,
    chainId,
    query: { enabled, refetchInterval: 10_000 },
  });
  const fill = useReadContract({
    address: o.address,
    abi: batchAuctionAbi,
    functionName: "fillOf",
    args,
    chainId,
    query: { enabled: enabled && !!o.batch && o.finalized },
  });
  return {
    deposit: deposit.data,
    refund: preview.data?.[0],
    tokens: preview.data?.[1],
    penalty: preview.data?.[2],
    position: position.data,
    fill: o.batch ? fill.data : undefined,
  };
}

export function SettlementPanel({ o, account, chainId }: { o: OfferingSummary; account: Address; chainId: number }) {
  const s = useSettlement(o, account, chainId);
  const tx = useTx();
  if (!s.deposit || s.deposit === 0n) return null;

  const stage = o.escrowInfo.stage;
  const done = s.position?.done ?? false;
  const refund = s.refund ?? 0n;
  const tokens = s.tokens ?? 0n;
  const penalty = s.penalty ?? 0n;
  const canSettle =
    stage !== Stage.Active &&
    !done &&
    (refund > 0n || tokens > 0n || penalty > 0n || stage === Stage.Failed || stage === Stage.Delivered);
  const vested = o.params.vestingDuration > 0n;

  const onSettle = () =>
    tx.run("Settle position", () =>
      tx.writeContractAsync({
        address: o.escrow,
        abi: offeringEscrowAbi,
        functionName: "settle",
        args: [account],
        chainId,
      }),
    );

  return (
    <div className="space-y-3">
      <Kv k="Your deposit">
        {fmtUnits(s.deposit, o.paymentToken.decimals)} {o.paymentToken.symbol}
      </Kv>
      {s.position && s.position.refunded > 0n && (
        <Kv k="Already refunded">
          {fmtUnits(s.position.refunded, o.paymentToken.decimals)} {o.paymentToken.symbol}
        </Kv>
      )}
      {s.fill !== undefined && (
        <Kv k="Your allocation (fill)">
          {fmtUnits(s.fill, o.saleToken.decimals)} {o.saleToken.symbol}
        </Kv>
      )}
      {stage === Stage.Active ? (
        <Notice>Settlement opens once the offering is finalized.</Notice>
      ) : done ? (
        <Notice tone="success">Your position is fully settled.</Notice>
      ) : (
        <>
          <Kv k="Refund available now">
            {fmtUnits(refund, o.paymentToken.decimals)} {o.paymentToken.symbol}
          </Kv>
          <Kv k="Tokens claimable now">
            {fmtUnits(tokens, o.saleToken.decimals)} {o.saleToken.symbol}
          </Kv>
          {penalty > 0n && (
            <Kv k="Non-reveal penalty">
              <span className="text-red-500">
                −{fmtUnits(penalty, o.paymentToken.decimals)} {o.paymentToken.symbol}
              </span>
            </Kv>
          )}
          {stage === Stage.Succeeded && (
            <Notice>
              The offering succeeded and is awaiting issuer delivery. Excess deposits can be refunded now; tokens become claimable once the
              issuer delivers. If delivery misses the deadline, your full payment becomes refundable.
            </Notice>
          )}
          {stage === Stage.Delivered && vested && tokens > 0n && (
            <Notice>
              Tokens are subject to vesting ({fmtDuration(o.params.vestingCliff)} cliff, {fmtDuration(o.params.vestingDuration)} total).
              Settling creates your vesting schedule; release tokens from the Portfolio page.
            </Notice>
          )}
          <button className="btn btn-primary w-full" disabled={!canSettle || tx.busy} onClick={onSettle}>
            {tx.busy ? "Processing…" : stage === Stage.Failed ? "Claim refund" : "Settle / claim"}
          </button>
        </>
      )}
      <TxStatusLine status={tx.status} error={tx.error} />
    </div>
  );
}
