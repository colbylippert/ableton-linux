/**
 * PairedDots: the ABAB pairs of a trial as dumbbells (DESIGN.md §4.3, §5).
 *
 * Form (dataviz "before → after per item"): one row per interleaved pair, A → B on one
 * value axis, the ordinal before/after pair (`--ord-before` → `--ord-after`: one hue, two
 * shades) — never two categorical slots, so nothing has to pass the all-pairs cap. The
 * optional wash behind each A dot is A ± 2 × the A/A spread, i.e. the acceptance gate the
 * agent applies ("median improvement > 2 × spread"), drawn at 10 % like every band.
 *
 * Marks: 8 px+ dots (r 5) with a 2 px surface ring, a 2 px connector, hairline solid
 * gridlines, one selective direct label per row (the signed Δ, text tokens only), a
 * 24 px hit target per dot with the same tooltip on hover and keyboard focus, and a table
 * twin (`PairedDotsTable`) rendered through ChartFrame's toggle.
 *
 * Plain SVG rather than Recharts: Recharts has no dumbbell primitive and this chart is a
 * handful of marks; the mark specs are applied by hand. `useMeasuredWidth` and
 * `SvgTooltip` are shared with DeltaBars and CallSiteTrend (same owner).
 */
import { useLayoutEffect, useRef, useState, type RefObject } from 'react';
import type { MetricDirection, Significance } from '../data/types';
import { formatNumber, median, signedDelta, significanceOf, NULL_TEXT } from '../data';
import DataTable, { type Column } from './DataTable';
import './PairedDots.css';

// ---------------------------------------------------------------------------
// Shared helpers (used by the other D3 charts)
// ---------------------------------------------------------------------------

/**
 * Width of a block container, kept current with ResizeObserver when available. Under
 * jsdom (no layout, no ResizeObserver) the fallback is returned, so tests render a
 * deterministic chart.
 */
export function useMeasuredWidth<T extends HTMLElement>(fallback = 640): [RefObject<T>, number] {
  const ref = useRef<T>(null);
  const [width, setWidth] = useState(fallback);
  useLayoutEffect(() => {
    const el = ref.current;
    if (!el) return undefined;
    const measure = () => {
      const w = el.getBoundingClientRect().width;
      if (w > 0) setWidth((prev) => (Math.abs(prev - w) < 1 ? prev : Math.round(w)));
    };
    measure();
    if (typeof ResizeObserver === 'undefined') return undefined;
    const observer = new ResizeObserver(measure);
    observer.observe(el);
    return () => observer.disconnect();
  }, []);
  return [ref, width];
}

export interface SvgTooltipState {
  /** Pixel position inside the chart wrapper. */
  x: number;
  y: number;
  title: string;
  sub?: string;
  rows: { value: string; label: string }[];
}

/** Hover/focus tooltip for the hand-drawn SVG charts; same chrome as the Recharts one. */
export function SvgTooltip({ tip, width }: { tip: SvgTooltipState | null; width: number }) {
  if (!tip) return null;
  const flip = tip.x > width * 0.6;
  return (
    <div
      className="chart-tooltip svg-tooltip"
      role="tooltip"
      style={{ left: tip.x + (flip ? -12 : 12), top: tip.y - 8, transform: flip ? 'translateX(-100%)' : undefined }}
    >
      <div className="tt-head">
        <strong>{tip.title}</strong>
      </div>
      {tip.sub ? <div className="tt-sub">{tip.sub}</div> : null}
      {tip.rows.length > 0 ? (
        <ul className="tt-rows">
          {tip.rows.map((r) => (
            <li key={`${r.label}-${r.value}`}>
              <span className="tt-value">{r.value}</span>
              <span className="tt-label">{r.label}</span>
            </li>
          ))}
        </ul>
      ) : null}
    </div>
  );
}

