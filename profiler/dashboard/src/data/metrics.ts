/**
 * Metric registry and Set helpers (DESIGN.md §2, §6 `metrics.ts` / `sets.ts`, §7.1).
 *
 * The registry is the single place that knows a metric's direction, source and display
 * format. `direction` says which way is an improvement; `source` says which runs are
 * authoritative: outcome metrics only from untraced runs (`trace_mode === 'off'`),
 * interface metrics only from traced runs. The gains code never mixes the two.
 */
import type { MetricDef, MetricKey, MetricSource, Run, ScalarMetricKey, SetMetrics, TraceMode } from './types';
import { formatDurationNs, formatInt, formatPct, formatRate, formatRate2 } from './format';

// ---------------------------------------------------------------------------
// Sets: fixed categorical slots (DESIGN.md §7.1) — colour follows the entity
// ---------------------------------------------------------------------------

/** Categorical palette slot; `'dim'` is the de-emphasis grey used for context series. */
export type SeriesSlot = 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 'dim';

/** Suite order = slot order: Zero 1 (blue), Empty 2, Inbuilts 3, Max4Live 4, VSTs 5. */
export const CANONICAL_SETS: readonly string[] = [
  'Benchmark_Zero',
  'Benchmark_Empty',
  'Benchmark_Inbuilts',
  'Benchmark_Max4Live',
  'Benchmark_VSTs',
];

/** Every non-canonical Set shares slot 6 (green); it is separated by labels and its own card. */
export const OTHER_SET_SLOT: SeriesSlot = 6;

export function compareStrings(a: string, b: string): number {
  return a < b ? -1 : a > b ? 1 : 0;
}

export function isCanonicalSet(name: string): boolean {
  return CANONICAL_SETS.includes(name);
}

/** Slot 1..5 for the canonical Sets in suite order, 6 for anything else — never cycled. */
export function setSlot(name: string): SeriesSlot {
  const index = CANONICAL_SETS.indexOf(name);
  return index === -1 ? OTHER_SET_SLOT : ((index + 1) as SeriesSlot);
}

/** `'Benchmark_VSTs'` → `'VSTs'`; other names unchanged. */
export function setLabel(name: string): string {
  return name.startsWith('Benchmark_') ? name.slice('Benchmark_'.length) : name;
}

/** Unique names in suite order, then the non-canonical ones alphabetically. */
export function orderSets(names: Iterable<string>): string[] {
  const unique = new Set(names);
  const canonical = CANONICAL_SETS.filter((n) => unique.has(n));
  const other = [...unique].filter((n) => !isCanonicalSet(n)).sort(compareStrings);
  return [...canonical, ...other];
}

// ---------------------------------------------------------------------------
// Registry
// ---------------------------------------------------------------------------

function num(v: unknown): number | null {
  return typeof v === 'number' && Number.isFinite(v) ? v : null;
}

function scalar(key: ScalarMetricKey): MetricDef['value'] {
  return (set: SetMetrics) => num(set[key]);
}

/** `count × 60 / duration_s`; `null` when the count or the duration is missing or 0. */
function perMinute(key: 'late_blocks' | 'near_late_blocks'): MetricDef['value'] {
  return (set: SetMetrics, run: Run) => {
    const n = num(set[key]);
    const d = num(run.duration_s);
    return n === null || d === null || d <= 0 ? null : (n * 60) / d;
  };
}

const pct1 = (v: number | null): string => formatPct(v, 1);
const int0 = (v: number | null): string => formatInt(v);
const ns1 = (v: number | null): string => formatDurationNs(v, 1);
const ns2 = (v: number | null): string => formatDurationNs(v, 2);

