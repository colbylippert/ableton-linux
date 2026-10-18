/**
 * Gains model (DESIGN.md §3) plus the identity, filter and series view-model helpers of
 * §6 (`identity.ts`, `filter.ts`, `gains.ts`, `series.ts` collapsed into one module).
 *
 * Everything here is pure. The rules the code encodes (DESIGN.md §1):
 *  - identity = (machine_id, virtualization, structure/scenario, trace_mode); baselines,
 *    deltas, spreads and trends never cross an identity;
 *  - outcome metrics are produced only for untraced identities, interface metrics only for
 *    traced ones;
 *  - positive delta = improvement, decided once in `signedDelta()`;
 *  - significance is judged against the A/A spread: |Δ| > 2 × spread → beyond noise.
 */
import type {
  Arm,
  Baselines,
  FilterState,
  GainRow,
  HotspotTop,
  Identity,
  MetricDirection,
  MetricKey,
  MetricSource,
  NoiseSpread,
  Run,
  RunValue,
  Significance,
  Structure,
  TraceMode,
  Trial,
  Virtualization,
} from './types';
import { DEFAULT_FILTER } from './types';
import { median } from './format';
import {
  compareStrings,
  isCanonicalSet,
  metric,
  metricValue,
  metricsFor,
  orderSets,
  setLabel,
  setSlot,
  sourceForTraceMode,
  type SeriesSlot,
} from './metrics';

// ---------------------------------------------------------------------------
// Ordering
// ---------------------------------------------------------------------------

/** `started_at` as epoch milliseconds; `NaN` when unparsable. */
export function startedMs(run: Pick<Run, 'started_at'>): number {
  return Date.parse(run.started_at);
}

/** By `started_at` (unparsable dates last, compared as text), then `run_id`. */
export function compareRuns(a: Run, b: Run): number {
  const ta = startedMs(a);
  const tb = startedMs(b);
  const na = Number.isNaN(ta);
  const nb = Number.isNaN(tb);
  if (na !== nb) return na ? 1 : -1;
  if (!na && ta !== tb) return ta < tb ? -1 : 1;
  if (na && a.started_at !== b.started_at) return compareStrings(a.started_at, b.started_at);
  return compareStrings(a.run_id, b.run_id);
}

export function sortRuns(runs: readonly Run[]): Run[] {
  return [...runs].sort(compareRuns);
}

/** The most recent run (max `started_at`, tie → `run_id`) or `null`. */
export function latestRun(runs: readonly Run[]): Run | null {
  let best: Run | null = null;
  for (const run of runs) if (best === null || compareRuns(run, best) > 0) best = run;
  return best;
}

// ---------------------------------------------------------------------------
// Identity
// ---------------------------------------------------------------------------

export function identityOf(run: Run): Identity {
  return {
    machine_id: run.machine_id,
    virtualization: run.virtualization,
    audio_device: run.audio_device ?? null,
    structure: run.structure,
    scenario: run.scenario,
    trace_mode: run.trace_mode,
  };
}

/** `"<structure>/<scenario or ->"` — the inner key of baselines.json (before the trace and device suffixes). */
export function baselineKeyOf(x: Pick<Identity, 'structure' | 'scenario'>): string {
  return `${x.structure}/${x.scenario ?? '-'}`;
}

/** `" [<node.name>]"` for a known audio device, else `""` — history-add's baseline-key suffix. */
export function deviceSuffix(x: Pick<Identity, 'audio_device'>): string {
  return x.audio_device ? ` [${x.audio_device}]` : '';
}

/** `"<machine>|<virtualization>|<structure>/<scenario or ->|<trace_mode>|<audio device or ->"` — stable grouping key. */
export function identityKeyOf(id: Identity): string {
  return `${id.machine_id}|${id.virtualization}|${baselineKeyOf(id)}|${id.trace_mode}|${id.audio_device ?? '-'}`;
}

