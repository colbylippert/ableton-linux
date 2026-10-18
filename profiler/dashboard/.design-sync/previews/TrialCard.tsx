import { TrialCard } from 'profiler-dashboard';
import type { TrialCardProps } from 'profiler-dashboard';

type TrialJoin = TrialCardProps['join'];
type Trial = TrialCardProps['trials'][number];
type Run = TrialCardProps['runs'][number];
type SetMetrics = Run['sets'][string];

// ---------------------------------------------------------------------------
// History records: the laptop (bare metal, Scarlett 2i4), untraced 30 s benchmark windows.
// ---------------------------------------------------------------------------

const SETS = ['Benchmark_Zero', 'Benchmark_Empty', 'Benchmark_Inbuilts', 'Benchmark_Max4Live', 'Benchmark_VSTs'] as const;

/** `[DSP avg, DSP peak, Live CPU / core, PipeWire errors, xruns]`; the idle Zero Set has no DSP meter. */
type Outcome = [dspAvg: number | null, dspPeak: number | null, liveCpu: number, pipewireErrors: number, xruns: number];
type FiveSets = [zero: Outcome, empty: Outcome, inbuilts: Outcome, max4live: Outcome, vsts: Outcome];

function setMetrics([dsp_avg, dsp_peak, live_cpu_pct_per_core, pipewire_errors, xruns]: Outcome, idle: boolean): SetMetrics {
  return {
    mode: idle ? 'idle-no-controller' : 'playback',
    host_cpu_pct: null,
    live_cpu_pct_per_core,
    wine_cpu_pct_per_core: null,
    pipewire_cpu_pct: null,
    irq_per_s: null,
    softirq_per_s: null,
    pipewire_errors,
    xruns,
    dsp_avg,
    dsp_peak,
    audio_workers: 15,
    voluntary_switches_per_s: null,
    late_blocks: null,
    near_late_blocks: null,
    slack_p01_ns: null,
    slack_p50_ns: null,
    lost_slack_total_ns: null,
    call_sites_top: null,
    hotspots_non_audio_top: null,
  };
}

function run(runId: string, startedAt: string, commit: string, values: FiveSets, extra: Partial<Run> = {}): Run {
  return {
    schema: 'ableton-linux-profiler-history/v1',
    run_id: runId,
    tag: runId,
    started_at: startedAt,
    machine_id: 'd65f2ea0b816442a8d38bcb991cc7fd2',
    hostname: 'abletonlinux',
    virtualization: 'none',
    audio_device: 'alsa_output.usb-Focusrite_Scarlett_2i4_USB-00.pro-output-0',
    structure: 'benchmark',
    scenario: null,
    trace_mode: 'off',
    duration_s: 30,
    runtime: { dist_version: '2026.08.28.1', source_tree_sha: null, dev_info: null },
    switches: {},
    harness_sha: null,
    commit,
    trial: null,
    arm: null,
    source_dir: `~/.local/share/profiler/runs/${runId}/bench`,
    sets: Object.fromEntries(SETS.map((name, i) => [name, setMetrics(values[i]!, i === 0)])),
    ...extra,
  };
}

const AA_SHA = '20286fd71e5dc6498b2a7d3d9358f3fba52e0ac7';
const T1_SHA = '1507eb36c2f336334febdcaffb22da0d1995e4e5';
const T2_SHA = 'b8145eee48130d23e569e00623d127844383b44c';
const RT = { PIPEASIO_REALTIME: '1' };

const AA1 = run('aa-focusrite-1', '2026-10-18T00:05:34Z', AA_SHA, [[null, null, 38.54, 0, 0], [5.48, 40.35, 38.64, 0, 0], [10.49, 143.55, 58.49, 4, 1], [10.24, 99.38, 57.79, 3, 0], [9.46, 104.02, 52.36, 3, 0]]);
const AA2 = run('aa-focusrite-2', '2026-10-18T00:10:40Z', AA_SHA, [[null, null, 35.87, 1, 0], [5.88, 15.9, 42.6, 0, 0], [11.38, 87.53, 67.15, 7, 0], [10.79, 155.1, 64.45, 7, 0], [10.32, 114.38, 58.69, 5, 0]], { arm: 'AA' });
const AA3 = run('aa-focusrite-3', '2026-10-18T00:15:45Z', AA_SHA, [[null, null, 38.4, 1, 0], [5.47, 11.7, 38.24, 0, 0], [10.2, 129.82, 56.59, 7, 0], [9.97, 104.02, 56.99, 3, 0], [9.48, 106.8, 52.23, 4, 0]], { arm: 'AA' });

