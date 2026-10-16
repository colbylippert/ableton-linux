/**
 * TrendChart: one metric over run time (DESIGN.md §5, §8).
 *
 * Form: line chart, one y-axis, time on x. One series = a small multiple in its Set's slot
 * hue (no legend box; a key row explains baseline / band / markers). Several series = the
 * overlay (legend, click to isolate, selective end labels) or the emphasis form
 * (`emphasis` names the one series drawn in its hue, the rest in the de-emphasis gray).
 *
 * Marks: 2 px linear lines (never smoothed), 8 px markers with a 2 px surface ring, the
 * baseline as a 1 px reference line, the A/A band as a 10 % wash, trial markers as thin
 * vertical lines in the status colour with an icon + label (dim verdicts unlabelled),
 * hairline solid grid, crosshair + one tooltip listing every visible series. Every chart
 * ships its table twin through `ChartFrame`.
 *
 * The chart receives raw values and the metric direction, so the per-point delta it shows
 * (tooltip, table) mirrors `signedDelta()` from the data layer: positive = improvement.
 */
import { useMemo, useState, type ReactElement, type ReactNode } from 'react';
import { CartesianGrid, Line, LineChart, ReferenceArea, ReferenceLine, Tooltip, XAxis, YAxis, type LabelProps, type TooltipContentProps } from 'recharts';
import type { Arm, MetricDirection, Significance, Verdict } from '../data/types';
import { PALETTE, seriesHex, useThemeMode, type SeriesSlot, type ThemeMode } from '../palette';
import Badge, { significanceBadge, type BadgeStatus, type DeltaDirection } from './Badge';
import ChartFrame from './ChartFrame';
import DataTable, { type Column } from './DataTable';
import './components.css';

export type { SeriesSlot };

export interface TrendPoint {
  /** Run start as epoch milliseconds (UTC). */
  t: number;
  runId: string;
  tag: string;
  value: number | null;
  arm: Arm | null;
  trial: string | null;
  switches: Record<string, string>;
}

export interface TrendSeries {
  id: string;
  label: string;
  slot: SeriesSlot;
  points: TrendPoint[];
}

export interface TrendMarker {
  t: number;
  trial: string;
  verdict: Verdict;
  label: string;
}

export interface TrendBaseline {
  value: number;
  runId: string;
  label?: string;
}

export interface TrendNoiseBand {
  center: number;
  /** `2 × A/A spread`, in the metric's unit. */
  halfWidth: number;
  pairs: number;
}

export interface TrendChartProps {
  title: string;
  subtitle?: string;
  series: TrendSeries[];
  baseline: TrendBaseline | null;
  noiseBand: TrendNoiseBand | null;
  markers: TrendMarker[];
  unit: string;
  direction: MetricDirection;
  format: (value: number | null) => string;
  /** Series id drawn in its slot; every other series is forced to `'dim'`. */
  emphasis?: string | null;
  /** Pixel height including the x-axis band (default 240). */
  height?: number;
  table: { caption: string };
  /** Fixed pixel width (tests, static export). Omitted = responsive to the card width. */
  width?: number;
  formatTime?: (t: number) => string;
  /** Stable id so the chart | table choice is remembered per viewer. */
  id?: string;
  footer?: ReactNode;
}

export interface ChartRowMeta {
  t: number;
  runId: string;
  tag: string;
  arm: Arm | null;
  trial: string | null;
  switches: Record<string, string>;
}

/** One row per run; series values live under `v0..vN` (safe Recharts data keys). */
export type ChartRow = ChartRowMeta & Record<string, unknown>;

const valueKey = (index: number): string => `v${index}`;

function cx(...parts: (string | false | null | undefined)[]): string {
  return parts.filter(Boolean).join(' ');
}

export function rowValue(row: ChartRow, key: string): number | null {
  const v = row[key];
  return typeof v === 'number' && Number.isFinite(v) ? v : null;
}