/** Clean tick positions over [min, max]: steps of 1 / 2 / 2.5 / 5 × 10^k, about `count` of them. */
export function niceTicks(min: number, max: number, count = 5): number[] {
  if (!(max > min) || !Number.isFinite(min) || !Number.isFinite(max)) return [min];
  const rawStep = (max - min) / Math.max(1, count - 1);
  const mag = 10 ** Math.floor(Math.log10(rawStep));
  const step = [1, 2, 2.5, 5, 10].map((m) => m * mag).find((s) => s >= rawStep) ?? 10 * mag;
  const decimals = Math.max(0, -Math.floor(Math.log10(step)) + 1);
  const ticks: number[] = [];
  for (let v = Math.ceil(min / step) * step; v <= max + step * 1e-9; v += step) {
    ticks.push(Number(v.toFixed(decimals)));
  }
  return ticks;
}

// ---------------------------------------------------------------------------
// PairedDots
// ---------------------------------------------------------------------------

export interface PairedDotsPair {
  /** 1-based pair number in ABAB order. */
  index: number;
  a: number | null;
  b: number | null;
  runA: string;
  runB: string;
}

export interface PairedDotsProps {
  pairs: PairedDotsPair[];
  unit: string;
  direction: MetricDirection;
  format: (v: number | null) => string;
  /** A/A spread in the metric's unit; draws A ± 2 × spread (the acceptance gate) behind each pair. */
  spread?: number | null;
  /** Accessible name of the chart. */
  label?: string;
  /** Fixed pixel width (tests); omitted = the container width. */
  width?: number;
  rowHeight?: number;
}

export type PairedDeltaDirection = 'better' | 'worse' | 'flat' | 'neutral';

export interface PairedDotsSummary {
  /** Pairs with both values. */
  n: number;
  /** Median over pairs of the signed B − A delta (positive = improvement). */
  medianDelta: number | null;
  spread: number | null;
  /** `|medianDelta| / spread`; `null` without a positive spread. */
  ratio: number | null;
  significance: Significance;
  direction: PairedDeltaDirection;
}

/** The acceptance-gate numbers for a Set: median signed delta over pairs vs 2 × spread. */
export function pairedDotsSummary(pairs: readonly PairedDotsPair[], direction: MetricDirection, spread: number | null = null): PairedDotsSummary {
  const deltas: number[] = [];
  for (const p of pairs) {
    if (p.a !== null && p.b !== null) deltas.push(signedDelta(p.b, p.a, direction).abs);
  }
  const medianDelta = median(deltas);
  const s = spread !== null && Number.isFinite(spread) ? spread : null;
  const ratio = medianDelta !== null && s !== null && s > 0 ? Math.abs(medianDelta) / s : null;
  const significance: Significance = direction === 'neutral' ? 'unknown' : significanceOf(medianDelta, s);
  let dir: PairedDeltaDirection = 'flat';
  if (direction === 'neutral') dir = 'neutral';
  else if (medianDelta !== null && medianDelta > 0) dir = 'better';
  else if (medianDelta !== null && medianDelta < 0) dir = 'worse';
  return { n: deltas.length, medianDelta, spread: s, ratio, significance, direction: dir };
}

interface DeltaText {
  glyph: string;
  status: 'good' | 'critical' | 'none';
  text: string;
}

/** `▲ 1.3%` — the glyph carries the direction (status colour on the glyph only), the number is unsigned. */
export function pairDeltaText(a: number | null, b: number | null, direction: MetricDirection, format: (v: number | null) => string): DeltaText {
  if (a === null || b === null) return { glyph: '', status: 'none', text: NULL_TEXT };
  const { abs } = signedDelta(b, a, direction);
  const magnitude = format(Math.abs(b - a));
  if (direction === 'neutral') {
    const raw = b - a;
    return { glyph: '', status: 'none', text: raw === 0 ? magnitude : `${raw > 0 ? '+' : '-'}${magnitude}` };
  }
  if (abs > 0) return { glyph: '▲', status: 'good', text: magnitude };
  if (abs < 0) return { glyph: '▼', status: 'critical', text: magnitude };
  return { glyph: '', status: 'none', text: magnitude };
}

const MARGIN = { top: 10, right: 112, bottom: 30, left: 64 };

