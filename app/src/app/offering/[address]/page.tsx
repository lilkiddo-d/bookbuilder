"use client";

import Link from "next/link";
import { useParams } from "next/navigation";
import { getAddress, isAddress, type Address } from "viem";
import { useReadContract } from "wagmi";
import { batchAuctionAbi, issuerRegistryAbi, offeringFactoryAbi, oracleAdapterAbi } from "@/abi";
import { DeploymentGate } from "@/components/NetworkGate";
import { DemandCurveChart, DutchCurveChart } from "@/components/Charts";
import { ParticipationPanel, PublicActions } from "@/components/participation/ParticipationPanel";
import { AddressLink, Countdown, EmptyState, KindBadge, Kv, Notice, ProgressBar, SectionTitle, Spinner, Stat as StatBox, StageBadge } from "@/components/ui";
import { useOffering } from "@/hooks/useOfferings";
import { useNow } from "@/hooks/useNow";
import { useProtocol } from "@/hooks/useProtocol";
import { ipfsUrl } from "@/lib/ipfs";
import { errorMessage, fmtBps, fmtDate, fmtDuration, fmtUnits, pct } from "@/lib/format";
import { soldOf, type OfferingSummary } from "@/lib/offerings";
import { batchPhaseLabel, issuerStatusLabel, kindLabel, Stage } from "@/lib/types";
import { nonZero } from "@/lib/deployments";
import type { Deployment } from "@/lib/types";

const ORACLE_SOURCE: Record<number, string> = { 1: "Chainlink", 2: "Manual NAV (governance)", 3: "Chainlink (stale)" };

function useUsdPrice(factory: Address, token: Address, chainId: number) {
  const { data: oracle } = useReadContract({ address: factory, abi: offeringFactoryAbi, functionName: "oracle", chainId });
  const o = nonZero(oracle);
  const { data } = useReadContract({
    address: o,
    abi: oracleAdapterAbi,
    functionName: "tryGetPrice",
    args: [token],
    chainId,
    query: { enabled: !!o },
  });
  if (!data || data[2] === 0) return undefined;
  return { price: data[0], updatedAt: data[1], source: data[2] };
}

function Documents({ o, chainId, registry }: { o: OfferingSummary; chainId: number; registry: Address }) {
  const { data: issuer } = useReadContract({
    address: registry,
    abi: issuerRegistryAbi,
    functionName: "getIssuer",
    args: [o.issuer],
    chainId,
  });
  const offeringDocs = ipfsUrl(o.params.docsCID);
  const issuerDocs = ipfsUrl(issuer?.docsCID);
  return (
    <div className="card">
      <SectionTitle>Documents & issuer</SectionTitle>
      <Kv k="Offering documents">
        {offeringDocs ? (
          <a href={offeringDocs} target="_blank" rel="noreferrer" className="text-accent underline">
            {o.params.docsCID.slice(0, 18)}…
          </a>
        ) : (
          "—"
        )}
      </Kv>
      <Kv k="Issuer">
        <AddressLink chainId={chainId} address={o.issuer} />
      </Kv>
      <Kv k="Legal entity">{issuer?.legalEntityRef || "—"}</Kv>
      <Kv k="Issuer status">{issuer ? (issuerStatusLabel[issuer.status] ?? "—") : "—"}</Kv>
      <Kv k="Approved">{issuer?.approvedAt ? fmtDate(issuer.approvedAt) : "—"}</Kv>
      <Kv k="Issuer documents">
        {issuerDocs ? (
          <a href={issuerDocs} target="_blank" rel="noreferrer" className="text-accent underline">
            {issuer!.docsCID.slice(0, 18)}…
          </a>
        ) : (
          "—"
        )}
      </Kv>
      {issuer && issuer.status !== 1 && (
        <div className="mt-3">
          <Notice tone="warn">This issuer is currently {issuerStatusLabel[issuer.status]?.toLowerCase()} by governance.</Notice>
        </div>
      )}
    </div>
  );
}

