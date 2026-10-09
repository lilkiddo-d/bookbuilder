"use client";

import { useState } from "react";
import type { Address } from "viem";
import { useAccount, useReadContract, useReadContracts } from "wagmi";
import { ConnectButton } from "@rainbow-me/rainbowkit";
import { erc20Abi, issuerRegistryAbi, offeringFactoryAbi } from "@/abi";
import { DeploymentGate } from "@/components/NetworkGate";
import { CreateOfferingForm } from "@/components/issuer/CreateOfferingForm";
import { IssuerOfferingRow } from "@/components/issuer/IssuerOfferingRow";
import { TxStatusLine } from "@/components/participation/common";
import { AddressLink, EmptyState, Kv, Notice, SectionTitle, Spinner } from "@/components/ui";
import { useOfferingSummaries } from "@/hooks/useOfferings";
import { useNow } from "@/hooks/useNow";
import { useProtocol } from "@/hooks/useProtocol";
import { useTx } from "@/hooks/useTx";
import { fmtDate, fmtDuration } from "@/lib/format";
import { ipfsUrl } from "@/lib/ipfs";
import { issuerStatusLabel, type Deployment } from "@/lib/types";

function IssuerRecord({ account, registry }: { account: Address; registry: Address }) {
  const { chainId } = useProtocol();
  const { data: rec } = useReadContract({ address: registry, abi: issuerRegistryAbi, functionName: "getIssuer", args: [account], chainId });
  const tx = useTx();
  const [docs, setDocs] = useState("");
  if (!rec) return <Spinner />;
  const docsUrl = ipfsUrl(rec.docsCID);
  return (
    <div className="card">
      <SectionTitle>Issuer record</SectionTitle>
      <Kv k="Status">{issuerStatusLabel[rec.status] ?? "—"}</Kv>
      <Kv k="Approved at">{rec.approvedAt ? fmtDate(rec.approvedAt) : "—"}</Kv>
      <Kv k="Legal entity">{rec.legalEntityRef || "—"}</Kv>
      <Kv k="Delivery token">
        <AddressLink chainId={chainId} address={rec.deliveryToken === "0x0000000000000000000000000000000000000000" ? undefined : rec.deliveryToken} />
      </Kv>
      <Kv k="Issuer documents">
        {docsUrl ? (
          <a className="text-accent underline" href={docsUrl} target="_blank" rel="noreferrer">
            {rec.docsCID.slice(0, 20)}…
          </a>
        ) : (
          "—"
        )}
      </Kv>
      {rec.status === 1 && (
        <div className="mt-3 flex gap-2">
          <input className="input" placeholder="New issuer documents CID" value={docs} onChange={(e) => setDocs(e.target.value)} />
          <button
            className="btn btn-secondary shrink-0"
            disabled={!docs.trim() || tx.busy}
            onClick={async () => {
              const ok = await tx.run("Update issuer documents", () =>
                tx.writeContractAsync({ address: registry, abi: issuerRegistryAbi, functionName: "updateDocs", args: [docs.trim()], chainId }),
              );
              if (ok) setDocs("");
            }}
          >
            Update
          </button>
        </div>
      )}
      <TxStatusLine status={tx.status} error={tx.error} />
    </div>
  );
}

function NotApproved({ account, deployment }: { account: Address; deployment: Deployment }) {
  const delay = deployment.timelockDelay ?? 172_800;
  const { chainId } = useProtocol();
  return (
    <div className="space-y-6">
      <div className="card space-y-3 text-sm">
        <SectionTitle>Becoming an approved issuer</SectionTitle>
        <p>
          Only issuers approved by protocol governance can create offerings. Approval is an on-chain transaction executed by the governance
          Timelock, so every approval is publicly visible for at least {fmtDuration(delay)} before it takes effect.
        </p>
        <ol className="list-decimal space-y-1 pl-5">
          <li>Prepare issuer-level documents (formation documents, offering memorandum, audits) and pin them to IPFS.</li>
          <li>Provide your legal entity reference (e.g. registered name and number, or LEI) and the address of the RWA token you will deliver.</li>
          <li>
            Governance schedules <code className="font-mono">IssuerRegistry.approveIssuer(issuer, deliveryToken, legalEntityRef, docsCID)</code> through the
            Timelock (<AddressLink chainId={chainId} address={deployment.contracts.Timelock} />).
          </li>
          <li>After the {fmtDuration(delay)} delay the proposal can be executed and this console unlocks for your wallet.</li>
        </ol>
        <p className="text-muted">
          The guardian can suspend an issuer instantly during an incident; only governance can re-approve.
        </p>
      </div>
      <IssuerRecord account={account} registry={deployment.contracts.IssuerRegistry} />
    </div>
  );
}