/** A `Run` satisfies `Identity` structurally, so runs and identities mix freely here. */
export function sameIdentity(a: Identity, b: Identity): boolean {
  return (
    a.machine_id === b.machine_id &&
    a.virtualization === b.virtualization &&
    (a.audio_device ?? null) === (b.audio_device ?? null) &&
    a.structure === b.structure &&
    (a.scenario ?? null) === (b.scenario ?? null) &&
    a.trace_mode === b.trace_mode
  );
}

export function environmentOf(x: Pick<Identity, 'virtualization'>): 'bare-metal' | 'virtualised' {
  return x.virtualization === 'none' ? 'bare-metal' : 'virtualised';
}

export function isTraced(x: Pick<Identity, 'trace_mode'>): boolean {
  return x.trace_mode !== 'off';
}

/** Distinct identities in order of their first (earliest) run. */
export function identitiesOf(runs: readonly Run[]): Identity[] {
  const seen = new Map<string, Identity>();
  for (const run of sortRuns(runs)) {
    const id = identityOf(run);
    const key = identityKeyOf(id);
    if (!seen.has(key)) seen.set(key, id);
  }
  return [...seen.values()];
}

// ---------------------------------------------------------------------------
// Filter
// ---------------------------------------------------------------------------

export interface FilterMachineOption {
  id: string;
  /** From the machine's most recent run. */
  hostname: string;
  virtualization: Virtualization;
  runs: number;
}

export interface FilterOptions {
  /** Most recently active machine first. */
  machines: FilterMachineOption[];
  structures: Structure[];
  scenarios: string[];
  traceModes: TraceMode[];
  sets: string[];
  /** Switch `ENV_NAME`s seen on any run (the `'none'` sentinel is added by the UI). */
  switches: string[];
}

const STRUCTURE_ORDER: readonly Structure[] = ['benchmark', 'diagnostic'];
const TRACE_MODE_ORDER: readonly TraceMode[] = ['off', 'interface', 'drilldown'];

function hasOwn(obj: object, key: string): boolean {
  return Object.prototype.hasOwnProperty.call(obj, key);
}

/**
 * Switch filter: `null` = all, `'none'` = runs with no switches, `ENV` = runs where that
 * switch is active (any value), `ENV=value` = runs where it has exactly that value.
 */
export function matchesSwitch(run: Run, filter: string | null): boolean {
  if (filter === null) return true;
  const switches = run.switches ?? {};
  if (filter === 'none') return Object.keys(switches).length === 0;
  const eq = filter.indexOf('=');
  if (eq === -1) return hasOwn(switches, filter);
  return switches[filter.slice(0, eq)] === filter.slice(eq + 1);
}

export function applyFilter(runs: readonly Run[], filter: FilterState): Run[] {
  return runs.filter(
    (run) =>
      (filter.machine === null || run.machine_id === filter.machine) &&
      (filter.environment === 'all' || environmentOf(run) === filter.environment) &&
      (filter.structure === null || run.structure === filter.structure) &&
      (filter.scenario === null || run.scenario === filter.scenario) &&
      (filter.traceMode === null || run.trace_mode === filter.traceMode) &&
      (filter.set === null || hasOwn(run.sets, filter.set)) &&
      matchesSwitch(run, filter.switch),
  );
}