/** Registry rows in display order (DESIGN.md §2). */
export const METRICS: readonly MetricDef[] = [
  { key: 'host_cpu_pct', label: 'Host CPU', unit: '%', direction: 'lower', source: 'outcome', decimals: 1, value: scalar('host_cpu_pct'), format: pct1, description: 'Whole-machine CPU during the window' },
  { key: 'live_cpu_pct_per_core', label: 'Live CPU / core', unit: '%', direction: 'lower', source: 'outcome', decimals: 1, value: scalar('live_cpu_pct_per_core'), format: pct1, description: 'Outcome primary' },
  { key: 'wine_cpu_pct_per_core', label: 'Wine CPU / core', unit: '%', direction: 'lower', source: 'outcome', decimals: 1, value: scalar('wine_cpu_pct_per_core'), format: pct1, description: 'wineserver + Wine threads' },
  { key: 'pipewire_cpu_pct', label: 'PipeWire CPU', unit: '%', direction: 'lower', source: 'outcome', decimals: 1, value: scalar('pipewire_cpu_pct'), format: pct1 },
  { key: 'irq_per_s', label: 'IRQs', unit: '/s', direction: 'lower', source: 'outcome', decimals: 0, value: scalar('irq_per_s'), format: formatRate },
  { key: 'softirq_per_s', label: 'SoftIRQs', unit: '/s', direction: 'lower', source: 'outcome', decimals: 0, value: scalar('softirq_per_s'), format: formatRate },
  { key: 'pipewire_errors', label: 'PipeWire errors', unit: '', direction: 'lower', source: 'outcome', decimals: 0, value: scalar('pipewire_errors'), format: int0, guard: true, description: 'Guard: any non-zero value is a reject' },
  { key: 'xruns', label: 'Xruns', unit: '', direction: 'lower', source: 'outcome', decimals: 0, value: scalar('xruns'), format: int0, guard: true, description: 'Guard: any non-zero value is a reject' },
  { key: 'dsp_avg', label: 'DSP load avg', unit: '%', direction: 'lower', source: 'outcome', decimals: 1, value: scalar('dsp_avg'), format: pct1, description: 'null on idle Sets' },
  { key: 'dsp_peak', label: 'DSP load peak', unit: '%', direction: 'lower', source: 'outcome', decimals: 1, value: scalar('dsp_peak'), format: pct1, description: 'null on idle Sets' },
  { key: 'audio_workers', label: 'Audio workers', unit: '', direction: 'neutral', source: 'outcome', decimals: 0, value: scalar('audio_workers'), format: int0, description: 'Informational: no delta colour, no significance' },
  { key: 'voluntary_switches_per_s', label: 'Voluntary switches', unit: '/s', direction: 'lower', source: 'outcome', decimals: 0, value: scalar('voluntary_switches_per_s'), format: formatRate },
  { key: 'late_blocks', label: 'Late blocks', unit: '', direction: 'lower', source: 'interface', decimals: 0, value: scalar('late_blocks'), format: int0, description: 'Raw count over the window' },
  { key: 'late_blocks_per_min', label: 'Late blocks / min', unit: '/min', direction: 'lower', source: 'interface', decimals: 2, value: perMinute('late_blocks'), format: formatRate2, description: 'Interface primary: late_blocks × 60 / duration_s' },
  { key: 'near_late_blocks', label: 'Near-late blocks', unit: '', direction: 'lower', source: 'interface', decimals: 0, value: scalar('near_late_blocks'), format: int0 },
  { key: 'near_late_blocks_per_min', label: 'Near-late blocks / min', unit: '/min', direction: 'lower', source: 'interface', decimals: 2, value: perMinute('near_late_blocks'), format: formatRate2, description: 'near_late_blocks × 60 / duration_s' },
  { key: 'slack_p01_ns', label: 'Slack p01', unit: 'µs', direction: 'higher', source: 'interface', decimals: 1, value: scalar('slack_p01_ns'), format: ns1, description: 'Stored in ns, displayed auto-scaled' },
  { key: 'slack_p50_ns', label: 'Slack p50', unit: 'µs', direction: 'higher', source: 'interface', decimals: 1, value: scalar('slack_p50_ns'), format: ns1, description: 'Stored in ns, displayed auto-scaled' },
  { key: 'lost_slack_total_ns', label: 'Lost slack (total)', unit: 'ms', direction: 'lower', source: 'interface', decimals: 2, value: scalar('lost_slack_total_ns'), format: ns2, description: 'Stored in ns, displayed auto-scaled' },
];

const BY_KEY = new Map<string, MetricDef>(METRICS.map((m) => [m.key, m]));

/** Hero / tile primaries: interface when the slice has traced runs, else outcome. */
export const PRIMARY_METRIC: Readonly<Record<MetricSource, MetricKey>> = {
  interface: 'late_blocks_per_min',
  outcome: 'live_cpu_pct_per_core',
};

/** Any non-zero value is an automatic reject (shown critical with the label "reject"). */
export const GUARD_METRICS: readonly MetricKey[] = ['pipewire_errors', 'xruns'];

/** The Overview tile metrics per Set, in tile order (errors + xruns share the guard tile). */
export const OVERVIEW_METRICS: readonly MetricKey[] = [
  'late_blocks_per_min',
  'pipewire_errors',
  'xruns',
  'live_cpu_pct_per_core',
  'slack_p01_ns',
];

export function metric(key: MetricKey): MetricDef {
  const def = BY_KEY.get(key);
  if (!def) throw new Error(`unknown metric "${key}"`);
  return def;
}

/** Lookup by an untyped key (e.g. the ledger's `metrics.primary`); `undefined` when unknown. */
export function findMetric(key: string): MetricDef | undefined {
  return BY_KEY.get(key);
}

export function metricsFor(source: MetricSource): MetricDef[] {
  return METRICS.filter((m) => m.source === source);
}

export function isGuardMetric(key: string): boolean {
  return GUARD_METRICS.includes(key as MetricKey);
}

/** Which metric source a run's trace mode is authoritative for. */
export function sourceForTraceMode(mode: TraceMode): MetricSource {
  return mode === 'off' ? 'outcome' : 'interface';
}

/** Raw value of `key` for `setName` in `run`; `null` when the Set or the value is missing. */
export function metricValue(run: Run, setName: string, key: MetricKey): number | null {
  const set = Object.prototype.hasOwnProperty.call(run.sets, setName) ? run.sets[setName] : undefined;
  if (!set) return null;
  return metric(key).value(set, run);
}

/** Guard check on a raw value: `true` when a guard metric is non-null and non-zero. */
export function isGuardReject(key: MetricKey, value: number | null): boolean {
  return isGuardMetric(key) && value !== null && value !== 0;
}
