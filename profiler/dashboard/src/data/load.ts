/**
 * Loaders (DESIGN.md §6 `history.ts` / `baselines.ts` / `ledger.ts` / `load.ts`).
 *
 * The three module-level imports below are the only side effects in the data layer.
 * They are what gives HMR: Vite re-evaluates this module when `profiler/bin/history-add`
 * writes a run, `history-add --baseline` rewrites baselines.json or the agent appends a
 * ledger line. Paths are relative to this file (profiler/dashboard/src/data/ → profiler/):
 *
 *   history/runs/*.json       — import.meta.glob, eager, default export = the record
 *   history/baselines.json    — import.meta.glob so a missing file is `{}` (a static
 *                               import would break the build before the first baseline)
 *   ledger.jsonl              — ?raw (the file exists, possibly empty)
 *
 * Everything else is a pure parser that takes the imported values, so tests inject
 * fixtures (`src/data/__fixtures__/`) through the same functions.
 */
import ledgerRaw from '../../../ledger.jsonl?raw';
import type {
  AbPair,
  ArmValues,
  Baselines,
  CallSiteTop,
  DashboardData,
  HotspotTop,
  ProbeResult,
  Run,
  RunRuntime,
  SetMetrics,
  Structure,
  TraceMode,
  TracedConfirmation,
  Trial,
  TrialChange,
  TrialEvidence,
  TrialMetrics,
  TrialRuns,
  TrialSetMetrics,
} from './types';
import { compareRuns } from './gains';
import { compareStrings } from './metrics';
import { isVerdict } from './trials';

const historyModules = import.meta.glob('../../../history/runs/*.json', { eager: true, import: 'default' });
const baselineModules = import.meta.glob('../../../history/baselines.json', { eager: true, import: 'default' });

export const HISTORY_SCHEMA = 'ableton-linux-profiler-history/v1';
export const LEDGER_SCHEMA = 'ableton-linux-profiler-ledger/v1';

// ---------------------------------------------------------------------------
// Small value helpers
// ---------------------------------------------------------------------------

type Rec = Record<string, unknown>;

function isRecord(v: unknown): v is Rec {
  return typeof v === 'object' && v !== null && !Array.isArray(v);
}

function str(v: unknown): string | null {
  return typeof v === 'string' ? v : null;
}

function num(v: unknown): number | null {
  return typeof v === 'number' && Number.isFinite(v) ? v : null;
}

/** A glob entry is the record itself (`import: 'default'`) or a module namespace with `default`. */
function unwrapModule(value: unknown): unknown {
  return isRecord(value) && isRecord(value.default) ? value.default : value;
}

function basename(path: string): string {
  return path.slice(path.lastIndexOf('/') + 1);
}

function errorMessage(e: unknown): string {
  return e instanceof Error ? e.message : String(e);
}

// ---------------------------------------------------------------------------
// History records
// ---------------------------------------------------------------------------

function normalizeCallSites(v: unknown): CallSiteTop[] | null {
  if (!Array.isArray(v)) return null;
  const out: CallSiteTop[] = [];
  for (const item of v) {
    if (!isRecord(item)) continue;
    const key = str(item.key);
    const share = num(item.share);
    if (key === null || share === null) continue;
    out.push({ key, share, total_ns_in_late_blocks: num(item.total_ns_in_late_blocks) ?? 0 });
  }
  return out;
}

function normalizeHotspots(v: unknown): HotspotTop[] | null {
  if (!Array.isArray(v)) return null;
  const out: HotspotTop[] = [];
  for (const item of v) {
    if (!isRecord(item)) continue;
    const total = num(item.total_ns);
    if (total === null) continue;
    out.push({
      role: str(item.role) ?? '',
      kind: str(item.kind) ?? '',
      caller: str(item.caller) ?? '',
      n: num(item.n) ?? 0,
      total_ns: total,
    });
  }
  return out;
}

/** Every metric may be null; unknown shapes become null rather than throwing. */
export function normalizeSet(raw: unknown): SetMetrics {
  const r: Rec = isRecord(raw) ? raw : {};
  return {
    mode: str(r.mode) ?? 'unknown',
    host_cpu_pct: num(r.host_cpu_pct),
    live_cpu_pct_per_core: num(r.live_cpu_pct_per_core),
    wine_cpu_pct_per_core: num(r.wine_cpu_pct_per_core),
    pipewire_cpu_pct: num(r.pipewire_cpu_pct),
    irq_per_s: num(r.irq_per_s),
    softirq_per_s: num(r.softirq_per_s),
    pipewire_errors: num(r.pipewire_errors),
    xruns: num(r.xruns),
    dsp_avg: num(r.dsp_avg),
    dsp_peak: num(r.dsp_peak),
    audio_workers: num(r.audio_workers),
    voluntary_switches_per_s: num(r.voluntary_switches_per_s),
    late_blocks: num(r.late_blocks),
    near_late_blocks: num(r.near_late_blocks),
    slack_p01_ns: num(r.slack_p01_ns),
    slack_p50_ns: num(r.slack_p50_ns),
    lost_slack_total_ns: num(r.lost_slack_total_ns),
    call_sites_top: normalizeCallSites(r.call_sites_top),
    hotspots_non_audio_top: normalizeHotspots(r.hotspots_non_audio_top),
  };
}