export function filterOptions(runs: readonly Run[]): FilterOptions {
  const sorted = sortRuns(runs);
  const machines = new Map<string, FilterMachineOption & { latest: number }>();
  const scenarios = new Set<string>();
  const sets: string[] = [];
  const switches = new Set<string>();
  const structures = new Set<Structure>();
  const traceModes = new Set<TraceMode>();
  for (const run of sorted) {
    const entry = machines.get(run.machine_id);
    if (entry) {
      entry.hostname = run.hostname;
      entry.virtualization = run.virtualization;
      entry.runs += 1;
      entry.latest = startedMs(run);
    } else {
      machines.set(run.machine_id, {
        id: run.machine_id,
        hostname: run.hostname,
        virtualization: run.virtualization,
        runs: 1,
        latest: startedMs(run),
      });
    }
    structures.add(run.structure);
    traceModes.add(run.trace_mode);
    if (run.scenario !== null) scenarios.add(run.scenario);
    sets.push(...Object.keys(run.sets));
    for (const name of Object.keys(run.switches ?? {})) switches.add(name);
  }
  // Sorted runs → the last insertion order is chronological; most recent machine first.
  const machineList = [...machines.values()].sort((a, b) => b.latest - a.latest || compareStrings(a.id, b.id));
  return {
    machines: machineList.map(({ id, hostname, virtualization, runs: n }) => ({ id, hostname, virtualization, runs: n })),
    structures: STRUCTURE_ORDER.filter((s) => structures.has(s)),
    scenarios: [...scenarios].sort(compareStrings),
    traceModes: TRACE_MODE_ORDER.filter((m) => traceModes.has(m)),
    sets: orderSets(sets),
    switches: [...switches].sort(compareStrings),
  };
}

/** `DEFAULT_FILTER` scoped to the machine of the most recent run (cross-machine charts are meaningless). */
export function defaultFilterFor(runs: readonly Run[]): FilterState {
  return { ...DEFAULT_FILTER, machine: latestRun(runs)?.machine_id ?? null };
}

// ---------------------------------------------------------------------------
// Baseline, A/A spread, delta, significance
// ---------------------------------------------------------------------------

/** A run with no switches, no trial and no arm — the fallback baseline candidate. */
export function isCleanRun(run: Run): boolean {
  return Object.keys(run.switches ?? {}).length === 0 && run.trial === null && run.arm === null;
}

/**
 * 1. the run named by `baselines[machine]["<structure>/<scenario or ->@<trace_mode>"]`
 *    or `baselines[machine]["<structure>/<scenario or ->"]`, if that run has this identity
 *    (baselines.json is keyed without trace mode, so a traced identity whose recorded
 *    baseline is untraced falls through);
 * 2. else the earliest clean run of the identity (no switches, no trial, no arm);
 * 3. else `null`.
 */
export function resolveBaseline(runs: readonly Run[], baselines: Baselines, identity: Identity): Run | null {
  const idRuns = sortRuns(runs.filter((r) => sameIdentity(r, identity)));
  const byMachine = hasOwn(baselines, identity.machine_id) ? baselines[identity.machine_id] : undefined;
  if (byMachine) {
    const key = baselineKeyOf(identity);
    const device = deviceSuffix(identity);
    const keys = [`${key}@${identity.trace_mode}`, key];
    for (const candidate of device ? [...keys.map((k) => `${k}${device}`), ...keys] : keys) {
      const runId = hasOwn(byMachine, candidate) ? byMachine[candidate] : undefined;
      if (typeof runId !== 'string') continue;
      const run = idRuns.find((r) => r.run_id === runId);
      if (run) return run;
    }
  }
  return idRuns.find(isCleanRun) ?? null;
}

/**
 * A/A pairs of one identity: explicit pairs from ledger lines (`runs.aa`, both members
 * resolve to runs of this identity) plus implicit pairs — runs with `arm === 'AA'` not
 * covered by an explicit pair, sorted by `started_at`, grouped by `trial`, paired
 * consecutively (an odd leftover is ignored).
 */
