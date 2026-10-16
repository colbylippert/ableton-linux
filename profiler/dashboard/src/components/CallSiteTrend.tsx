/**
 * CallSiteTrend: which call sites lose the slack, run by run (DESIGN.md §4.4).
 *
 * Form: one horizontal stacked bar per traced run (part-to-whole of the attributed lost
 * slack), segments = call sites. Colour is categorical and **fixed per call-site key
 * within the view**: the view ranks the keys once (`assignCallSiteSlots`, top 8 by maximum
 * share across the slice) and every card of the view uses the same key → slot map, so a
 * key keeps its hue from card to card and from run to run. Keys outside the top 8 fold
 * into "other listed sites" in the de-emphasis gray — never a 9th hue. The legend lists
 * every segment with its targeted-by chips (ledger evidence), click = isolate.
 *
 * Marks: bars 24 px, 2 px surface gap between segments, 4 px rounded data-end on the last
 * segment only, hairline solid grid, per-segment tooltip (no crosshair), hovered segment
 * lifts; direct labels only on the latest run's bar and only where they fit. The table
 * twin (`CallSiteTrendTable`) carries every share and the targeted-by chips.
 *
 * Colours reach Recharts as hex through `src/palette.ts` (`useThemeMode`), like TrendChart.
 */
import { useMemo, type ReactElement } from 'react';
import { Bar, BarChart, CartesianGrid, Tooltip, XAxis, YAxis, type BarShapeProps } from 'recharts';
import type { Arm, Run, Verdict } from '../data/types';
import { compareStrings, formatDate, formatDateTick, formatShare, sortRuns, startedMs, type SeriesSlot } from '../data';
import { PALETTE, seriesHex, useThemeMode, type ThemeMode } from '../palette';
import Badge, { verdictBadge } from './Badge';
import DataTable, { type Column } from './DataTable';
import { useMeasuredWidth } from './PairedDots';
import './CallSiteTrend.css';

export const OTHER_ID = 'other';
export const MAX_CALL_SITE_SLOTS = 8;

export interface CallSiteKeyParts {
  kind: string;
  name: string;
  caller: string;
  /** Short display label (the symbol name, else the whole key). */
  label: string;
  /** `kind · caller`. */
  detail: string;
}

/** `"ntsync_wait|NtWaitForSingleObject|ntdll+0x7f3a1"` → kind / name / caller. */
export function parseCallSiteKey(key: string): CallSiteKeyParts {
  const parts = key.split('|');
  const kind = parts.length >= 3 ? (parts[0] ?? '') : '';
  const name = parts.length >= 3 ? (parts[1] ?? '') : parts.length === 2 ? (parts[0] ?? '') : key;
  const caller = parts.length >= 3 ? parts.slice(2).join('|') : parts.length === 2 ? (parts[1] ?? '') : '';
  return { kind, name, caller, label: name || key, detail: [kind, caller].filter(Boolean).join(' · ') };
}

export type TargetedBy = (key: string) => { trial: string; verdict: Verdict }[];

/**
 * key → categorical slot for the whole view: keys ranked by their maximum share across
 * every run × Set given (ties by key), the first `max` get slots 1..max.
 */
export function assignCallSiteSlots(runs: readonly Run[], sets?: readonly string[], max = MAX_CALL_SITE_SLOTS): Map<string, SeriesSlot> {
  const best = new Map<string, number>();
  for (const run of runs) {
    for (const name of sets ?? Object.keys(run.sets)) {
      for (const cs of run.sets[name]?.call_sites_top ?? []) {
        if (!Number.isFinite(cs.share)) continue;
        const prev = best.get(cs.key);
        if (prev === undefined || cs.share > prev) best.set(cs.key, cs.share);
      }
    }
  }
  const ranked = [...best.entries()].sort((a, b) => b[1] - a[1] || compareStrings(a[0], b[0])).slice(0, Math.min(max, MAX_CALL_SITE_SLOTS));
  const slots = new Map<string, SeriesSlot>();
  ranked.forEach(([key], i) => slots.set(key, (i + 1) as SeriesSlot));
  return slots;
}

