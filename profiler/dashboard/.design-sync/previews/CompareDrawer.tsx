import { CompareDrawer } from 'profiler-dashboard';
import type { CompareDrawerProps } from 'profiler-dashboard';

type Run = CompareDrawerProps['a'];
type Trial = CompareDrawerProps['trials'][number];
type SetMetrics = Run['sets'][string];

const noop = () => {};

const LAPTOP = 'd65f2ea0b816442a8d38bcb991cc7fd2';
const SCARLETT = 'alsa_output.usb-Focusrite_Scarlett_2i4_USB-00.pro-output-0';

function metrics(m: Partial<SetMetrics>): SetMetrics {
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
    ...m,
  };
}

/** `[DSP avg, Live CPU / core, PipeWire errors, xruns]` per heavy Set, untraced 30 s windows. */
type Outcome = [dspAvg: number, liveCpu: number, pipewireErrors: number, xruns: number];

function outcome(inbuilts: Outcome, max4live: Outcome, vsts: Outcome): Run['sets'] {
  const set = ([dsp_avg, live_cpu_pct_per_core, pipewire_errors, xruns]: Outcome) => metrics({ dsp_avg, live_cpu_pct_per_core, pipewire_errors, xruns });
  return { Benchmark_Inbuilts: set(inbuilts), Benchmark_Max4Live: set(max4live), Benchmark_VSTs: set(vsts) };
}

function run(runId: string, startedAt: string, sets: Run['sets'], extra: Partial<Run> = {}): Run {
  return {
    schema: 'ableton-linux-profiler-history/v1',
    run_id: runId,
    tag: runId,
    started_at: startedAt,
    machine_id: LAPTOP,
    hostname: 'abletonlinux',
    virtualization: 'none',
    audio_device: SCARLETT,
    structure: 'benchmark',
    scenario: null,
    trace_mode: 'off',
    duration_s: 30,
    runtime: { dist_version: '2026.08.28.1', source_tree_sha: null, dev_info: null },
    switches: {},
    harness_sha: null,
    commit: 'b8145eee48130d23e569e00623d127844383b44c',
    trial: null,
    arm: null,
    source_dir: `~/.local/share/profiler/runs/${runId}/bench`,
    sets,
    ...extra,
  };
}

// --- T0002 arm A vs arm B, with the identity's A/A runs for the noise spread ---------------

const AA_SHA = '20286fd71e5dc6498b2a7d3d9358f3fba52e0ac7';
const AA1 = run('aa-focusrite-1', '2026-10-18T00:05:34Z', outcome([10.49, 58.49, 4, 1], [10.24, 57.79, 3, 0], [9.46, 52.36, 3, 0]), { commit: AA_SHA });
const AA2 = run('aa-focusrite-2', '2026-10-18T00:10:40Z', outcome([11.38, 67.15, 7, 0], [10.79, 64.45, 7, 0], [10.32, 58.69, 5, 0]), { commit: AA_SHA, arm: 'AA' });
const AA3 = run('aa-focusrite-3', '2026-10-18T00:15:45Z', outcome([10.2, 56.59, 7, 0], [9.97, 56.99, 3, 0], [9.48, 52.23, 4, 0]), { commit: AA_SHA, arm: 'AA' });
const T2A1 = run('trial-T0002-A1', '2026-10-18T00:56:22Z', outcome([9.86, 54.86, 6, 0], [11.49, 69.64, 11, 1], [10.29, 58.72, 7, 0]), { trial: 'T0002', arm: 'A' });
const T2B1 = run('trial-T0002-B1', '2026-10-18T01:01:28Z', outcome([11.18, 63.35, 5, 0], [9.69, 56.69, 6, 0], [9.12, 51.42, 1, 0]), {
  trial: 'T0002',
  arm: 'B',
  switches: { PIPEASIO_REALTIME: '1' },
});

/** The ledger line whose explicit A/A pairs give the noise spread of this identity. */
const T0002: Trial = {
  schema: 'ableton-linux-profiler-ledger/v1',
  trial: 'T0002',
  date: '2026-10-18T00:56:22Z',
  host: 'bare-metal',
  branch: 'profiler',
  hypothesis: 'pipeasio-rt runs SCHED_OTHER under PipeASIO’s shipped realtime=false while Live runs SCHED_RR 10; PIPEASIO_REALTIME=1 removes its CPU wait and with it late blocks and dropouts.',
  evidence: [],
  change: { kind: 'config', patch: null, switch: 'PIPEASIO_REALTIME=1', probe: null, note: 'profiler/plans/resume-plan.md (T0002)' },
  probe_result: null,
  runs: {
    aa: [
      ['aa-focusrite-1', 'aa-focusrite-2'],
      ['aa-focusrite-2', 'aa-focusrite-3'],
    ],
    abab: [
      { a: 'trial-T0002-A1', b: 'trial-T0002-B1' },
      { a: 'trial-T0002-A2', b: 'trial-T0002-B2' },
      { a: 'trial-T0002-A3', b: 'trial-T0002-B3' },
    ],
    traced: null,
  },
  metrics: null,
  traced_confirmation: null,
  verdict: 'inconclusive',
  rationale: 'Dropouts fell (PipeWire errors 67 → 32) but the DSP meter stays within about 2× the A/A spread.',
  commit: '1fd348e',
  minutes: 42,
};

