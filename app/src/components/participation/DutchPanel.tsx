"use client";

import { useState } from "react";
import type { Address } from "viem";
import { useReadContract } from "wagmi";
import { dutchAuctionAbi } from "@/abi";
import { useTx } from "@/hooks/useTx";
import { fmtUnits, safeParseUnits } from "@/lib/format";
import type { OfferingSummary } from "@/lib/offerings";
import { AmountInput, BalanceLine, TxStatusLine, useTokenBalance } from "./common";

const SLIPPAGE_BPS = 100n; // 1%

export function DutchPanel({
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

  const { data: currentPrice } = useReadContract({
    address: o.address,
    abi: dutchAuctionAbi,
    functionName: "currentPrice",
    chainId,
    query: { refetchInterval: 5_000 },
  });
  const { data: cost } = useReadContract({
    address: o.address,
    abi: dutchAuctionAbi,
    functionName: "quote",
    args: [tokens ?? 0n],
    chainId,
    query: { enabled: valid, refetchInterval: 5_000 },
  });
  const { data: purchased } = useReadContract({
    address: o.address,
    abi: dutchAuctionAbi,
    functionName: "purchased",
    args: [account],
    chainId,
  });
  const { data: balance } = useTokenBalance(o.paymentToken.address, account, chainId);

  // the price only falls, so the buffer protects against a stale quote; never more than balance
  const maxCost = cost !== undefined ? cost + (cost * SLIPPAGE_BPS + 9_999n) / 10_000n : undefined;
  const remainingSupply = o.params.supply - (o.dutch?.totalSold ?? 0n);
  const walletRemaining = o.params.perWalletMax > 0n ? o.params.perWalletMax - (purchased ?? 0n) : undefined;
  const overSupply = valid && tokens > remainingSupply;
  const overWallet = valid && walletRemaining !== undefined && tokens > walletRemaining;
  const insufficient = cost !== undefined && balance !== undefined && cost > balance;

  const onBuy = async () => {
    if (!valid || maxCost === undefined) return;
    const cap = balance !== undefined && maxCost > balance ? balance : maxCost;
    const ok = await tx.ensureAllowance(o.paymentToken.address, o.address, cap, o.paymentToken.symbol);
    if (!ok) return;
    const done = await tx.run(`Buy ${fmtUnits(tokens, o.saleToken.decimals)} ${o.saleToken.symbol}`, () =>
      tx.writeContractAsync({
        address: o.address,
        abi: dutchAuctionAbi,
        functionName: "buy",
        args: [tokens, cap],
        chainId,
      }),
    );
    if (done) setAmount("");
  };

  return (
    <div className="space-y-3">
      <div className="rounded-lg bg-surface-2 p-3 text-sm">
        <div className="flex justify-between">
          <span className="text-muted">Current price</span>
          <span className="font-medium tabular-nums">
            {currentPrice !== undefined ? `${fmtUnits(currentPrice, o.paymentToken.decimals, 6)} ${o.paymentToken.symbol}` : "—"}
          </span>
        </div>
        <p className="mt-1 text-xs text-muted">Price falls linearly to the floor; you pay the price at the block your purchase is mined.</p>
      </div>
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
          <span className="text-muted">Estimated cost</span>
          <span className="tabular-nums">{valid && cost !== undefined ? `${fmtUnits(cost, o.paymentToken.decimals, 6)} ${o.paymentToken.symbol}` : "—"}</span>
        </div>
        <div className="flex justify-between">
          <span className="text-muted">Max cost (1% slippage)</span>
          <span className="tabular-nums">{valid && maxCost !== undefined ? `${fmtUnits(maxCost, o.paymentToken.decimals, 6)} ${o.paymentToken.symbol}` : "—"}</span>
        </div>
      </div>
      <BalanceLine token={o.paymentToken} account={account} chainId={chainId} />
      {overSupply && <p className="text-xs text-red-500">Exceeds remaining supply.</p>}
      {overWallet && <p className="text-xs text-red-500">Exceeds the per-wallet maximum.</p>}
      {insufficient && <p className="text-xs text-red-500">Insufficient {o.paymentToken.symbol} balance.</p>}
      <button
        className="btn btn-primary w-full"
        disabled={!canAct || !valid || maxCost === undefined || overSupply || overWallet || insufficient || tx.busy}
        onClick={onBuy}
      >
        {tx.busy ? "Processing…" : "Approve & buy"}
      </button>
      {purchased !== undefined && purchased > 0n && (
        <p className="text-xs text-muted">
          You have bought {fmtUnits(purchased, o.saleToken.decimals)} {o.saleToken.symbol} in this auction.
        </p>
      )}
      <TxStatusLine status={tx.status} error={tx.error} />
    </div>
  );
}
