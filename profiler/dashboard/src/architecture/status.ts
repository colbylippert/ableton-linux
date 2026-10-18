/**
 * Status of each profiler part, listed under the diagrams on the Architecture tab.
 * Hand-maintained: when a block lands, update its rows and STATUS_AS_OF.
 */

export type PartState = 'working' | 'in progress' | 'written, not run' | 'planned';

export interface PartStatus {
  part: string;
  paths: readonly string[];
  state: PartState;
  note: string;
}

export const STATUS_AS_OF = '18 October 2026 (trials T0001–T0010)';

export const STATUS_ROWS: readonly PartStatus[] = [
  {
    part: 'Trace points in Wine and PipeASIO',
    paths: ['patches/0108-ntdll-add-static-trace-points.patch', 'patches/pipeasio/0017-usdt-block-markers.patch'],
    state: 'working',
    note: "8 Wine and 6 PipeASIO probes on the 10-byte nop that kernel 7.2 turns into its fast uprobe path; build-audit checks every site.",
  },
  {
    part: 'bpftrace tracer',
    paths: ['profiler/tracer/wine-trace.bt', 'profiler/bin/wine-trace'],
    state: 'working',
    note: 'The first backend; libbpf replaced it as the default in block B5b.',
  },
  {
    part: 'libbpf tracer and real callers',
    paths: ['profiler/tracer/wine-trace.bpf.c', 'profiler/tracer/symbolize.py'],
    state: 'working',
    note: 'Callers from stack windows and .pdata unwinding. Block B5c cut the cost to about 0.26 ms per block (201 ns per probe hit on a P-core).',
  },
  {
    part: 'Validation probe',
    paths: ['tools/traceprobe.c', 'profiler/tracer/validate.py'],
    state: 'working',
    note: "All 15 expected counts match the tracer's output.",
  },
  {
    part: 'Bench suite and Interface report',
    paths: ['scripts/bench-suite.sh', 'scripts/bench-report.py'],
    state: 'working',
    note: 'Graceful quit, performance hold, effective buffer size in the report.',
  },
  {
    part: 'Control layer',
    paths: ['profiler/control/'],
    state: 'working',
    note: 'AbletonOSC with the bench handler; the smoke test passes 9 of 9.',
  },
  {
    part: 'Scenarios',
    paths: ['profiler/scenarios/', 'profiler/control/scenario-run.py'],
    state: 'written, not run',
    note: 'Seven timelines, from idle playback to clip-launch storms.',
  },
  {
    part: 'Trial-dialog automation',
    paths: ['profiler/bin/live-trial-dialog'],
    state: 'working',
    note: "Clicks Save/Export Disabled or Exit Live through Wine's input queue.",
  },
  {
    part: 'Machine setup',
    paths: ['profiler/setup/setup-machine.sh'],
    state: 'working',
    note: 'All 19 phases ran on the laptop.',
  },
  {
    part: 'Golden snapshots',
    paths: ['profiler/bin/state'],
    state: 'working',
    note: 'Re-baselined on the block B5c runtime; restored before every trial run.',
  },
  {
    part: 'Official build',
    paths: ['profiler/dev/build-official.sh'],
    state: 'working',
    note: "Builds run on the workstation's WSL build host in about 4 minutes; build-audit passes 189 of 189. The laptop install runs over ssh under its session lock, queued behind any trial (first used 18 October).",
  },
  {
    part: 'Wine dev loop',
    paths: ['profiler/dev/wine-dev.sh', 'profiler/dev/remote-runtime.sh'],
    state: 'in progress',
    note: "Runs on the workstation's WSL build host: about 10 minutes to set up once, then rebuilds in seconds. Syncing to the laptop's dev runtime is written, not yet run.",
  },
  {
    part: 'A/B trials',
    paths: ['profiler/ledger.jsonl', 'profiler/history/runs/'],
    state: 'in progress',
    note: 'Kept: PipeASIO realtime (T0003, PipeWire errors 204 to 30), P-core audio threads (T0004, 38 to 17) and nine audio workers (T0008, 20 to 10, Live CPU -23 %). Inconclusive: six audio workers (T0006). Reverted: T0001, T0005, T0007, T0009 (eight workers). Diagnostic: Live minimised during playback (T0010) changed nothing.',
  },
  {
    part: 'History and dashboard',
    paths: ['profiler/history/', 'profiler/dashboard/'],
    state: 'working',
    note: "The audio device is part of a run's identity; review pending (block B6).",
  },
  {
    part: 'Agent loop',
    paths: ['.claude/commands/profiler-loop.md', 'profiler/AGENT-PROMPT.md'],
    state: 'planned',
    note: 'Block B7 hands repeatable trials to /profiler-loop.',
  },
];