export function aaPairs(runs: readonly Run[], trials: readonly Trial[], identity: Identity): [Run, Run][] {
  const byId = new Map(runs.map((r) => [r.run_id, r] as const));
  const pairs: [Run, Run][] = [];
  const covered = new Set<string>();
  for (const trial of trials) {
    for (const pair of trial.runs?.aa ?? []) {
      const [a, b] = pair;
      const ra = byId.get(a);
      const rb = byId.get(b);
      if (!ra || !rb || ra === rb || !sameIdentity(ra, identity) || !sameIdentity(rb, identity)) continue;
      pairs.push([ra, rb]);
      covered.add(a);
      covered.add(b);
    }
  }
  const implicit = sortRuns(runs.filter((r) => r.arm === 'AA' && sameIdentity(r, identity) && !covered.has(r.run_id)));
  const groups = new Map<string, Run[]>();
  for (const run of implicit) {
    const key = run.trial ?? '';
    const group = groups.get(key);
    if (group) group.push(run);
    else groups.set(key, [run]);
  }
  for (const members of groups.values()) {
    for (let i = 0; i + 1 < members.length; i += 2) pairs.push([members[i]!, members[i + 1]!]);
  }
  return pairs;
}

/** Median over A/A pairs of |a − b| for (set, metric); `null` without a usable pair. */
export function aaSpread(
  runs: readonly Run[],
  trials: readonly Trial[],
  identity: Identity,
  set: string,
  metricKey: MetricKey,
): NoiseSpread | null {
  const diffs: number[] = [];
  for (const [a, b] of aaPairs(runs, trials, identity)) {
    const va = metricValue(a, set, metricKey);
    const vb = metricValue(b, set, metricKey);
    if (va !== null && vb !== null) diffs.push(Math.abs(va - vb));
  }
  const spread = median(diffs);
  return spread === null ? null : { spread, pairs: diffs.length };
}

/**
 * The one place the sign is flipped: `abs` is positive when the change is an improvement
 * (`lower`: baseline − value; `higher` / `neutral`: value − baseline); `pct = abs / |baseline|`,
 * `null` for a zero baseline.
 */
export function signedDelta(value: number, baseline: number, direction: MetricDirection): { abs: number; pct: number | null } {
  const raw = value - baseline;
  const abs = direction === 'lower' ? -raw : raw;
  return { abs, pct: baseline === 0 ? null : abs / Math.abs(baseline) };
}

/** `unknown` without a delta or an A/A estimate; `|Δ| > 2 × spread` → `beyond`; else `within`. */
export function significanceOf(deltaAbs: number | null, spread: NoiseSpread | number | null): Significance {
  const s = typeof spread === 'number' ? spread : (spread?.spread ?? null);
  if (deltaAbs === null || s === null || !Number.isFinite(s)) return 'unknown';
  return Math.abs(deltaAbs) > 2 * s ? 'beyond' : 'within';
}

interface Entry {
  run: Run;
  value: number;
}

function toRunValue(entry: Entry): RunValue {
  return { runId: entry.run.run_id, startedAt: entry.run.started_at, value: entry.value };
}

/** First entry (in the given order) with the best value for the direction. */
function bestOf(entries: readonly Entry[], direction: MetricDirection): Entry | null {
  let best: Entry | null = null;
  for (const e of entries) {
    if (best === null) best = e;
    else if (direction === 'lower' ? e.value < best.value : e.value > best.value) best = e;
  }
  return best;
}

/**
 * One `GainRow` per (identity, set, metric) with at least one contributing run (a non-null
 * value in the filtered slice, or a baseline value). Identities and the competing runs
 * come from the filtered slice; the baseline and the A/A spread are resolved over all
 * runs of the identity, so the `switch` filter narrows latest/best but never the baseline.
 * `latest` is the most recent run with a non-null value; `best` is the best value since
 * the baseline (inclusive) — or over the slice when there is no baseline — and `null` for
 * neutral metrics, which also carry no spread and no significance.
 */
