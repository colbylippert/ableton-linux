/**
 * Data contracts for the profiler dashboard.
 *
 * Section 1 mirrors the committed files byte-for-byte in shape — the schemas are owned
 * by `profiler/bin/history-add` (history records), the agent loop (ledger lines) and
 * `history-add --baseline` (baselines.json). Section 2 holds the dashboard-internal
 * contracts from DESIGN.md that the data layer (`src/data/*`) and the views share.
 *
 * Rules the types encode:
 *  - any measured value may be `null` when the run did not produce it (untraced runs have
 *    null interface metrics; idle sets have null dsp);
 *  - "outcome" metrics are only meaningful from untraced runs, "interface" metrics only from
 *    traced runs — the two are never mixed in one comparison;
 *  - virtualised runs (`virtualization !== 'none'`) carry no timing claims and are never
 *    compared with bare-metal runs.
 */

// ---------------------------------------------------------------------------
// 1. Schema types
// ---------------------------------------------------------------------------

/** `systemd-detect-virt` output recorded by the suite; `"none"` = bare metal. Open union. */
export type Virtualization = 'none' | 'vmware' | 'kvm' | (string & {});

/** `benchmark` = the canonical five Sets without a scenario; anything else is `diagnostic`. */
export type Structure = 'benchmark' | 'diagnostic';

export type TraceMode = 'off' | 'interface' | 'drilldown';

/** A/B arm of a trial run; `AA` marks one member of an A/A noise pair. */
export type Arm = 'A' | 'B' | 'AA';

/** Per-set measurement mode as written by bench-suite.sh / bench-run.sh. Open union. */
export type SetMode = 'playback' | 'idle-no-controller' | 'scenario' | (string & {});

export interface CallSiteTop {
  /** Join key as produced by the symbolizer, e.g. `"ntsync_wait|NtWaitForSingleObject|ntdll+0x7f3a1"`. */
  key: string;
  /** `share_of_lost_slack`, 0..1. */
  share: number;
  total_ns_in_late_blocks: number;
}

export interface HotspotTop {
  /** Thread role from roles.toml (e.g. `"ui"`, `"worker"`). */
  role: string;
  /** Crossing kind (syscall, unix-call, server request, ntsync wait, ...). */
  kind: string;
  /** Caller as `module+offset`. */
  caller: string;
  n: number;
  total_ns: number;
}

/** One Set's compact summary inside a history record. Every metric may be `null`. */
export interface SetMetrics {
  mode: SetMode;

  // Outcome metrics — authoritative only from untraced runs (`trace_mode === 'off'`).
  host_cpu_pct: number | null;
  live_cpu_pct_per_core: number | null;
  wine_cpu_pct_per_core: number | null;
  pipewire_cpu_pct: number | null;
  irq_per_s: number | null;
  softirq_per_s: number | null;
  pipewire_errors: number | null;
  xruns: number | null;
  dsp_avg: number | null;
  dsp_peak: number | null;
  audio_workers: number | null;
  voluntary_switches_per_s: number | null;

  // Interface metrics — only from traced runs; `null` on untraced runs.
  late_blocks: number | null;
  near_late_blocks: number | null;
  slack_p01_ns: number | null;
  slack_p50_ns: number | null;
  lost_slack_total_ns: number | null;
  call_sites_top: CallSiteTop[] | null;
  hotspots_non_audio_top: HotspotTop[] | null;
}

export interface RunRuntime {
  dist_version: string | null;
  source_tree_sha: string | null;
  dev_info: string | null;
}

/** One file under `profiler/history/runs/<run_id>.json` (`ableton-linux-profiler-history/v1`). */
export interface Run {
  schema?: 'ableton-linux-profiler-history/v1' | (string & {});
  run_id: string;
  tag: string;
  /** ISO 8601 UTC, e.g. `"2026-10-16T12:00:00Z"`. */
  started_at: string;
  machine_id: string;
  hostname: string;
  virtualization: Virtualization;
  /**
   * PipeWire node.name of the default sink when the run started (history-add, from
   * bench-report's endpoint identity). Part of the identity: runs on different interfaces
   * never compare. `null`/absent = unknown (records written before the field existed).
   */
  audio_device?: string | null;
  structure: Structure;
  scenario: string | null;
  trace_mode: TraceMode;
  duration_s: number | null;
  runtime: RunRuntime;
  /** Opt-in switches active for the run, `ENV_NAME -> value`. Empty object = none. */
  switches: Record<string, string>;
  harness_sha: string | null;
  commit: string | null;
  /** Trial id such as `"T0007"`, or `null` for runs outside a trial. */
  trial: string | null;
  arm: Arm | null;
  source_dir: string | null;
  sets: Record<string, SetMetrics>;
}