export interface CallSiteSeries {
  /** Recharts data key suffix: `s<slot>` or `other`. */
  id: string;
  key: string | null;
  slot: SeriesSlot;
  label: string;
  detail: string;
}

export interface CallSiteRow {
  runId: string;
  startedAt: string;
  t: number;
  /** Y tick: date, plus trial / arm when the run belongs to a trial. */
  label: string;
  tag: string;
  trial: string | null;
  arm: Arm | null;
  switches: Record<string, string>;
  /** Share per series id (`s1`, `s2`, …, `other`); absent = 0. */
  values: Record<string, number>;
  /** Sum of the listed shares (≤ 1; the rest is unattributed or unlisted). */
  total: number;
  /** Series id of the last non-zero segment (gets the rounded data-end). */
  lastId: string | null;
}

export const seriesId = (slot: SeriesSlot): string => (slot === 'dim' ? OTHER_ID : `s${slot}`);

/** The segments of one card in slot order, then "other listed sites" when any run folds something into it. */
export function callSiteSeries(runs: readonly Run[], set: string, slots: ReadonlyMap<string, SeriesSlot>): CallSiteSeries[] {
  const present = new Map<string, SeriesSlot>();
  let other = false;
  for (const run of runs) {
    for (const cs of run.sets[set]?.call_sites_top ?? []) {
      const slot = slots.get(cs.key);
      if (slot === undefined || slot === 'dim') other = other || cs.share > 0;
      else present.set(cs.key, slot);
    }
  }
  const out: CallSiteSeries[] = [...present.entries()]
    .sort((a, b) => Number(a[1]) - Number(b[1]))
    .map(([key, slot]) => {
      const parts = parseCallSiteKey(key);
      return { id: seriesId(slot), key, slot, label: parts.label, detail: parts.detail };
    });
  if (other) out.push({ id: OTHER_ID, key: null, slot: 'dim', label: 'other listed sites', detail: 'keys outside the top 8 of this view' });
  return out;
}

/** One row per run (chronological) with the share per series id. */
export function buildCallSiteRows(runs: readonly Run[], set: string, slots: ReadonlyMap<string, SeriesSlot>): CallSiteRow[] {
  const rows: CallSiteRow[] = [];
  for (const run of sortRuns(runs)) {
    const list = run.sets[set]?.call_sites_top;
    if (!Array.isArray(list)) continue;
    const values: Record<string, number> = {};
    let total = 0;
    for (const cs of list) {
      if (!Number.isFinite(cs.share)) continue;
      const slot = slots.get(cs.key);
      const id = slot === undefined ? OTHER_ID : seriesId(slot);
      values[id] = (values[id] ?? 0) + cs.share;
      total += cs.share;
    }
    const order = Object.keys(values)
      .filter((id) => id !== OTHER_ID)
      .sort((a, b) => Number(a.slice(1)) - Number(b.slice(1)));
    if (values[OTHER_ID] !== undefined) order.push(OTHER_ID);
    let lastId: string | null = null;
    for (const id of order) if ((values[id] ?? 0) > 0) lastId = id;
    const trialText = run.trial ? ` · ${run.trial}${run.arm ? ` ${run.arm}` : ''}` : run.arm ? ` · ${run.arm}` : '';
    rows.push({
      runId: run.run_id,
      startedAt: run.started_at,
      t: startedMs(run),
      label: `${formatDateTick(run.started_at)}${trialText}`,
      tag: run.tag,
      trial: run.trial,
      arm: run.arm,
      switches: run.switches ?? {},
      values,
      total,
      lastId,
    });
  }
  return rows;
}

// ---------------------------------------------------------------------------
// Colour helpers
// ---------------------------------------------------------------------------

function channel(c: number): number {
  const s = c / 255;
  return s <= 0.03928 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4;
}

