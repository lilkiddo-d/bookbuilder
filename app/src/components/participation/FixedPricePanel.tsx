"use client";

import { useState } from "react";
import type { Address } from "viem";
import { useReadContract } from "wagmi";
import { fixedPriceOfferingAbi } from "@/abi";
import { useTx } from "@/hooks/useTx";
import { fmtUnits, safeParseUnits } from "@/lib/format";
import type { OfferingSummary } from "@/lib/offerings";
import { AmountInput, BalanceLine, TxStatusLine, useTokenBalance } from "./common";

export function FixedPricePanel({
  o,
  account,
  chainId,
  canAct,
}: {
  o: OfferingSummary;
  account: Address;
  chainId: number;
  canAct: boolean;
}) {
  const [amount, setAmount] = useState("");
  const tx = useTx();
  const tokens = safeParseUnits(amount, o.saleToken.decimals);
  const valid = tokens !== undefined && tokens > 0n;

  const { data: cost } = useReadContract({
    address: o.address,
    abi: fixedPriceOfferingAbi,
    functionName: "quote",
    args: [tokens ?? 0n],
    chainId,
    query: { enabled: valid },
  });
  const { data: purchased } = useReadContract({
    address: o.address,
    abi: fixedPriceOfferingAbi,
    functionName: "purchased",
    args: [account],
    chainId,
  });
  const { data: balance } = useTokenBalance(o.paymentToken.address, account, chainId);

  const remainingSupply = o.params.supply - (o.fixed?.totalSold ?? 0n);
  const walletRemaining =
    o.params.perWalletMax > 0n ? o.params.perWalletMax - (purchased ?? 0n) : undefined;
  const overSupply = valid && tokens > remainingSupply;
  const overWallet = valid && walletRemaining !== undefined && tokens > walletRemaining;
  const insufficient = cost !== undefined && balance !== undefined && cost > balance;

  const onBuy = async () => {
    if (!valid || cost === undefined) return;
    const ok = await tx.ensureAllowance(o.paymentToken.address, o.address, cost, o.paymentToken.symbol);
    if (!ok) return;
    const done = await tx.run(`Buy ${fmtUnits(tokens, o.saleToken.decimals)} ${o.saleToken.symbol}`, () =>
      tx.writeContractAsync({
        address: o.address,
        abi: fixedPriceOfferingAbi,
        functionName: "buy",
        args: [tokens],
        chainId,
      }),
    );
    if (done) setAmount("");
  };

  return (
    <div className="space-y-3">
      <div>
        <label className="label">Tokens to buy</label>
        <AmountInput value={amount} onChange={setAmount} symbol={o.saleToken.symbol} invalid={amount !== "" && !valid} />
        <div className="mt-1 flex flex-wrap justify-between gap-2 text-xs text-muted">
          <span>Remaining supply: {fmtUnits(remainingSupply, o.saleToken.decimals)}</span>
          {walletRemaining !== undefined && <span>Your remaining wallet limit: {fmtUnits(walletRemaining, o.saleToken.decimals)}</span>}
        </div>
      </div>
      <div className="rounded-lg bg-surface-2 p-3 text-sm">
        <div className="flex justify-between">
          <span className="text-muted">Cost</span>
          <span className="font-medium tabular-nums">
            {valid && cost !== undefined ? `${fmtUnits(cost, o.paymentToken.decimals, 6)} ${o.paymentToken.symbol}` : "—"}
          </span>
        </div>
        <p className="mt-1 text-xs text-muted">
          You approve the offering contract, which moves your payment straight into its escrow ({o.escrow.slice(0, 10)}…). Funds never go directly to the issuer.
        </p>
      </div>
      <BalanceLine token={o.paymentToken} account={account} chainId={chainId} />
      {overSupply && <p className="text-xs text-red-500">Exceeds remaining supply.</p>}
      {overWallet && <p className="text-xs text-red-500">Exceeds the per-wallet maximum.</p>}
      {insufficient && <p className="text-xs text-red-500">Insufficient {o.paymentToken.symbol} balance.</p>}
      <button
        className="btn btn-primary w-full"
        disabled={!canAct || !valid || cost === undefined || overSupply || overWallet || insufficient || tx.busy}
        onClick={onBuy}
      >
        {tx.busy ? "Processing…" : "Approve & buy"}
      </button>
      {purchased !== undefined && purchased > 0n && (
        <p className="text-xs text-muted">
          You have bought {fmtUnits(purchased, o.saleToken.decimals)} {o.saleToken.symbol} in this offering.
        </p>
      )}
      <TxStatusLine status={tx.status} error={tx.error} />
    </div>
  );
}