/**
 * `profiler/history/baselines.json`: `{ machine_id: { "<structure>/<scenario or ->": run_id } }`.
 * The inner key is `baselineKeyOf(run)` — e.g. `"benchmark/-"`, `"diagnostic/clip-launch-storm"`.
 */
export type Baselines = Record<string, Record<string, string>>;

export type Verdict = 'keep' | 'revert' | 'inconclusive' | 'tooling' | 'mechanism-confirmed';

export type ChangeKind = 'wine-patch' | 'pipeasio-patch' | 'launcher' | 'config' | (string & {});

export interface TrialEvidence {
  /** run_id the evidence came from. */
  run: string;
  set: string;
  /** Call-site join key (same format as `CallSiteTop.key`). */
  call_site: string;
  share_of_lost_slack: number;
}

export interface TrialChange {
  kind: ChangeKind;
  patch: string | null;
  /** Opt-in env switch, e.g. `"WINE_FOO=1"`. */
  switch: string | null;
  probe: string | null;
  note: string | null;
}

export interface ProbeResult {
  pass: number;
  fail: number;
  skip: number;
  log: string | null;
}

export interface AbPair {
  a: string;
  b: string;
}

export interface TrialRuns {
  /** A/A pairs, each `[run_id, run_id]`. */
  aa: [string, string][];
  /** Interleaved untraced A/B pairs in order. */
  abab: AbPair[];
  /** One traced run per arm confirming the mechanism, if done. */
  traced: AbPair | null;
}

export interface TrialSetMetrics {
  a_median: number | null;
  b_median: number | null;
  aa_spread: number | null;
  /** Raw difference `b_median - a_median` in the metric's unit (sign as recorded by the agent). */
  delta: number | null;
  /** `|delta| / aa_spread`; `>= 2` clears the acceptance gate. */
  ratio_to_spread: number | null;
}

export interface ArmValues {
  a: number | null;
  b: number | null;
}

export interface TrialMetrics {
  /** Primary metric key, e.g. `"late_blocks"`. */
  primary: string;
  per_set: Record<string, TrialSetMetrics>;
  xruns: ArmValues | null;
  cpu_live_pct: ArmValues | null;
}

export interface TracedConfirmation {
  call_site_share_before: number | null;
  after: number | null;
}

/** One line of `profiler/ledger.jsonl` (`ableton-linux-profiler-ledger/v1`). */
export interface Trial {
  schema: 'ableton-linux-profiler-ledger/v1' | (string & {});
  /** `"T0007"` */
  trial: string;
  /** ISO 8601 UTC. */
  date: string;
  /** `"bare-metal"` or `"vm:<virtualization>"`. */
  host: 'bare-metal' | `vm:${string}` | (string & {});
  branch: string;
  hypothesis: string;
  evidence: TrialEvidence[];
  change: TrialChange;
  probe_result: ProbeResult | null;
  runs: TrialRuns;
  metrics: TrialMetrics | null;
  traced_confirmation: TracedConfirmation | null;
  verdict: Verdict;
  rationale: string;
  commit: string | null;
  minutes: number | null;
}

// ---------------------------------------------------------------------------
// 2. Dashboard contracts (DESIGN.md) shared by src/data and the views
// ---------------------------------------------------------------------------

/** `lower` / `higher` = which direction is an improvement; `neutral` = informational only. */
export type MetricDirection = 'lower' | 'higher' | 'neutral';

/** Where a metric is authoritative: untraced (`outcome`) or traced (`interface`) runs. */
export type MetricSource = 'outcome' | 'interface';

/** Scalar keys of `SetMetrics` that the registry exposes directly. */
export type ScalarMetricKey = Exclude<keyof SetMetrics, 'mode' | 'call_sites_top' | 'hotspots_non_audio_top'>;