// --- Traced diagnostic runs (interface metrics; no traced A/A pairs yet) ---------------------

const B5_SHA = '4f5728e1450b69f512059d7a1ab756543be3d980';
const iface = (late: number, nearLate: number, p01: number, p50: number, lost: number) =>
  metrics({ late_blocks: late, near_late_blocks: nearLate, slack_p01_ns: p01, slack_p50_ns: p50, lost_slack_total_ns: lost, dsp_avg: null });

const VERIFIER_TRACED = run(
  'b5c-verifier-traced',
  '2026-10-17T20:19:51Z',
  { Benchmark_Inbuilts: iface(12, 5, 796554, 1058248, 12524325), Benchmark_VSTs: iface(10, 5, 804566, 1081386, 6046617) },
  { tag: 'b5c-traced', structure: 'diagnostic', trace_mode: 'interface', commit: B5_SHA },
);
const FINAL_TRACED = run(
  'b5c-final-traced',
  '2026-10-17T20:44:57Z',
  { Benchmark_Inbuilts: iface(9, 6, 837330, 1069330, 5786690), Benchmark_VSTs: iface(9, 5, 825194, 1146731, 4766908) },
  { structure: 'diagnostic', trace_mode: 'interface', commit: B5_SHA },
);
const FINAL_UNTRACED = run(
  'b5c-final-untraced',
  '2026-10-17T20:42:50Z',
  {
    Benchmark_Inbuilts: metrics({ dsp_avg: 10.79, dsp_peak: 122.4, live_cpu_pct_per_core: 62.78, pipewire_errors: 5, xruns: 1 }),
    Benchmark_VSTs: metrics({ dsp_avg: 10.85, dsp_peak: 116.92, live_cpu_pct_per_core: 62.75, pipewire_errors: 6, xruns: 0 }),
  },
  { structure: 'diagnostic', commit: B5_SHA },
);

// --- Two runs on the retired VMware guest ----------------------------------------------------

const VM = { machine_id: '5c1e0a77d02b4f6e9a3c6b2d8e4f1a09', hostname: 'abletonlinux-vm', virtualization: 'vmware', audio_device: null, commit: 'c41d9e2b7a0f5e8d3c6b1a4f9e2d7c0b5a8f3e61' };
const VM_A = run('20261009T140210Z-vm-baseline', '2026-10-09T14:02:10Z', { Benchmark_VSTs: metrics({ dsp_avg: 31.6, dsp_peak: 188.4, live_cpu_pct_per_core: 92.3, pipewire_errors: 41, xruns: 6 }) }, { ...VM, tag: 'vm-baseline' });
const VM_B = run('20261009T143655Z-vm-ntsync', '2026-10-09T14:36:55Z', { Benchmark_VSTs: metrics({ dsp_avg: 29.8, dsp_peak: 201.7, live_cpu_pct_per_core: 90.1, pipewire_errors: 37, xruns: 5 }) }, { ...VM, tag: 'vm-ntsync' });

/** T0002's first ABAB pair: per-Set Δ with the A/A spread of aa-focusrite-1..3; ▲ beyond noise, ≈ within, ✗ guard rejects. */
export const TrialArmsAgainstNoise = () => (
  <CompareDrawer a={T2A1} b={T2B1} runs={[AA1, AA2, AA3, T2A1, T2B1]} trials={[T0002]} onSwap={noop} onClose={noop} />
);

/** Two traced diagnostic runs: interface metrics only, and no traced A/A pairs, so every status is "no A/A data". */
export const TracedRunsNoAaData = () => (
  <CompareDrawer a={VERIFIER_TRACED} b={FINAL_TRACED} runs={[VERIFIER_TRACED, FINAL_TRACED]} trials={[T0002]} onSwap={noop} onClose={noop} />
);

/** An untraced and a traced run never compare: the identity guard refuses with the reason. */
export const RefusedTraceModeMismatch = () => (
  <CompareDrawer a={FINAL_UNTRACED} b={FINAL_TRACED} runs={[FINAL_UNTRACED, FINAL_TRACED]} trials={[]} onSwap={noop} onClose={noop} />
);

/** Two runs on the VMware guest compare, but under the NO TIMING CLAIMS ribbon. */
export const VirtualisedPair = () => <CompareDrawer a={VM_A} b={VM_B} runs={[VM_A, VM_B]} trials={[]} onSwap={noop} onClose={noop} />;
