"use client";

import { useState } from "react";
import type { Address } from "viem";
import { useAccount, useReadContract, useReadContracts } from "wagmi";
import { ConnectButton } from "@rainbow-me/rainbowkit";
import { erc20Abi, projectTokenHooksAbi } from "@/abi";
import { DeploymentGate } from "@/components/NetworkGate";
import { AmountInput, BalanceLine, TxStatusLine } from "@/components/participation/common";
import { EmptyState, Kv, Notice, SectionTitle, Spinner, Stat } from "@/components/ui";
import { useProjectToken } from "@/components/TokenFeatures";
import { useNow } from "@/hooks/useNow";
import { useProtocol } from "@/hooks/useProtocol";
import { useTx } from "@/hooks/useTx";
import { fmtBps, fmtDate, fmtDuration, fmtUnits, safeParseUnits } from "@/lib/format";
import type { TokenMeta } from "@/lib/offerings";

function useTokenMeta(address: Address | undefined, chainId: number): TokenMeta | undefined {
  const { data } = useReadContracts({
    contracts: address
      ? [
          { address, abi: erc20Abi, functionName: "symbol", chainId },
          { address, abi: erc20Abi, functionName: "decimals", chainId },
        ]
      : [],
    query: { enabled: !!address },
  });
  if (!address || !data) return undefined;
  return {
    address,
    symbol: data[0]?.status === "success" ? String(data[0].result) : "TOKEN",
    decimals: data[1]?.status === "success" ? Number(data[1].result) : 18,
  };
}

