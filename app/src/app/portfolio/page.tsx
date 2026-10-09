"use client";

import Link from "next/link";
import { useMemo } from "react";
import type { Address } from "viem";
import { useAccount, useReadContract, useReadContracts } from "wagmi";
import { ConnectButton } from "@rainbow-me/rainbowkit";
import { deliveryVestingAbi, erc20Abi, offeringEscrowAbi } from "@/abi";
import { DeploymentGate } from "@/components/NetworkGate";
import { SettlementPanel } from "@/components/participation/SettlementPanel";
import { EmptyState, KindBadge, Notice, ProgressBar, SectionTitle, Spinner, StageBadge } from "@/components/ui";
import { TxStatusLine } from "@/components/participation/common";
import { useAllOfferings } from "@/hooks/useOfferings";
import { useProtocol } from "@/hooks/useProtocol";
import { useNow } from "@/hooks/useNow";
import { useTx } from "@/hooks/useTx";
import { fmtDate, fmtDuration, fmtUnits, pct } from "@/lib/format";
import type { Deployment } from "@/lib/types";

function Allocations({ account }: { account: Address }) {
  const { chainId } = useProtocol();
  const { data: offerings, isLoading } = useAllOfferings();
  const { data: deposits } = useReadContracts({
    contracts: (offerings ?? []).map((o) => ({
      address: o.escrow,
      abi: offeringEscrowAbi,
      functionName: "depositOf" as const,
      args: [account] as const,
      chainId,
    })),
    query: { enabled: !!offerings && offerings.length > 0, refetchInterval: 15_000 },
  });
  const mine = useMemo(
    () =>
      (offerings ?? []).filter((_, i) => {
        const r = deposits?.[i];
        return r?.status === "success" && typeof r.result === "bigint" && r.result > 0n;
      }),
    [offerings, deposits],
  );

  if (isLoading) return <Spinner label="Loading allocations…" />;
  if (mine.length === 0)
    return (
      <EmptyState title="No allocations yet">
        Participate in an offering from the <Link href="/" className="text-accent underline">calendar</Link>.
      </EmptyState>
    );
  return (
    <div className="grid gap-4 md:grid-cols-2">
      {mine.map((o) => (
        <div key={o.address} className="card space-y-3">
          <div className="flex items-start justify-between gap-2">
            <div>
              <Link href={`/offering/${o.address}`} className="text-lg font-semibold hover:underline">
                {o.saleToken.symbol}
              </Link>
              <p className="text-xs text-muted">paid in {o.paymentToken.symbol}</p>
            </div>
            <div className="flex flex-col items-end gap-1">
              <StageBadge stage={o.escrowInfo.stage} cancelled={o.escrowInfo.cancelled} />
              <KindBadge kind={o.kind} />
            </div>
          </div>
          <SettlementPanel o={o} account={account} chainId={chainId} />
        </div>
      ))}
    </div>
  );
}