/** Merges the series by run (all Sets of one run share its `t`); missing values are null. */
export function buildRows(series: TrendSeries[]): ChartRow[] {
  const byRun = new Map<string, ChartRow>();
  series.forEach((s, i) => {
    for (const p of s.points) {
      let row = byRun.get(p.runId);
      if (!row) {
        row = { t: p.t, runId: p.runId, tag: p.tag, arm: p.arm, trial: p.trial, switches: p.switches };
        byRun.set(p.runId, row);
      }
      row[valueKey(i)] = p.value;
    }
  });
  const rows = Array.from(byRun.values()).sort((a, b) => a.t - b.t || a.runId.localeCompare(b.runId));
  for (const row of rows) {
    for (let i = 0; i < series.length; i += 1) {
      if (!(valueKey(i) in row)) row[valueKey(i)] = null;
    }
  }
  return rows;
}

/** Mirror of the data layer's `signedDelta`: positive = improvement whatever the direction. */
export function signedDeltaOf(value: number, baseline: number, direction: MetricDirection): { abs: number; pct: number | null } {
  const raw = value - baseline;
  const abs = direction === 'lower' ? -raw : raw;
  return { abs, pct: baseline === 0 ? null : abs / Math.abs(baseline) };
}

/** `|abs| > 2 × spread` → beyond; `halfWidth` is already `2 × spread`. */
export function significanceFor(abs: number | null, halfWidth: number | null): Significance {
  if (abs === null || halfWidth === null) return 'unknown';
  return Math.abs(abs) > halfWidth ? 'beyond' : 'within';
}

export function deltaDirectionOf(abs: number | null, direction: MetricDirection): DeltaDirection {
  if (direction === 'neutral') return 'neutral';
  if (abs === null || abs === 0) return 'flat';
  return abs > 0 ? 'better' : 'worse';
}

/** "+1.20/min (10.0%)" — sign first, the metric's own formatter for the magnitude. */
export function formatSignedDelta(abs: number, pct: number | null, format: (v: number | null) => string): string {
  const sign = abs > 0 ? '+' : abs < 0 ? '−' : '';
  const pctText = pct === null ? '' : ` (${sign}${(Math.abs(pct) * 100).toFixed(1)}%)`;
  return `${sign}${format(Math.abs(abs))}${pctText}`;
}

/** Default time formatter: `2026-10-16 12:00 UTC`. */
export function formatUtc(t: number): string {
  const date = new Date(t);
  if (Number.isNaN(date.getTime())) return '—';
  return `${date.toISOString().slice(0, 16).replace('T', ' ')} UTC`;
}

function tickLabel(t: number): string {
  const date = new Date(t);
  if (Number.isNaN(date.getTime())) return '';
  return date.toISOString().slice(5, 16).replace('T', ' ');
}

export function switchesText(switches: Record<string, string>): string {
  const entries = Object.entries(switches);
  return entries.length === 0 ? '—' : entries.map(([k, v]) => `${k}=${v}`).join(' ');
}

type MarkerStatus = Extract<BadgeStatus, 'good' | 'critical' | 'dim'>;

function markerStatus(verdict: Verdict): MarkerStatus {
  if (verdict === 'keep') return 'good';
  if (verdict === 'revert') return 'critical';
  return 'dim';
}

/**
 * Y domain with ~8 % headroom on each side so the first and last points never sit on the
 * plot edges; a non-negative range never dips below zero (counts and rates have no
 * negative values to suggest). Recharts still snaps the ticks to clean numbers.
 */
export function paddedDomain([lo, hi]: readonly [number, number]): [number, number] {
  if (!Number.isFinite(lo) || !Number.isFinite(hi)) return [0, 1];
  const span = hi - lo;
  const pad = span > 0 ? span * 0.08 : Math.abs(hi) * 0.1 || 1;
  const min = lo >= 0 ? Math.max(0, lo - pad) : lo - pad;
  return [min, hi + pad];
}

/**
 * Clean tick values (steps of 1, 2, 2.5 or 5 × 10^k) covering `[lo, hi]`, about `count`
 * of them; the chart's y domain is the first and last tick so the axis reads in round
 * numbers whatever the data range.
 */