function StakeView({ hooks, account }: { hooks: Address; account: Address }) {
  const { chainId } = useProtocol();
  const now = useNow();
  const tx = useTx();
  const [stakeAmt, setStakeAmt] = useState("");
  const [unstakeAmt, setUnstakeAmt] = useState("");

  const c = { address: hooks, abi: projectTokenHooksAbi, chainId } as const;
  const { data } = useReadContracts({
    contracts: [
      { ...c, functionName: "projectToken" },
      { ...c, functionName: "rewardToken" },
      { ...c, functionName: "tiers" },
      { ...c, functionName: "accounts", args: [account] },
      { ...c, functionName: "tierOf", args: [account] },
      { ...c, functionName: "guaranteedBps", args: [account] },
      { ...c, functionName: "pendingRewards", args: [account] },
      { ...c, functionName: "totalStaked" },
      { ...c, functionName: "unstakeCooldown" },
      { ...c, functionName: "minStakeAge" },
    ],
    query: { refetchInterval: 15_000 },
  });
  const projectToken = data?.[0]?.result;
  const rewardToken = data?.[1]?.result;
  const tiers = data?.[2]?.result ?? [];
  const acct = data?.[3]?.result;
  const tier = data?.[4]?.result ?? 0n;
  const gBps = data?.[5]?.result ?? 0;
  const pending = data?.[6]?.result ?? 0n;
  const totalStaked = data?.[7]?.result ?? 0n;
  const cooldown = data?.[8]?.result ?? 0n;
  const minAge = data?.[9]?.result ?? 0n;

  const pt = useTokenMeta(projectToken, chainId);
  const rt = useTokenMeta(rewardToken, chainId);
  const { data: ptBalance } = useReadContract({
    address: projectToken,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: [account],
    chainId,
    query: { enabled: !!projectToken },
  });

  if (!pt || !acct) return <Spinner />;
  const [staked, pendingUnstake, eligibleAt, unlockAt] = acct;
  const stakeVal = safeParseUnits(stakeAmt, pt.decimals);
  const unstakeVal = safeParseUnits(unstakeAmt, pt.decimals);
  const agingLeft = now > 0 && Number(eligibleAt) > now ? Number(eligibleAt) - now : 0;
  const unlockLeft = now > 0 && Number(unlockAt) > now ? Number(unlockAt) - now : 0;

  const onStake = async () => {
    if (!stakeVal) return;
    const ok = await tx.ensureAllowance(pt.address, hooks, stakeVal, pt.symbol);
    if (!ok) return;
    if (await tx.run(`Stake ${pt.symbol}`, () => tx.writeContractAsync({ ...c, functionName: "stake", args: [stakeVal] }))) setStakeAmt("");
  };

  return (
    <div className="space-y-6">
      <div className="card grid grid-cols-2 gap-4 sm:grid-cols-4">
        <Stat label="Your stake" value={fmtUnits(staked, pt.decimals, 2)} sub={pt.symbol} />
        <Stat label="Your tier" value={tier === 0n ? "None" : `Tier ${tier.toString()}`} sub={gBps ? `${fmtBps(gBps)} guaranteed slot` : agingLeft ? `active in ${fmtDuration(agingLeft)}` : undefined} />
        <Stat label="Pending rewards" value={rt ? fmtUnits(pending, rt.decimals, 4) : "—"} sub={rt?.symbol} />
        <Stat label="Total staked" value={fmtUnits(totalStaked, pt.decimals, 0)} sub={pt.symbol} />
      </div>

      <div className="grid gap-6 md:grid-cols-2">
        <div className="card space-y-3">
          <SectionTitle>Stake</SectionTitle>
          <AmountInput value={stakeAmt} onChange={setStakeAmt} symbol={pt.symbol} invalid={stakeAmt !== "" && !stakeVal} />
          <BalanceLine token={pt} account={account} chainId={chainId} />
          <p className="text-xs text-muted">
            New stake must age {fmtDuration(minAge)} before it counts toward tiers. Any top-up restarts the aging clock.
          </p>
          <button className="btn btn-primary w-full" disabled={!stakeVal || (ptBalance !== undefined && stakeVal > ptBalance) || tx.busy} onClick={onStake}>
            Approve & stake
          </button>
        </div>

        <div className="card space-y-3">
          <SectionTitle>Unstake</SectionTitle>
          <AmountInput value={unstakeAmt} onChange={setUnstakeAmt} symbol={pt.symbol} invalid={unstakeAmt !== "" && !unstakeVal} />
          <p className="text-xs text-muted">Cooldown: {fmtDuration(cooldown)}. Tier benefits drop immediately for the unstaked amount.</p>
          <button
            className="btn btn-secondary w-full"
            disabled={!unstakeVal || unstakeVal > staked || tx.busy}
            onClick={async () => {
              if (!unstakeVal) return;
              if (await tx.run("Request unstake", () => tx.writeContractAsync({ ...c, functionName: "requestUnstake", args: [unstakeVal] }))) setUnstakeAmt("");
            }}
          >
            Request unstake
          </button>
          {pendingUnstake > 0n && (
            <div className="rounded-lg bg-surface-2 p-3 text-sm">
              <p>
                Pending withdrawal: {fmtUnits(pendingUnstake, pt.decimals)} {pt.symbol}
              </p>
              <p className="text-xs text-muted">{unlockLeft ? `Unlocks ${fmtDate(unlockAt)} (in ${fmtDuration(unlockLeft)})` : "Unlocked"}</p>
              <button
                className="btn btn-primary mt-2 w-full"
                disabled={unlockLeft > 0 || tx.busy}
                onClick={() => tx.run("Withdraw", () => tx.writeContractAsync({ ...c, functionName: "withdraw" }))}
              >
                Withdraw
              </button>
            </div>
          )}
        </div>
      </div>

      <div className="grid gap-6 md:grid-cols-2">
        <div className="card space-y-3">
          <SectionTitle>Fee sharing</SectionTitle>
          <p className="text-sm text-muted">A share of protocol fees is distributed pro-rata to stakers in {rt?.symbol ?? "the reward token"}.</p>
          <Kv k="Claimable">{rt ? `${fmtUnits(pending, rt.decimals)} ${rt.symbol}` : "—"}</Kv>
          <button
            className="btn btn-primary w-full"
            disabled={pending === 0n || tx.busy}
            onClick={() => tx.run("Claim rewards", () => tx.writeContractAsync({ ...c, functionName: "claimRewards" }))}
          >
            Claim rewards
          </button>
        </div>
        <div className="card">
          <SectionTitle>Tiers</SectionTitle>
          {tiers.length === 0 ? (
            <p className="text-sm text-muted">No tiers configured by governance yet.</p>
          ) : (
            tiers.map((t, i) => (
              <Kv key={i} k={`Tier ${i + 1}${BigInt(i + 1) === tier ? " (you)" : ""}`}>
                ≥ {fmtUnits(t.minStake, pt.decimals, 0)} {pt.symbol} · {fmtBps(t.guaranteedBps)} guaranteed slot
              </Kv>
            ))
          )}
          <p className="mt-2 text-xs text-muted">
            A guaranteed slot is the share of an oversubscribed batch auction&apos;s supply filled first for your marginal bid at the clearing price. Stakers
            may also join during priority windows.
          </p>
        </div>
      </div>
      <TxStatusLine status={tx.status} error={tx.error} />
    </div>
  );
}

function StakeGate() {
  const { configured, enabled, loading, hooks } = useProjectToken();
  const { address, isConnected } = useAccount();
  const { wrongNetwork } = useProtocol();
  if (!configured) return <EmptyState title="Staking is not available">The project token is not configured for this deployment.</EmptyState>;
  if (loading) return <Spinner />;
  if (!enabled || !hooks) return <EmptyState title="Token not yet activated">Staking opens once governance activates the project token on-chain.</EmptyState>;
  if (!isConnected || !address)
    return (
      <div className="card space-y-3">
        <p className="text-sm text-muted">Connect a wallet to stake.</p>
        <ConnectButton />
      </div>
    );
  if (wrongNetwork) return <Notice tone="warn">Switch your wallet to a supported network.</Notice>;
  return <StakeView hooks={hooks} account={address} />;
}

export default function StakePage() {
  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold tracking-tight">Stake</h1>
        <p className="mt-1 text-sm text-muted">Stake the project token for guaranteed auction slots, priority access, and a share of protocol fees.</p>
      </div>
      <DeploymentGate>{() => <StakeGate />}</DeploymentGate>
    </div>
  );
}
