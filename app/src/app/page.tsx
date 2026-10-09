"use client";

import { useMemo, useState } from "react";
import { DeploymentGate } from "@/components/NetworkGate";
import { OfferingCard } from "@/components/OfferingCard";
import { EmptyState, Notice, Spinner } from "@/components/ui";
import { useAllOfferings } from "@/hooks/useOfferings";
import { useNow } from "@/hooks/useNow";
import { bucketOf, type Bucket } from "@/lib/offerings";
import { errorMessage } from "@/lib/format";

const TABS: { id: Bucket; label: string }[] = [
  { id: "live", label: "Live" },
  { id: "upcoming", label: "Upcoming" },
  { id: "closed", label: "Closed" },
];

function Calendar() {
  const { data, isLoading, error } = useAllOfferings();
  const now = useNow();
  const [tab, setTab] = useState<Bucket>("live");

  const grouped = useMemo(() => {
    const g: Record<Bucket, NonNullable<typeof data>> = { live: [], upcoming: [], closed: [] };
    if (!data || !now) return g;
    for (const o of data) g[bucketOf(o, now)].push(o);
    g.upcoming.sort((a, b) => Number(a.params.startTime - b.params.startTime));
    g.live.sort((a, b) => Number(a.params.endTime - b.params.endTime));
    g.closed.sort((a, b) => Number(b.params.endTime - a.params.endTime));
    return g;
  }, [data, now]);

  if (isLoading) return <Spinner label="Loading offerings…" />;
  if (error) return <Notice tone="error">Could not load offerings: {errorMessage(error)}</Notice>;
  if (!data || data.length === 0)
    return (
      <EmptyState title="No offerings yet — issuers must be approved by governance">
        Offerings appear here as soon as an approved issuer creates one.
      </EmptyState>
    );

  const list = grouped[tab];
  return (
    <div>
      <div className="mb-4 flex gap-1 border-b border-line">
        {TABS.map((t) => (
          <button
            key={t.id}
            onClick={() => setTab(t.id)}
            className={`-mb-px border-b-2 px-3 py-2 text-sm ${
              tab === t.id ? "border-accent font-medium" : "border-transparent text-muted hover:text-fg"
            }`}
          >
            {t.label} <span className="text-xs text-muted">({grouped[t.id].length})</span>
          </button>
        ))}
      </div>
      {list.length === 0 ? (
        <EmptyState title={`No ${tab} offerings`} />
      ) : (
        <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
          {list.map((o) => (
            <OfferingCard key={o.address} o={o} now={now} />
          ))}
        </div>
      )}
    </div>
  );
}

export default function HomePage() {
  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold tracking-tight">Offerings calendar</h1>
        <p className="mt-1 max-w-2xl text-sm text-muted">
          Primary offerings of tokenized real-world assets by governance-approved issuers. Investor payments are held in a
          per-offering escrow and released to the issuer only after the full token amount is delivered.
        </p>
      </div>
      <DeploymentGate>{() => <Calendar />}</DeploymentGate>
    </div>
  );
}