export function niceTicks(lo: number, hi: number, count = 5): number[] {
  if (!Number.isFinite(lo) || !Number.isFinite(hi)) return [0, 1];
  let top = hi;
  if (top <= lo) top = lo + (Math.abs(lo) * 0.1 || 1);
  const rawStep = (top - lo) / Math.max(1, count - 1);
  const magnitude = 10 ** Math.floor(Math.log10(rawStep));
  // Round away floating-point noise (0.05 / 0.01 evaluates to 5.000000000000001).
  const norm = Number((rawStep / magnitude).toFixed(9));
  const step = (norm <= 1 ? 1 : norm <= 2 ? 2 : norm <= 2.5 ? 2.5 : norm <= 5 ? 5 : 10) * magnitude;
  // Tolerance keeps 4.4 / 0.1 (= 44.00000000000001) from adding a spurious tick.
  const start = Math.floor(lo / step + 1e-9) * step;
  const end = Math.ceil(top / step - 1e-9) * step;
  const ticks: number[] = [];
  for (let v = start; v <= end + step / 2; v += step) ticks.push(Number(v.toFixed(12)) || 0);
  return ticks;
}

/** At most `max` tick positions, always including the first and last run. */
export function sampleTicks(ts: number[], max: number): number[] {
  const unique = Array.from(new Set(ts)).sort((a, b) => a - b);
  if (unique.length <= max) return unique;
  const out: number[] = [];
  for (let k = 0; k < max; k += 1) {
    const idx = Math.round((k * (unique.length - 1)) / (max - 1));
    const v = unique[idx];
    if (v !== undefined && out[out.length - 1] !== v) out.push(v);
  }
  return out;
}

interface Drawn {
  s: TrendSeries;
  key: string;
  dim: boolean;
  slot: SeriesSlot;
  hidden: boolean;
}

/** Recharts calls a Line `label` function once per point with the label props plus `index`. */
type EndLabelProps = LabelProps & { index?: number };

interface Box {
  x: number;
  y: number;
  width: number;
  height: number;
}

/** The reference line's box as Recharts hands it to a label renderer (a zero-width or zero-height segment). */
function viewBoxOf(p: LabelProps): Box | null {
  const vb = p.viewBox as { x?: number; y?: number; width?: number; height?: number } | undefined;
  if (!vb || typeof vb.x !== 'number' || typeof vb.y !== 'number') return null;
  return { x: vb.x, y: vb.y, width: vb.width ?? 0, height: vb.height ?? 0 };
}

/** Trial marker label: just right of the vertical line, in the top margin, so it never spills over the y-axis. */
function makeMarkerLabel(value: string, fill: string) {
  return function MarkerLabel(p: LabelProps): ReactElement | null {
    const vb = viewBoxOf(p);
    if (!vb) return null;
    return (
      <text className="trend-marker-label" x={vb.x + 4} y={vb.y - 6} fill={fill} fontSize={11} textAnchor="start">
        {value}
      </text>
    );
  };
}

/** Baseline label: above the line at its right end, clear of the last point's marker and end label. */
function makeBaselineLabel(value: string, fill: string) {
  return function BaselineLabel(p: LabelProps): ReactElement | null {
    const vb = viewBoxOf(p);
    if (!vb) return null;
    return (
      <text className="trend-baseline-label" x={vb.x + vb.width - 10} y={vb.y - 5} fill={fill} fontSize={11} textAnchor="end">
        {value}
      </text>
    );
  };
}

interface MarkerGroup {
  t: number;
  status: MarkerStatus;
  /** Icon + trial per labelled marker, joined; empty for dim-only groups. */
  label: string;
}

/**
 * Markers outside the plotted run range carry nothing for this chart (a ledger line whose
 * runs are not in history, or a trial filtered out of the slice) and are dropped; markers
 * sharing one x are merged into a single line with a combined label.
 */