const TRACE_MODES: readonly string[] = ['off', 'interface', 'drilldown'];

/**
 * Validates and normalises one history record. A record is rejected (`run: null`) when it
 * is not an object, carries a foreign `schema`, or lacks `run_id` / `started_at` /
 * `machine_id`; softer problems are reported but the run is kept with safe defaults.
 */
export function parseHistoryRecord(value: unknown, file: string): { run: Run | null; errors: string[] } {
  const errors: string[] = [];
  const r = unwrapModule(value);
  if (!isRecord(r)) return { run: null, errors: [`${file}: not a JSON object`] };
  const schema = r.schema;
  if (schema !== undefined && schema !== HISTORY_SCHEMA) {
    return { run: null, errors: [`${file}: unknown schema "${String(schema)}" (expected ${HISTORY_SCHEMA}); skipped`] };
  }
  const run_id = str(r.run_id);
  const started_at = str(r.started_at);
  const machine_id = str(r.machine_id);
  if (!run_id || !started_at || !machine_id) {
    return { run: null, errors: [`${file}: missing run_id, started_at or machine_id; skipped`] };
  }
  if (Number.isNaN(Date.parse(started_at))) errors.push(`${file}: unparsable started_at "${started_at}"`);

  const scenario = str(r.scenario);
  let structure: Structure;
  if (r.structure === 'benchmark' || r.structure === 'diagnostic') {
    structure = r.structure;
  } else {
    structure = scenario !== null ? 'diagnostic' : 'benchmark';
    if (r.structure !== undefined && r.structure !== null) {
      errors.push(`${file}: unknown structure "${String(r.structure)}"; treated as ${structure}`);
    }
  }

  let trace_mode: TraceMode;
  if (typeof r.trace_mode === 'string' && r.trace_mode !== '') {
    trace_mode = r.trace_mode as TraceMode;
    if (!TRACE_MODES.includes(r.trace_mode)) errors.push(`${file}: unknown trace_mode "${r.trace_mode}" (kept as its own identity)`);
  } else {
    trace_mode = 'off';
    errors.push(`${file}: missing trace_mode; treated as "off"`);
  }

  let virtualization = str(r.virtualization);
  if (virtualization === null || virtualization === '') {
    virtualization = 'unknown';
    errors.push(`${file}: missing virtualization; treated as "unknown" (no timing claims)`);
  }

  let arm: Run['arm'] = null;
  if (r.arm === 'A' || r.arm === 'B' || r.arm === 'AA') arm = r.arm;
  else if (r.arm !== undefined && r.arm !== null) errors.push(`${file}: unknown arm "${String(r.arm)}"; treated as null`);

  const switches: Record<string, string> = {};
  if (isRecord(r.switches)) {
    for (const [name, v] of Object.entries(r.switches)) switches[name] = v === null || v === undefined ? '' : String(v);
  }

  const rt: Rec = isRecord(r.runtime) ? r.runtime : {};
  const runtime: RunRuntime = {
    dist_version: str(rt.dist_version),
    source_tree_sha: str(rt.source_tree_sha),
    dev_info: str(rt.dev_info),
  };

  const sets: Record<string, SetMetrics> = {};
  if (isRecord(r.sets)) {
    for (const [name, v] of Object.entries(r.sets)) sets[name] = normalizeSet(v);
  } else {
    errors.push(`${file}: missing sets`);
  }

  const run: Run = {
    run_id,
    tag: str(r.tag) ?? '',
    started_at,
    machine_id,
    hostname: str(r.hostname) ?? '',
    virtualization,
    audio_device: str(r.audio_device),
    structure,
    scenario,
    trace_mode,
    duration_s: num(r.duration_s),
    runtime,
    switches,
    harness_sha: str(r.harness_sha),
    commit: str(r.commit),
    trial: str(r.trial),
    arm,
    source_dir: str(r.source_dir),
    sets,
  };
  if (typeof schema === 'string') run.schema = schema;
  return { run, errors };
}

/**
 * Builds the run list from an eager glob result (`path → record`). Records are read in
 * path order, duplicates by `run_id` are skipped and reported, and the result is sorted
 * by `started_at`, then `run_id`.
 */
