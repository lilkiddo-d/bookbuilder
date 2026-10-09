"use client";

import Link from "next/link";
import type { Address } from "viem";
import { useAccount, useReadContract } from "wagmi";
import { ConnectButton } from "@rainbow-me/rainbowkit";
import { complianceRegistryAbi, fixedPriceOfferingAbi, offeringEscrowAbi } from "@/abi";
import { useProtocol } from "@/hooks/useProtocol";
import { useRiskAck } from "@/hooks/useRiskAck";
import { useTx } from "@/hooks/useTx";
import { fmtDate } from "@/lib/format";
import { participationEnd, type OfferingSummary } from "@/lib/offerings";
import { OfferingKind, Stage } from "@/lib/types";
import { Notice, SectionTitle } from "../ui";
import { RiskAck } from "../RiskAck";
import { TierBadge } from "../TokenFeatures";
import { BatchPanel } from "./BatchPanel";
import { DutchPanel } from "./DutchPanel";
import { FixedPricePanel } from "./FixedPricePanel";
import { SettlementPanel } from "./SettlementPanel";
import { TxStatusLine } from "./common";

function Eligibility({ o, account, eligible }: { o: OfferingSummary; account: Address; eligible: boolean | undefined }) {
  const { deployment, chainId } = useProtocol();
  const { data: att } = useReadContract({
    address: deployment?.contracts.ComplianceRegistry,
    abi: complianceRegistryAbi,
    functionName: "attestationOf",
    args: [account],
    chainId,
    query: { enabled: !!deployment },
  });
  if (eligible === undefined) return null;
  if (eligible) {
    return (
      <Notice tone="success">
        You are eligible to participate{att && att.tier > 0 ? ` (compliance tier ${att.tier}${att.accredited ? ", accredited" : ""})` : ""}.
      </Notice>
    );
  }
  const rules = o.params.compliance;
  const now = Math.floor(Date.now() / 1000);
  const inPriority = o.params.priorityWindow > 0 && now < Number(o.params.startTime) + o.params.priorityWindow;
  const reasons: string[] = [];
  if (att) {
    if (att.frozen) reasons.push("your attestation is frozen");
    if (att.tier === 0) reasons.push("no KYC attestation found for this wallet");
    else if (Number(att.expiry) < now) reasons.push(`your attestation expired on ${fmtDate(att.expiry)}`);
    if (rules.enabled && att.tier > 0 && att.tier < rules.minTier) reasons.push(`tier ${rules.minTier} required (you have ${att.tier})`);
    if (rules.enabled && rules.requireAccredited && !att.accredited) reasons.push("accredited / professional investor status required");
  }
  if (inPriority) reasons.push(`priority window: only tier ${o.params.priorityTier}+ investors (or $BOOK stakers) until ${fmtDate(o.params.startTime + BigInt(o.params.priorityWindow))}`);
  return (
    <Notice tone="warn">
      <p className="font-medium">This wallet is not eligible to participate right now.</p>
      {reasons.length > 0 && (
        <ul className="mt-1 list-disc pl-5">
          {reasons.map((r) => (
            <li key={r}>{r}</li>
          ))}
        </ul>
      )}
      <p className="mt-1">
        Eligibility is attested on-chain by an approved KYC/compliance provider. See the{" "}
        <Link href="/risk#compliance" className="text-accent underline">
          compliance & eligibility
        </Link>{" "}
        section for how to get verified.
      </p>
    </Notice>
  );
}

