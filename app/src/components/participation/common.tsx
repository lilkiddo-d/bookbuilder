"use client";

import type { ReactNode } from "react";
import type { Address } from "viem";
import { useReadContract } from "wagmi";
import { erc20Abi } from "@/abi";
import { fmtUnits } from "@/lib/format";
import type { TokenMeta } from "@/lib/offerings";
import type { TxStatus } from "@/hooks/useTx";

export function useTokenBalance(token: Address, account: Address | undefined, chainId: number) {
  return useReadContract({
    address: token,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: account ? [account] : undefined,
    chainId,
    query: { enabled: !!account, refetchInterval: 10_000 },
  });
}

export function BalanceLine({ token, account, chainId }: { token: TokenMeta; account: Address | undefined; chainId: number }) {
  const { data } = useTokenBalance(token.address, account, chainId);
  return (
    <p className="text-xs text-muted">
      Balance: {data === undefined ? "—" : fmtUnits(data, token.decimals)} {token.symbol}
    </p>
  );
}

export function TxStatusLine({ status, error }: { status: TxStatus; error?: string }) {
  if (status === "idle") return null;
  const text: Record<TxStatus, ReactNode> = {
    idle: null,
    signing: "Waiting for wallet signature…",
    pending: "Transaction submitted, waiting for confirmation…",
    success: "Transaction confirmed.",
    error: `Transaction failed: ${error ?? "unknown error"}`,
  };
  return (
    <p className={`text-xs ${status === "error" ? "text-red-500" : status === "success" ? "text-emerald-600" : "text-muted"}`}>
      {text[status]}
    </p>
  );
}

export function AmountInput({
  value,
  onChange,
  symbol,
  placeholder,
  disabled,
  invalid,
}: {
  value: string;
  onChange: (v: string) => void;
  symbol: string;
  placeholder?: string;
  disabled?: boolean;
  invalid?: boolean;
}) {
  return (
    <div className="relative">
      <input
        className={`input pr-20 tabular-nums ${invalid ? "border-red-500" : ""}`}
        inputMode="decimal"
        value={value}
        placeholder={placeholder ?? "0.0"}
        disabled={disabled}
        onChange={(e) => onChange(e.target.value)}
      />
      <span className="pointer-events-none absolute right-3 top-1/2 -translate-y-1/2 text-xs text-muted">{symbol}</span>
    </div>
  );
}