export function groupMarkers(markers: TrendMarker[], tMin: number, tMax: number): MarkerGroup[] {
  const byT = new Map<number, TrendMarker[]>();
  for (const m of markers) {
    if (!Number.isFinite(m.t) || m.t < tMin || m.t > tMax) continue;
    byT.set(m.t, [...(byT.get(m.t) ?? []), m]);
  }
  return Array.from(byT.entries())
    .sort((a, b) => a[0] - b[0])
    .map(([t, group]) => {
      const labelled = group.filter((m) => markerStatus(m.verdict) !== 'dim');
      const status = labelled.length === 0 ? 'dim' : markerStatus(labelled[0]!.verdict);
      // The data layer may already prefix the label with a status glyph; the chart owns the icon.
      const label = labelled
        .map((m) => `${markerStatus(m.verdict) === 'good' ? '✓' : '✗'} ${(m.label || m.trial).replace(/^[✓✗≈·?⚠]\s*/u, '')}`)
        .join(' · ');
      return { t, status, label };
    });
}

function makeEndLabel(last: number, format: (v: number | null) => string, fill: string) {
  return function EndLabel(p: EndLabelProps): ReactElement | null {
    const x = typeof p.x === 'number' ? p.x : Number(p.x);
    const y = typeof p.y === 'number' ? p.y : Number(p.y);
    if (p.index !== last || typeof p.value !== 'number' || !Number.isFinite(x) || !Number.isFinite(y)) return null;
    return (
      <text className="trend-end-label" x={x + 8} y={y} dy={4} fill={fill} fontSize={11} textAnchor="start">
        {format(p.value)}
      </text>
    );
  };
}

interface TooltipCtx {
  drawn: Drawn[];
  baseline: TrendBaseline | null;
  noiseBand: TrendNoiseBand | null;
  direction: MetricDirection;
  format: (v: number | null) => string;
  formatTime: (t: number) => string;
  mode: ThemeMode;
}

interface TrendTooltipProps {
  active?: boolean;
  payload?: ReadonlyArray<{ payload?: unknown }>;
  ctx: TooltipCtx;
}

/** One tooltip, every visible series: value first (strong), series name second, line key in the hue. */
export function TrendTooltip({ active, payload, ctx }: TrendTooltipProps) {
  if (!active || !payload || payload.length === 0) return null;
  const row = payload[0]?.payload as ChartRow | undefined;
  if (!row || typeof row.t !== 'number') return null;
  const visible = ctx.drawn.filter((d) => !d.hidden);
  const single = visible.length === 1 ? visible[0]! : null;
  const singleValue = single ? rowValue(row, single.key) : null;
  const delta = single && ctx.baseline && singleValue !== null ? signedDeltaOf(singleValue, ctx.baseline.value, ctx.direction) : null;
  const significance = delta ? significanceFor(delta.abs, ctx.noiseBand ? ctx.noiseBand.halfWidth : null) : 'unknown';
  const context = [row.tag, row.trial ? `${row.trial}${row.arm ? ` / ${row.arm}` : ''}` : row.arm, Object.keys(row.switches).length > 0 ? switchesText(row.switches) : null]
    .filter((part): part is string => Boolean(part))
    .join(' · ');
  return (
    <div className="chart-tooltip">
      <div className="tt-head">
        <strong>{ctx.formatTime(row.t)}</strong>
        <span className="mono muted">{row.runId}</span>
      </div>
      {context ? <div className="tt-sub">{context}</div> : null}
      <ul className="tt-rows">
        {visible.map((d) => (
          <li key={d.s.id}>
            <span className="tt-key" style={{ background: seriesHex(d.slot, ctx.mode) }} aria-hidden="true" />
            <span className="tt-value">{ctx.format(rowValue(row, d.key))}</span>
            <span className="tt-label">{d.s.label}</span>
          </li>
        ))}
      </ul>
      {delta ? (
        <div className="tt-delta">
          <span className="tt-label">vs baseline</span>
          <span className="tt-value">{formatSignedDelta(delta.abs, delta.pct, ctx.format)}</span>
          <Badge {...significanceBadge(significance, deltaDirectionOf(delta.abs, ctx.direction))} />
        </div>
      ) : null}
    </div>
  );
}

