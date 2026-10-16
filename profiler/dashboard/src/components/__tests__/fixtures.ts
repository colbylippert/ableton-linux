/**
 * History / ledger fixtures for the view smoke tests. One bare-metal machine (`m1`) with
 * an untraced baseline, an A/A pair, an A/B trial (switch on arm B), a later clean run, a
 * traced baseline + traced follow-up and a diagnostic scenario run; one virtualised
 * machine (`m2`); a kept and a reverted ledger line.
 */
import type { Baselines, DashboardData, Run, SetMetrics, Trial } from '../../data/types';

export function makeSet(overrides: Partial<SetMetrics> = {}): SetMetrics {
  return {
    mode: 'playback',
    host_cpu_pct: 32.5,
    live_cpu_pct_per_core: 41.2,
    wine_cpu_pct_per_core: 12.1,
    pipewire_cpu_pct: 3.4,
    irq_per_s: 1204,
    softirq_per_s: 2210,
    pipewire_errors: 0,
    xruns: 0,
    dsp_avg: 18.2,
    dsp_peak: 44.1,
    audio_workers: 6,
    voluntary_switches_per_s: 5400,
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

export function makeTracedSet(overrides: Partial<SetMetrics> = {}): SetMetrics {
  return makeSet({
    late_blocks: 12,
    near_late_blocks: 40,
    slack_p01_ns: 812_000,
    slack_p50_ns: 2_100_000,
    lost_slack_total_ns: 48_000_000,
    call_sites_top: [
      { key: 'ntsync_wait|NtWaitForSingleObject|ntdll+0x7f3a1', share: 0.62, total_ns_in_late_blocks: 30_000_000 },
      { key: 'server|select|ntdll+0x11a20', share: 0.21, total_ns_in_late_blocks: 10_000_000 },
    ],
    hotspots_non_audio_top: [{ role: 'ui', kind: 'syscall', caller: 'user32+0x1234', n: 120, total_ns: 9_000_000 }],
    ...overrides,
  });
}

export function makeRun(overrides: Partial<Run> = {}): Run {
  return {
    schema: 'ableton-linux-profiler-history/v1',
    run_id: '20261010T100000Z-baseline',
    tag: 'baseline',
    started_at: '2026-10-10T10:00:00Z',
    machine_id: 'm1',
    hostname: 'bench-box',
    virtualization: 'none',
    structure: 'benchmark',
    scenario: null,
    trace_mode: 'off',
    duration_s: 120,
    runtime: { dist_version: '11.13', source_tree_sha: 'abc123', dev_info: null },
    switches: {},
    harness_sha: 'h1',
    commit: 'c1',
    trial: null,
    arm: null,
    source_dir: 'runs/x',
    sets: {
      Benchmark_Zero: makeSet({ live_cpu_pct_per_core: 20.0 }),
      Benchmark_VSTs: makeSet({ live_cpu_pct_per_core: 41.2 }),
    },
    ...overrides,
  };
}

const untraced = (runId: string, startedAt: string, tag: string, zeroCpu: number, vstCpu: number, extra: Partial<Run> = {}): Run =>
  makeRun({
    run_id: runId,
    started_at: startedAt,
    tag,
    sets: { Benchmark_Zero: makeSet({ live_cpu_pct_per_core: zeroCpu }), Benchmark_VSTs: makeSet({ live_cpu_pct_per_core: vstCpu }) },
    ...extra,
  });

const traced = (runId: string, startedAt: string, tag: string, zeroLate: number, vstLate: number, extra: Partial<Run> = {}): Run =>
  makeRun({
    run_id: runId,
    started_at: startedAt,
    tag,
    trace_mode: 'interface',
    sets: {
      Benchmark_Zero: makeTracedSet({ late_blocks: zeroLate, slack_p01_ns: 900_000 }),
      Benchmark_VSTs: makeTracedSet({ late_blocks: vstLate, slack_p01_ns: 600_000 }),
    },
    ...extra,
  });

export const RUN_BASELINE = untraced('20261010T100000Z-baseline', '2026-10-10T10:00:00Z', 'baseline', 20.0, 41.2);
export const RUN_AA1 = untraced('20261011T100000Z-aa1', '2026-10-11T10:00:00Z', 'aa', 20.2, 41.0, { trial: 'T0007', arm: 'AA' });
export const RUN_AA2 = untraced('20261011T120000Z-aa2', '2026-10-11T12:00:00Z', 'aa', 19.9, 41.5, { trial: 'T0007', arm: 'AA' });
export const RUN_A = untraced('20261012T100000Z-a', '2026-10-12T10:00:00Z', 'T0007-A', 20.1, 41.3, { trial: 'T0007', arm: 'A' });
export const RUN_B = untraced('20261012T120000Z-b', '2026-10-12T12:00:00Z', 'T0007-B', 17.0, 36.0, { trial: 'T0007', arm: 'B', switches: { WINE_FOO: '1' } });
export const RUN_LATEST = untraced('20261014T100000Z-after', '2026-10-14T10:00:00Z', 'after', 17.2, 36.4, { commit: 'c2' });
export const RUN_TRACED_BASELINE = traced('20261010T140000Z-traced', '2026-10-10T14:00:00Z', 'traced-baseline', 12, 30);
export const RUN_TRACED_LATEST = traced('20261013T100000Z-traced', '2026-10-13T10:00:00Z', 'traced-after', 6, 22, { switches: { WINE_FOO: '1' }, trial: 'T0007', arm: 'B' });
export const RUN_SCENARIO = untraced('20261012T150000Z-scn', '2026-10-12T15:00:00Z', 'scenario', 25.0, 50.0, { structure: 'diagnostic', scenario: 'clip-launch-storm' });
export const RUN_VM = untraced('20261009T100000Z-vm', '2026-10-09T10:00:00Z', 'vm-baseline', 30.0, 60.0, {
  machine_id: 'm2',
  hostname: 'abletonlinux',
  virtualization: 'vmware',
});

export const FIXTURE_RUNS: Run[] = [
  RUN_VM,
  RUN_BASELINE,
  RUN_TRACED_BASELINE,
  RUN_AA1,
  RUN_AA2,
  RUN_A,
  RUN_B,
  RUN_SCENARIO,
  RUN_TRACED_LATEST,
  RUN_LATEST,
];

export const FIXTURE_BASELINES: Baselines = { m1: { 'benchmark/-': RUN_BASELINE.run_id } };

export const FIXTURE_TRIALS: Trial[] = [
  {
    schema: 'ableton-linux-profiler-ledger/v1',
    trial: 'T0007',
    date: '2026-10-12T13:00:00Z',
    host: 'bare-metal',
    branch: 'profiler',
    hypothesis: 'APC fast path removes the ntsync wait crossing',
    evidence: [{ run: RUN_TRACED_BASELINE.run_id, set: 'Benchmark_Zero', call_site: 'ntsync_wait|NtWaitForSingleObject|ntdll+0x7f3a1', share_of_lost_slack: 0.62 }],
    change: { kind: 'wine-patch', patch: '0201-apc-fastpath.patch', switch: 'WINE_FOO=1', probe: null, note: null },
    probe_result: { pass: 5, fail: 0, skip: 1, log: null },
    runs: { aa: [[RUN_AA1.run_id, RUN_AA2.run_id]], abab: [{ a: RUN_A.run_id, b: RUN_B.run_id }], traced: { a: RUN_TRACED_BASELINE.run_id, b: RUN_TRACED_LATEST.run_id } },
    metrics: {
      primary: 'late_blocks',
      per_set: { Benchmark_Zero: { a_median: 20.1, b_median: 17.0, aa_spread: 0.3, delta: -3.1, ratio_to_spread: 10.3 } },
      xruns: { a: 0, b: 0 },
      cpu_live_pct: { a: 20.1, b: 17.0 },
    },
    traced_confirmation: { call_site_share_before: 0.62, after: 0.2 },
    verdict: 'keep',
    rationale: 'Cleared 2× spread on every Set',
    commit: 'c2',
    minutes: 95,
  },
  {
    schema: 'ableton-linux-profiler-ledger/v1',
    trial: 'T0008',
    date: '2026-10-15T09:00:00Z',
    host: 'bare-metal',
    branch: 'profiler',
    hypothesis: 'Bigger select batches',
    evidence: [],
    change: { kind: 'config', patch: null, switch: 'WINE_BAR=1', probe: null, note: null },
    probe_result: null,
    runs: { aa: [], abab: [], traced: null },
    metrics: null,
    traced_confirmation: null,
    verdict: 'revert',
    rationale: 'Regressed VSTs',
    commit: null,
    minutes: 40,
  },
];

export const FIXTURE_DATA: DashboardData = { runs: FIXTURE_RUNS, baselines: FIXTURE_BASELINES, trials: FIXTURE_TRIALS, loadErrors: [] };

export const EMPTY_DATA: DashboardData = { runs: [], baselines: {}, trials: [], loadErrors: [] };
