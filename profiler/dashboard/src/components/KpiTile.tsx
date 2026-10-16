/**
 * Figures: the stat tile (`KpiTile`), the 12-point `Sparkline` and the one `HeroFigure`
 * per view (dataviz "Figures - when the form is a number").
 *
 * Tile = label · value · delta · trend. The delta glyph carries direction and wears the
 * status colour (good / critical only beyond the noise, warning within it, muted without an
 * A/A estimate); the number stays in ink. The guard tile (xruns / PipeWire errors) turns
 * critical with the label "reject" on any non-zero value.
 */
import type { ReactNode } from 'react';
import type { MetricSource, Significance } from '../data/types';
import { seriesVar, type SeriesSlot } from '../palette';
import Badge, { significanceBadge, type BadgeStatus, type DeltaDirection } from './Badge';
import './components.css';

export interface KpiDelta {
  /** Fraction (0.184 = 18.4 %), `null` when the baseline is 0 or missing. */
  pct: number | null;
  /** In the metric's unit, signed so that positive = improvement. */
  abs: number | null;
  direction: DeltaDirection;
  significance: Significance;
  /** Preformatted text such as "▲ 18.4%" (a leading glyph is stripped; the tile draws its own). */
  text: string;
}

export interface KpiTileProps {
  label: string;
  value: string;
  unit?: string;
  baseline?: { value: string; label: string };
  best?: { value: string; runId: string };
  delta?: KpiDelta;
  /** Up to 12 values, oldest first; the last one is the current run. */
  trend?: number[];
  slot?: SeriesSlot;
  source: MetricSource;
  note?: string;
  guard?: { reject: boolean; label: string };
}

function cx(...parts: (string | false | null | undefined)[]): string {
  return parts.filter(Boolean).join(' ');
}

/** Status colour of the delta glyph: a win is only coloured as a win beyond the noise. */
export function deltaGlyphStatus(delta: Pick<KpiDelta, 'direction' | 'significance'>): BadgeStatus {
  if (delta.direction === 'neutral' || delta.direction === 'flat') return 'none';
  if (delta.significance === 'beyond') return delta.direction === 'better' ? 'good' : 'critical';
  if (delta.significance === 'within') return 'warning';
  return 'none';
}

export function deltaGlyph(direction: DeltaDirection): string {
  if (direction === 'better') return '▲';
  if (direction === 'worse') return '▼';
  return '';
}

export default function KpiTile({ label, value, unit, baseline, best, delta, trend, slot = 1, source, note, guard }: KpiTileProps) {
  const glyph = delta ? deltaGlyph(delta.direction) : '';
  const deltaText = delta ? delta.text.replace(/^[▲▼]\s*/u, '') : '';
  const glyphStatus = delta ? deltaGlyphStatus(delta) : 'none';
  return (
    <div className={cx('card', 'kpi', guard?.reject && 'kpi-reject')} data-source={source} data-slot={String(slot)}>
      <div className="kpi-head">
        <span className="kpi-label">{label}</span>
        <span className="kpi-source" title={source === 'interface' ? 'From traced runs' : 'From untraced runs'}>
          {source}
        </span>
      </div>
      <div className="kpi-value-row">
        <span className="kpi-value">{value}</span>
        {unit ? <span className="kpi-unit">{unit}</span> : null}
      </div>
      {delta ? (
        <div className="kpi-delta" data-direction={delta.direction} data-significance={delta.significance}>
          {glyph ? (
            <span className={cx('delta-glyph', `glyph-${glyphStatus}`)} aria-hidden="true">
              {glyph}
            </span>
          ) : null}
          <span className="delta-text">
            <span className="sr-only">{delta.direction === 'better' ? 'better by ' : delta.direction === 'worse' ? 'worse by ' : ''}</span>
            {deltaText}
          </span>
          <Badge {...significanceBadge(delta.significance, delta.direction)} />
        </div>
      ) : null}
      {guard ? (
        <div className="kpi-guard">
          <Badge kind="neutral" value={guard.label} status={guard.reject ? 'critical' : 'good'} icon={guard.reject ? '✗' : '✓'} />
        </div>
      ) : null}
      {baseline || best ? (
        <div className="kpi-meta">
          {baseline ? (
            <div>
              <span className="muted">{baseline.label}</span> <strong>{baseline.value}</strong>
            </div>
          ) : null}
          {best ? (
            <div>
              <span className="muted">best</span> <strong>{best.value}</strong> <span className="mono muted">{best.runId}</span>
            </div>
          ) : null}
        </div>
      ) : null}
      {trend && trend.length >= 2 ? <Sparkline values={trend} slot={slot} label={label} /> : null}
      {note ? <p className="kpi-note">{note}</p> : null}
    </div>
  );
}

export interface SparklineProps {
  values: number[];
  slot?: SeriesSlot;
  width?: number;
  height?: number;
  label?: string;
}

/** 12-point sparkline: body in the de-emphasis gray, the current point in the slot hue. */
export function Sparkline({ values, slot = 1, width = 120, height = 28, label }: SparklineProps) {
  const points = values.filter((v) => Number.isFinite(v)).slice(-12);
  if (points.length === 0) return null;
  const min = Math.min(...points);
  const max = Math.max(...points);
  const range = max - min;
  const padX = 5;
  const padY = 5;
  const stepX = points.length > 1 ? (width - 2 * padX) / (points.length - 1) : 0;
  const xy = points.map((v, i) => {
    const x = padX + i * stepX;
    const y = range === 0 ? height / 2 : padY + (1 - (v - min) / range) * (height - 2 * padY);
    return [x, y] as const;
  });
  const d = xy.map(([x, y], i) => `${i === 0 ? 'M' : 'L'}${x.toFixed(1)},${y.toFixed(1)}`).join('');
  const last = xy[xy.length - 1]!;
  const latest = points[points.length - 1]!;
  return (
    <svg
      className="sparkline"
      width={width}
      height={height}
      viewBox={`0 0 ${width} ${height}`}
      role="img"
      aria-label={`${label ?? 'Trend'}: ${points.length} runs, latest ${latest}`}
      data-slot={String(slot)}
    >
      <path d={d} fill="none" strokeWidth={2} strokeLinejoin="round" strokeLinecap="round" style={{ stroke: 'var(--series-dim)' }} />
      <circle cx={last[0]} cy={last[1]} r={4} strokeWidth={2} style={{ fill: seriesVar(slot), stroke: 'var(--surface-1)' }} />
    </svg>
  );
}

export interface HeroFigureProps {
  label: string;
  value: string;
  sub?: string;
  chip?: ReactNode;
  /** Kept-trial count shown beside the chip. */
  kept?: number | null;
  direction?: DeltaDirection;
  /** True when the gain clears the A/A noise; only then does an improvement wear the success colour. */
  significant?: boolean;
}

/** The single number a view leads with (exactly one per view; Overview only). */
export function HeroFigure({ label, value, sub, chip, kept, direction = 'flat', significant = false }: HeroFigureProps) {
  return (
    <div className="hero" data-direction={direction} data-significant={significant ? 'true' : 'false'}>
      <div className="hero-label">{label}</div>
      <div className={cx('hero-figure', direction === 'better' && significant && 'hero-better')}>{value}</div>
      {sub ? <div className="hero-sub">{sub}</div> : null}
      {chip || kept !== undefined ? (
        <div className="hero-row">
          {chip}
          {kept !== undefined && kept !== null ? (
            <span className="hero-kept">
              {kept} kept trial{kept === 1 ? '' : 's'}
            </span>
          ) : null}
        </div>
      ) : null}
    </div>
  );
}