export default function TrendChart(props: TrendChartProps) {
  const {
    title,
    subtitle,
    series,
    baseline,
    noiseBand,
    markers,
    unit,
    direction,
    format,
    emphasis = null,
    height = 240,
    table,
    width,
    formatTime = formatUtc,
    id,
    footer,
  } = props;
  const mode = useThemeMode();
  const pal = PALETTE[mode];
  const [isolated, setIsolated] = useState<string | null>(null);

  const rows = useMemo(() => buildRows(series), [series]);
  const drawn = useMemo<Drawn[]>(
    () =>
      series.map((s, i) => {
        const dim = emphasis !== null && s.id !== emphasis;
        return { s, key: valueKey(i), dim, slot: dim ? 'dim' : s.slot, hidden: isolated !== null && isolated !== s.id };
      }),
    [series, emphasis, isolated],
  );
  // Dim context series are drawn first so the emphasised one sits on top.
  const ordered = useMemo(() => [...drawn].sort((a, b) => Number(b.dim) - Number(a.dim)), [drawn]);
  const visible = drawn.filter((d) => !d.hidden);
  const labelledCount = visible.filter((d) => !d.dim).length;
  const endLabels = labelledCount > 0 && labelledCount <= 4;
  const hasValues = rows.some((r) => drawn.some((d) => rowValue(r, d.key) !== null));
  const showDots = rows.length <= 40;

  const ts = rows.map((r) => r.t);
  const tMin = ts.length ? Math.min(...ts) : 0;
  const tMax = ts.length ? Math.max(...ts) : 0;
  const span = tMax - tMin;
  const pad = span > 0 ? Math.max(span * 0.04, 60e3) : 3600e3;
  const xDomain: [number, number] = [tMin - pad, tMax + pad];
  const ticks = sampleTicks(ts, 12);
  const markerGroups = rows.length > 0 ? groupMarkers(markers, tMin, tMax) : [];

  // Y axis: clean ticks over the visible values plus the baseline and the band edges.
  const yValues: number[] = [];
  for (const r of rows) for (const d of visible) {
    const v = rowValue(r, d.key);
    if (v !== null) yValues.push(v);
  }
  if (baseline) yValues.push(baseline.value);
  if (noiseBand) yValues.push(noiseBand.center - noiseBand.halfWidth, noiseBand.center + noiseBand.halfWidth);
  const yPadded = paddedDomain([yValues.length ? Math.min(...yValues) : 0, yValues.length ? Math.max(...yValues) : 1]);
  const yTicks = niceTicks(yPadded[0], yPadded[1], 5);
  const yDomain: [number, number] = [yTicks[0] ?? yPadded[0], yTicks[yTicks.length - 1] ?? yPadded[1]];

  const lastIndexOf = (key: string): number => {
    for (let i = rows.length - 1; i >= 0; i -= 1) {
      if (rowValue(rows[i]!, key) !== null) return i;
    }
    return -1;
  };

  const accent = visible.find((d) => !d.dim) ?? drawn.find((d) => !d.dim) ?? drawn[0];
  const bandHex = accent ? seriesHex(accent.slot, mode) : pal.seriesDim;
  const ctx: TooltipCtx = { drawn, baseline, noiseBand, direction, format, formatTime, mode };

  const legend =
    series.length >= 2 ? (
      <div className="legend" role="group" aria-label="Series (click to isolate)">
        {drawn.map((d) => (
          <button
            key={d.s.id}
            type="button"
            className={cx(d.hidden && 'is-muted')}
            aria-pressed={isolated === d.s.id}
            onClick={() => setIsolated((prev) => (prev === d.s.id ? null : d.s.id))}
          >
            <span className="legend-key" style={{ background: seriesHex(d.slot, mode) }} aria-hidden="true" />
            {d.s.label}
          </button>
        ))}
      </div>
    ) : null;

  const hasKeep = markerGroups.some((g) => g.label.includes('✓'));
  const hasRevert = markerGroups.some((g) => g.label.includes('✗'));
  const hasOther = markers.some((m) => m.verdict !== 'keep' && m.verdict !== 'revert' && m.t >= tMin && m.t <= tMax);
  const keyRow =
    baseline || noiseBand || markerGroups.length > 0 ? (
      <div className="chart-key">
        {baseline ? (
          <span>
            <span className="key-line" aria-hidden="true" />
            {baseline.label ?? 'baseline'} {format(baseline.value)}
          </span>
        ) : null}
        {noiseBand ? (
          <span>
            <span className="key-band" style={{ background: bandHex }} aria-hidden="true" />
            A/A band ±{format(noiseBand.halfWidth)} ({noiseBand.pairs} pair{noiseBand.pairs === 1 ? '' : 's'})
          </span>
        ) : null}
        {hasKeep ? (
          <span>
            <span className="key-marker" aria-hidden="true" />✓ kept trial
          </span>
        ) : null}
        {hasRevert ? (
          <span>
            <span className="key-marker is-revert" aria-hidden="true" />✗ reverted trial
          </span>
        ) : null}
        {hasOther ? (
          <span>
            <span className="key-marker is-dim" aria-hidden="true" />
            other trial
          </span>
        ) : null}
      </div>
    ) : null;

  const sizing = width !== undefined ? { width, height } : { responsive: true as const, style: { width: '100%', height } };

  const chart = hasValues ? (
    <div className="trend-plot" style={{ height }}>
      <LineChart
        {...sizing}
        data={rows}
        margin={{ top: 22, right: 72, bottom: 4, left: 4 }}
        title={title}
        desc={`${title}: ${series.map((s) => s.label).join(', ')} over run time`}
      >
        <CartesianGrid stroke={pal.grid} vertical={false} />
        <XAxis
          type="number"
          dataKey="t"
          scale="time"
          domain={xDomain}
          ticks={ticks}
          tickFormatter={tickLabel}
          tick={{ fill: pal.textMuted, fontSize: 11 }}
          axisLine={{ stroke: pal.axis }}
          tickLine={false}
          minTickGap={56}
          interval="preserveStartEnd"
        />
        <YAxis
          type="number"
          domain={yDomain}
          ticks={yTicks}
          width="auto"
          tickFormatter={(v: number) => format(v)}
          tick={{ fill: pal.textMuted, fontSize: 11 }}
          axisLine={false}
          tickLine={false}
        />
        {noiseBand ? (
          <ReferenceArea
            y1={noiseBand.center - noiseBand.halfWidth}
            y2={noiseBand.center + noiseBand.halfWidth}
            fill={bandHex}
            fillOpacity={0.1}
            stroke="none"
            ifOverflow="extendDomain"
            className="trend-band"
          />
        ) : null}
        {baseline ? (
          <ReferenceLine
            y={baseline.value}
            stroke={pal.textSecondary}
            strokeWidth={1}
            ifOverflow="extendDomain"
            className="trend-baseline"
            label={makeBaselineLabel(baseline.label ?? 'baseline', pal.textSecondary)}
          />
        ) : null}
        {markerGroups.map((g) => {
          if (g.status === 'dim') {
            return (
              <ReferenceLine
                key={g.t}
                x={g.t}
                stroke={pal.seriesDim}
                strokeOpacity={0.6}
                strokeWidth={1}
                ifOverflow="hidden"
                className="trend-marker trend-marker-dim"
              />
            );
          }
          return (
            <ReferenceLine
              key={g.t}
              x={g.t}
              stroke={pal.status[g.status]}
              strokeWidth={1}
              ifOverflow="hidden"
              className={`trend-marker trend-marker-${g.status}`}
              label={makeMarkerLabel(g.label, pal.textSecondary)}
            />
          );
        })}
        <Tooltip
          cursor={{ stroke: pal.axis, strokeWidth: 1 }}
          isAnimationActive={false}
          wrapperStyle={{ outline: 'none', zIndex: 2 }}
          content={(p: TooltipContentProps) => <TrendTooltip active={p.active} payload={p.payload} ctx={ctx} />}
        />
        {ordered.map((d) => {
          const hex = seriesHex(d.slot, mode);
          return (
            <Line
              key={d.s.id}
              type="linear"
              dataKey={d.key}
              name={d.s.label}
              hide={d.hidden}
              stroke={hex}
              strokeWidth={2}
              strokeOpacity={d.dim ? 0.7 : 1}
              strokeLinejoin="round"
              strokeLinecap="round"
              connectNulls={false}
              isAnimationActive={false}
              dot={showDots ? { r: 4, strokeWidth: 2, stroke: pal.surface1, fill: hex } : false}
              activeDot={{ r: 6, strokeWidth: 2, stroke: pal.surface1, fill: hex }}
              label={endLabels && !d.dim ? makeEndLabel(lastIndexOf(d.key), format, pal.textSecondary) : false}
            />
          );
        })}
      </LineChart>
    </div>
  ) : (
    <div className="chart-frame-empty">No values for this metric in the slice; the table lists the runs.</div>
  );

  const columns: Column<ChartRow>[] = [
    {
      key: 'runId',
      header: 'Run',
      render: (r) => (
        <span className="cell-mono">
          {r.runId}
          {baseline && r.runId === baseline.runId ? <span className="muted"> · baseline</span> : null}
        </span>
      ),
    },
    { key: 't', header: 'Started', render: (r) => formatTime(r.t), sortValue: (r) => r.t },
    { key: 'tag', header: 'Tag' },
    {
      key: 'trial',
      header: 'Trial / arm',
      render: (r) => (r.trial ? `${r.trial}${r.arm ? ` / ${r.arm}` : ''}` : (r.arm ?? '—')),
      sortValue: (r) => r.trial ?? r.arm ?? null,
    },
    {
      key: 'switches',
      header: 'Switches',
      render: (r) => <span className="cell-switches">{switchesText(r.switches)}</span>,
      sortValue: (r) => (Object.keys(r.switches).length ? switchesText(r.switches) : null),
    },
    ...series.map(
      (s, i): Column<ChartRow> => ({
        key: valueKey(i),
        header: series.length === 1 ? (unit ? `Value (${unit})` : 'Value') : unit ? `${s.label} (${unit})` : s.label,
        numeric: true,
        render: (r) => format(rowValue(r, valueKey(i))),
        sortValue: (r) => rowValue(r, valueKey(i)),
      }),
    ),
  ];
  if (series.length === 1 && baseline) {
    const key0 = valueKey(0);
    columns.push({
      key: 'delta',
      header: 'Δ vs baseline',
      numeric: true,
      title: 'Signed so that positive = improvement',
      render: (r) => {
        const v = rowValue(r, key0);
        if (v === null) return '—';
        const d = signedDeltaOf(v, baseline.value, direction);
        return formatSignedDelta(d.abs, d.pct, format);
      },
      sortValue: (r) => {
        const v = rowValue(r, key0);
        return v === null ? null : signedDeltaOf(v, baseline.value, direction).abs;
      },
    });
    columns.push({
      key: 'significance',
      header: 'Significance',
      render: (r) => {
        const v = rowValue(r, key0);
        if (v === null) return '—';
        const d = signedDeltaOf(v, baseline.value, direction);
        return <Badge {...significanceBadge(significanceFor(d.abs, noiseBand ? noiseBand.halfWidth : null), deltaDirectionOf(d.abs, direction))} />;
      },
      sortValue: (r) => {
        const v = rowValue(r, key0);
        if (v === null) return null;
        const d = signedDeltaOf(v, baseline.value, direction);
        return significanceFor(d.abs, noiseBand ? noiseBand.halfWidth : null);
      },
    });
  }

  const twin = (
    <DataTable
      caption={table.caption}
      captionHidden
      columns={columns}
      rows={rows}
      rowKey={(r) => r.runId}
      defaultSort={{ key: 't', dir: 'asc' }}
      dense
      emptyMessage="No runs in this slice."
    />
  );

  return (
    <ChartFrame
      title={title}
      subtitle={subtitle}
      keyRow={
        legend || keyRow ? (
          <>
            {legend}
            {keyRow}
          </>
        ) : undefined
      }
      chart={chart}
      table={twin}
      id={id}
      footer={footer}
      empty={rows.length === 0 ? 'No runs in this slice.' : undefined}
      className="trend-chart"
    />
  );
}