/** Metrics computed from a set + its run (per-minute rates need `duration_s`). */
export type DerivedMetricKey = 'late_blocks_per_min' | 'near_late_blocks_per_min';

export type MetricKey = ScalarMetricKey | DerivedMetricKey;

export interface MetricDef {
  key: MetricKey;
  /** Sentence-case label, no unit (the unit is appended by the formatter / axis). */
  label: string;
  /** Display unit after formatting: `"%"`, `"/s"`, `"/min"`, `"µs"`, `"ms"` or `""` (count). */
  unit: string;
  direction: MetricDirection;
  source: MetricSource;
  /** Decimals in the formatted display value. */
  decimals: number;
  /** Raw value in the schema's unit for this set/run; `null` when not produced. */
  value: (set: SetMetrics, run: Run) => number | null;
  /** Formats a raw (schema-unit) value for display; `null` renders as `"—"`. */
  format: (value: number | null) => string;
  /** Guard metric: any non-zero value is an automatic reject (xruns, PipeWire errors). */
  guard?: boolean;
  /** Short explanation shown in tooltips/tables. */
  description?: string;
}

/**
 * Everything a comparison must hold equal. Runs with different identities are never
 * compared (different machine, environment, structure/scenario or trace mode).
 */
export interface Identity {
  machine_id: string;
  virtualization: Virtualization;
  /** Audio interface (see `Run.audio_device`); absent and `null` both mean unknown. */
  audio_device?: string | null;
  structure: Structure;
  scenario: string | null;
  trace_mode: TraceMode;
}

export type EnvironmentFilter = 'all' | 'bare-metal' | 'virtualised';

/**
 * FilterBar state. `null` means "all". One row above the charts; every view re-renders
 * against the same slice. `switch` takes an `ENV_NAME` (runs where that switch is active)
 * or the sentinel `"none"` (runs with no switches).
 */
export interface FilterState {
  machine: string | null;
  environment: EnvironmentFilter;
  structure: Structure | null;
  scenario: string | null;
  traceMode: TraceMode | null;
  set: string | null;
  switch: string | null;
}

export const DEFAULT_FILTER: FilterState = {
  machine: null,
  environment: 'all',
  structure: null,
  scenario: null,
  traceMode: null,
  set: null,
  switch: null,
};

export type Significance = 'beyond' | 'within' | 'unknown';

/** A/A noise estimate in the metric's own unit (median over pairs of |a − b|). */
export interface NoiseSpread {
  spread: number;
  pairs: number;
}

export interface RunValue {
  runId: string;
  startedAt: string;
  value: number;
}

/** One (identity, set, metric) row from `computeGains`. */
export interface GainRow {
  identity: Identity;
  /** `identityKeyOf(identity)` — stable string for grouping. */
  identityKey: string;
  /** `"<structure>/<scenario or ->"` — the baselines.json key. */
  baselineKey: string;
  set: string;
  metric: MetricKey;
  direction: MetricDirection;
  source: MetricSource;
  baseline: RunValue | null;
  latest: RunValue | null;
  /** Best value since the baseline (inclusive), per `direction`; `null` for neutral metrics. */
  best: RunValue | null;
  /** `latest − baseline`, signed so that positive = improvement; `null` if either side is missing. */
  deltaAbs: number | null;
  /** `deltaAbs / |baseline|`; `null` when the baseline is 0 or missing. */
  deltaPct: number | null;
  spread: NoiseSpread | null;
  /** `|deltaAbs| > 2 × spread` → `beyond`; otherwise `within`; `unknown` without an A/A estimate. */
  significance: Significance;
  /** Number of runs that contributed after filtering. */
  runs: number;
}

/** Ledger line joined to the history records it references. */
export interface TrialJoin {
  trial: Trial;
  runs: {
    aa: [Run | null, Run | null][];
    abab: { a: Run | null; b: Run | null }[];
    traced: { a: Run | null; b: Run | null } | null;
  };
  /** run_ids the ledger references that have no history record. */
  missing: string[];
}

/** Everything the UI needs, loaded once at module evaluation (HMR re-evaluates on change). */
export interface DashboardData {
  runs: Run[];
  baselines: Baselines;
  trials: Trial[];
  /** Human-readable problems found while parsing (bad ledger lines, unknown schemas). */
  loadErrors: string[];
}
