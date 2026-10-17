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

export const STATUS_AS_OF = '17 October 2026 (block B5b in progress)';

export const STATUS_ROWS: readonly PartStatus[] = [
  {
    part: 'Trace points in Wine and PipeASIO',
    paths: ['patches/0108-ntdll-add-static-trace-points.patch', 'patches/pipeasio/0017-usdt-block-markers.patch'],
    state: 'working',
    note: 'Built and audited: 8 Wine and 6 PipeASIO probes in the installed runtime.',
  },
  {
    part: 'bpftrace tracer',
    paths: ['profiler/tracer/wine-trace.bt', 'profiler/bin/wine-trace'],
    state: 'working',
    note: 'Traced suite runs work end to end; callers stop at the ntdll entry point.',
  },
  {
    part: 'libbpf tracer and real callers',
    paths: ['profiler/tracer/wine-trace.bpf.c', 'profiler/tracer/symbolize.py'],
    state: 'in progress',
    note: 'Block B5b: every program under 64 bytes of stack, JIT self-check, stack windows.',
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
    note: 'Re-baselined with the Focusrite configuration.',
  },
  {
    part: 'Wine dev loop',
    paths: ['profiler/dev/wine-dev.sh', 'profiler/dev/build-official.sh'],
    state: 'written, not run',
    note: 'First real use comes with the first optimisation trial.',
  },
  {
    part: 'History and dashboard',
    paths: ['profiler/history/', 'profiler/dashboard/'],
    state: 'working',
    note: "Review pending (block B6); the audio device is not yet part of a run's identity.",
  },
  {
    part: 'Agent loop',
    paths: ['.claude/commands/profiler-loop.md', 'profiler/AGENT-PROMPT.md'],
    state: 'planned',
    note: 'Block B7, after the real baselines on the Focusrite.',
  },
];