/** WCAG relative luminance of a `#rrggbb` hex. */
export function luminance(hex: string): number {
  const h = hex.replace('#', '');
  const r = parseInt(h.slice(0, 2), 16);
  const g = parseInt(h.slice(2, 4), 16);
  const b = parseInt(h.slice(4, 6), 16);
  return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b);
}

/** Ink for a label set inside a fill: white or near-black, whichever contrasts more. */
export function inkOnFill(hex: string): string {
  const l = luminance(hex);
  const white = 1.05 / (l + 0.05);
  const black = (l + 0.05) / 0.05;
  return white >= 4.5 || white > black ? '#ffffff' : '#0b0b0b';
}

// ---------------------------------------------------------------------------
// Chart
// ---------------------------------------------------------------------------

export interface CallSiteTrendProps {
  /** Traced runs of one identity (any order). */
  runs: readonly Run[];
  set: string;
  /** View-level key → slot map (`assignCallSiteSlots`). */
  slots: ReadonlyMap<string, SeriesSlot>;
  targeted?: TargetedBy;
  /** Isolated call-site key (legend click); `OTHER_ID` isolates the fold. */
  emphasis?: string | null;
  onEmphasis?: (key: string | null) => void;
  /** Fixed pixel width (tests); omitted = the container width. */
  width?: number;
}

const TICKS = [0, 0.25, 0.5, 0.75, 1];
const pctTick = (v: number): string => `${Math.round(v * 100)}%`;
const ROW = 34;
const AXIS_BAND = 44;

interface SegmentOptions {
  id: string;
  hex: string;
  dimmed: boolean;
  lastRow: number;
}

function segmentShape({ id, hex, dimmed, lastRow }: SegmentOptions, active: boolean) {
  const ink = inkOnFill(hex);
  return function Segment(p: BarShapeProps): ReactElement | null {
    const { x, y, width, height, index } = p;
    const row = p.payload as CallSiteRow | undefined;
    if (!row || !Number.isFinite(x) || !Number.isFinite(width) || width <= 0 || height <= 0) return null;
    const gx = x + 1;
    const gw = Math.max(0, width - 2);
    if (gw <= 0) return null;
    const rounded = row.lastId === id;
    const r = rounded ? Math.min(4, gw / 2, height / 2) : 0;
    const d = rounded
      ? `M${gx},${y} h${gw - r} a${r},${r} 0 0 1 ${r},${r} v${height - 2 * r} a${r},${r} 0 0 1 -${r},${r} h-${gw - r} z`
      : `M${gx},${y} h${gw} v${height} h-${gw} z`;
    const value = row.values[id] ?? 0;
    const text = pctTick(value);
    const fits = index === lastRow && value > 0 && gw >= text.length * 6.6 + 12;
    return (
      <g className="cst-segment" data-series={id}>
        <path d={d} fill={hex} fillOpacity={dimmed ? 0.25 : active ? 0.82 : 1} stroke="none" />
        {fits && !dimmed ? (
          <text x={gx + gw / 2} y={y + height / 2} dy={4} fill={ink} fontSize={11} textAnchor="middle" className="cst-inlabel">
            {text}
          </text>
        ) : null}
      </g>
    );
  };
}

interface TooltipEntry {
  dataKey?: unknown;
  value?: unknown;
  payload?: unknown;
}

interface CallSiteTooltipProps {
  active?: boolean;
  payload?: ReadonlyArray<TooltipEntry>;
  series: CallSiteSeries[];
  mode: ThemeMode;
}

