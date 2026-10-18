import { RunTable } from 'profiler-dashboard';
import type { RunTableProps } from 'profiler-dashboard';

type Run = RunTableProps['runs'][number];
type SetMetrics = Run['sets'][string];

const noop = () => {};

const LAPTOP = 'd65f2ea0b816442a8d38bcb991cc7fd2';
const SCARLETT = 'alsa_output.usb-Focusrite_Scarlett_2i4_USB-00.pro-output-0';
const BENCHMARK = ['Benchmark_Zero', 'Benchmark_Empty', 'Benchmark_Inbuilts', 'Benchmark_Max4Live', 'Benchmark_VSTs'];
const DIAGNOSTIC = ['Benchmark_Inbuilts', 'Benchmark_VSTs'];

const NO_METRICS: SetMetrics = {
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
};

/** The table only reads the Set names; the metrics stay empty here. */
const sets = (names: string[]): Run['sets'] =>
  Object.fromEntries(names.map((n) => [n, { ...NO_METRICS, mode: n === 'Benchmark_Zero' ? 'idle-no-controller' : 'playback' }]));

/** A history record on the laptop (bare metal, Scarlett 2i4, untraced benchmark) unless overridden. */
function run(runId: string, startedAt: string, commit: string, extra: Partial<Run> = {}): Run {
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
    commit,
    trial: null,
    arm: null,
    source_dir: `~/.local/share/profiler/runs/${runId}/bench`,
    sets: sets(BENCHMARK),
    ...extra,
  };
}

const AA_SHA = '20286fd71e5dc6498b2a7d3d9358f3fba52e0ac7';
const T0002_SHA = 'b8145eee48130d23e569e00623d127844383b44c';
const ON = { PIPEASIO_REALTIME: '1' };

/** T0002's interleaved ABAB runs (PIPEASIO_REALTIME=1 on arm B). */
const T0002_SLICE: Run[] = [
  run('trial-T0002-A1', '2026-10-18T00:56:22Z', T0002_SHA, { trial: 'T0002', arm: 'A' }),
  run('trial-T0002-B1', '2026-10-18T01:01:28Z', T0002_SHA, { trial: 'T0002', arm: 'B', switches: ON }),
  run('trial-T0002-A2', '2026-10-18T01:06:36Z', T0002_SHA, { trial: 'T0002', arm: 'A' }),
  run('trial-T0002-B2', '2026-10-18T01:11:44Z', T0002_SHA, { trial: 'T0002', arm: 'B', switches: ON }),
  run('trial-T0002-A3', '2026-10-18T01:16:52Z', T0002_SHA, { trial: 'T0002', arm: 'A' }),
  run('trial-T0002-B3', '2026-10-18T01:21:51Z', '1fd348ecf177792fec7f0f497c179bac6d5aeb02', { trial: 'T0002', arm: 'B', switches: ON }),
];

const B5_SHA = '4f5728e1450b69f512059d7a1ab756543be3d980';

/**
 * Different identities side by side: traced vs untraced diagnostics (two Sets), an A/A noise run,
 * and a traced run from the retired VMware guest (recorded before the audio device was part of a run).
 */
const MIXED: Run[] = [
  run('b5c-final-traced', '2026-10-17T20:44:57Z', B5_SHA, { structure: 'diagnostic', trace_mode: 'interface', sets: sets(DIAGNOSTIC) }),
  run('b5c-final-untraced', '2026-10-17T20:42:50Z', B5_SHA, { structure: 'diagnostic', sets: sets(DIAGNOSTIC) }),
  run('b5c-verifier-traced', '2026-10-17T20:19:51Z', B5_SHA, { tag: 'b5c-traced', structure: 'diagnostic', trace_mode: 'interface', sets: sets(DIAGNOSTIC) }),
  run('aa-focusrite-2', '2026-10-18T00:10:40Z', AA_SHA, { arm: 'AA' }),
  run('vm-tracer-bringup', '2026-10-09T15:12:04Z', 'c41d9e2b7a0f5e8d3c6b1a4f9e2d7c0b5a8f3e61', {
    machine_id: '5c1e0a77d02b4f6e9a3c6b2d8e4f1a09',
    hostname: 'abletonlinux-vm',
    virtualization: 'vmware',
    audio_device: null,
    trace_mode: 'interface',
  }),
];

/** The Runs tab's table: every run of the slice with its identity, newest first, nothing picked yet. */
export const TrialSliceNewestFirst = () => <RunTable runs={T0002_SLICE} selected={[]} onSelect={noop} />;

/** Two runs ticked (the cap is two): the first ABAB pair of T0002, which opens the compare drawer. */
export const PickedPairToCompare = () => <RunTable runs={T0002_SLICE} selected={['trial-T0002-A1', 'trial-T0002-B1']} onSelect={noop} />;

/** Identity variety: traced vs untraced, diagnostic vs benchmark, an A/A arm, an unknown audio device and a virtualised host. */
export const MixedIdentities = () => <RunTable runs={MIXED} selected={[]} onSelect={noop} />;

/** A slice with no runs: header kept, empty message in the body. */
export const EmptySlice = () => <RunTable runs={[]} selected={[]} onSelect={noop} />;
