"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import type { Address, Hex } from "viem";
import { useConfig, useReadContract } from "wagmi";
import { readContract } from "wagmi/actions";
import { batchAuctionAbi, offeringEscrowAbi } from "@/abi";
import { useTx } from "@/hooks/useTx";
import {
  downloadBidSecret,
  loadBidSecret,
  parseBidSecret,
  randomSalt,
  saveBidSecret,
  type BidSecret,
} from "@/lib/bidSecrets";
import { fmtBps, fmtDate, fmtDuration, fmtUnits, mulDivUp, safeParseUnits } from "@/lib/format";
import { priceAtTick, type OfferingSummary } from "@/lib/offerings";
import { Notice } from "../ui";
import { AmountInput, BalanceLine, TxStatusLine } from "./common";
import { GuaranteedSlotBadge } from "../TokenFeatures";

const ZERO32 = "0x0000000000000000000000000000000000000000000000000000000000000000";

export function BatchPanel({
  o,
  account,
  chainId,
  canAct,
  now,
}: {
  o: OfferingSummary;
  account: Address;
  chainId: number;
  canAct: boolean;
  now: number;
}) {
  const b = o.batch!;
  const config = useConfig();
  const tx = useTx();
  const saleUnit = 10n ** BigInt(o.saleToken.decimals);

  const { data: bid, refetch: refetchBid } = useReadContract({
    address: o.address,
    abi: batchAuctionAbi,
    functionName: "bids",
    args: [account],
    chainId,
    query: { refetchInterval: 10_000 },
  });
  const { data: deposit } = useReadContract({
    address: o.escrow,
    abi: offeringEscrowAbi,
    functionName: "depositOf",
    args: [account],
    chainId,
    query: { refetchInterval: 10_000 },
  });
  const { data: livePhase } = useReadContract({
    address: o.address,
    abi: batchAuctionAbi,
    functionName: "phase",
    chainId,
    query: { refetchInterval: 5_000 },
  });
  const phase = livePhase ?? b.phase;
  const hasCommitted = !!bid && bid[0] !== ZERO32;
  const revealed = !!bid && bid[4];

  // ------------------------------------------------------------------ saved secret
  const [secret, setSecret] = useState<BidSecret | null>(null);
  const [importError, setImportError] = useState<string>();
  useEffect(() => {
    setSecret(loadBidSecret(chainId, o.address, account));
  }, [chainId, o.address, account]);

  // ------------------------------------------------------------------ commit form
  const [tick, setTick] = useState(0);
  const [qtyStr, setQtyStr] = useState("");
  const [extraStr, setExtraStr] = useState("");
  const qty = safeParseUnits(qtyStr, o.saleToken.decimals);
  const extra = extraStr ? safeParseUnits(extraStr, o.paymentToken.decimals) : 0n;
  const localPrice = priceAtTick(b, tick);
  const { data: onchainPrice } = useReadContract({
    address: o.address,
    abi: batchAuctionAbi,
    functionName: "priceAt",
    args: [BigInt(tick)],
    chainId,
  });
  const price = onchainPrice ?? localPrice;
  const needed = qty !== undefined && qty > 0n ? mulDivUp(qty, price, saleUnit) : undefined;
  const target = needed !== undefined && extra !== undefined ? needed + extra : undefined;
  const topUp = target !== undefined ? (target > (deposit ?? 0n) ? target - (deposit ?? 0n) : 0n) : undefined;
  const overWallet = qty !== undefined && o.params.perWalletMax > 0n && qty > o.params.perWalletMax;
  const overSupply = qty !== undefined && qty > o.params.supply;
  const validCommit =
    qty !== undefined && qty > 0n && extra !== undefined && topUp !== undefined && !overWallet && !overSupply && (topUp > 0n || (deposit ?? 0n) > 0n);

  const [ackSalt, setAckSalt] = useState(false);
  const [justSaved, setJustSaved] = useState<BidSecret | null>(null);

  const onCommit = async () => {
    if (!validCommit || qty === undefined || topUp === undefined || target === undefined) return;
    const salt = randomSalt();
    let commitment: Hex;
    try {
      commitment = await readContract(config, {
        address: o.address,
        abi: batchAuctionAbi,
        functionName: "commitmentHash",
        args: [account, tick, qty, salt],
        chainId,
      });
    } catch {
      return;
    }
    const s: BidSecret = {
      version: 1,
      chainId,
      offering: o.address,
      bidder: account,
      tick,
      qty: qty.toString(),
      salt,
      deposit: target.toString(),
      commitment,
      createdAt: Math.floor(Date.now() / 1000),
    };
    // persist BEFORE sending, so the secret survives a closed tab after the tx is mined
    const stored = saveBidSecret(s);
    setJustSaved(s);
    if (!stored) downloadBidSecret(s);
    if (topUp > 0n) {
      const ok = await tx.ensureAllowance(o.paymentToken.address, o.address, topUp, o.paymentToken.symbol);
      if (!ok) return;
    }
    const done = await tx.run("Commit sealed bid", () =>
      tx.writeContractAsync({
        address: o.address,
        abi: batchAuctionAbi,
        functionName: "commit",
        args: [commitment, topUp],
        chainId,
      }),
    );
    if (done) {
      setSecret(s);
      refetchBid();
    }
  };

  // ------------------------------------------------------------------ reveal
  const fileRef = useRef<HTMLInputElement>(null);
  const onImport = async (f: File | undefined) => {
    setImportError(undefined);
    if (!f) return;
    const parsed = parseBidSecret(await f.text());
    if (!parsed) return setImportError("Not a valid bid backup file.");
    if (parsed.offering.toLowerCase() !== o.address.toLowerCase() || parsed.chainId !== chainId)
      return setImportError("This backup belongs to a different offering or network.");
    if (parsed.bidder.toLowerCase() !== account.toLowerCase())
      return setImportError("This backup belongs to a different wallet. (Anyone may reveal for a bidder, but connect that wallet to keep things simple.)");
    saveBidSecret(parsed);
    setSecret(parsed);
  };

  const secretMatches = useMemo(() => {
    if (!secret || !bid) return undefined;
    return secret.commitment !== "0x" ? secret.commitment.toLowerCase() === bid[0].toLowerCase() : undefined;
  }, [secret, bid]);

  const onReveal = async () => {
    if (!secret) return;
    await tx.run("Reveal bid", () =>
      tx.writeContractAsync({
        address: o.address,
        abi: batchAuctionAbi,
        functionName: "reveal",
        args: [secret.bidder, secret.tick, BigInt(secret.qty), secret.salt],
        chainId,
      }),
    );
    refetchBid();
  };

  const maxTick = Math.max(0, b.numTicks - 1);
  const extendable = b.antiSnipeWindow > 0 && b.antiSnipeExtension > 0;

  return (
    <div className="space-y-4">
      <GuaranteedSlotBadge account={account} />
      <div className="grid grid-cols-2 gap-2 text-xs text-muted">
        <span>
          Commit ends: {fmtDate(b.commitEnd)}
          {now > 0 && Number(b.commitEnd) > now ? ` (in ${fmtDuration(Number(b.commitEnd) - now)})` : ""}
        </span>
        <span>Reveal ends: {fmtDate(b.revealEnd)}</span>
        <span>Bidders: {b.bidderCount} / {b.maxBidders}</span>
        <span>Non-reveal penalty: {fmtBps(b.nonRevealPenaltyBps)}</span>
      </div>
      {extendable && (
        <Notice>
          Anti-snipe: a commit within the last {Math.round(b.antiSnipeWindow / 60)} min extends the commit phase by{" "}
          {Math.round(b.antiSnipeExtension / 60)} min, never beyond {fmtDate(b.maxEndTime)}.
        </Notice>
      )}

      {hasCommitted && (
        <div className="rounded-lg bg-surface-2 p-3 text-sm">
          <p className="font-medium">Your sealed bid is on-chain{revealed ? " and revealed" : ""}.</p>
          <p className="text-xs text-muted">
            Deposit: {fmtUnits(deposit ?? 0n, o.paymentToken.decimals)} {o.paymentToken.symbol}
            {revealed && bid ? ` · revealed ${fmtUnits(bid[1], o.saleToken.decimals)} ${o.saleToken.symbol} @ tick ${bid[3]}` : ""}
          </p>
        </div>
      )}

      {phase === 0 && <Notice>The commit phase has not started yet.</Notice>}

      {phase === 1 && (
        <div className="space-y-3">
          <div>
            <label className="label">Bid price (tick {tick} of {maxTick})</label>
            <input
              type="range"
              min={0}
              max={maxTick}
              step={1}
              value={tick}
              onChange={(e) => setTick(Number(e.target.value))}
              className="w-full accent-[var(--accent)]"
              disabled={b.numTicks <= 1}
            />
            <p className="text-sm font-medium tabular-nums">
              {fmtUnits(price, o.paymentToken.decimals, 6)} {o.paymentToken.symbol} per {o.saleToken.symbol}
            </p>
            <p className="text-xs text-muted">Everyone pays the single clearing price. Bidding higher improves your fill priority, not your price.</p>
          </div>
          <div>
            <label className="label">Quantity</label>
            <AmountInput value={qtyStr} onChange={setQtyStr} symbol={o.saleToken.symbol} invalid={qtyStr !== "" && (qty === undefined || qty === 0n)} />
            {overWallet && <p className="mt-1 text-xs text-red-500">Exceeds the per-wallet maximum ({fmtUnits(o.params.perWalletMax, o.saleToken.decimals)}).</p>}
            {overSupply && <p className="mt-1 text-xs text-red-500">Exceeds total supply.</p>}
          </div>
          <div>
            <label className="label">Extra masking deposit (optional)</label>
            <AmountInput value={extraStr} onChange={setExtraStr} symbol={o.paymentToken.symbol} invalid={extra === undefined} />
            <p className="mt-1 text-xs text-muted">Over-depositing hides your bid size. Any excess is refunded at settlement.</p>
          </div>
          <div className="rounded-lg bg-surface-2 p-3 text-sm">
            <div className="flex justify-between">
              <span className="text-muted">Required deposit</span>
              <span className="tabular-nums">{needed !== undefined ? fmtUnits(needed, o.paymentToken.decimals, 6) : "—"} {o.paymentToken.symbol}</span>
            </div>
            <div className="flex justify-between">
              <span className="text-muted">Already deposited</span>
              <span className="tabular-nums">{fmtUnits(deposit ?? 0n, o.paymentToken.decimals, 6)} {o.paymentToken.symbol}</span>
            </div>
            <div className="flex justify-between font-medium">
              <span>To deposit now</span>
              <span className="tabular-nums">{topUp !== undefined ? fmtUnits(topUp, o.paymentToken.decimals, 6) : "—"} {o.paymentToken.symbol}</span>
            </div>
          </div>
          <BalanceLine token={o.paymentToken} account={account} chainId={chainId} />
          <Notice tone="warn">
            <strong>Keep your bid secret safe.</strong> A random salt is generated in your browser and saved locally. Without it you cannot reveal,
            and an unrevealed bid loses {fmtBps(b.nonRevealPenaltyBps)} of its deposit. Download the backup after committing.
            {hasCommitted && " Committing again replaces your previous sealed bid."}
          </Notice>
          <label className="flex items-start gap-2 text-sm">
            <input type="checkbox" className="mt-0.5" checked={ackSalt} onChange={(e) => setAckSalt(e.target.checked)} />
            <span>I understand that losing the bid backup means I cannot reveal and will be penalised.</span>
          </label>
          <button className="btn btn-primary w-full" disabled={!canAct || !validCommit || !ackSalt || tx.busy} onClick={onCommit}>
            {tx.busy ? "Processing…" : topUp && topUp > 0n ? "Approve & commit bid" : "Commit bid"}
          </button>
        </div>
      )}

      {(justSaved || secret) && (
        <div className="flex flex-wrap items-center justify-between gap-2 rounded-lg border border-line p-3 text-sm">
          <span>
            Bid secret saved in this browser
            {(justSaved ?? secret) && ` (tick ${(justSaved ?? secret)!.tick}, ${fmtUnits(BigInt((justSaved ?? secret)!.qty), o.saleToken.decimals)} ${o.saleToken.symbol})`}
            .
          </span>
          <button className="btn btn-secondary py-1" onClick={() => downloadBidSecret((justSaved ?? secret)!)}>
            Download bid backup
          </button>
        </div>
      )}

      {phase === 2 && (
        <div className="space-y-3">
          {!hasCommitted && <Notice>You did not commit a bid in this auction.</Notice>}
          {hasCommitted && revealed && <Notice tone="success">Your bid has been revealed. Settlement opens after finalization.</Notice>}
          {hasCommitted && !revealed && (
            <>
              <Notice tone="warn">Reveal before {fmtDate(b.revealEnd)} or lose {fmtBps(b.nonRevealPenaltyBps)} of your deposit.</Notice>
              {secret ? (
                <div className="rounded-lg bg-surface-2 p-3 text-sm">
                  <p>
                    Loaded bid: {fmtUnits(BigInt(secret.qty), o.saleToken.decimals)} {o.saleToken.symbol} at{" "}
                    {fmtUnits(priceAtTick(b, secret.tick), o.paymentToken.decimals, 6)} {o.paymentToken.symbol} (tick {secret.tick})
                  </p>
                  {secretMatches === false && (
                    <p className="mt-1 text-xs text-red-500">This saved secret does not match your on-chain commitment (you may have re-committed). Import the matching backup.</p>
                  )}
                </div>
              ) : (
                <Notice tone="error">No saved bid secret found in this browser. Import your backup file to reveal.</Notice>
              )}
              <button className="btn btn-primary w-full" disabled={!secret || secretMatches === false || tx.busy} onClick={onReveal}>
                {tx.busy ? "Processing…" : "Reveal bid"}
              </button>
            </>
          )}
        </div>
      )}

      {phase !== 4 && (
        <div className="text-sm">
          <input ref={fileRef} type="file" accept="application/json,.json" className="hidden" onChange={(e) => onImport(e.target.files?.[0])} />
          <button className="text-accent underline" onClick={() => fileRef.current?.click()}>
            Import bid backup (JSON)
          </button>
          {importError && <p className="mt-1 text-xs text-red-500">{importError}</p>}
        </div>
      )}

      {phase === 3 && <Notice>The reveal phase is over. Anyone can now finalize the auction.</Notice>}
      <TxStatusLine status={tx.status} error={tx.error} />
    </div>
  );
}