function Vesting({ account, vesting }: { account: Address; vesting: Address }) {
  const { chainId } = useProtocol();
  const now = useNow(5000);
  const tx = useTx();
  const { data: ids, isLoading } = useReadContract({
    address: vesting,
    abi: deliveryVestingAbi,
    functionName: "schedulesOf",
    args: [account],
    chainId,
    query: { refetchInterval: 20_000 },
  });
  const idList = ids ?? [];
  const { data: rows } = useReadContracts({
    contracts: idList.flatMap((id) => [
      { address: vesting, abi: deliveryVestingAbi, functionName: "getSchedule" as const, args: [id] as const, chainId },
      { address: vesting, abi: deliveryVestingAbi, functionName: "releasable" as const, args: [id] as const, chainId },
    ]),
    query: { enabled: idList.length > 0, refetchInterval: 15_000 },
  });
  const schedules = idList.map((id, i) => {
    const s = rows?.[i * 2];
    const r = rows?.[i * 2 + 1];
    return {
      id,
      schedule: s?.status === "success" ? (s.result as { beneficiary: Address; token: Address; start: bigint; cliff: bigint; duration: bigint; total: bigint; released: bigint }) : undefined,
      releasable: r?.status === "success" ? (r.result as bigint) : undefined,
    };
  });
  const tokens = [...new Set(schedules.map((s) => s.schedule?.token).filter((t): t is Address => !!t))];
  const { data: meta } = useReadContracts({
    contracts: tokens.flatMap((t) => [
      { address: t, abi: erc20Abi, functionName: "symbol" as const, chainId },
      { address: t, abi: erc20Abi, functionName: "decimals" as const, chainId },
    ]),
    query: { enabled: tokens.length > 0 },
  });
  const metaOf = (t: Address) => {
    const i = tokens.indexOf(t);
    const sym = meta?.[i * 2];
    const dec = meta?.[i * 2 + 1];
    return {
      symbol: sym?.status === "success" ? String(sym.result) : "TOKEN",
      decimals: dec?.status === "success" ? Number(dec.result) : 18,
    };
  };

  if (isLoading) return <Spinner label="Loading vesting schedules…" />;
  if (idList.length === 0) return <EmptyState title="No vesting schedules">Schedules appear here when you claim tokens from an offering with a lockup.</EmptyState>;

  return (
    <div className="space-y-3">
      {schedules.map(({ id, schedule: s, releasable }) => {
        if (!s) return null;
        const m = metaOf(s.token);
        const cliffEnd = s.start + s.cliff;
        const end = s.start + s.duration;
        const vested = s.released + (releasable ?? 0n);
        return (
          <div key={id.toString()} className="card space-y-2">
            <div className="flex flex-wrap items-center justify-between gap-2">
              <p className="font-medium">
                Schedule #{id.toString()} · {fmtUnits(s.total, m.decimals)} {m.symbol}
              </p>
              <button
                className="btn btn-primary py-1.5"
                disabled={!releasable || tx.busy}
                onClick={() =>
                  tx.run(`Release ${m.symbol}`, () =>
                    tx.writeContractAsync({ address: vesting, abi: deliveryVestingAbi, functionName: "release", args: [id], chainId }),
                  )
                }
              >
                Release {releasable ? fmtUnits(releasable, m.decimals) : "0"} {m.symbol}
              </button>
            </div>
            <ProgressBar
              value={pct(vested, s.total)}
              label={`Vested ${fmtUnits(vested, m.decimals)} · released ${fmtUnits(s.released, m.decimals)} of ${fmtUnits(s.total, m.decimals)} ${m.symbol}`}
            />
            <p className="text-xs text-muted">
              Start {fmtDate(s.start)} · cliff {fmtDate(cliffEnd)} ({fmtDuration(s.cliff)}) · fully vested {fmtDate(end)}
              {now > 0 && Number(cliffEnd) > now ? ` · cliff in ${fmtDuration(Number(cliffEnd) - now)}` : ""}
            </p>
          </div>
        );
      })}
      <TxStatusLine status={tx.status} error={tx.error} />
    </div>
  );
}

function PortfolioView({ deployment }: { deployment: Deployment }) {
  const { address, isConnected } = useAccount();
  const { wrongNetwork } = useProtocol();
  if (!isConnected || !address)
    return (
      <div className="card space-y-3">
        <p className="text-sm text-muted">Connect a wallet to see your allocations and vesting schedules.</p>
        <ConnectButton />
      </div>
    );
  if (wrongNetwork) return <Notice tone="warn">Switch your wallet to a supported network.</Notice>;
  return (
    <div className="space-y-8">
      <section>
        <SectionTitle>My allocations</SectionTitle>
        <Allocations account={address} />
      </section>
      <section>
        <SectionTitle>Vesting</SectionTitle>
        <Vesting account={address} vesting={deployment.contracts.DeliveryVesting} />
      </section>
    </div>
  );
}

export default function PortfolioPage() {
  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold tracking-tight">Portfolio</h1>
        <p className="mt-1 text-sm text-muted">Your deposits, allocations, refunds and vesting across all offerings.</p>
      </div>
      <DeploymentGate>{(d) => <PortfolioView deployment={d} />}</DeploymentGate>
    </div>
  );
}
