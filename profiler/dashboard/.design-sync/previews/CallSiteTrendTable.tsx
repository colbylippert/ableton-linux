import { CallSiteTrendTable } from 'profiler-dashboard';
import type { CallSiteTrendTableProps } from 'profiler-dashboard';

type Run = CallSiteTrendTableProps['runs'][number];
type SetMetrics = Run['sets'][string];
type Slots = CallSiteTrendTableProps['slots'];
type TargetedBy = NonNullable<CallSiteTrendTableProps['targeted']>;
/** `[call-site key, share of lost slack, ns in late blocks]` as `call_sites_top` lists them. */
type Site = [key: string, share: number, ns: number];

// Call-site keys as the symbolizer writes them: `kind|name|caller` (frames joined by " <- ").
const LIVE = 'Ableton Live 12 Trial.exe';
const SRW = 'ntdll.dll!RtlWaitOnAddress+0x16d <- ntdll.dll!RtlSleepConditionVariableSRW+0x14b <- kernelbase.dll!SleepConditionVariableSRW+0x2c';
const K = {
  waitSingle: `syscall|NtWaitForSingleObject|kernelbase.dll!WaitForSingleObject+0x49 <- ${LIVE}+0x4f8c119`,
  waitAny: `ntsync_wait|WAIT_ANY|kernelbase.dll!WaitForSingleObject+0x49 <- ${LIVE}+0x4f8c119`,
  spliceAlert: `syscall|NtWaitForAlertByThreadId|${SRW} <- SpliceAbletonLive.vst3+0x559c60`,
  dwmFlush: `syscall|NtDelayExecution|dwmapi.dll!DwmFlush+0x1b3 <- ${LIVE}+0x31f0886`,
  maxSleep: 'syscall|NtDelayExecution|kernelbase.dll!Sleep+0x28 <- dxgi.dll!DXGIGetDebugInterface1+0x44c4 <- MaxPlug.dll+0x89ccaf',
  getMessage: `syscall|NtUserGetMessage|${LIVE}+0x313f8c2`,
  waitAnyUi: `ntsync_wait|WAIT_ANY|${LIVE}+0x313f8c2`,
  setEvent: `syscall|NtSetEvent|kernelbase.dll!SetEvent+0xf <- ${LIVE}+0x33f587e`,
  setEvent2: `syscall|NtSetEvent|kernelbase.dll!SetEvent+0xf <- ${LIVE}+0x363bc91`,
  resetEvent: `syscall|NtResetEvent|kernelbase.dll!ResetEvent+0xf <- ${LIVE}+0x33f41d2`,
  qpc: `syscall|NtQueryPerformanceCounter|ntdll.dll!RtlQueryPerformanceCounter+0xb <- ${LIVE}+0x3403253`,
  qpc2: `syscall|NtQueryPerformanceCounter|ntdll.dll!RtlQueryPerformanceCounter+0xb <- ${LIVE}+0x3402fbb`,
  sendMessage: `syscall|NtUserMessageCall|user32.dll!SendMessageW+0x3b <- ${LIVE}+0x31f0910`,
  maxAlert: `syscall|NtWaitForAlertByThreadId|${SRW} <- msvcp140.dll+0x122e8 <- MaxPlug.dll+0x64b9e9`,
  maxWaitMulti: 'syscall|NtWaitForMultipleObjects|kernelbase.dll!WaitForMultipleObjects+0xae <- MaxPlug.dll+0x4afb5b',
};

/** The view-level key → slot map (`assignCallSiteSlots`): top 8 keys by maximum share over every traced run × Set. */
const SLOTS: Slots = new Map([
  [K.waitSingle, 1],
  [K.waitAny, 2],
  [K.spliceAlert, 3],
  [K.dwmFlush, 4],
  [K.maxSleep, 5],
  [K.getMessage, 6],
  [K.waitAnyUi, 7],
  [K.setEvent, 8],
]);

function traced(sites: Site[], m: Partial<SetMetrics>): SetMetrics {
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
    audio_workers: 15,
    voluntary_switches_per_s: null,
    late_blocks: null,
    near_late_blocks: null,
    slack_p01_ns: null,
    slack_p50_ns: null,
    lost_slack_total_ns: null,
    call_sites_top: sites.map(([key, share, ns]) => ({ key, share, total_ns_in_late_blocks: ns })),
    hotspots_non_audio_top: null,
    ...m,
  };
}

function run(runId: string, tag: string, startedAt: string, setsOf: Run['sets']): Run {
  return {
    schema: 'ableton-linux-profiler-history/v1',
    run_id: runId,
    tag,
    started_at: startedAt,
    machine_id: 'd65f2ea0b816442a8d38bcb991cc7fd2',
    hostname: 'abletonlinux',
    virtualization: 'none',
    audio_device: 'alsa_output.usb-Focusrite_Scarlett_2i4_USB-00.pro-output-0',
    structure: 'diagnostic',
    scenario: null,
    trace_mode: 'interface',
    duration_s: 30,
    runtime: { dist_version: '2026.08.28.1', source_tree_sha: null, dev_info: null },
    switches: {},
    harness_sha: null,
    commit: '4f5728e1450b69f512059d7a1ab756543be3d980',
    trial: null,
    arm: null,
    source_dir: `~/.local/share/profiler/runs/${runId}/bench`,
    sets: setsOf,
  };
}