const T1 = { trial: 'T0001' } as const;
const T1A1 = run('trial-T0001-A1', '2026-10-18T00:22:24Z', T1_SHA, [[null, null, 36.64, 0, 0], [5.06, 20.17, 37.67, 0, 0], [11.3, 175.2, 65.25, 8, 0], [11.49, 135.38, 68.21, 6, 0], [9.42, 94.27, 51.76, 4, 0]], { ...T1, arm: 'A' });
const T1B1 = run('trial-T0001-B1', '2026-10-18T00:27:26Z', T1_SHA, [[null, null, 34.17, 0, 0], [5.42, 24.67, 39.4, 2, 0], [11.49, 179.62, 67.01, 10, 1], [10.97, 135.3, 65.28, 11, 1], [9.33, 141.15, 51.09, 5, 0]], { ...T1, arm: 'B' });
const T1A2 = run('trial-T0001-A2', '2026-10-18T00:32:31Z', T1_SHA, [[null, null, 38.5, 2, 0], [4.7, 73.35, 34.17, 0, 0], [10.44, 103.05, 59.42, 3, 0], [11.01, 103.2, 65.78, 11, 0], [9.29, 92.92, 50.53, 4, 0]], { ...T1, arm: 'A' });
const T1B2 = run('trial-T0001-B2', '2026-10-18T00:37:33Z', T1_SHA, [[null, null, 38.97, 0, 0], [4.65, 56.55, 34.31, 0, 0], [10.39, 101.85, 58.52, 7, 0], [11.94, 123.67, 72.74, 13, 1], [10.27, 127.65, 59.19, 8, 0]], { ...T1, arm: 'B' });
const T1A3 = run('trial-T0001-A3', '2026-10-18T00:42:37Z', T1_SHA, [[null, null, 38.47, 0, 0], [5.35, 53.7, 38.14, 1, 0], [9.92, 102.3, 55.32, 9, 0], [11.14, 105.3, 65.88, 7, 0], [10.9, 105.0, 63.65, 8, 0]], { ...T1, arm: 'A' });
const T1B3 = run('trial-T0001-B3', '2026-10-18T00:47:45Z', T1_SHA, [[null, null, 37.2, 0, 0], [5.39, 11.78, 39.77, 0, 0], [11.4, 102.97, 65.38, 8, 1], [10.31, 130.65, 60.22, 4, 0], [9.56, 101.32, 53.13, 5, 0]], { ...T1, arm: 'B' });

const T2 = { trial: 'T0002' } as const;
const T2A1 = run('trial-T0002-A1', '2026-10-18T00:56:22Z', T2_SHA, [[null, null, 38.0, 1, 0], [4.62, 11.92, 33.67, 0, 0], [9.86, 112.57, 54.86, 6, 0], [11.49, 114.9, 69.64, 11, 1], [10.29, 141.52, 58.72, 7, 0]], { ...T2, arm: 'A' });
const T2B1 = run('trial-T0002-B1', '2026-10-18T01:01:28Z', T2_SHA, [[null, null, 38.9, 0, 0], [5.93, 10.5, 41.83, 0, 0], [11.18, 117.6, 63.35, 5, 0], [9.69, 107.4, 56.69, 6, 0], [9.12, 90.82, 51.42, 1, 0]], { ...T2, arm: 'B', switches: RT });
const T2A2 = run('trial-T0002-A2', '2026-10-18T01:06:36Z', T2_SHA, [[null, null, 38.57, 2, 0], [5.75, 15.67, 41.6, 0, 0], [10.68, 111.15, 61.28, 3, 0], [10.91, 130.8, 64.18, 11, 1], [10.14, 100.95, 56.62, 3, 1]], { ...T2, arm: 'A' });
const T2B2 = run('trial-T0002-B2', '2026-10-18T01:11:44Z', T2_SHA, [[null, null, 38.7, 0, 0], [5.44, 10.12, 38.17, 0, 0], [11.22, 109.88, 64.68, 5, 0], [9.98, 104.4, 56.09, 6, 0], [10.97, 106.2, 64.61, 0, 0]], { ...T2, arm: 'B', switches: RT });
const T2A3 = run('trial-T0002-A3', '2026-10-18T01:16:52Z', T2_SHA, [[null, null, 38.5, 1, 0], [5.16, 19.35, 37.11, 0, 0], [9.82, 119.32, 54.42, 5, 0], [11.43, 93.22, 68.38, 14, 0], [10.19, 115.8, 58.32, 3, 0]], { ...T2, arm: 'A' });
const T2B3 = run('trial-T0002-B3', '2026-10-18T01:21:51Z', '1fd348ecf177792fec7f0f497c179bac6d5aeb02', [[null, null, 41.47, 0, 0], [4.91, 9.82, 34.54, 0, 0], [10.57, 112.8, 63.05, 2, 0], [11.09, 98.47, 65.18, 3, 0], [10.11, 98.32, 58.65, 4, 0]], { ...T2, arm: 'B', switches: RT });

