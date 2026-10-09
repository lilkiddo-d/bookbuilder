"use client";

import { useCallback, useState } from "react";
import type { Address, Hash } from "viem";
import { useAccount, useConfig, useSwitchChain, useWaitForTransactionReceipt, useWriteContract } from "wagmi";
import { readContract, waitForTransactionReceipt } from "wagmi/actions";
import { erc20Abi } from "@/abi";
import { useQueryClient } from "@tanstack/react-query";
import { useToast } from "@/components/Toaster";
import { useProtocol } from "./useProtocol";
import { explorerTxUrl } from "@/lib/chains";
import { errorMessage } from "@/lib/format";

export type TxStatus = "idle" | "signing" | "pending" | "success" | "error";

/**
 * Wraps wagmi's useWriteContract with: network switching to the read chain, toasts,
 * receipt waiting (sequential approve -> action flows), and query invalidation on success.
 */
export function useTx() {
  const config = useConfig();
  const { chainId } = useProtocol();
  const { chainId: walletChainId, address: account } = useAccount();
  const { switchChainAsync } = useSwitchChain();
  const { writeContractAsync } = useWriteContract();
  const queryClient = useQueryClient();
  const toast = useToast();
  const [status, setStatus] = useState<TxStatus>("idle");
  const [hash, setHash] = useState<Hash | undefined>();
  const [error, setError] = useState<string | undefined>();
  const receipt = useWaitForTransactionReceipt({ hash, chainId });

  const run = useCallback(
    async (label: string, send: () => Promise<Hash>): Promise<boolean> => {
      setError(undefined);
      setStatus("signing");
      const id = toast.push({ kind: "pending", title: label, body: "Confirm in your wallet…" });
      try {
        if (walletChainId !== chainId) await switchChainAsync({ chainId });
        const h = await send();
        setHash(h);
        setStatus("pending");
        toast.update(id, { body: "Waiting for confirmation…", href: explorerTxUrl(chainId, h) });
        const r = await waitForTransactionReceipt(config, { hash: h, chainId });
        if (r.status !== "success") throw new Error("Transaction reverted");
        setStatus("success");
        toast.update(id, { kind: "success", body: "Confirmed" });
        await queryClient.invalidateQueries();
        return true;
      } catch (e) {
        const msg = errorMessage(e);
        setStatus("error");
        setError(msg);
        toast.update(id, { kind: "error", body: msg });
        return false;
      }
    },
    [config, chainId, walletChainId, switchChainAsync, queryClient, toast],
  );

  /** Approve `spender` for exactly `amount` of `token` if the current allowance is lower. */
  const ensureAllowance = useCallback(
    async (token: Address, spender: Address, amount: bigint, symbol = "token"): Promise<boolean> => {
      if (!account || amount === 0n) return true;
      try {
        const current = await readContract(config, {
          address: token,
          abi: erc20Abi,
          functionName: "allowance",
          args: [account, spender],
          chainId,
        });
        if (current >= amount) return true;
      } catch {
        /* fall through and approve */
      }
      return run(`Approve ${symbol}`, () =>
        writeContractAsync({ address: token, abi: erc20Abi, functionName: "approve", args: [spender, amount], chainId }),
      );
    },
    [account, config, chainId, run, writeContractAsync],
  );

  return {
    run,
    ensureAllowance,
    writeContractAsync,
    status,
    hash,
    error,
    receiptStatus: receipt.status,
    busy: status === "signing" || status === "pending",
  };
}
