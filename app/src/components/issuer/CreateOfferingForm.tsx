"use client";

import { useMemo, useState, type ReactNode } from "react";
import type { Address } from "viem";
import { useReadContract } from "wagmi";
import { erc20Abi, offeringFactoryAbi } from "@/abi";
import { useTx } from "@/hooks/useTx";
import { useProtocol } from "@/hooks/useProtocol";
import { fmtUnits, safeParseUnits } from "@/lib/format";
import { OfferingKind } from "@/lib/types";
import type { TokenMeta } from "@/lib/offerings";
import { Notice, SectionTitle } from "../ui";
import { TxStatusLine } from "../participation/common";

const DAY = 86_400;
const HOUR = 3_600;
const MIN_DELIVERY_DAYS = 1;
const MAX_DELIVERY_DAYS = 180;
const MAX_DURATION_DAYS = 180;
const MAX_TICKS = 400;

function toLocalInput(ts: number): string {
  const d = new Date(ts * 1000);
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

function fromLocalInput(v: string): number | undefined {
  if (!v) return undefined;
  const t = new Date(v).getTime();
  return Number.isFinite(t) ? Math.floor(t / 1000) : undefined;
}

function num(v: string): number | undefined {
  if (v.trim() === "") return undefined;
  const n = Number(v);
  return Number.isFinite(n) && n >= 0 ? n : undefined;
}

function Field({ label, hint, children }: { label: string; hint?: ReactNode; children: ReactNode }) {
  return (
    <div>
      <label className="label">{label}</label>
      {children}
      {hint && <p className="mt-1 text-xs text-muted">{hint}</p>}
    </div>
  );
}

export function CreateOfferingForm({
  saleToken,
  paymentTokens,
  factory,
}: {
  saleToken: TokenMeta;
  paymentTokens: Record<string, Address>;
  factory: Address;
}) {
  const { chainId } = useProtocol();
  const tx = useTx();
  const payOptions = Object.entries(paymentTokens);
  const [kind, setKind] = useState<OfferingKind>(OfferingKind.FixedPrice);
  const [payment, setPayment] = useState<Address | "">(payOptions[0]?.[1] ?? "");

  const nowSec = useMemo(() => Math.floor(Date.now() / 1000), []);
  const [f, setF] = useState({
    supply: "",
    softCap: "",
    perWalletMax: "",
    start: toLocalInput(nowSec + HOUR),
    end: toLocalInput(nowSec + HOUR + 7 * DAY),
    deliveryDays: "14",
    cliffDays: "0",
    vestingDays: "0",
    priorityTier: "0",
    priorityHours: "0",
    complianceEnabled: true,
    minTier: "1",
    requireAccredited: false,
    docsCID: "",
    // fixed
    price: "",
    // batch
    minPrice: "",
    tickSize: "",
    numTicks: "100",
    revealHours: "24",
    antiSnipeMin: "10",
    antiSnipeExtMin: "10",
    maxEnd: toLocalInput(nowSec + HOUR + 8 * DAY),
    penaltyPct: "5",
    maxBidders: "1000",
    // dutch
    startPrice: "",
    floorPrice: "",
    decayHours: "72",
  });
  const set = <K extends keyof typeof f>(k: K, v: (typeof f)[K]) => setF((s) => ({ ...s, [k]: v }));

  const payAddr = payment || undefined;
  const { data: payDecimals } = useReadContract({
    address: payAddr,
    abi: erc20Abi,
    functionName: "decimals",
    chainId,
    query: { enabled: !!payAddr },
  });
  const { data: paySymbol } = useReadContract({
    address: payAddr,
    abi: erc20Abi,
    functionName: "symbol",
    chainId,
    query: { enabled: !!payAddr },
  });
  const { data: allowed } = useReadContract({
    address: factory,
    abi: offeringFactoryAbi,
    functionName: "allowedPaymentToken",
    args: payAddr ? [payAddr] : undefined,
    chainId,
    query: { enabled: !!payAddr },
  });
  const { data: mandatory } = useReadContract({ address: factory, abi: offeringFactoryAbi, functionName: "complianceMandatory", chainId });
  const { data: paused } = useReadContract({ address: factory, abi: offeringFactoryAbi, functionName: "paused", chainId });

  const sd = saleToken.decimals;
  const pd = payDecimals;
  const sym = paySymbol ?? "payment";

  const built = useMemo(() => {
    const errors: string[] = [];
    const supply = safeParseUnits(f.supply, sd);
    const softCap = f.softCap ? safeParseUnits(f.softCap, sd) : 0n;
    const perWalletMax = f.perWalletMax ? safeParseUnits(f.perWalletMax, sd) : 0n;
    const start = fromLocalInput(f.start);
    const end = fromLocalInput(f.end);
    const deliveryDays = num(f.deliveryDays);
    const cliffDays = num(f.cliffDays) ?? 0;
    const vestingDays = num(f.vestingDays) ?? 0;
    const priorityTier = num(f.priorityTier) ?? 0;
    const priorityHours = num(f.priorityHours) ?? 0;
    const minTier = num(f.minTier) ?? 0;
    if (!payAddr) errors.push("Select a payment token.");
    if (pd === undefined) errors.push("Loading payment token decimals…");
    if (!supply || supply === 0n) errors.push("Supply must be greater than 0.");
    if (softCap === undefined) errors.push("Invalid soft cap.");
    if (perWalletMax === undefined) errors.push("Invalid per-wallet max.");
    if (supply && softCap !== undefined && softCap > supply) errors.push("Soft cap cannot exceed supply.");
    if (supply && perWalletMax !== undefined && perWalletMax > supply) errors.push("Per-wallet max cannot exceed supply.");
    if (!start || !end) errors.push("Start and end times are required.");
    if (start && start <= Math.floor(Date.now() / 1000)) errors.push("Start time must be in the future.");
    if (start && end && end <= start) errors.push("End must be after start.");
    if (start && end && end - start > MAX_DURATION_DAYS * DAY) errors.push(`Duration cannot exceed ${MAX_DURATION_DAYS} days.`);
    if (deliveryDays === undefined || deliveryDays < MIN_DELIVERY_DAYS || deliveryDays > MAX_DELIVERY_DAYS)
      errors.push(`Delivery window must be ${MIN_DELIVERY_DAYS}–${MAX_DELIVERY_DAYS} days.`);
    if (vestingDays > 0 && cliffDays > vestingDays) errors.push("Vesting cliff cannot exceed vesting duration.");
    if (priorityTier > 255 || minTier > 255) errors.push("Tiers must be 0–255.");
    if (start && end && priorityHours * HOUR > end - start) errors.push("Priority window cannot exceed the offering duration.");
    if (mandatory && !f.complianceEnabled) errors.push("Compliance is mandatory on this deployment.");
    if (allowed === false) errors.push("This payment token is not allowed by governance.");
    if (paused) errors.push("The factory is paused by the guardian.");

    const common = {
      saleToken: saleToken.address,
      paymentToken: (payAddr ?? "0x0000000000000000000000000000000000000000") as Address,
      supply: supply ?? 0n,
      softCap: softCap ?? 0n,
      perWalletMax: perWalletMax ?? 0n,
      startTime: BigInt(start ?? 0),
      endTime: BigInt(end ?? 0),
      deliveryWindow: Math.round((deliveryDays ?? 0) * DAY),
      vestingCliff: BigInt(Math.round(vestingDays > 0 ? cliffDays * DAY : 0)),
      vestingDuration: BigInt(Math.round(vestingDays * DAY)),
      priorityTier: Math.floor(priorityTier),
      priorityWindow: Math.round(priorityHours * HOUR),
      compliance: { enabled: f.complianceEnabled, minTier: Math.floor(minTier), requireAccredited: f.requireAccredited },
      docsCID: f.docsCID.trim(),
    };

    let fixed: { price: bigint } | undefined;
    let batch:
      | {
          minPrice: bigint;
          tickSize: bigint;
          numTicks: number;
          revealDuration: bigint;
          antiSnipeWindow: number;
          antiSnipeExtension: number;
          maxEndTime: bigint;
          nonRevealPenaltyBps: number;
          maxBidders: number;
        }
      | undefined;
    let dutch: { startPrice: bigint; floorPrice: bigint; decayDuration: bigint } | undefined;

    if (kind === OfferingKind.FixedPrice) {
      const price = safeParseUnits(f.price, pd);
      if (!price) errors.push("Price must be greater than 0.");
      fixed = { price: price ?? 0n };
    } else if (kind === OfferingKind.BatchAuction) {
      const minPrice = safeParseUnits(f.minPrice, pd);
      const tickSize = f.tickSize ? safeParseUnits(f.tickSize, pd) : 0n;
      const numTicks = num(f.numTicks);
      const revealHours = num(f.revealHours);
      const asw = num(f.antiSnipeMin) ?? 0;
      const ase = num(f.antiSnipeExtMin) ?? 0;
      const maxEnd = fromLocalInput(f.maxEnd);
      const penaltyPct = num(f.penaltyPct);
      const maxBidders = num(f.maxBidders);
      if (!minPrice) errors.push("Reserve (minimum) price must be greater than 0.");
      if (!numTicks || numTicks < 1 || numTicks > MAX_TICKS || !Number.isInteger(numTicks)) errors.push(`Number of ticks must be 1–${MAX_TICKS}.`);
      if (tickSize === undefined || (numTicks && numTicks > 1 && tickSize === 0n)) errors.push("Tick size must be greater than 0 when using more than one tick.");
      if (revealHours === undefined || revealHours < 1 || revealHours > 30 * 24) errors.push("Reveal window must be between 1 hour and 30 days.");
      if (!maxEnd || (end && maxEnd < end)) errors.push("Max commit end must be at or after the commit end.");
      if (penaltyPct === undefined || penaltyPct > 20) errors.push("Non-reveal penalty must be 0–20%.");
      if (!maxBidders || maxBidders < 1 || !Number.isInteger(maxBidders)) errors.push("Max bidders must be at least 1.");
      batch = {
        minPrice: minPrice ?? 0n,
        tickSize: tickSize ?? 0n,
        numTicks: Math.floor(numTicks ?? 0),
        revealDuration: BigInt(Math.round((revealHours ?? 0) * HOUR)),
        antiSnipeWindow: Math.round(asw * 60),
        antiSnipeExtension: Math.round(ase * 60),
        maxEndTime: BigInt(maxEnd ?? 0),
        nonRevealPenaltyBps: Math.round((penaltyPct ?? 0) * 100),
        maxBidders: Math.floor(maxBidders ?? 0),
      };
    } else {
      const startPrice = safeParseUnits(f.startPrice, pd);
      const floorPrice = safeParseUnits(f.floorPrice, pd);
      const decayHours = num(f.decayHours);
      if (!floorPrice) errors.push("Floor price must be greater than 0.");
      if (!startPrice || (floorPrice && startPrice < floorPrice)) errors.push("Start price must be at least the floor price.");
      const decay = Math.round((decayHours ?? 0) * HOUR);
      if (!decay) errors.push("Decay duration must be greater than 0.");
      if (start && end && decay > end - start) errors.push("Decay duration cannot exceed the auction duration.");
      dutch = { startPrice: startPrice ?? 0n, floorPrice: floorPrice ?? 0n, decayDuration: BigInt(decay) };
    }
    return { errors, common, fixed, batch, dutch };
  }, [f, kind, payAddr, pd, sd, saleToken.address, mandatory, allowed, paused]);

  const onSubmit = async () => {
    if (built.errors.length) return;
    const { common } = built;
    if (kind === OfferingKind.FixedPrice && built.fixed) {
      const fp = built.fixed;
      await tx.run("Create fixed-price offering", () =>
        tx.writeContractAsync({ address: factory, abi: offeringFactoryAbi, functionName: "createFixedPrice", args: [common, fp], chainId }),
      );
    } else if (kind === OfferingKind.BatchAuction && built.batch) {
      const bp = built.batch;
      await tx.run("Create batch auction", () =>
        tx.writeContractAsync({ address: factory, abi: offeringFactoryAbi, functionName: "createBatchAuction", args: [common, bp], chainId }),
      );
    } else if (kind === OfferingKind.DutchAuction && built.dutch) {
      const dp = built.dutch;
      await tx.run("Create Dutch auction", () =>
        tx.writeContractAsync({ address: factory, abi: offeringFactoryAbi, functionName: "createDutchAuction", args: [common, dp], chainId }),
      );
    }
  };

  const priceHint = `${sym} per 1 whole ${saleToken.symbol}`;

  return (
    <div className="card space-y-5">
      <SectionTitle>Create an offering</SectionTitle>
      {payOptions.length === 0 && <Notice tone="warn">No payment tokens are listed in this deployment file.</Notice>}

      <div className="grid gap-4 sm:grid-cols-3">
        <Field label="Offering type">
          <select className="input" value={kind} onChange={(e) => setKind(Number(e.target.value) as OfferingKind)}>
            <option value={OfferingKind.FixedPrice}>Fixed price</option>
            <option value={OfferingKind.BatchAuction}>Batch auction (sealed bid)</option>
            <option value={OfferingKind.DutchAuction}>Dutch auction</option>
          </select>
        </Field>
        <Field label="Sale token (locked)" hint="Your governance-approved delivery token.">
          <input className="input" value={`${saleToken.symbol} · ${saleToken.address}`} disabled readOnly />
        </Field>
        <Field label="Payment token">
          <select className="input" value={payment} onChange={(e) => setPayment(e.target.value as Address)}>
            {payOptions.map(([s, a]) => (
              <option key={a} value={a}>
                {s}
              </option>
            ))}
          </select>
        </Field>
      </div>

      <div className="grid gap-4 sm:grid-cols-3">
        <Field label={`Supply (${saleToken.symbol})`} hint="Hard cap">
          <input className="input" inputMode="decimal" value={f.supply} onChange={(e) => set("supply", e.target.value)} />
        </Field>
        <Field label={`Soft cap (${saleToken.symbol})`} hint="Refund everyone if not reached. Blank = none.">
          <input className="input" inputMode="decimal" value={f.softCap} onChange={(e) => set("softCap", e.target.value)} />
        </Field>
        <Field label={`Per-wallet max (${saleToken.symbol})`} hint="Blank = no limit">
          <input className="input" inputMode="decimal" value={f.perWalletMax} onChange={(e) => set("perWalletMax", e.target.value)} />
        </Field>
        <Field label="Start">
          <input type="datetime-local" className="input" value={f.start} onChange={(e) => set("start", e.target.value)} />
        </Field>
        <Field label={kind === OfferingKind.BatchAuction ? "Commit end" : "End"}>
          <input type="datetime-local" className="input" value={f.end} onChange={(e) => set("end", e.target.value)} />
        </Field>
        <Field label="Delivery window (days)" hint="Time after finalization to deliver tokens (1–180).">
          <input className="input" inputMode="decimal" value={f.deliveryDays} onChange={(e) => set("deliveryDays", e.target.value)} />
        </Field>
      </div>

      {kind === OfferingKind.FixedPrice && (
        <div className="grid gap-4 sm:grid-cols-3">
          <Field label="Price" hint={priceHint}>
            <input className="input" inputMode="decimal" value={f.price} onChange={(e) => set("price", e.target.value)} />
          </Field>
        </div>
      )}
      {kind === OfferingKind.BatchAuction && (
        <div className="grid gap-4 sm:grid-cols-3">
          <Field label="Reserve / tick-0 price" hint={priceHint}>
            <input className="input" inputMode="decimal" value={f.minPrice} onChange={(e) => set("minPrice", e.target.value)} />
          </Field>
          <Field label="Tick size" hint={`Price step (${sym})`}>
            <input className="input" inputMode="decimal" value={f.tickSize} onChange={(e) => set("tickSize", e.target.value)} />
          </Field>
          <Field
            label="Number of ticks"
            hint={
              pd !== undefined && safeParseUnits(f.minPrice, pd) !== undefined && safeParseUnits(f.tickSize || "0", pd) !== undefined && num(f.numTicks)
                ? `Top price: ${fmtUnits(safeParseUnits(f.minPrice, pd)! + BigInt(Math.max(0, Math.floor(num(f.numTicks)!) - 1)) * safeParseUnits(f.tickSize || "0", pd)!, pd, 6)} ${sym}`
                : `1–${MAX_TICKS}`
            }
          >
            <input className="input" inputMode="numeric" value={f.numTicks} onChange={(e) => set("numTicks", e.target.value)} />
          </Field>
          <Field label="Reveal window (hours)">
            <input className="input" inputMode="decimal" value={f.revealHours} onChange={(e) => set("revealHours", e.target.value)} />
          </Field>
          <Field label="Anti-snipe window (minutes)" hint="0 disables extensions">
            <input className="input" inputMode="decimal" value={f.antiSnipeMin} onChange={(e) => set("antiSnipeMin", e.target.value)} />
          </Field>
          <Field label="Extension per late commit (minutes)">
            <input className="input" inputMode="decimal" value={f.antiSnipeExtMin} onChange={(e) => set("antiSnipeExtMin", e.target.value)} />
          </Field>
          <Field label="Max commit end" hint="Hard ceiling for extensions">
            <input type="datetime-local" className="input" value={f.maxEnd} onChange={(e) => set("maxEnd", e.target.value)} />
          </Field>
          <Field label="Non-reveal penalty (%)" hint="0–20%">
            <input className="input" inputMode="decimal" value={f.penaltyPct} onChange={(e) => set("penaltyPct", e.target.value)} />
          </Field>
          <Field label="Max bidders">
            <input className="input" inputMode="numeric" value={f.maxBidders} onChange={(e) => set("maxBidders", e.target.value)} />
          </Field>
        </div>
      )}
      {kind === OfferingKind.DutchAuction && (
        <div className="grid gap-4 sm:grid-cols-3">
          <Field label="Start price" hint={priceHint}>
            <input className="input" inputMode="decimal" value={f.startPrice} onChange={(e) => set("startPrice", e.target.value)} />
          </Field>
          <Field label="Floor price" hint={priceHint}>
            <input className="input" inputMode="decimal" value={f.floorPrice} onChange={(e) => set("floorPrice", e.target.value)} />
          </Field>
          <Field label="Decay duration (hours)" hint="Time to reach the floor">
            <input className="input" inputMode="decimal" value={f.decayHours} onChange={(e) => set("decayHours", e.target.value)} />
          </Field>
        </div>
      )}

      <div className="grid gap-4 sm:grid-cols-3">
        <Field label="Vesting cliff (days)">
          <input className="input" inputMode="decimal" value={f.cliffDays} onChange={(e) => set("cliffDays", e.target.value)} />
        </Field>
        <Field label="Vesting duration (days)" hint="0 = tokens liquid on claim">
          <input className="input" inputMode="decimal" value={f.vestingDays} onChange={(e) => set("vestingDays", e.target.value)} />
        </Field>
        <Field label="Offering documents (IPFS CID)">
          <input className="input" value={f.docsCID} placeholder="bafy…" onChange={(e) => set("docsCID", e.target.value)} />
        </Field>
      </div>

      <fieldset className="rounded-lg border border-line p-4">
        <legend className="px-1 text-sm font-medium">Investor eligibility</legend>
        <div className="grid gap-4 sm:grid-cols-3">
          <label className="flex items-center gap-2 text-sm">
            <input
              type="checkbox"
              checked={f.complianceEnabled}
              disabled={mandatory === true}
              onChange={(e) => set("complianceEnabled", e.target.checked)}
            />
            Compliance checks enabled{mandatory ? " (mandatory)" : ""}
          </label>
          <Field label="Minimum KYC tier" hint="1 = basic KYC">
            <input className="input" inputMode="numeric" value={f.minTier} onChange={(e) => set("minTier", e.target.value)} disabled={!f.complianceEnabled} />
          </Field>
          <label className="flex items-center gap-2 text-sm">
            <input type="checkbox" checked={f.requireAccredited} disabled={!f.complianceEnabled} onChange={(e) => set("requireAccredited", e.target.checked)} />
            Accredited / professional investors only
          </label>
          <Field label="Priority tier" hint="Tier allowed during the priority window">
            <input className="input" inputMode="numeric" value={f.priorityTier} onChange={(e) => set("priorityTier", e.target.value)} />
          </Field>
          <Field label="Priority window (hours)" hint="0 = none">
            <input className="input" inputMode="decimal" value={f.priorityHours} onChange={(e) => set("priorityHours", e.target.value)} />
          </Field>
        </div>
      </fieldset>

      {built.errors.length > 0 && (
        <Notice tone="warn">
          <ul className="list-disc pl-5">
            {built.errors.map((e) => (
              <li key={e}>{e}</li>
            ))}
          </ul>
        </Notice>
      )}
      <button className="btn btn-primary" disabled={built.errors.length > 0 || tx.busy} onClick={onSubmit}>
        {tx.busy ? "Processing…" : "Create offering"}
      </button>
      <TxStatusLine status={tx.status} error={tx.error} />
    </div>
  );
}