export function computeGains(
  runs: readonly Run[],
  baselines: Baselines,
  filter: FilterState,
  trials: readonly Trial[] = [],
): GainRow[] {
  const all = sortRuns(runs);
  const slice = applyFilter(all, filter);
  const rows: GainRow[] = [];
  for (const identity of identitiesOf(slice)) {
    const identityKey = identityKeyOf(identity);
    const baselineKey = baselineKeyOf(identity);
    const idRuns = all.filter((r) => sameIdentity(r, identity));
    const sliceRuns = slice.filter((r) => sameIdentity(r, identity));
    const baselineRun = resolveBaseline(idRuns, baselines, identity);
    const baselineMs = baselineRun ? startedMs(baselineRun) : Number.NaN;
    const source: MetricSource = sourceForTraceMode(identity.trace_mode);
    const defs = metricsFor(source);
    const setNames = orderSets(sliceRuns.flatMap((r) => Object.keys(r.sets))).filter(
      (s) => filter.set === null || s === filter.set,
    );
    for (const set of setNames) {
      for (const def of defs) {
        const entries: Entry[] = [];
        for (const run of sliceRuns) {
          const value = metricValue(run, set, def.key);
          if (value !== null) entries.push({ run, value });
        }
        const baselineValue = baselineRun ? metricValue(baselineRun, set, def.key) : null;
        const baselineEntry: Entry | null = baselineRun && baselineValue !== null ? { run: baselineRun, value: baselineValue } : null;
        if (entries.length === 0 && baselineEntry === null) continue;

        const latestEntry = entries.length > 0 ? entries[entries.length - 1]! : null;
        let best: RunValue | null = null;
        if (def.direction !== 'neutral') {
          const candidates: Entry[] = baselineEntry
            ? [baselineEntry, ...entries.filter((e) => e.run.run_id !== baselineEntry.run.run_id && !(startedMs(e.run) < baselineMs))]
            : entries;
          const b = bestOf(candidates, def.direction);
          best = b ? toRunValue(b) : null;
        }
        const delta = latestEntry && baselineEntry ? signedDelta(latestEntry.value, baselineEntry.value, def.direction) : null;
        const spread = def.direction === 'neutral' ? null : aaSpread(idRuns, trials, identity, set, def.key);
        rows.push({
          identity,
          identityKey,
          baselineKey,
          set,
          metric: def.key,
          direction: def.direction,
          source,
          baseline: baselineEntry ? toRunValue(baselineEntry) : null,
          latest: latestEntry ? toRunValue(latestEntry) : null,
          best,
          deltaAbs: delta?.abs ?? null,
          deltaPct: delta?.pct ?? null,
          spread,
          significance: def.direction === 'neutral' ? 'unknown' : significanceOf(delta?.abs ?? null, spread),
          runs: entries.length,
        });
      }
    }
  }
  return rows;
}

export interface CumulativeGain {
  /** Median over Sets of `deltaPct` (a fraction; positive = improvement); `null` without deltas. */
  medianPct: number | null;
  /** Number of Sets with a delta. */
  sets: number;
  /** `beyond` when at least half of the Sets with an A/A estimate are beyond noise; `unknown` without any estimate. */
  significance: Significance;
  /** Sets that regressed beyond noise (the acceptance rule's "no Set regresses beyond the spread"). */
  regressions: number;
}

/** Hero figure: the median delta % over Sets on `metricKey`, optionally restricted to one identity. */
export function cumulativeGain(rows: readonly GainRow[], metricKey: MetricKey, identityKey?: string): CumulativeGain {
  const selected = rows.filter((r) => r.metric === metricKey && (identityKey === undefined || r.identityKey === identityKey));
  const pcts: number[] = [];
  for (const r of selected) if (r.deltaPct !== null) pcts.push(r.deltaPct);
  const known = selected.filter((r) => r.deltaPct !== null && r.significance !== 'unknown');
  const beyond = known.filter((r) => r.significance === 'beyond');
  const regressions = beyond.filter((r) => (r.deltaAbs ?? 0) < 0).length;
  const significance: Significance = known.length === 0 ? 'unknown' : beyond.length * 2 >= known.length ? 'beyond' : 'within';
  return { medianPct: median(pcts), sets: pcts.length, significance, regressions };
}