export function ParticipationPanel({ o, now }: { o: OfferingSummary; now: number }) {
  const { address: account, isConnected } = useAccount();
  const { chainId, wrongNetwork } = useProtocol();
  const [acked] = useRiskAck();

  const { data: eligible } = useReadContract({
    address: o.address,
    abi: fixedPriceOfferingAbi,
    functionName: "canParticipate",
    args: account ? [account] : undefined,
    chainId,
    query: { enabled: !!account, refetchInterval: 20_000 },
  });

  if (!isConnected || !account) {
    return (
      <div className="card space-y-3">
        <SectionTitle>Participate</SectionTitle>
        <p className="text-sm text-muted">Connect a wallet to check eligibility and participate.</p>
        <ConnectButton />
      </div>
    );
  }
  if (wrongNetwork) {
    return (
      <div className="card">
        <SectionTitle>Participate</SectionTitle>
        <Notice tone="warn">Switch your wallet to a supported network to continue.</Notice>
      </div>
    );
  }

  const n = BigInt(now || 0);
  const active = o.escrowInfo.stage === Stage.Active && !o.finalized;
  const started = now > 0 && n >= o.params.startTime;
  const isBatch = o.kind === OfferingKind.BatchAuction;
  const open = active && started && (isBatch ? n < (o.batch?.revealEnd ?? 0n) : n < participationEnd(o));
  const canAct = acked && eligible === true;

  return (
    <div className="space-y-4">
      {(active || o.batch) && (
        <div className="card space-y-4">
          <SectionTitle right={<TierBadge account={account} />}>Participate</SectionTitle>
          {!started && active && <Notice>Opens {fmtDate(o.params.startTime)}.</Notice>}
          {active && started && !open && <Notice>Participation has ended. Waiting for finalization.</Notice>}
          {active && <Eligibility o={o} account={account} eligible={eligible} />}
          {open && <RiskAck />}
          {open && !acked && <p className="text-xs text-muted">Acknowledge the risk disclosure to enable participation.</p>}
          {o.kind === OfferingKind.FixedPrice && open && <FixedPricePanel o={o} account={account} chainId={chainId} canAct={canAct} />}
          {o.kind === OfferingKind.DutchAuction && open && <DutchPanel o={o} account={account} chainId={chainId} canAct={canAct} />}
          {isBatch && <BatchPanel o={o} account={account} chainId={chainId} canAct={canAct} now={now} />}
        </div>
      )}
      <div className="card">
        <SectionTitle>Your position</SectionTitle>
        <PositionOrEmpty o={o} account={account} chainId={chainId} />
      </div>
    </div>
  );
}

function PositionOrEmpty({ o, account, chainId }: { o: OfferingSummary; account: Address; chainId: number }) {
  const { data: deposit } = useReadContract({
    address: o.escrow,
    abi: offeringEscrowAbi,
    functionName: "depositOf",
    args: [account],
    chainId,
  });
  if (!deposit) return <p className="text-sm text-muted">No deposit from this wallet.</p>;
  return <SettlementPanel o={o} account={account} chainId={chainId} />;
}

/** Permissionless lifecycle actions: finalize and mark delivery failed. */
export function PublicActions({ o, now }: { o: OfferingSummary; now: number }) {
  const { isConnected } = useAccount();
  const { chainId } = useProtocol();
  const tx = useTx();
  const deliveryMissed =
    o.escrowInfo.stage === Stage.Succeeded && now > 0 && BigInt(now) > o.escrowInfo.deliveryDeadline;
  if (!o.canFinalize && !deliveryMissed) return null;
  return (
    <div className="card space-y-3">
      <SectionTitle>Lifecycle actions</SectionTitle>
      <p className="text-sm text-muted">These actions are permissionless — anyone may trigger them.</p>
      {o.canFinalize && (
        <button
          className="btn btn-secondary w-full"
          disabled={!isConnected || tx.busy}
          onClick={() =>
            tx.run("Finalize offering", () =>
              tx.writeContractAsync({ address: o.address, abi: fixedPriceOfferingAbi, functionName: "finalize", chainId }),
            )
          }
        >
          Finalize offering
        </button>
      )}
      {deliveryMissed && (
        <>
          <Notice tone="warn">The issuer missed the delivery deadline ({fmtDate(o.escrowInfo.deliveryDeadline)}). Marking delivery as failed enables full refunds.</Notice>
          <button
            className="btn btn-danger w-full"
            disabled={!isConnected || tx.busy}
            onClick={() =>
              tx.run("Mark delivery failed", () =>
                tx.writeContractAsync({ address: o.escrow, abi: offeringEscrowAbi, functionName: "markDeliveryFailed", chainId }),
              )
            }
          >
            Mark delivery failed
          </button>
        </>
      )}
      {!isConnected && <p className="text-xs text-muted">Connect a wallet to send these transactions.</p>}
      <TxStatusLine status={tx.status} error={tx.error} />
    </div>
  );
}