function IssuerConsole({ deployment }: { deployment: Deployment }) {
  const { address: account, isConnected } = useAccount();
  const { chainId, wrongNetwork } = useProtocol();
  const now = useNow();
  const registry = deployment.contracts.IssuerRegistry;
  const factory = deployment.contracts.OfferingFactory;

  const { data: base, isLoading } = useReadContracts({
    contracts: account
      ? [
          { address: registry, abi: issuerRegistryAbi, functionName: "isApprovedIssuer", args: [account], chainId },
          { address: registry, abi: issuerRegistryAbi, functionName: "deliveryTokenOf", args: [account], chainId },
          { address: factory, abi: offeringFactoryAbi, functionName: "offeringsOf", args: [account], chainId },
        ]
      : [],
    query: { enabled: !!account, refetchInterval: 20_000 },
  });
  const approved = base?.[0]?.result === true;
  const deliveryToken = base?.[1]?.result as Address | undefined;
  const offeringAddrs = base?.[2]?.result as readonly Address[] | undefined;

  const { data: tokenMeta } = useReadContracts({
    contracts: deliveryToken
      ? [
          { address: deliveryToken, abi: erc20Abi, functionName: "symbol", chainId },
          { address: deliveryToken, abi: erc20Abi, functionName: "decimals", chainId },
        ]
      : [],
    query: { enabled: !!deliveryToken },
  });
  const { data: myOfferings, isLoading: loadingOfferings } = useOfferingSummaries(offeringAddrs);

  if (!isConnected || !account)
    return (
      <div className="card space-y-3">
        <p className="text-sm text-muted">Connect the issuer wallet to manage offerings.</p>
        <ConnectButton />
      </div>
    );
  if (wrongNetwork) return <Notice tone="warn">Switch your wallet to a supported network.</Notice>;
  if (isLoading) return <Spinner label="Checking issuer status…" />;
  if (!approved) return <NotApproved account={account} deployment={deployment} />;

  const symbol = tokenMeta?.[0]?.status === "success" ? String(tokenMeta[0].result) : undefined;
  const decimals = tokenMeta?.[1]?.status === "success" ? Number(tokenMeta[1].result) : undefined;

  return (
    <div className="space-y-8">
      <IssuerRecord account={account} registry={registry} />
      {deliveryToken && symbol !== undefined && decimals !== undefined ? (
        <CreateOfferingForm
          saleToken={{ address: deliveryToken, symbol, decimals }}
          paymentTokens={deployment.paymentTokens}
          factory={factory}
        />
      ) : (
        <Spinner label="Loading delivery token…" />
      )}
      <section>
        <SectionTitle>Your offerings</SectionTitle>
        {loadingOfferings ? (
          <Spinner />
        ) : !myOfferings || myOfferings.length === 0 ? (
          <EmptyState title="No offerings yet">Create your first offering above.</EmptyState>
        ) : (
          <div className="grid gap-4 md:grid-cols-2">
            {[...myOfferings].reverse().map((o) => (
              <IssuerOfferingRow key={o.address} o={o} account={account} chainId={chainId} now={now} />
            ))}
          </div>
        )}
      </section>
    </div>
  );
}

export default function IssuerPage() {
  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold tracking-tight">Issuer console</h1>
        <p className="mt-1 text-sm text-muted">Create offerings, deliver tokens into escrow, and manage documents.</p>
      </div>
      <DeploymentGate>{(d) => <IssuerConsole deployment={d} />}</DeploymentGate>
    </div>
  );
}
