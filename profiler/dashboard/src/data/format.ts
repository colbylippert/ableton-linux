/**
 * Display formatters and the small numeric helpers the data layer shares
 * (DESIGN.md §2 "Formatters", §6 `format.ts` / `stats.ts`).
 *
 * Every formatter accepts `null` and renders it as `—`. Numbers are grouped with en-US
 * separators regardless of the viewer's locale so that output is deterministic (the
 * dashboard is a single-locale tool and tests compare strings). Signs are ASCII so values
 * can be copied into a terminal.
 */
import type { MetricDirection } from './types';

export const NULL_TEXT = '—';
export const UP_GLYPH = '▲';
export const DOWN_GLYPH = '▼';

export function isFiniteNumber(v: unknown): v is number {
  return typeof v === 'number' && Number.isFinite(v);
}

const numberFormats = new Map<number, Intl.NumberFormat>();

function numberFormat(decimals: number): Intl.NumberFormat {
  let nf = numberFormats.get(decimals);
  if (!nf) {
    nf = new Intl.NumberFormat('en-US', {
      minimumFractionDigits: decimals,
      maximumFractionDigits: decimals,
      useGrouping: true,
    });
    numberFormats.set(decimals, nf);
  }
  return nf;
}

/** Rounds half away from zero to `decimals` places (avoids `-0` and float noise). */
export function round(v: number, decimals = 0): number {
  const f = 10 ** decimals;
  const r = Math.round(Math.abs(v) * f) / f;
  return v < 0 && r !== 0 ? -r : r;
}

/** `1,284` / `41.2` — plain number with grouping; `null` → `—`. */
export function formatNumber(v: number | null, decimals = 0): string {
  if (!isFiniteNumber(v)) return NULL_TEXT;
  return numberFormat(decimals).format(round(v, decimals));
}

/** `41.2%` — the value is already a percentage (CPU %, DSP %). */
export function formatPct(v: number | null, decimals = 1): string {
  return isFiniteNumber(v) ? `${formatNumber(v, decimals)}%` : NULL_TEXT;
}

/** `1,284`; with `compact`, `12.9K` above 9,999 and `1.3M` / `2.0B` beyond (tiles only). */
export function formatInt(v: number | null, compact = false): string {
  if (!isFiniteNumber(v)) return NULL_TEXT;
  if (compact) {
    const abs = Math.abs(v);
    if (abs >= 1e9) return `${formatNumber(v / 1e9, 1)}B`;
    if (abs >= 1e6) return `${formatNumber(v / 1e6, 1)}M`;
    if (abs > 9999) return `${formatNumber(v / 1e3, 1)}K`;
  }
  return formatNumber(v, 0);
}

/** `1,204/s` */
export function formatRate(v: number | null): string {
  return isFiniteNumber(v) ? `${formatNumber(v, 0)}/s` : NULL_TEXT;
}

/** `3.20/min` */
export function formatRate2(v: number | null): string {
  return isFiniteNumber(v) ? `${formatNumber(v, 2)}/min` : NULL_TEXT;
}

/**
 * Auto-scaled duration from nanoseconds: `812 ns` / `12.4 µs` / `3.21 ms` / `1.20 s`.
 * Nanoseconds are always whole; the other units use `decimals`.
 */
export function formatDurationNs(v: number | null, decimals = 1): string {
  if (!isFiniteNumber(v)) return NULL_TEXT;
  const abs = Math.abs(v);
  if (abs < 1e3) return `${formatNumber(v, 0)} ns`;
  if (abs < 1e6) return `${formatNumber(v / 1e3, decimals)} µs`;
  if (abs < 1e9) return `${formatNumber(v / 1e6, decimals)} ms`;
  return `${formatNumber(v / 1e9, decimals)} s`;
}

/** `62.0%` — the value is a fraction 0..1 (call-site share of lost slack). */
export function formatShare(v: number | null, decimals = 1): string {
  return isFiniteNumber(v) ? `${formatNumber(v * 100, decimals)}%` : NULL_TEXT;
}