export function PairedDots({ pairs, unit, direction, format, spread = null, label, width, rowHeight = 36 }: PairedDotsProps) {
  const [ref, measured] = useMeasuredWidth<HTMLDivElement>(640);
  const [tip, setTip] = useState<SvgTooltipState | null>(null);
  const w = width ?? measured;

  const values: number[] = [];
  for (const p of pairs) {
    if (p.a !== null) values.push(p.a);
    if (p.b !== null) values.push(p.b);
    if (spread !== null && p.a !== null) values.push(p.a - 2 * spread, p.a + 2 * spread);
  }
  if (values.length === 0 || pairs.length === 0) {
    return <div className="empty pd-empty">No pair values to plot.</div>;
  }

  let dMin = Math.min(...values);
  let dMax = Math.max(...values);
  if (dMax === dMin) {
    const padAbs = Math.max(Math.abs(dMin) * 0.1, 1);
    dMin -= padAbs;
    dMax += padAbs;
  } else {
    const pad = (dMax - dMin) * 0.06;
    dMin -= pad;
    dMax += pad;
  }
  const plotW = Math.max(80, w - MARGIN.left - MARGIN.right);
  const plotH = pairs.length * rowHeight;
  const height = MARGIN.top + plotH + MARGIN.bottom;
  const x = (v: number) => MARGIN.left + ((v - dMin) / (dMax - dMin)) * plotW;
  const clampX = (v: number) => Math.min(MARGIN.left + plotW, Math.max(MARGIN.left, x(v)));
  // Five ticks need ~200 px of plot; narrower frames (four per row at 1280 px) get three, so labels never overlap.
  const ticks = niceTicks(dMin, dMax, plotW < 200 ? 3 : 5);
  const axisY = MARGIN.top + plotH;

  const show = (cx: number, cy: number, arm: 'A' | 'B', p: PairedDotsPair) => {
    const value = arm === 'A' ? p.a : p.b;
    const run = arm === 'A' ? p.runA : p.runB;
    setTip({
      x: cx,
      y: cy,
      title: `${format(value)}${unit ? ` ${unit}` : ''}`,
      sub: `pair ${p.index} · arm ${arm}${arm === 'A' ? ' (before)' : ' (after)'}`,
      rows: [{ value: run, label: 'run' }],
    });
  };
  const hide = () => setTip(null);

  return (
    <div ref={ref} className="svg-chart pd" style={{ position: 'relative' }}>
      <svg
        className="pd-svg"
        width={w}
        height={height}
        viewBox={`0 0 ${w} ${height}`}
        role="img"
        aria-label={label ?? `${pairs.length} A/B pairs, A before B after`}
      >
        {/* gridlines + ticks: hairline solid, one step off the surface */}
        {ticks.map((t) => (
          <g key={t}>
            <line x1={x(t)} x2={x(t)} y1={MARGIN.top} y2={axisY} className="pd-grid" />
            <text x={x(t)} y={axisY + 16} className="pd-tick" textAnchor="middle">
              {format(t)}
            </text>
          </g>
        ))}
        <line x1={MARGIN.left} x2={MARGIN.left + plotW} y1={axisY} y2={axisY} className="pd-axis" />
        {unit ? (
          <text x={MARGIN.left + plotW} y={axisY + 28} className="pd-tick pd-unit" textAnchor="end">
            {unit}
          </text>
        ) : null}

        {pairs.map((p, i) => {
          const cy = MARGIN.top + i * rowHeight + rowHeight / 2;
          const delta = pairDeltaText(p.a, p.b, direction, format);
          return (
            <g key={p.index} className="pd-row">
              <text x={MARGIN.left - 10} y={cy + 4} className="pd-label" textAnchor="end">
                pair {p.index}
              </text>
              {spread !== null && p.a !== null ? (
                <rect
                  className="pd-wash"
                  x={clampX(p.a - 2 * spread)}
                  y={cy - rowHeight / 2 + 4}
                  width={Math.max(0, clampX(p.a + 2 * spread) - clampX(p.a - 2 * spread))}
                  height={rowHeight - 8}
                />
              ) : null}
              {p.a !== null && p.b !== null ? <line className="pd-connector" x1={x(p.a)} x2={x(p.b)} y1={cy} y2={cy} /> : null}
              {p.a !== null ? <circle className="pd-dot pd-dot-a" cx={x(p.a)} cy={cy} r={5} /> : null}
              {p.b !== null ? <circle className="pd-dot pd-dot-b" cx={x(p.b)} cy={cy} r={5} /> : null}
              {(['A', 'B'] as const).map((arm) => {
                const v = arm === 'A' ? p.a : p.b;
                if (v === null) return null;
                const run = arm === 'A' ? p.runA : p.runB;
                return (
                  <circle
                    key={arm}
                    className="pd-hit"
                    cx={x(v)}
                    cy={cy}
                    r={12}
                    tabIndex={0}
                    role="img"
                    aria-label={`pair ${p.index} arm ${arm}: ${format(v)}${unit ? ` ${unit}` : ''}, run ${run}`}
                    onMouseEnter={() => show(x(v), cy, arm, p)}
                    onFocus={() => show(x(v), cy, arm, p)}
                    onMouseLeave={hide}
                    onBlur={hide}
                  />
                );
              })}
              <text x={MARGIN.left + plotW + 12} y={cy + 4} className="pd-delta" textAnchor="start">
                {delta.glyph ? (
                  <tspan className={`pd-glyph pd-glyph-${delta.status}`} aria-hidden="true">
                    {delta.glyph}{' '}
                  </tspan>
                ) : null}
                <tspan>{delta.text}</tspan>
              </text>
            </g>
          );
        })}
      </svg>
      <SvgTooltip tip={tip} width={w} />
    </div>
  );
}