/**
 * The identity of the most recent run in `runs` that is authoritative for `source`
 * (traced for `interface`, untraced for `outcome`); `null` when there is none.
 */
export function headlineIdentity(runs: readonly Run[], source: MetricSource): Identity | null {
  const wantTraced = source === 'interface';
  const latest = latestRun(runs.filter((r) => isTraced(r) === wantTraced));
  return latest ? identityOf(latest) : null;
}

// ---------------------------------------------------------------------------
// Series view models (DESIGN.md §5 TrendSeries, §6 series.ts)
// ---------------------------------------------------------------------------

export interface TrendPoint {
  /** `started_at` as epoch milliseconds (the x value). */
  t: number;
  runId: string;
  tag: string;
  /** `null` is kept (the line breaks; `connectNulls={false}`). */
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

function pointOf(run: Run, value: number | null): TrendPoint {
  return {
    t: startedMs(run),
    runId: run.run_id,
    tag: run.tag,
    value,
    arm: run.arm,
    trial: run.trial,
    switches: run.switches ?? {},
  };
}

/** One Set's metric over run time (runs lacking the Set are skipped; null values are kept). */
export function trendSeries(runs: readonly Run[], set: string, metricKey: MetricKey, slot: SeriesSlot): TrendSeries {
  const points = sortRuns(runs)
    .filter((r) => hasOwn(r.sets, set))
    .map((r) => pointOf(r, metricValue(r, set, metricKey)));
  return { id: set, label: setLabel(set), slot, points };
}

/**
 * Overlay form: one series per canonical Set with a baseline, y = delta % vs that Set's own
 * baseline (signed, positive = improvement) for every run of the row's identity. Pass the
 * rows of one identity and one metric; non-canonical Sets are left out (they share slot 6).
 */
export function overlaySeries(rows: readonly GainRow[], runs: readonly Run[]): TrendSeries[] {
  const sorted = sortRuns(runs);
  const bySet = new Map<string, GainRow>();
  for (const row of rows) {
    if (row.baseline === null || !isCanonicalSet(row.set) || bySet.has(row.set)) continue;
    bySet.set(row.set, row);
  }
  return orderSets(bySet.keys()).map((set) => {
    const row = bySet.get(set)!;
    const baseline = row.baseline!.value;
    const direction = metric(row.metric).direction;
    const points = sorted
      .filter((r) => sameIdentity(r, row.identity) && hasOwn(r.sets, set))
      .map((r) => {
        const v = metricValue(r, set, row.metric);
        return pointOf(r, v === null ? null : signedDelta(v, baseline, direction).pct);
      });
    return { id: set, label: setLabel(set), slot: setSlot(set), points };
  });
}

interface RankedSeriesInput {
  runs: Run[];
  valuesOf: (run: Run) => Map<string, number>;
  topN: number;
}

/** Shared ranking for the emphasis form: top-N keys by their maximum value across runs. */
function rankedSeries({ runs, valuesOf, topN }: RankedSeriesInput): TrendSeries[] {
  const perRun = runs.map((run) => ({ run, values: valuesOf(run) }));
  const maxByKey = new Map<string, number>();
  for (const { values } of perRun) {
    for (const [key, v] of values) {
      const prev = maxByKey.get(key);
      if (prev === undefined || v > prev) maxByKey.set(key, v);
    }
  }
  const keys = [...maxByKey.entries()]
    .sort((a, b) => b[1] - a[1] || compareStrings(a[0], b[0]))
    .slice(0, Math.max(0, topN))
    .map(([key]) => key);
  return keys.map((key) => ({
    id: key,
    label: key,
    slot: 'dim' as const,
    points: perRun.map(({ run, values }) => pointOf(run, values.get(key) ?? null)),
  }));
}

/**
 * Call-site share of lost slack over traced runs for one Set: the top-N keys by maximum
 * share, each a series in slot `'dim'` (the chart emphasises one). A key absent from a
 * run's top list is `null` there.
 */
export function callSiteTrends(runs: readonly Run[], set: string, topN = 8): TrendSeries[] {
  const traced = sortRuns(runs).filter((r) => Array.isArray(r.sets[set]?.call_sites_top));
  return rankedSeries({
    runs: traced,
    topN,
    valuesOf: (run) => {
      const values = new Map<string, number>();
      for (const cs of run.sets[set]?.call_sites_top ?? []) {
        if (typeof cs.key === 'string' && Number.isFinite(cs.share)) values.set(cs.key, cs.share);
      }
      return values;
    },
  });
}

/** `"<role>|<kind>|<caller>"` — the join key of a non-audio hotspot. */
export function hotspotKey(h: Pick<HotspotTop, 'role' | 'kind' | 'caller'>): string {
  return `${h.role}|${h.kind}|${h.caller}`;
}

/** Non-audio hotspot `total_ns` over runs for one Set: top-N keys by maximum total. */
export function hotspotTrends(runs: readonly Run[], set: string, topN = 8): TrendSeries[] {
  const withHotspots = sortRuns(runs).filter((r) => Array.isArray(r.sets[set]?.hotspots_non_audio_top));
  return rankedSeries({
    runs: withHotspots,
    topN,
    valuesOf: (run) => {
      const values = new Map<string, number>();
      for (const h of run.sets[set]?.hotspots_non_audio_top ?? []) {
        if (Number.isFinite(h.total_ns)) values.set(hotspotKey(h), h.total_ns);
      }
      return values;
    },
  });
}

export interface RunDeltaRow {
  set: string;
  metric: MetricKey;
  label: string;
  unit: string;
  source: MetricSource;
  direction: MetricDirection;
  a: number | null;
  b: number | null;
  /** `b` vs `a`, signed so that positive = improvement. */
  deltaAbs: number | null;
  deltaPct: number | null;
}

export type RunDeltaResult = { ok: true; rows: RunDeltaRow[] } | { ok: false; reason: string };

/**
 * Inline comparison of two runs (Runs view). Refuses, with a reason, any pair that is not
 * one identity: machine, virtualisation, structure/scenario or trace-mode mismatch. Rows
 * cover the union of Sets × the metrics the pair's trace mode is authoritative for; rows
 * where both sides are null are dropped.
 */
export function runDelta(a: Run, b: Run): RunDeltaResult {
  if (a.machine_id !== b.machine_id) {
    return { ok: false, reason: `machine mismatch: ${a.machine_id} vs ${b.machine_id}` };
  }
  if (a.virtualization !== b.virtualization) {
    return {
      ok: false,
      reason: `virtualisation mismatch: ${a.virtualization} vs ${b.virtualization} — no timing claims across environments`,
    };
  }
  if (baselineKeyOf(a) !== baselineKeyOf(b)) {
    return { ok: false, reason: `structure/scenario mismatch: ${baselineKeyOf(a)} vs ${baselineKeyOf(b)}` };
  }
  if (a.trace_mode !== b.trace_mode) {
    return { ok: false, reason: `trace mode mismatch: ${a.trace_mode} vs ${b.trace_mode}` };
  }
  const source = sourceForTraceMode(a.trace_mode);
  const rows: RunDeltaRow[] = [];
  for (const set of orderSets([...Object.keys(a.sets), ...Object.keys(b.sets)])) {
    for (const def of metricsFor(source)) {
      const va = metricValue(a, set, def.key);
      const vb = metricValue(b, set, def.key);
      if (va === null && vb === null) continue;
      const delta = va !== null && vb !== null ? signedDelta(vb, va, def.direction) : null;
      rows.push({
        set,
        metric: def.key,
        label: def.label,
        unit: def.unit,
        source,
        direction: def.direction,
        a: va,
        b: vb,
        deltaAbs: delta?.abs ?? null,
        deltaPct: delta?.pct ?? null,
      });
    }
  }
  return { ok: true, rows };
}