function DemandSection({ o, chainId }: { o: OfferingSummary; chainId: number }) {
  const b = o.batch!;
  const { data: demand } = useReadContract({
    address: o.address,
    abi: batchAuctionAbi,
    functionName: "demandCurve",
    args: [0, b.numTicks],
    chainId,
    query: { refetchInterval: 10_000 },
  });
  return (
    <div className="card">
      <SectionTitle right={<span className="text-xs text-muted">Phase: {batchPhaseLabel[b.phase]}</span>}>Live demand curve</SectionTitle>
      {b.phase <= 1 && (
        <Notice>
          Bids are sealed during the commit phase. {b.bidderCount} bidder{b.bidderCount === 1 ? "" : "s"} committed so far; demand appears here as bids are
          revealed.
        </Notice>
      )}
      <div className="mt-3">
        <DemandCurveChart
          demand={demand ?? []}
          minPrice={b.minPrice}
          tickSize={b.tickSize}
          supply={o.params.supply}
          saleDecimals={o.saleToken.decimals}
          payDecimals={o.paymentToken.decimals}
          saleSymbol={o.saleToken.symbol}
          paySymbol={o.paymentToken.symbol}
          clearingPrice={o.finalized ? b.clearingPrice : undefined}
        />
      </div>
      <div className="mt-3 grid grid-cols-2 gap-4 sm:grid-cols-4">
        <StatBox label="Revealed demand" value={fmtUnits(b.totalDemand, o.saleToken.decimals, 2)} sub={o.saleToken.symbol} />
        <StatBox label="Revealed bids" value={`${b.revealedCount} / ${b.bidderCount}`} />
        <StatBox label="Clearing price" value={o.finalized && b.clearingPrice > 0n ? fmtUnits(b.clearingPrice, o.paymentToken.decimals, 6) : "—"} sub={o.finalized ? `tick ${b.clearingTick}` : "after finalize"} />
        <StatBox label="Oversubscribed" value={o.finalized ? (b.oversubscribed ? "Yes" : "No") : "—"} />
      </div>
    </div>
  );
}