export function historyFromModules(modules: Record<string, unknown>): { runs: Run[]; errors: string[] } {
  const runs: Run[] = [];
  const errors: string[] = [];
  const seen = new Map<string, string>();
  for (const path of Object.keys(modules).sort(compareStrings)) {
    const file = basename(path);
    const parsed = parseHistoryRecord(modules[path], file);
    errors.push(...parsed.errors);
    if (!parsed.run) continue;
    const previous = seen.get(parsed.run.run_id);
    if (previous !== undefined) {
      errors.push(`${file}: duplicate run_id "${parsed.run.run_id}" (already loaded from ${previous}); skipped`);
      continue;
    }
    seen.set(parsed.run.run_id, file);
    runs.push(parsed.run);
  }
  runs.sort(compareRuns);
  return { runs, errors };
}

// ---------------------------------------------------------------------------
// Baselines
// ---------------------------------------------------------------------------

/** `{ machine_id: { "<structure>/<scenario or ->": run_id } }`; `undefined` (no file) → `{}`. */
export function parseBaselines(value: unknown, file = 'baselines.json'): { baselines: Baselines; errors: string[] } {
  if (value === undefined) return { baselines: {}, errors: [] };
  const v = unwrapModule(value);
  if (!isRecord(v)) return { baselines: {}, errors: [`${file}: not a JSON object`] };
  const baselines: Baselines = {};
  const errors: string[] = [];
  for (const [machine, inner] of Object.entries(v)) {
    if (!isRecord(inner)) {
      errors.push(`${file}: ${machine}: expected { "<structure>/<scenario or ->": run_id }`);
      continue;
    }
    const entries: Record<string, string> = {};
    for (const [key, runId] of Object.entries(inner)) {
      if (typeof runId === 'string') entries[key] = runId;
      else errors.push(`${file}: ${machine}/${key}: run_id must be a string`);
    }
    baselines[machine] = entries;
  }
  return { baselines, errors };
}

/** The glob matches at most one file; an empty glob (file absent) yields `{}`. */
export function baselinesFromModules(modules: Record<string, unknown>): { baselines: Baselines; errors: string[] } {
  const paths = Object.keys(modules).sort(compareStrings);
  const first = paths[0];
  if (first === undefined) return { baselines: {}, errors: [] };
  return parseBaselines(modules[first], basename(first));
}

// ---------------------------------------------------------------------------
// Ledger
// ---------------------------------------------------------------------------

function normalizeEvidence(v: unknown): TrialEvidence[] {
  if (!Array.isArray(v)) return [];
  const out: TrialEvidence[] = [];
  for (const item of v) {
    if (!isRecord(item)) continue;
    const run = str(item.run);
    const set = str(item.set);
    const call_site = str(item.call_site);
    if (run === null || set === null || call_site === null) continue;
    out.push({ run, set, call_site, share_of_lost_slack: num(item.share_of_lost_slack) ?? 0 });
  }
  return out;
}

function normalizeChange(v: unknown): TrialChange {
  const r: Rec = isRecord(v) ? v : {};
  return {
    kind: str(r.kind) ?? 'unknown',
    patch: str(r.patch),
    switch: str(r.switch),
    probe: str(r.probe),
    note: str(r.note),
  };
}

function normalizeProbe(v: unknown): ProbeResult | null {
  if (!isRecord(v)) return null;
  return { pass: num(v.pass) ?? 0, fail: num(v.fail) ?? 0, skip: num(v.skip) ?? 0, log: str(v.log) };
}

function normalizePair(v: unknown): AbPair | null {
  if (!isRecord(v)) return null;
  const a = str(v.a);
  const b = str(v.b);
  return a !== null && b !== null ? { a, b } : null;
}

function normalizeRuns(v: unknown): TrialRuns {
  const r: Rec = isRecord(v) ? v : {};
  const aa: [string, string][] = [];
  if (Array.isArray(r.aa)) {
    for (const pair of r.aa) {
      if (Array.isArray(pair) && typeof pair[0] === 'string' && typeof pair[1] === 'string') aa.push([pair[0], pair[1]]);
    }
  }
  const abab: AbPair[] = [];
  if (Array.isArray(r.abab)) {
    for (const item of r.abab) {
      const pair = normalizePair(item);
      if (pair) abab.push(pair);
    }
  }
  return { aa, abab, traced: normalizePair(r.traced) };
}

function normalizeArmValues(v: unknown): ArmValues | null {
  return isRecord(v) ? { a: num(v.a), b: num(v.b) } : null;
}