/** Per-segment tooltip: the segment's share first (strong), then the run and its total. */
export function CallSiteTooltip({ active, payload, series, mode }: CallSiteTooltipProps) {
  if (!active || !payload || payload.length === 0) return null;
  const entry = payload[0]!;
  const row = entry.payload as CallSiteRow | undefined;
  if (!row) return null;
  const key = typeof entry.dataKey === 'string' ? entry.dataKey.replace(/^values\./u, '') : '';
  const s = series.find((x) => x.id === key);
  const value = typeof entry.value === 'number' ? entry.value : (row.values[key] ?? null);
  const context = [row.tag, row.trial ? `${row.trial}${row.arm ? ` / ${row.arm}` : ''}` : row.arm]
    .filter((part): part is string => Boolean(part))
    .join(' · ');
  return (
    <div className="chart-tooltip">
      <div className="tt-head">
        <strong>{formatShare(value)}</strong>
        <span className="tt-label">{s?.label ?? key}</span>
      </div>
      {s?.detail ? <div className="tt-sub mono">{s.detail}</div> : null}
      <div className="tt-sub">
        {formatDate(row.startedAt)} <span className="mono muted">{row.runId}</span>
        {context ? ` · ${context}` : ''}
      </div>
      <ul className="tt-rows">
        <li>
          <span className="tt-key" style={{ background: s ? seriesHex(s.slot, mode) : 'transparent' }} aria-hidden="true" />
          <span className="tt-value">{formatShare(row.total)}</span>
          <span className="tt-label">attributed to listed sites in this run</span>
        </li>
      </ul>
    </div>
  );
}

export function CallSiteTrend({ runs, set, slots, targeted, emphasis = null, onEmphasis, width }: CallSiteTrendProps) {
  const mode = useThemeMode();
  const pal = PALETTE[mode];
  const [ref, measured] = useMeasuredWidth<HTMLDivElement>(640);
  const w = width ?? measured;
  const rows = useMemo(() => buildCallSiteRows(runs, set, slots), [runs, set, slots]);
  const series = useMemo(() => callSiteSeries(runs, set, slots), [runs, set, slots]);

  if (rows.length === 0 || series.length === 0) {
    return <div className="empty cst-empty">No call-site data for this Set in the traced runs of the slice.</div>;
  }
  const height = rows.length * ROW + AXIS_BAND;
  const yWidth = Math.min(180, Math.max(96, ...rows.map((r) => r.label.length * 6.4 + 8)));
  const lastRow = rows.length - 1;
  const isolated = (s: CallSiteSeries): boolean => emphasis !== null && (s.key ?? OTHER_ID) !== emphasis;

  return (
    <div ref={ref} className="cst">
      <div className="cst-plot">
        <BarChart layout="vertical" width={w} height={height} data={rows} margin={{ top: 4, right: 16, bottom: 4, left: 4 }} barCategoryGap={10}>
          <CartesianGrid horizontal={false} vertical stroke={pal.grid} strokeDasharray="" />
          <XAxis
            type="number"
            domain={[0, 1]}
            ticks={TICKS}
            tickFormatter={pctTick}
            tick={{ fill: pal.textMuted, fontSize: 11 }}
            axisLine={{ stroke: pal.axis }}
            tickLine={false}
          />
          <YAxis type="category" dataKey="label" width={yWidth} interval={0} tick={{ fill: pal.textSecondary, fontSize: 11 }} axisLine={false} tickLine={false} />
          <Tooltip
            shared={false}
            cursor={false}
            isAnimationActive={false}
            wrapperStyle={{ outline: 'none', zIndex: 2 }}
            content={(p) => <CallSiteTooltip active={p.active} payload={p.payload as ReadonlyArray<TooltipEntry>} series={series} mode={mode} />}
          />
          {series.map((s) => {
            const hex = seriesHex(s.slot, mode);
            const opts: SegmentOptions = { id: s.id, hex, dimmed: isolated(s), lastRow };
            return (
              <Bar
                key={s.id}
                dataKey={`values.${s.id}`}
                name={s.label}
                stackId="share"
                fill={hex}
                barSize={24}
                isAnimationActive={false}
                shape={segmentShape(opts, false)}
                activeBar={segmentShape(opts, true)}
              />
            );
          })}
        </BarChart>
      </div>
      <CallSiteLegend series={series} mode={mode} targeted={targeted} emphasis={emphasis} onEmphasis={onEmphasis} />
    </div>
  );
}

export default CallSiteTrend;

interface CallSiteLegendProps {
  series: CallSiteSeries[];
  mode: ThemeMode;
  targeted?: TargetedBy;
  emphasis: string | null;
  onEmphasis?: (key: string | null) => void;
}

