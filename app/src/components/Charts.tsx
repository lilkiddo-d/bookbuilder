"use client";

import { useMemo } from "react";
import { fmtDate, toFloat } from "@/lib/format";

const W = 640;
const H = 280;
const PAD = { l: 64, r: 16, t: 16, b: 40 };
const IW = W - PAD.l - PAD.r;
const IH = H - PAD.t - PAD.b;

function niceNum(n: number): string {
  if (!Number.isFinite(n)) return "—";
  const a = Math.abs(n);
  if (a >= 1e9) return `${(n / 1e9).toFixed(2)}B`;
  if (a >= 1e6) return `${(n / 1e6).toFixed(2)}M`;
  if (a >= 1e4) return `${(n / 1e3).toFixed(1)}k`;
  if (a >= 100) return n.toFixed(0);
  if (a >= 1) return n.toFixed(2);
  return n.toPrecision(3);
}

function Axes({ xTicks, yTicks, xLabel, yLabel }: { xTicks: { x: number; label: string }[]; yTicks: { y: number; label: string }[]; xLabel: string; yLabel: string }) {
  return (
    <g fontSize="10" fill="var(--muted)">
      <line x1={PAD.l} y1={PAD.t + IH} x2={PAD.l + IW} y2={PAD.t + IH} stroke="var(--line)" />
      <line x1={PAD.l} y1={PAD.t} x2={PAD.l} y2={PAD.t + IH} stroke="var(--line)" />
      {yTicks.map((t, i) => (
        <g key={`y${i}`}>
          <line x1={PAD.l} x2={PAD.l + IW} y1={t.y} y2={t.y} stroke="var(--line)" strokeDasharray="2 4" />
          <text x={PAD.l - 6} y={t.y + 3} textAnchor="end">
            {t.label}
          </text>
        </g>
      ))}
      {xTicks.map((t, i) => (
        <text key={`x${i}`} x={t.x} y={PAD.t + IH + 14} textAnchor="middle">
          {t.label}
        </text>
      ))}
      <text x={PAD.l + IW / 2} y={H - 4} textAnchor="middle">
        {xLabel}
      </text>
      <text x={12} y={PAD.t + IH / 2} textAnchor="middle" transform={`rotate(-90 12 ${PAD.t + IH / 2})`}>
        {yLabel}
      </text>
    </g>
  );
}

export interface DemandCurveProps {
  /** revealed demand per tick (sale base units), index = tick */
  demand: readonly bigint[];
  minPrice: bigint;
  tickSize: bigint;
  supply: bigint;
  saleDecimals: number;
  payDecimals: number;
  saleSymbol: string;
  paySymbol: string;
  clearingPrice?: bigint;
}