function normalizeMetrics(v: unknown): TrialMetrics | null {
  if (!isRecord(v)) return null;
  const per_set: Record<string, TrialSetMetrics> = {};
  if (isRecord(v.per_set)) {
    for (const [set, m] of Object.entries(v.per_set)) {
      const r: Rec = isRecord(m) ? m : {};
      per_set[set] = {
        a_median: num(r.a_median),
        b_median: num(r.b_median),
        aa_spread: num(r.aa_spread),
        delta: num(r.delta),
        ratio_to_spread: num(r.ratio_to_spread),
      };
    }
  }
  return {
    primary: str(v.primary) ?? '',
    per_set,
    xruns: normalizeArmValues(v.xruns),
    cpu_live_pct: normalizeArmValues(v.cpu_live_pct),
  };
}

/** Accepts design-C's `{ call_site_share_before, after }` and the plan's `{ before, after }`. */
function normalizeTracedConfirmation(v: unknown): TracedConfirmation | null {
  if (!isRecord(v)) return null;
  return { call_site_share_before: num(v.call_site_share_before) ?? num(v.before), after: num(v.after) };
}

/** One parsed ledger line; `trial: null` when the line cannot be used (reason in `errors`). */
export function parseLedgerLine(value: unknown, line: number, file = 'ledger.jsonl'): { trial: Trial | null; errors: string[] } {
  const where = `${file}:${line}`;
  if (!isRecord(value)) return { trial: null, errors: [`${where}: not a JSON object; skipped`] };
  const schema = value.schema;
  if (schema !== undefined && schema !== LEDGER_SCHEMA) {
    return { trial: null, errors: [`${where}: unknown schema "${String(schema)}" (expected ${LEDGER_SCHEMA}); skipped`] };
  }
  const trialId = str(value.trial);
  if (trialId === null || trialId === '') return { trial: null, errors: [`${where}: missing trial id; skipped`] };
  if (!isVerdict(value.verdict)) {
    return { trial: null, errors: [`${where}: ${trialId}: unknown verdict "${String(value.verdict)}"; skipped`] };
  }
  const errors: string[] = [];
  const date = str(value.date);
  if (date === null || Number.isNaN(Date.parse(date))) errors.push(`${where}: ${trialId}: missing or unparsable date`);
  const trial: Trial = {
    schema: typeof schema === 'string' ? schema : LEDGER_SCHEMA,
    trial: trialId,
    date: date ?? '',
    host: str(value.host) ?? 'unknown',
    branch: str(value.branch) ?? '',
    hypothesis: str(value.hypothesis) ?? '',
    evidence: normalizeEvidence(value.evidence),
    change: normalizeChange(value.change),
    probe_result: normalizeProbe(value.probe_result),
    runs: normalizeRuns(value.runs),
    metrics: normalizeMetrics(value.metrics),
    traced_confirmation: normalizeTracedConfirmation(value.traced_confirmation),
    verdict: value.verdict,
    rationale: str(value.rationale) ?? '',
    commit: str(value.commit),
    minutes: num(value.minutes),
  };
  return { trial, errors };
}

/** One JSON object per line; blank lines skipped; bad lines reported with their number. */
export function parseLedger(raw: string, file = 'ledger.jsonl'): { trials: Trial[]; errors: string[] } {
  const trials: Trial[] = [];
  const errors: string[] = [];
  raw.split(/\r?\n/).forEach((line, index) => {
    if (line.trim() === '') return;
    const n = index + 1;
    let parsed: unknown;
    try {
      parsed = JSON.parse(line);
    } catch (e) {
      errors.push(`${file}:${n}: invalid JSON (${errorMessage(e)}); skipped`);
      return;
    }
    const result = parseLedgerLine(parsed, n, file);
    errors.push(...result.errors);
    if (result.trial) trials.push(result.trial);
  });
  return { trials, errors };
}

// ---------------------------------------------------------------------------
// Loaders over the module-level imports
// ---------------------------------------------------------------------------

export function loadHistory(): { runs: Run[]; errors: string[] } {
  return historyFromModules(historyModules);
}

export function loadBaselines(): Baselines {
  return baselinesFromModules(baselineModules).baselines;
}

export function loadLedger(): { trials: Trial[]; errors: string[] } {
  return parseLedger(ledgerRaw);
}

/** Everything the UI needs; `loadErrors` collects every parser complaint in file order. */
export function loadDashboardData(): DashboardData {
  const history = historyFromModules(historyModules);
  const baselines = baselinesFromModules(baselineModules);
  const ledger = parseLedger(ledgerRaw);
  return {
    runs: history.runs,
    baselines: baselines.baselines,
    trials: ledger.trials,
    loadErrors: [...history.errors, ...baselines.errors, ...ledger.errors],
  };
}