/** Legend = identity channel: swatch (rect, like the mark), name, kind · caller, targeted-by chips; click isolates. */
export function CallSiteLegend({ series, mode, targeted, emphasis, onEmphasis }: CallSiteLegendProps) {
  return (
    <ul className="legend cst-legend" aria-label="Call sites">
      {series.map((s) => {
        const key = s.key ?? OTHER_ID;
        const pressed = emphasis === key;
        const muted = emphasis !== null && !pressed;
        const hits = s.key && targeted ? targeted(s.key) : [];
        return (
          <li key={s.id}>
            <button
              type="button"
              className={muted ? 'is-muted' : undefined}
              aria-pressed={pressed}
              title={s.key ?? s.detail}
              onClick={() => onEmphasis?.(pressed ? null : key)}
            >
              <span className="cst-swatch" style={{ background: seriesHex(s.slot, mode) }} aria-hidden="true" />
              <span className="cst-name">{s.label}</span>
              {s.detail ? <span className="cst-detail mono muted">{s.detail}</span> : null}
            </button>
            {hits.map((h) => {
              const vb = verdictBadge(h.verdict);
              return <Badge key={h.trial} {...vb} value={`${h.trial} · ${vb.value}`} title={`${h.trial} targeted this call site (${h.verdict})`} />;
            })}
          </li>
        );
      })}
    </ul>
  );
}

export interface CallSiteTrendTableProps {
  runs: readonly Run[];
  set: string;
  slots: ReadonlyMap<string, SeriesSlot>;
  targeted?: TargetedBy;
  caption: string;
  captionHidden?: boolean;
}

interface CallSiteTableRow {
  series: CallSiteSeries;
  targeted: { trial: string; verdict: Verdict }[];
  shares: (number | null)[];
}

/** The table twin: one row per call site, one column per run, plus the targeted-by chips. */
export function CallSiteTrendTable({ runs, set, slots, targeted, caption, captionHidden }: CallSiteTrendTableProps) {
  const mode = useThemeMode();
  const rows = useMemo(() => buildCallSiteRows(runs, set, slots), [runs, set, slots]);
  const series = useMemo(() => callSiteSeries(runs, set, slots), [runs, set, slots]);
  const tableRows: CallSiteTableRow[] = series.map((s) => ({
    series: s,
    targeted: s.key && targeted ? targeted(s.key) : [],
    shares: rows.map((r) => r.values[s.id] ?? null),
  }));
  const columns: Column<CallSiteTableRow>[] = [
    {
      key: 'site',
      header: 'Call site',
      render: (r) => (
        <span className="cst-cell-site">
          <span className="cst-swatch" style={{ background: seriesHex(r.series.slot, mode) }} aria-hidden="true" />
          <span>
            {r.series.label}
            {r.series.detail ? <span className="cst-detail mono muted"> {r.series.detail}</span> : null}
          </span>
        </span>
      ),
      sortValue: (r) => r.series.label,
    },
    {
      key: 'targeted',
      header: 'Targeted by',
      render: (r) =>
        r.targeted.length === 0 ? (
          '—'
        ) : (
          <span className="cst-chips">
            {r.targeted.map((h) => {
              const vb = verdictBadge(h.verdict);
              return <Badge key={h.trial} {...vb} value={`${h.trial} · ${vb.value}`} />;
            })}
          </span>
        ),
      sortValue: (r) => r.targeted.length,
    },
    ...rows.map<Column<CallSiteTableRow>>((run, i) => ({
      key: run.runId,
      header: run.label,
      title: `${formatDate(run.startedAt)} · ${run.runId}${run.tag ? ` · ${run.tag}` : ''}`,
      numeric: true,
      render: (r) => formatShare(r.shares[i] ?? null),
      sortValue: (r) => r.shares[i] ?? null,
    })),
  ];
  return <DataTable caption={caption} captionHidden={captionHidden} columns={columns} rows={tableRows} rowKey={(r) => r.series.id} dense />;
}
