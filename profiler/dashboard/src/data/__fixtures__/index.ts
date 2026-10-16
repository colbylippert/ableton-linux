/**
 * Test fixtures: a small but complete history (two machines, five identities, 19 runs),
 * its baselines.json and a ledger with a kept trial, a reverted trial, a tooling trial,
 * one malformed line and one line with a foreign schema.
 *
 * The run files under `./runs/` are loaded through the same glob + parser path as the real
 * data (`historyFromModules`), so the loader is exercised by every test that uses them.
 *
 * Machines:   m1-studio (bare metal, hostname "studio") · m2-vm (vmware, "abletonlinux")
 * Identities: m1 benchmark untraced · m1 benchmark traced · m1 diagnostic
 *             "clip-launch-storm" traced · m2 benchmark untraced · m2 benchmark traced
 * Trials:     T0001 tooling (vm, evidence only) · T0007 keep (A/A pair, ABAB × 3 with
 *             WINE_FOO=1 on arm B, traced confirmation) · T0008 revert (one ABAB pair in
 *             history, one missing; arm B trips the xrun guard)
 * Nulls:      20261014T100000Z-nulls has null duration/runtime/commit/harness/source_dir
 *             and a Set whose every metric is null.
 */
import type { Baselines, Identity, Run, SetMetrics, Trial } from '../types';
import { historyFromModules, parseLedger } from '../load';
import baselinesJson from './baselines.json';
import ledgerRaw from './ledger.jsonl?raw';

const modules = import.meta.glob('./runs/*.json', { eager: true, import: 'default' });

export const fixtureModules: Record<string, unknown> = modules;
export const fixtureHistory = historyFromModules(modules);
export const fixtureRuns: readonly Run[] = fixtureHistory.runs;
export const fixtureBaselines: Baselines = baselinesJson;
export const fixtureLedgerRaw: string = ledgerRaw;
export const fixtureLedger = parseLedger(ledgerRaw);
export const fixtureTrials: readonly Trial[] = fixtureLedger.trials;

export const M1 = 'm1-studio';
export const M2 = 'm2-vm';

export const SET = {
  zero: 'Benchmark_Zero',
  empty: 'Benchmark_Empty',
  inbuilts: 'Benchmark_Inbuilts',
  max4live: 'Benchmark_Max4Live',
  vsts: 'Benchmark_VSTs',
} as const;

export const CALL_SITE = {
  ntsync: 'ntsync_wait|NtWaitForSingleObject|ntdll+0x7f3a1',
  readFile: 'unix_call|NtReadFile|ntdll+0x1a2b3',
  setEvent: 'server_req|NtSetEvent|ntdll+0x44c10',
} as const;

export const RUN = {
  baseline: '20261010T100000Z-baseline',
  baselineTraced: '20261010T120000Z-baseline-traced',
  aa1: '20261011T090000Z-T0007-aa1',
  aa2: '20261011T093000Z-T0007-aa2',
  a1: '20261011T100000Z-T0007-a1',
  b1: '20261011T103000Z-T0007-b1',
  a2: '20261011T110000Z-T0007-a2',
  b2: '20261011T113000Z-T0007-b2',
  a3: '20261011T120000Z-T0007-a3',
  b3: '20261011T123000Z-T0007-b3',
  tracedA: '20261011T133000Z-T0007-traced-a',
  tracedB: '20261011T140000Z-T0007-traced-b',
  t8a1: '20261012T100000Z-T0008-a1',
  t8b1: '20261012T103000Z-T0008-b1',
  t8a2Missing: '20261012T110000Z-T0008-a2',
  t8b2Missing: '20261012T113000Z-T0008-b2',
  scenario1: '20261012T150000Z-scenario-clip',
  scenario2: '20261013T150000Z-scenario-clip-2',
  nulls: '20261014T100000Z-nulls',
  vmBaseline: '20261009T100000Z-vm-baseline',
  vmTraced: '20261009T110000Z-vm-traced',
} as const;