export default PairedDots;

/** Key row for the chart: A / B marks and the wash, in words. */
export function PairedDotsKey({ spread, format }: { spread?: number | null; format: (v: number | null) => string }) {
  return (
    <div className="chart-key pd-key">
      <span>
        <span className="pd-key-dot pd-key-a" aria-hidden="true" /> A (before)
      </span>
      <span>
        <span className="pd-key-dot pd-key-b" aria-hidden="true" /> B (after)
      </span>
      <span>
        <span className="pd-key-delta" aria-hidden="true">
          ▲▼
        </span>{' '}
        Δ = B vs A, positive = improvement
      </span>
      {spread !== null && spread !== undefined ? (
        <span>
          <span className="key-band pd-key-wash" aria-hidden="true" /> A ± 2 × A/A spread ({format(spread)})
        </span>
      ) : null}
    </div>
  );
}

export interface PairedDotsTableProps {
  pairs: PairedDotsPair[];
  direction: MetricDirection;
  format: (v: number | null) => string;
  caption: string;
  captionHidden?: boolean;
}

/** The table twin: every value the chart shows, plus the run ids. */
export function PairedDotsTable({ pairs, direction, format, caption, captionHidden }: PairedDotsTableProps) {
  const columns: Column<PairedDotsPair>[] = [
    { key: 'index', header: 'Pair', numeric: true, render: (p) => String(p.index), sortValue: (p) => p.index },
    { key: 'runA', header: 'Run A', render: (p) => <span className="cell-mono">{p.runA}</span> },
    { key: 'runB', header: 'Run B', render: (p) => <span className="cell-mono">{p.runB}</span> },
    { key: 'a', header: 'A', numeric: true, render: (p) => format(p.a), sortValue: (p) => p.a },
    { key: 'b', header: 'B', numeric: true, render: (p) => format(p.b), sortValue: (p) => p.b },
    {
      key: 'delta',
      header: 'Δ (B vs A)',
      numeric: true,
      title: 'Positive = improvement',
      render: (p) => {
        const d = pairDeltaText(p.a, p.b, direction, format);
        return (
          <span>
            {d.glyph ? (
              <span className={`pd-glyph pd-glyph-${d.status}`} aria-hidden="true">
                {d.glyph}{' '}
              </span>
            ) : null}
            {d.text}
          </span>
        );
      },
      sortValue: (p) => (p.a === null || p.b === null ? null : signedDelta(p.b, p.a, direction).abs),
    },
  ];
  return <DataTable caption={caption} captionHidden={captionHidden} columns={columns} rows={pairs} rowKey={(p) => String(p.index)} dense />;
}

/** `3.2×` for the ratio-to-spread chip text. */
export function formatRatio(ratio: number | null): string {
  return ratio === null ? NULL_TEXT : `${formatNumber(ratio, 1)}×`;
}
