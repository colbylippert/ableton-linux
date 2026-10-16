/**
 * DeltaBars: a trial's traced confirmation as two horizontal bars — the targeted call
 * site's share of lost slack before (arm A) and after (arm B) the change
 * (DESIGN.md §4.3 "BeforeAfterBars", §5).
 *
 * Form: before → after for one item = the ordinal pair (`--ord-before` → `--ord-after`),
 * one axis (share 0..100 %). Marks: bars 24 px thick, 4 px rounded data-end, square at the
 * baseline, 2 px surface gap, hairline solid gridlines, the two values as direct labels
 * at the bar tips (text tokens), a per-bar hit target with the same tooltip on hover and
 * keyboard focus, hovered bar lifts. Table twin: `DeltaBarsTable`.
 */
import { useState } from 'react';
import { NULL_TEXT, formatNumber } from '../data';
import DataTable, { type Column } from './DataTable';
import { SvgTooltip, useMeasuredWidth, type SvgTooltipState } from './PairedDots';
import './DeltaBars.css';

export interface DeltaBarsNames {
  before: string;
  after: string;
}

export interface DeltaBarsProps {
  before: number | null;
  after: number | null;
  /** What the bars measure, e.g. "NtWaitForSingleObject share of lost slack (VSTs)". */
  label: string;
  format: (v: number | null) => string;
  /** Axis domain; shares are 0..1. */
  domain?: [number, number];
  formatTick?: (v: number) => string;
  names?: DeltaBarsNames;
  /** Fixed pixel width (tests); omitted = the container width. */
  width?: number;
}

const DEFAULT_NAMES: DeltaBarsNames = { before: 'before (A)', after: 'after (B)' };
const MARGIN = { top: 6, right: 76, bottom: 28, left: 92 };
const BAR = 24;
const PITCH = 34;

/** `62.0% → 11.0% (▼ 51.0 pts)`: the change line for a subtitle; `pts` for shares, the unit otherwise. */
export function deltaBarsChange(before: number | null, after: number | null, format: (v: number | null) => string, share = true): string {
  if (before === null || after === null) return `${format(before)} → ${format(after)}`;
  const diff = after - before;
  const glyph = diff < 0 ? '▼' : diff > 0 ? '▲' : '';
  const magnitude = share ? `${formatNumber(Math.abs(diff) * 100, 1)} pts` : format(Math.abs(diff));
  return `${format(before)} → ${format(after)} (${glyph ? `${glyph} ` : ''}${magnitude})`;
}

function barPath(x: number, y: number, w: number, h: number): string {
  const r = Math.min(4, w / 2, h / 2);
  if (w <= 0) return '';
  return `M${x},${y} h${w - r} a${r},${r} 0 0 1 ${r},${r} v${h - 2 * r} a${r},${r} 0 0 1 -${r},${r} h-${w - r} z`;
}