const HISTORY: Run[] = [AA1, AA2, AA3, T1A1, T1B1, T1A2, T1B2, T1A3, T1B3, T2A1, T2B1, T2A2, T2B2, T2A3, T2B3];

// ---------------------------------------------------------------------------
// Ledger lines (profiler/ledger.jsonl)
// ---------------------------------------------------------------------------

const AA_PAIRS: [string, string][] = [
  ['aa-focusrite-1', 'aa-focusrite-2'],
  ['aa-focusrite-2', 'aa-focusrite-3'],
];
const abab = (trial: string) => [1, 2, 3].map((i) => ({ a: `trial-${trial}-A${i}`, b: `trial-${trial}-B${i}` }));

const T0001: Trial = {
  schema: 'ableton-linux-profiler-ledger/v1',
  trial: 'T0001',
  date: '2026-10-18T00:22:24Z',
  host: 'bare-metal',
  branch: 'profiler',
  hypothesis:
    'Deep CPU idle states (C2 127 us, C3 1048 us exit latency) on the audio cores add wake-up latency that makes audio blocks late; holding PM QoS /dev/cpu_dma_latency at 10 us (C1 only) lowers Live’s DSP load, its peaks and PipeWire errors.',
  evidence: [],
  change: { kind: 'config', patch: null, switch: '/dev/cpu_dma_latency = 10 us held for the run (PM QoS)', probe: null, note: 'profiler/plans/resume-plan.md (Proving gains)' },
  probe_result: null,
  runs: { aa: AA_PAIRS, abab: abab('T0001'), traced: null },
  metrics: {
    primary: 'dsp_avg',
    per_set: {
      Benchmark_Zero: { a_median: null, b_median: null, aa_spread: null, delta: null, ratio_to_spread: null },
      Benchmark_Empty: { a_median: 5.06, b_median: 5.39, aa_spread: 0.41, delta: 0.33, ratio_to_spread: 0.8 },
      Benchmark_Inbuilts: { a_median: 10.44, b_median: 11.4, aa_spread: 1.18, delta: 0.96, ratio_to_spread: 0.81 },
      Benchmark_Max4Live: { a_median: 11.14, b_median: 10.97, aa_spread: 0.82, delta: -0.17, ratio_to_spread: 0.21 },
      Benchmark_VSTs: { a_median: 9.42, b_median: 9.56, aa_spread: 0.86, delta: 0.14, ratio_to_spread: 0.16 },
    },
    xruns: { a: 63, b: 73 },
    cpu_live_pct: { a: 60.6, b: 61.4 },
  },
  traced_confirmation: null,
  verdict: 'revert',
  rationale:
    'No Set improved beyond the A/A spread on DSP average or typical peak; PipeWire errors 63 (A) vs 73 (B). The cap held: 0 C2/C3 entries during B runs vs about 7 million per A run. Deep idle states are not what causes the dropouts.',
  commit: '532305f',
  minutes: 40,
};

