import { useState } from 'react';
import { CallSiteTrend } from 'profiler-dashboard';
import type { CallSiteTrendProps } from 'profiler-dashboard';

type Run = CallSiteTrendProps['runs'][number];
type Slots = CallSiteTrendProps['slots'];

// Call-site keys exactly as the symbolizer writes them: kind | name | caller chain.
const LIVE = 'Ableton Live 12 Trial.exe';
const WAIT = `syscall|NtWaitForSingleObject|kernelbase.dll!WaitForSingleObject+0x49 <- ${LIVE}+0x4f8c119`;
const WAIT_ANY = `ntsync_wait|WAIT_ANY|kernelbase.dll!WaitForSingleObject+0x49 <- ${LIVE}+0x4f8c119`;
const SPLICE =
  'syscall|NtWaitForAlertByThreadId|ntdll.dll!RtlWaitOnAddress+0x16d <- ntdll.dll!RtlSleepConditionVariableSRW+0x14b <- kernelbase.dll!SleepConditionVariableSRW+0x2c <- SpliceAbletonLive.vst3+0x559c60';
const DWM = `syscall|NtDelayExecution|dwmapi.dll!DwmFlush+0x1b3 <- ${LIVE}+0x31f0886`;
const SLEEP = 'syscall|NtDelayExecution|kernelbase.dll!Sleep+0x28 <- dxgi.dll!DXGIGetDebugInterface1+0x44c4 <- MaxPlug.dll+0x89ccaf';
const GET_MESSAGE = `syscall|NtUserGetMessage|${LIVE}+0x313f8c2`;
const WAIT_ANY_UI = `ntsync_wait|WAIT_ANY|${LIVE}+0x313f8c2`;
const SET_EVENT = `syscall|NtSetEvent|kernelbase.dll!SetEvent+0xf <- ${LIVE}+0x33f587e`;
const SET_EVENT_2 = `syscall|NtSetEvent|kernelbase.dll!SetEvent+0xf <- ${LIVE}+0x363bc91`;
const RESET_EVENT = `syscall|NtResetEvent|kernelbase.dll!ResetEvent+0xf <- ${LIVE}+0x33f41d2`;
const QPC = `syscall|NtQueryPerformanceCounter|ntdll.dll!RtlQueryPerformanceCounter+0xb <- ${LIVE}+0x3403253`;

type Sites = [key: string, share: number][];

function set(sites: Sites): Run['sets'][string] {
  return {
    mode: 'playback',
    host_cpu_pct: null, live_cpu_pct_per_core: null, wine_cpu_pct_per_core: null, pipewire_cpu_pct: null,
    irq_per_s: null, softirq_per_s: null, pipewire_errors: null, xruns: null, dsp_avg: null, dsp_peak: null,
    audio_workers: null, voluntary_switches_per_s: null, late_blocks: null, near_late_blocks: null,
    slack_p01_ns: null, slack_p50_ns: null, lost_slack_total_ns: null, hotspots_non_audio_top: null,
    call_sites_top: sites.map(([key, share]) => ({ key, share, total_ns_in_late_blocks: Math.round(share * 48_000_000) })),
  };
}

/** A traced (interface) benchmark run on the bare-metal laptop with its Inbuilts and VSTs call sites. */
function traced(run_id: string, tag: string, started_at: string, inbuilts: Sites, vsts: Sites): Run {
  return {
    schema: 'ableton-linux-profiler-history/v1', run_id, tag, started_at,
    machine_id: 'd65f2ea0b816442a8d38bcb991cc7fd2', hostname: 'abletonlinux', virtualization: 'none',
    audio_device: 'alsa_output.usb-Focusrite_Scarlett_2i4_USB-00.pro-output-0',
    structure: 'benchmark', scenario: null, trace_mode: 'interface', duration_s: 30,
    runtime: { dist_version: null, source_tree_sha: null, dev_info: null },
    switches: {}, harness_sha: null, commit: null, trial: null, arm: null, source_dir: null,
    sets: { Benchmark_Inbuilts: set(inbuilts), Benchmark_VSTs: set(vsts) },
  };
}