function OfferingView({ address, deployment }: { address: Address; deployment: Deployment }) {
  const { chainId } = useProtocol();
  const now = useNow();
  const { data: o, isLoading, error } = useOffering(address);
  const usd = useUsdPrice(deployment.contracts.OfferingFactory, o?.paymentToken.address ?? address, chainId);

  if (isLoading) return <Spinner label="Loading offering…" />;
  if (error) return <Notice tone="error">Could not load offering: {errorMessage(error)}</Notice>;
  if (!o) return <EmptyState title="Offering not found">This address is not a Bookbuilder offering on this network.</EmptyState>;

  const sd = o.saleToken.decimals;
  const pd = o.paymentToken.decimals;
  const sold = soldOf(o);
  const p = o.params;
  const e = o.escrowInfo;
  const usdOf = (amount: bigint) =>
    usd ? `≈ $${fmtUnits((amount * usd.price) / 10n ** 18n, pd, 2)}` : undefined;
  const unitPrice = o.fixed?.price ?? o.dutch?.currentPrice ?? (o.batch && o.finalized ? o.batch.clearingPrice : o.batch?.minPrice);

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div>
          <Link href="/" className="text-xs text-muted hover:underline">
            ← All offerings
          </Link>
          <h1 className="mt-1 text-2xl font-semibold tracking-tight">
            {o.saleToken.symbol} <span className="text-muted">· {kindLabel[o.kind]}</span>
          </h1>
          <div className="mt-2 flex flex-wrap items-center gap-2 text-xs">
            <StageBadge stage={e.stage} cancelled={e.cancelled} />
            <KindBadge kind={o.kind} />
            <span className="text-muted">
              Offering <AddressLink chainId={chainId} address={o.address} /> · Escrow <AddressLink chainId={chainId} address={o.escrow} />
            </span>
          </div>
        </div>
      </div>

      <div className="card grid grid-cols-2 gap-4 sm:grid-cols-4">
        <StatBox label="Supply (hard cap)" value={fmtUnits(p.supply, sd, 2)} sub={o.saleToken.symbol} />
        <StatBox
          label={o.batch ? (o.finalized ? "Clearing price" : "Reserve price") : o.dutch ? "Current price" : "Price"}
          value={unitPrice !== undefined ? fmtUnits(unitPrice, pd, 6) : "—"}
          sub={
            <>
              {o.paymentToken.symbol} per token{" "}
              {unitPrice !== undefined && usd ? <span title={`Oracle: ${ORACLE_SOURCE[usd.source]}`}>({usdOf(unitPrice)})</span> : null}
            </>
          }
        />
        <StatBox label={o.batch && !o.finalized ? "Revealed demand" : "Sold"} value={fmtUnits(sold, sd, 2)} sub={`${pct(sold, p.supply).toFixed(1)}% of supply`} />
        <StatBox
          label="Timing"
          value={
            e.stage !== Stage.Active || o.finalized ? (
              "Closed"
            ) : now && BigInt(now) < p.startTime ? (
              <Countdown to={p.startTime} now={now} />
            ) : (
              <Countdown to={o.batch ? (BigInt(now) < o.batch.commitEnd ? o.batch.commitEnd : o.batch.revealEnd) : p.endTime} now={now} />
            )
          }
          sub={
            e.stage !== Stage.Active || o.finalized
              ? `Ended ${fmtDate(o.batch ? o.batch.revealEnd : p.endTime)}`
              : now && BigInt(now) < p.startTime
                ? "until start"
                : o.batch
                  ? BigInt(now) < o.batch.commitEnd
                    ? "until commit end"
                    : "until reveal end"
                  : "until end"
          }
        />
        <div className="col-span-2 sm:col-span-4">
          <ProgressBar
            value={pct(sold, p.supply)}
            marker={pct(p.softCap, p.supply)}
            label={p.softCap > 0n ? `Soft cap ${fmtUnits(p.softCap, sd, 2)} ${o.saleToken.symbol} (marker)` : "No soft cap"}
          />
        </div>
        {usd && (
          <p className="col-span-2 text-xs text-muted sm:col-span-4">
            USD values are display-only, from the protocol oracle ({ORACLE_SOURCE[usd.source]}, updated {fmtDate(usd.updatedAt)}). They never affect settlement.
          </p>
        )}
      </div>

      <div className="grid gap-6 lg:grid-cols-[1fr_380px]">
        <div className="space-y-6">
          {o.batch && <DemandSection o={o} chainId={chainId} />}
          {o.dutch && (
            <div className="card">
              <SectionTitle>Price decay</SectionTitle>
              <DutchCurveChart
                startTime={p.startTime}
                endTime={p.endTime}
                decayDuration={o.dutch.decayDuration}
                startPrice={o.dutch.startPrice}
                floorPrice={o.dutch.floorPrice}
                currentPrice={o.dutch.currentPrice}
                now={now}
                payDecimals={pd}
                paySymbol={o.paymentToken.symbol}
              />
            </div>
          )}

          <div className="card">
            <SectionTitle>Parameters</SectionTitle>
            <Kv k="Sale token">
              {o.saleToken.symbol} · <AddressLink chainId={chainId} address={p.saleToken} />
            </Kv>
            <Kv k="Payment token">
              {o.paymentToken.symbol} · <AddressLink chainId={chainId} address={p.paymentToken} />
            </Kv>
            <Kv k="Start">{fmtDate(p.startTime)}</Kv>
            <Kv k={o.batch ? "Commit end (initial)" : "End"}>{fmtDate(p.endTime)}</Kv>
            {o.batch && (
              <>
                <Kv k="Commit end (current)">{fmtDate(o.batch.commitEnd)}</Kv>
                <Kv k="Max commit end (anti-snipe cap)">{fmtDate(o.batch.maxEndTime)}</Kv>
                <Kv k="Reveal window">{fmtDuration(o.batch.revealDuration)}</Kv>
                <Kv k="Price grid">
                  {o.batch.numTicks} ticks · {fmtUnits(o.batch.minPrice, pd, 6)} + n × {fmtUnits(o.batch.tickSize, pd, 6)} {o.paymentToken.symbol}
                </Kv>
                <Kv k="Anti-snipe">
                  {o.batch.antiSnipeWindow > 0 ? `+${fmtDuration(o.batch.antiSnipeExtension)} if committed in last ${fmtDuration(o.batch.antiSnipeWindow)}` : "Off"}
                </Kv>
                <Kv k="Non-reveal penalty">{fmtBps(o.batch.nonRevealPenaltyBps)}</Kv>
                <Kv k="Max bidders">{o.batch.maxBidders}</Kv>
              </>
            )}
            {o.dutch && (
              <>
                <Kv k="Start price">{fmtUnits(o.dutch.startPrice, pd, 6)} {o.paymentToken.symbol}</Kv>
                <Kv k="Floor price">{fmtUnits(o.dutch.floorPrice, pd, 6)} {o.paymentToken.symbol}</Kv>
                <Kv k="Decay duration">{fmtDuration(o.dutch.decayDuration)}</Kv>
              </>
            )}
            <Kv k="Soft cap">{p.softCap > 0n ? `${fmtUnits(p.softCap, sd)} ${o.saleToken.symbol}` : "None"}</Kv>
            <Kv k="Per-wallet max">{p.perWalletMax > 0n ? `${fmtUnits(p.perWalletMax, sd)} ${o.saleToken.symbol}` : "No limit"}</Kv>
            <Kv k="Compliance">
              {p.compliance.enabled
                ? `On · min tier ${p.compliance.minTier}${p.compliance.requireAccredited ? " · accredited only" : ""}`
                : "Off"}
            </Kv>
            <Kv k="Priority window">
              {p.priorityWindow > 0 ? `${fmtDuration(p.priorityWindow)} for tier ${p.priorityTier}+ (and $BOOK stakers)` : "None"}
            </Kv>
            <Kv k="Vesting">
              {p.vestingDuration > 0n ? `${fmtDuration(p.vestingCliff)} cliff, ${fmtDuration(p.vestingDuration)} linear` : "None (liquid on claim)"}
            </Kv>
            <Kv k="Delivery window">{fmtDuration(p.deliveryWindow)} after finalization</Kv>
            <Kv k="Protocol fee">{fmtBps(e.feeBps)} of proceeds (on delivery)</Kv>
          </div>

          <div className="card">
            <SectionTitle>Escrow status</SectionTitle>
            <Kv k="Stage">
              <StageBadge stage={e.stage} cancelled={e.cancelled} />
            </Kv>
            <Kv k="Total deposited">
              {fmtUnits(e.totalDeposited, pd)} {o.paymentToken.symbol} {usdOf(e.totalDeposited) && <span className="text-xs text-muted">{usdOf(e.totalDeposited)}</span>}
            </Kv>
            <Kv k="Participants">{e.participants.toString()} ({e.settledCount.toString()} settled)</Kv>
            {e.finalizedAt > 0n && <Kv k="Finalized">{fmtDate(e.finalizedAt)}</Kv>}
            {(e.stage === Stage.Succeeded || e.stage === Stage.Delivered) && (
              <>
                <Kv k="Gross proceeds">
                  {fmtUnits(e.grossProceeds, pd)} {o.paymentToken.symbol}
                </Kv>
                <Kv k="Tokens to deliver">
                  {fmtUnits(e.tokensToDeliver, sd)} {o.saleToken.symbol}
                </Kv>
              </>
            )}
            {e.stage === Stage.Succeeded && (
              <Kv k="Delivery deadline">
                {fmtDate(e.deliveryDeadline)} (<Countdown to={e.deliveryDeadline} now={now} />)
              </Kv>
            )}
            {e.deliveredAt > 0n && <Kv k="Delivered">{fmtDate(e.deliveredAt)}</Kv>}
            {e.stage === Stage.Failed && (
              <div className="mt-3">
                <Notice tone="warn">
                  {e.cancelled ? "This offering was cancelled." : "This offering did not complete (soft cap missed or delivery failed)."} Deposits are fully
                  refundable{o.batch ? " (minus any non-reveal penalty)" : ""} via settle.
                </Notice>
              </div>
            )}
          </div>
          <Documents o={o} chainId={chainId} registry={deployment.contracts.IssuerRegistry} />
        </div>

        <div className="space-y-6">
          <ParticipationPanel o={o} now={now} />
          <PublicActions o={o} now={now} />
        </div>
      </div>
    </div>
  );
}

export default function OfferingPage() {
  const params = useParams<{ address: string }>();
  const raw = params?.address ?? "";
  if (!isAddress(raw)) return <EmptyState title="Invalid offering address" />;
  const address = getAddress(raw);
  return <DeploymentGate>{(d) => <OfferingView address={address} deployment={d} />}</DeploymentGate>;
}