export const ID_M1_OFF: Identity = { machine_id: M1, virtualization: 'none', structure: 'benchmark', scenario: null, trace_mode: 'off' };
export const ID_M1_IFACE: Identity = { machine_id: M1, virtualization: 'none', structure: 'benchmark', scenario: null, trace_mode: 'interface' };
export const ID_M1_SCENARIO: Identity = { machine_id: M1, virtualization: 'none', structure: 'diagnostic', scenario: 'clip-launch-storm', trace_mode: 'interface' };
export const ID_M2_OFF: Identity = { machine_id: M2, virtualization: 'vmware', structure: 'benchmark', scenario: null, trace_mode: 'off' };
export const ID_M2_IFACE: Identity = { machine_id: M2, virtualization: 'vmware', structure: 'benchmark', scenario: null, trace_mode: 'interface' };

export function runById(id: string): Run {
  const run = fixtureRuns.find((r) => r.run_id === id);
  if (!run) throw new Error(`fixture run "${id}" is missing`);
  return run;
}

export function trialById(id: string): Trial {
  const trial = fixtureTrials.find((t) => t.trial === id);
  if (!trial) throw new Error(`fixture trial "${id}" is missing`);
  return trial;
}

/** A Set whose every metric is null (override what the test needs). */
export function makeSet(overrides: Partial<SetMetrics> = {}): SetMetrics {
  return {
    mode: 'playback',
    host_cpu_pct: null,
    live_cpu_pct_per_core: null,
    wine_cpu_pct_per_core: null,
    pipewire_cpu_pct: null,
    irq_per_s: null,
    softirq_per_s: null,
    pipewire_errors: null,
    xruns: null,
    dsp_avg: null,
    dsp_peak: null,
    audio_workers: null,
    voluntary_switches_per_s: null,
    late_blocks: null,
    near_late_blocks: null,
    slack_p01_ns: null,
    slack_p50_ns: null,
    lost_slack_total_ns: null,
    call_sites_top: null,
    hotspots_non_audio_top: null,
    ...overrides,
  };
}

let counter = 0;

/** A clean untraced m1 benchmark run with one Set (`Benchmark_VSTs`, live CPU 40). */
export function makeRun(overrides: Partial<Run> = {}): Run {
  counter += 1;
  const n = String(counter).padStart(2, '0');
  return {
    schema: 'ableton-linux-profiler-history/v1',
    run_id: `20261101T${n}0000Z-synthetic`,
    tag: 'synthetic',
    started_at: `2026-11-01T${n}:00:00Z`,
    machine_id: M1,
    hostname: 'studio',
    virtualization: 'none',
    structure: 'benchmark',
    scenario: null,
    trace_mode: 'off',
    duration_s: 120,
    runtime: { dist_version: '11.13', source_tree_sha: 'abc', dev_info: null },
    switches: {},
    harness_sha: 'h',
    commit: 'c',
    trial: null,
    arm: null,
    source_dir: null,
    sets: { [SET.vsts]: makeSet({ live_cpu_pct_per_core: 40, xruns: 0, pipewire_errors: 0, audio_workers: 8 }) },
    ...overrides,
  };
}

/** A minimal kept trial with no runs (override `runs`, `evidence`, `verdict`, …). */
export function makeTrial(overrides: Partial<Trial> = {}): Trial {
  return {
    schema: 'ableton-linux-profiler-ledger/v1',
    trial: 'T0100',
    date: '2026-11-02T10:00:00Z',
    host: 'bare-metal',
    branch: 'trial/T0100-synthetic',
    hypothesis: 'synthetic',
    evidence: [],
    change: { kind: 'config', patch: null, switch: null, probe: null, note: null },
    probe_result: null,
    runs: { aa: [], abab: [], traced: null },
    metrics: null,
    traced_confirmation: null,
    verdict: 'keep',
    rationale: '',
    commit: null,
    minutes: null,
    ...overrides,
  };
}