const T0002: Trial = {
  schema: 'ableton-linux-profiler-ledger/v1',
  trial: 'T0002',
  date: '2026-10-18T00:56:22Z',
  host: 'bare-metal',
  branch: 'profiler',
  hypothesis:
    'pipeasio-rt, the thread that starts every audio block, runs SCHED_OTHER under PipeASIO’s shipped realtime=false while all of Live’s threads run SCHED_RR 10, so it waits about 650 ms per 30 s for a CPU; PIPEASIO_REALTIME=1 removes that wait and with it late blocks and dropouts.',
  evidence: [],
  change: { kind: 'config', patch: null, switch: 'PIPEASIO_REALTIME=1', probe: null, note: 'profiler/plans/resume-plan.md (T0002)' },
  probe_result: null,
  runs: { aa: AA_PAIRS, abab: abab('T0002'), traced: null },
  metrics: {
    primary: 'dsp_avg',
    per_set: {
      Benchmark_Zero: { a_median: null, b_median: null, aa_spread: null, delta: null, ratio_to_spread: null },
      Benchmark_Empty: { a_median: 5.16, b_median: 5.44, aa_spread: 0.41, delta: 0.28, ratio_to_spread: 0.68 },
      Benchmark_Inbuilts: { a_median: 9.86, b_median: 11.18, aa_spread: 1.18, delta: 1.33, ratio_to_spread: 1.13 },
      Benchmark_Max4Live: { a_median: 11.43, b_median: 9.98, aa_spread: 0.82, delta: -1.45, ratio_to_spread: 1.77 },
      Benchmark_VSTs: { a_median: 10.19, b_median: 10.11, aa_spread: 0.86, delta: -0.08, ratio_to_spread: 0.09 },
    },
    xruns: { a: 67, b: 32 },
    cpu_live_pct: { a: 60.7, b: 60.4 },
  },
  traced_confirmation: null,
  verdict: 'inconclusive',
  rationale:
    'Mechanism confirmed: pipeasio-rt ran SCHED_FIFO 15 in every B run and its CPU wait fell from 595-706 ms to 1.2-2.4 ms per 30 s. Dropouts fell (PipeWire errors 67 → 32), but Live’s DSP meter is mixed within about 2× the A/A spread. Confirm with longer, dropout-focused windows (T0003).',
  commit: '1fd348e',
  minutes: 42,
};

const LEDGER: Trial[] = [T0001, T0002];

// ---------------------------------------------------------------------------
// Joins (what joinTrials() resolves for the Trials tab)
// ---------------------------------------------------------------------------

const AA_JOINED: [Run | null, Run | null][] = [
  [AA1, AA2],
  [AA2, AA3],
];

const T0002_JOIN: TrialJoin = {
  trial: T0002,
  runs: { aa: AA_JOINED, abab: [{ a: T2A1, b: T2B1 }, { a: T2A2, b: T2B2 }, { a: T2A3, b: T2B3 }], traced: null },
  missing: [],
};

const T0001_JOIN: TrialJoin = {
  trial: T0001,
  runs: { aa: AA_JOINED, abab: [{ a: T1A1, b: T1B1 }, { a: T1A2, b: T1B2 }, { a: T1A3, b: T1B3 }], traced: null },
  missing: [],
};

/** T0001's ledger line landed before history-add ran for its ABAB runs. */
const T0001_UNRECORDED: TrialJoin = {
  trial: T0001,
  runs: { aa: AA_JOINED, abab: [{ a: null, b: null }, { a: null, b: null }, { a: null, b: null }], traced: null },
  missing: abab('T0001').flatMap((p) => [p.a, p.b]),
};

/** The newest ledger line as the Trials tab opens it: ABAB pairs per Set on the ledger primary (DSP load avg), guard chips for B-run dropouts, no traced confirmation yet. */
export const PipeAsioRealtimeInconclusive = () => <TrialCard join={T0002_JOIN} runs={HISTORY} trials={LEDGER} />;

/** The reverted idle-state cap: same layout, revert verdict, the dropout guard tripped on every B run. */
export const IdleStateCapReverted = () => <TrialCard join={T0001_JOIN} runs={HISTORY} trials={LEDGER} />;

/** Run references without history records: missing-record chips, no ABAB charts. */
export const AbabRecordsMissing = () => <TrialCard join={T0001_UNRECORDED} runs={[AA1, AA2, AA3]} trials={LEDGER} />;
