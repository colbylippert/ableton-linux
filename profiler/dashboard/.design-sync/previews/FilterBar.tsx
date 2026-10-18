import { FilterBar } from 'profiler-dashboard';
import type { FilterBarProps, FilterOptions } from 'profiler-dashboard';

type FilterState = FilterBarProps['filter'];

const noop = () => {};
const LAPTOP = 'd65f2ea0b816442a8d38bcb991cc7fd2';

/** `null` = all, exactly like the app's DEFAULT_FILTER. */
const ALL: FilterState = { machine: null, environment: 'all', structure: null, scenario: null, traceMode: null, set: null, switch: null };

const SETS = ['Benchmark_Zero', 'Benchmark_Empty', 'Benchmark_Inbuilts', 'Benchmark_Max4Live', 'Benchmark_VSTs'];

/** What `filterOptions()` derives from the laptop's history: 22 runs, no scenario runs yet. */
const HISTORY: FilterOptions = {
  machines: [{ id: LAPTOP, hostname: 'abletonlinux', virtualization: 'none', runs: 22 }],
  structures: ['benchmark', 'diagnostic'],
  scenarios: [],
  traceModes: ['off', 'interface'],
  sets: SETS,
  switches: ['PIPEASIO_REALTIME'],
};

/** Once diagnostic scenario runs exist, the Scenario select comes alive; the retired VM keeps its runs. */
const WITH_SCENARIOS: FilterOptions = {
  ...HISTORY,
  machines: [
    { id: LAPTOP, hostname: 'abletonlinux', virtualization: 'none', runs: 26 },
    { id: '5c1e0a77d02b4f6e9a3c6b2d8e4f1a09', hostname: 'abletonlinux-vm', virtualization: 'vmware', runs: 4 },
  ],
  scenarios: ['clip-launch-storm', 'tempo-ramp', 'track-churn'],
};

/** The default slice: every run in history, no Reset. */
export const WholeHistory = () => <FilterBar filter={ALL} options={HISTORY} onChange={noop} runsInSlice={22} />;

/** Scoped to T0002's arm B: bare-metal untraced benchmark runs with PIPEASIO_REALTIME set; Reset appears. */
export const PipeAsioArmB = () => (
  <FilterBar
    filter={{ ...ALL, machine: LAPTOP, environment: 'bare-metal', structure: 'benchmark', traceMode: 'off', switch: 'PIPEASIO_REALTIME' }}
    options={HISTORY}
    onChange={noop}
    runsInSlice={3}
  />
);

/** A traced diagnostic scenario on one Set, runs without switches only. */
export const TracedScenarioOneSet = () => (
  <FilterBar
    filter={{ ...ALL, machine: LAPTOP, structure: 'diagnostic', scenario: 'clip-launch-storm', traceMode: 'interface', set: 'Benchmark_VSTs', switch: 'none' }}
    options={WITH_SCENARIOS}
    onChange={noop}
    runsInSlice={2}
  />
);