/** Cumulative revealed demand (x) vs price (y), as a step chart, with supply line and clearing price marker. */
export function DemandCurveChart(p: DemandCurveProps) {
  const model = useMemo(() => {
    const n = p.demand.length;
    const prices = Array.from({ length: n }, (_, t) => toFloat(p.minPrice + BigInt(t) * p.tickSize, p.payDecimals));
    // cumulative demand at or above each tick
    const cum: number[] = new Array(n).fill(0);
    let acc = 0n;
    for (let t = n - 1; t >= 0; t--) {
      acc += p.demand[t];
      cum[t] = toFloat(acc, p.saleDecimals);
    }
    const supply = toFloat(p.supply, p.saleDecimals);
    const maxX = Math.max(supply * 1.15, cum[0] ?? 0, 1e-9);
    const minY = prices[0] ?? 0;
    const maxY = Math.max(prices[n - 1] ?? 1, minY + 1e-9);
    const span = maxY - minY || maxY || 1;
    const yLo = Math.max(0, minY - span * 0.05);
    const yHi = maxY + span * 0.05;
    const sx = (x: number) => PAD.l + (x / maxX) * IW;
    const sy = (y: number) => PAD.t + IH - ((y - yLo) / (yHi - yLo || 1)) * IH;
    // step path: walk from top price down; horizontal at each price to its cumulative demand
    let d = "";
    let prevX = 0;
    for (let t = n - 1; t >= 0; t--) {
      const y = sy(prices[t]);
      if (t === n - 1) d += `M ${sx(0)} ${y}`;
      else d += ` L ${sx(prevX)} ${y}`;
      d += ` L ${sx(cum[t])} ${y}`;
      prevX = cum[t];
    }
    const xTicks = [0, 0.25, 0.5, 0.75, 1].map((f) => ({ x: sx(maxX * f), label: niceNum(maxX * f) }));
    const yTicks = [0, 0.25, 0.5, 0.75, 1].map((f) => {
      const v = yLo + (yHi - yLo) * f;
      return { y: sy(v), label: niceNum(v) };
    });
    const clearing = p.clearingPrice && p.clearingPrice > 0n ? toFloat(p.clearingPrice, p.payDecimals) : undefined;
    return { d, sx, sy, supply, xTicks, yTicks, clearing, totalDemand: cum[0] ?? 0 };
  }, [p]);

  return (
    <svg viewBox={`0 0 ${W} ${H}`} className="h-auto w-full" role="img" aria-label="Demand curve">
      <Axes xTicks={model.xTicks} yTicks={model.yTicks} xLabel={`Cumulative demand (${p.saleSymbol})`} yLabel={`Price (${p.paySymbol})`} />
      <line x1={model.sx(model.supply)} x2={model.sx(model.supply)} y1={PAD.t} y2={PAD.t + IH} stroke="var(--warn)" strokeWidth="1.5" strokeDasharray="5 3" />
      <text x={model.sx(model.supply) + 4} y={PAD.t + 10} fontSize="10" fill="var(--warn)">
        Supply
      </text>
      {model.d && <path d={model.d} fill="none" stroke="var(--accent)" strokeWidth="2" />}
      {model.clearing !== undefined && (
        <g>
          <line x1={PAD.l} x2={PAD.l + IW} y1={model.sy(model.clearing)} y2={model.sy(model.clearing)} stroke="#10b981" strokeWidth="1.5" />
          <text x={PAD.l + IW - 4} y={model.sy(model.clearing) - 4} fontSize="10" textAnchor="end" fill="#10b981">
            Clearing {niceNum(model.clearing)} {p.paySymbol}
          </text>
        </g>
      )}
      {model.totalDemand === 0 && (
        <text x={PAD.l + IW / 2} y={PAD.t + IH / 2} textAnchor="middle" fontSize="12" fill="var(--muted)">
          No revealed demand yet
        </text>
      )}
    </svg>
  );
}

export interface DutchCurveProps {
  startTime: bigint;
  endTime: bigint;
  decayDuration: bigint;
  startPrice: bigint;
  floorPrice: bigint;
  currentPrice: bigint;
  now: number;
  payDecimals: number;
  paySymbol: string;
}

/** Linear price decay from startPrice to floorPrice over decayDuration, then flat until endTime. */
export function DutchCurveChart(p: DutchCurveProps) {
  const start = Number(p.startTime);
  const end = Number(p.endTime);
  const floorAt = start + Number(p.decayDuration);
  const sp = toFloat(p.startPrice, p.payDecimals);
  const fp = toFloat(p.floorPrice, p.payDecimals);
  const cp = toFloat(p.currentPrice, p.payDecimals);
  const yLo = Math.max(0, fp - (sp - fp) * 0.1);
  const yHi = sp + (sp - fp) * 0.1 || sp * 1.1 || 1;
  const sx = (t: number) => PAD.l + ((t - start) / Math.max(1, end - start)) * IW;
  const sy = (v: number) => PAD.t + IH - ((v - yLo) / (yHi - yLo || 1)) * IH;
  const nowClamped = Math.min(Math.max(p.now || start, start), end);
  const xTicks = [0, 0.5, 1].map((f) => {
    const t = start + (end - start) * f;
    return { x: sx(t), label: fmtDate(BigInt(Math.floor(t))) };
  });
  const yTicks = [0, 0.5, 1].map((f) => {
    const v = yLo + (yHi - yLo) * f;
    return { y: sy(v), label: niceNum(v) };
  });
  return (
    <svg viewBox={`0 0 ${W} ${H}`} className="h-auto w-full" role="img" aria-label="Dutch auction price curve">
      <Axes xTicks={xTicks} yTicks={yTicks} xLabel="Time" yLabel={`Price (${p.paySymbol})`} />
      <path d={`M ${sx(start)} ${sy(sp)} L ${sx(floorAt)} ${sy(fp)} L ${sx(end)} ${sy(fp)}`} fill="none" stroke="var(--accent)" strokeWidth="2" />
      {p.now > 0 && (
        <g>
          <line x1={sx(nowClamped)} x2={sx(nowClamped)} y1={PAD.t} y2={PAD.t + IH} stroke="var(--line)" strokeDasharray="3 3" />
          <circle cx={sx(nowClamped)} cy={sy(cp)} r="5" fill="var(--warn)" />
          <text x={sx(nowClamped) + 8} y={sy(cp) - 8} fontSize="10" fill="var(--warn)">
            Now {niceNum(cp)} {p.paySymbol}
          </text>
        </g>
      )}
    </svg>
  );
}