/** `+18.4%` / `-3.1%` / `0.0%` — a signed fraction (delta % vs baseline); no glyph. */
export function formatSignedPct(v: number | null, decimals = 1): string {
  if (!isFiniteNumber(v)) return NULL_TEXT;
  const r = round(v * 100, decimals);
  const body = `${formatNumber(Math.abs(r), decimals)}%`;
  return r > 0 ? `+${body}` : r < 0 ? `-${body}` : body;
}

/** The fields `formatDelta` / `deltaDirection` read; a `GainRow` satisfies it. */
export interface DeltaLike {
  deltaAbs: number | null;
  deltaPct: number | null;
  direction: MetricDirection;
}

export type DeltaDirection = 'better' | 'worse' | 'flat' | 'neutral';

/**
 * Direction of a signed delta (positive = improvement by construction). Neutral metrics
 * never report better/worse; a missing or zero delta is `flat` (callers omit the delta
 * when `deltaAbs` is `null`).
 */
export function deltaDirection(row: DeltaLike): DeltaDirection {
  if (row.direction === 'neutral') return 'neutral';
  if (row.deltaAbs === null || row.deltaAbs === 0) return 'flat';
  return row.deltaAbs > 0 ? 'better' : 'worse';
}

/**
 * `▲ 18.4%` / `▼ 3.1%` / `0.0%` — the glyph carries the direction (status colour sits on
 * the glyph only), the number is the unsigned percentage. Neutral metrics get a signed
 * percentage without a glyph. When no percentage exists (zero baseline) the absolute
 * change is shown instead, formatted with `formatAbs` when given: `▼ 2 vs 0`.
 */
export function formatDelta(row: DeltaLike, formatAbs?: (v: number | null) => string): string {
  if (row.deltaAbs === null) return NULL_TEXT;
  const neutral = row.direction === 'neutral';
  const glyph = neutral ? '' : row.deltaAbs > 0 ? UP_GLYPH : row.deltaAbs < 0 ? DOWN_GLYPH : '';
  let body: string;
  if (row.deltaPct !== null) {
    body = neutral ? formatSignedPct(row.deltaPct) : formatShare(Math.abs(row.deltaPct));
  } else {
    const abs = formatAbs ? formatAbs(Math.abs(row.deltaAbs)) : formatNumber(Math.abs(row.deltaAbs), 2);
    body = neutral ? `${row.deltaAbs < 0 ? '-' : '+'}${abs} vs 0` : `${abs} vs 0`;
  }
  return glyph ? `${glyph} ${body}` : body;
}

function pad2(n: number): string {
  return n < 10 ? `0${n}` : String(n);
}

/**
 * `2026-10-16 12:00` in UTC (the data is recorded in UTC; the caller labels it). Accepts an
 * ISO string or epoch milliseconds (chart axes); an unparsable string is returned as is.
 */
export function formatDate(value: string | number | null): string {
  if (value === null || value === '') return NULL_TEXT;
  const ms = typeof value === 'number' ? value : Date.parse(value);
  if (!Number.isFinite(ms)) return typeof value === 'string' ? value : NULL_TEXT;
  const d = new Date(ms);
  return `${d.getUTCFullYear()}-${pad2(d.getUTCMonth() + 1)}-${pad2(d.getUTCDate())} ${pad2(d.getUTCHours())}:${pad2(d.getUTCMinutes())}`;
}

/** `10-16 12:00` — the same instant without the year, for dense axis ticks. */
export function formatDateTick(value: string | number | null): string {
  const full = formatDate(value);
  return /^\d{4}-/.test(full) ? full.slice(5) : full;
}

/** Median of the finite values; `null` when there are none. */
export function median(values: readonly number[]): number | null {
  const sorted = values.filter(isFiniteNumber).sort((a, b) => a - b);
  const n = sorted.length;
  if (n === 0) return null;
  const mid = n >> 1;
  return n % 2 === 1 ? sorted[mid]! : (sorted[mid - 1]! + sorted[mid]!) / 2;
}