// Today's traces: before the B5c attribution fix (b5b) the wait was split across a syscall and an
// ntsync WAIT_ANY entry; after it, one site carries 94–97 % of the lost slack.
const RUNS: Run[] = [
  traced('b5b-verify-traced', 'b5b-traced', '2026-10-17T16:38:03Z',
    [[WAIT, 0.3769], [WAIT_ANY, 0.3739], [DWM, 0.113], [SLEEP, 0.0502], [WAIT_ANY_UI, 0.0297], [GET_MESSAGE, 0.0191], [SET_EVENT, 0.013], [QPC, 0.0101], [RESET_EVENT, 0.0024]],
    [[SPLICE, 0.2978], [DWM, 0.1198], [WAIT, 0.1177], [WAIT_ANY, 0.1153], [SLEEP, 0.1066], [GET_MESSAGE, 0.0987], [WAIT_ANY_UI, 0.095], [SET_EVENT, 0.0258], [RESET_EVENT, 0.0022], [QPC, 0.0012]]),
  traced('b5c-verifier-traced', 'b5c-traced', '2026-10-17T20:19:51Z',
    [[WAIT, 0.9599], [SET_EVENT, 0.0218], [RESET_EVENT, 0.0061], [SPLICE, 0]],
    [[WAIT, 0.9573], [SET_EVENT, 0.019], [RESET_EVENT, 0.0095], [QPC, 0.0065], [SPLICE, 0]]),
  traced('b5c-final-traced', 'b5c-final-traced', '2026-10-17T20:44:57Z',
    [[WAIT, 0.9366], [SET_EVENT, 0.0354], [RESET_EVENT, 0.0129], [SET_EVENT_2, 0.0079]],
    [[WAIT, 0.9651], [SET_EVENT, 0.0234], [RESET_EVENT, 0.0064]]),
];

/** The view's key → slot map: keys ranked once by maximum share over every run × Set, top 8 get a hue. */
function rankSlots(runs: Run[]): Slots {
  const best = new Map<string, number>();
  for (const run of runs) for (const s of Object.values(run.sets)) for (const cs of s.call_sites_top ?? []) best.set(cs.key, Math.max(best.get(cs.key) ?? 0, cs.share));
  const ranked = [...best.entries()].sort((a, b) => b[1] - a[1] || (a[0] < b[0] ? -1 : 1)).slice(0, 8);
  return new Map(ranked.map(([key], i) => [key, (i + 1) as 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8]));
}

const SLOTS = rankSlots(RUNS);
const frame = { width: 600 };

/** VSTs across the attribution fix: a spread of sites collapses onto the audio wait. Click a site to isolate it. */
export const AttributionFixVSTs = () => {
  const [emphasis, setEmphasis] = useState<string | null>(null);
  return (
    <div style={frame}>
      <CallSiteTrend runs={RUNS} set="Benchmark_VSTs" slots={SLOTS} emphasis={emphasis} onEmphasis={setEmphasis} width={600} />
    </div>
  );
};

/** One site isolated from the legend: every other segment drops to 25 % and its legend entry mutes. */
export const IsolatedCallSite = () => {
  const [emphasis, setEmphasis] = useState<string | null>(WAIT);
  return (
    <div style={frame}>
      <CallSiteTrend runs={RUNS} set="Benchmark_VSTs" slots={SLOTS} emphasis={emphasis} onEmphasis={setEmphasis} width={600} />
    </div>
  );
};

/** Inbuilts, with the trial that went after the audio wait listed as a targeted-by chip in the legend. */
export const TargetedByTrial = () => (
  <div style={frame}>
    <CallSiteTrend
      runs={RUNS}
      set="Benchmark_Inbuilts"
      slots={SLOTS}
      targeted={(key) => (key === WAIT ? [{ trial: 'T0002', verdict: 'inconclusive' }] : [])}
      width={600}
    />
  </div>
);

/** A Set the traced runs list no call sites for: the empty state. */
export const NoCallSitesForSet = () => (
  <div style={frame}>
    <CallSiteTrend runs={RUNS} set="Benchmark_Zero" slots={SLOTS} width={600} />
  </div>
);