const B5B = run('b5b-verify-traced', 'b5b-traced', '2026-10-17T16:38:03Z', {
  Benchmark_Inbuilts: traced(
    [
      [K.waitSingle, 0.3769, 261285134],
      [K.waitAny, 0.3739, 259143664],
      [K.dwmFlush, 0.113, 47461690],
      [K.maxSleep, 0.0502, 30039911],
      [K.waitAnyUi, 0.0297, 21975705],
      [K.getMessage, 0.0191, 20421868],
      [K.setEvent, 0.013, 5993450],
      [K.qpc, 0.0101, 2033697],
      [K.resetEvent, 0.0024, 1698896],
      [K.sendMessage, 0.0012, 838298],
    ],
    { late_blocks: 10, near_late_blocks: 2, slack_p01_ns: 912899, lost_slack_total_ns: 5681373 },
  ),
  Benchmark_VSTs: traced(
    [
      [K.waitSingle, 0.1177, 47347977],
      [K.waitAny, 0.1153, 46844964],
      [K.spliceAlert, 0.2978, 33538378],
      [K.dwmFlush, 0.1198, 13509950],
      [K.maxSleep, 0.1066, 12024935],
      [K.getMessage, 0.0987, 11548330],
      [K.waitAnyUi, 0.095, 10015447],
      [K.setEvent, 0.0258, 1993195],
      [K.resetEvent, 0.0022, 397268],
      [K.qpc, 0.0012, 170034],
    ],
    { late_blocks: 2, near_late_blocks: 1, slack_p01_ns: 937685, lost_slack_total_ns: 2310323 },
  ),
});

const B5C_VERIFIER = run('b5c-verifier-traced', 'b5c-traced', '2026-10-17T20:19:51Z', {
  Benchmark_Inbuilts: traced(
    [
      [K.maxWaitMulti, 0, 499959373],
      [K.waitSingle, 0.9599, 395140325],
      [K.dwmFlush, 0, 60803543],
      [K.maxAlert, 0, 23614328],
      [K.maxSleep, 0, 12008464],
      [K.setEvent, 0.0218, 8188438],
      [K.getMessage, 0, 3870829],
      [K.resetEvent, 0.0061, 2239734],
      [K.spliceAlert, 0, 1281652],
    ],
    { late_blocks: 12, near_late_blocks: 5, slack_p01_ns: 796554, lost_slack_total_ns: 12524325 },
  ),
  Benchmark_VSTs: traced(
    [
      [K.waitSingle, 0.9573, 277648285],
      [K.dwmFlush, 0, 68181828],
      [K.maxSleep, 0, 18008655],
      [K.spliceAlert, 0, 16313691],
      [K.getMessage, 0, 15120177],
      [K.setEvent, 0.019, 3929759],
      [K.resetEvent, 0.0095, 1799018],
      [K.qpc, 0.0065, 596659],
      [K.sendMessage, 0, 581265],
      [K.qpc2, 0.0023, 526207],
    ],
    { late_blocks: 10, near_late_blocks: 5, slack_p01_ns: 804566, lost_slack_total_ns: 6046617 },
  ),
});

const B5C_FINAL = run('b5c-final-traced', 'b5c-final-traced', '2026-10-17T20:44:57Z', {
  Benchmark_Inbuilts: traced(
    [
      [K.waitSingle, 0.9366, 345876906],
      [K.dwmFlush, 0, 47550511],
      [K.spliceAlert, 0, 16137045],
      [K.getMessage, 0, 8774218],
      [K.maxSleep, 0, 6006274],
      [K.setEvent, 0.0354, 5717273],
      [K.setEvent2, 0.0079, 2035254],
      [K.resetEvent, 0.0129, 1631742],
      [K.maxAlert, 0, 1135988],
      [K.sendMessage, 0, 507004],
    ],
    { late_blocks: 9, near_late_blocks: 6, slack_p01_ns: 837330, lost_slack_total_ns: 5786690 },
  ),
  Benchmark_VSTs: traced(
    [
      [K.waitSingle, 0.9651, 1313649219],
      [K.dwmFlush, 0, 61150678],
      [K.maxSleep, 0, 18009343],
      [K.spliceAlert, 0, 15003172],
      [K.setEvent, 0.0234, 6209175],
      [K.getMessage, 0, 6050701],
      [K.resetEvent, 0.0064, 1570130],
      [K.maxAlert, 0, 1223783],
    ],
    { late_blocks: 9, near_late_blocks: 5, slack_p01_ns: 825194, lost_slack_total_ns: 4766908 },
  ),
});

const TRACED_RUNS = [B5B, B5C_VERIFIER, B5C_FINAL];

/** Ledger evidence: both trials so far went after the audio thread's wait at Live+0x4f8c119. */
const targetedBy: TargetedBy = (key) =>
  key === K.waitSingle
    ? [
        { trial: 'T0001', verdict: 'revert' },
        { trial: 'T0002', verdict: 'inconclusive' },
      ]
    : [];

/** VSTs, one share column per traced run (oldest first); keys outside the top 8 fold into "other listed sites". */
export const VstsAcrossTracedRuns = () => (
  <CallSiteTrendTable runs={TRACED_RUNS} set="Benchmark_VSTs" slots={SLOTS} caption="VSTs: call-site share of lost slack per traced run" />
);

/** Inbuilts with the same view-level slot map (same swatch per key) and the trials that targeted a site. */
export const InbuiltsTargetedBy = () => (
  <CallSiteTrendTable
    runs={TRACED_RUNS}
    set="Benchmark_Inbuilts"
    slots={SLOTS}
    targeted={targetedBy}
    caption="Inbuilts: call-site share of lost slack per traced run, with the trials that targeted each site"
  />
);

/** The latest traced run alone: only the sites it lists, one share column. */
export const LatestTracedRunOnly = () => (
  <CallSiteTrendTable runs={[B5C_FINAL]} set="Benchmark_VSTs" slots={SLOTS} targeted={targetedBy} caption="VSTs: call-site share of lost slack in b5c-final-traced" />
);