export function DeltaBars({ before, after, label, format, domain = [0, 1], formatTick, names = DEFAULT_NAMES, width }: DeltaBarsProps) {
  const [ref, measured] = useMeasuredWidth<HTMLDivElement>(640);
  const [tip, setTip] = useState<SvgTooltipState | null>(null);
  const w = width ?? measured;
  if (before === null && after === null) {
    return <div className="empty db-empty">No before / after values.</div>;
  }
  const [dMin, dMaxRaw] = domain;
  const dMax = Math.max(dMaxRaw, before ?? dMin, after ?? dMin);
  const plotW = Math.max(80, w - MARGIN.left - MARGIN.right);
  const height = MARGIN.top + 2 * PITCH + MARGIN.bottom;
  const x = (v: number) => MARGIN.left + ((Math.min(Math.max(v, dMin), dMax) - dMin) / (dMax - dMin || 1)) * plotW;
  const tickOf = formatTick ?? ((v: number) => format(v));
  const ticks = [0, 0.25, 0.5, 0.75, 1].map((f) => dMin + f * (dMax - dMin));
  const axisY = MARGIN.top + 2 * PITCH;
  const rows: { id: 'before' | 'after'; name: string; value: number | null }[] = [
    { id: 'before', name: names.before, value: before },
    { id: 'after', name: names.after, value: after },
  ];
  const show = (row: (typeof rows)[number], cy: number) =>
    setTip({ x: row.value === null ? MARGIN.left : x(row.value), y: cy, title: format(row.value), sub: `${row.name} · ${label}`, rows: [] });

  return (
    <div ref={ref} className="svg-chart db" style={{ position: 'relative' }}>
      <svg className="db-svg" width={w} height={height} viewBox={`0 0 ${w} ${height}`} role="img" aria-label={`${label}: ${deltaBarsChange(before, after, format)}`}>
        {ticks.map((t) => (
          <g key={t}>
            <line x1={x(t)} x2={x(t)} y1={MARGIN.top} y2={axisY} className="db-grid" />
            <text x={x(t)} y={axisY + 16} className="db-tick" textAnchor="middle">
              {tickOf(t)}
            </text>
          </g>
        ))}
        <line x1={MARGIN.left} x2={MARGIN.left + plotW} y1={axisY} y2={axisY} className="db-axis" />
        {rows.map((row, i) => {
          const top = MARGIN.top + i * PITCH + (PITCH - BAR) / 2;
          const cy = top + BAR / 2;
          const bw = row.value === null ? 0 : Math.max(0, x(row.value) - MARGIN.left);
          return (
            <g
              key={row.id}
              className="db-row"
              tabIndex={0}
              role="img"
              aria-label={`${row.name}: ${format(row.value)}`}
              onMouseEnter={() => show(row, cy)}
              onFocus={() => show(row, cy)}
              onMouseLeave={() => setTip(null)}
              onBlur={() => setTip(null)}
            >
              <rect className="db-hit" x={MARGIN.left - 2} y={top - 4} width={plotW + 4} height={BAR + 8} />
              <text x={MARGIN.left - 10} y={cy + 4} className="db-label" textAnchor="end">
                {row.name}
              </text>
              {row.value !== null && bw > 0 ? <path className={`db-bar db-bar-${row.id}`} d={barPath(MARGIN.left, top, bw, BAR)} /> : null}
              <text x={MARGIN.left + bw + 8} y={cy + 4} className="db-value" textAnchor="start">
                {row.value === null ? NULL_TEXT : format(row.value)}
              </text>
            </g>
          );
        })}
      </svg>
      <SvgTooltip tip={tip} width={w} />
    </div>
  );
}

export default DeltaBars;

export interface DeltaBarsTableProps {
  before: number | null;
  after: number | null;
  label: string;
  format: (v: number | null) => string;
  names?: DeltaBarsNames;
  caption: string;
  captionHidden?: boolean;
  /** When true the change row is in percentage points (shares). */
  share?: boolean;
}

interface DeltaRow {
  id: string;
  what: string;
  value: string;
}

/** The table twin: before, after and the change. */
export function DeltaBarsTable({ before, after, label, format, names = DEFAULT_NAMES, caption, captionHidden, share = true }: DeltaBarsTableProps) {
  const change =
    before === null || after === null
      ? NULL_TEXT
      : share
        ? `${after - before < 0 ? '▼ ' : after - before > 0 ? '▲ ' : ''}${formatNumber(Math.abs(after - before) * 100, 1)} pts`
        : `${after - before < 0 ? '▼ ' : after - before > 0 ? '▲ ' : ''}${format(Math.abs(after - before))}`;
  const rows: DeltaRow[] = [
    { id: 'before', what: names.before, value: format(before) },
    { id: 'after', what: names.after, value: format(after) },
    { id: 'change', what: 'change (after − before)', value: change },
  ];
  const columns: Column<DeltaRow>[] = [
    { key: 'what', header: label, render: (r) => r.what },
    { key: 'value', header: 'Value', numeric: true, render: (r) => r.value },
  ];
  return <DataTable caption={caption} captionHidden={captionHidden} columns={columns} rows={rows} rowKey={(r) => r.id} dense />;
}
