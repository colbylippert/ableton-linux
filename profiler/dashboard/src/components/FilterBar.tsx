/**
 * FilterBar: one row above the panel that scopes every view (dataviz "Filters & time
 * ranges": standard form controls styled to the chrome, never inside a chart card).
 *
 * Controlled: the app owns `FilterState`; every change emits a complete next state.
 * `null` means "all"; the `switch` filter takes an ENV_NAME, the sentinel `"none"` (runs
 * with no switches) or `null`. Picking `structure = benchmark` clears the scenario, since
 * benchmark runs never carry one.
 */
import { DEFAULT_FILTER, type EnvironmentFilter, type FilterState, type Structure, type TraceMode, type Virtualization } from '../data/types';
import './components.css';

export interface FilterOptions {
  machines: { id: string; hostname: string; virtualization: Virtualization; runs: number }[];
  structures: Structure[];
  scenarios: string[];
  traceModes: TraceMode[];
  sets: string[];
  switches: string[];
}

export interface FilterBarProps {
  filter: FilterState;
  options: FilterOptions;
  onChange: (next: FilterState) => void;
  runsInSlice: number;
}

const TRACE_LABEL: Record<string, string> = {
  off: 'untraced (off)',
  interface: 'traced · interface',
  drilldown: 'traced · drilldown',
};

const FILTER_KEYS = Object.keys(DEFAULT_FILTER) as (keyof FilterState)[];

export function isDefaultFilter(filter: FilterState): boolean {
  return FILTER_KEYS.every((key) => filter[key] === DEFAULT_FILTER[key]);
}

function orNull(value: string): string | null {
  return value === '' ? null : value;
}

export default function FilterBar({ filter, options, onChange, runsInSlice }: FilterBarProps) {
  const update = (patch: Partial<FilterState>) => onChange({ ...filter, ...patch });

  return (
    <form className="filterbar" role="group" aria-label="Filters" onSubmit={(event) => event.preventDefault()}>
      <label className="filter">
        <span className="filter-label">Machine</span>
        <select name="machine" value={filter.machine ?? ''} onChange={(e) => update({ machine: orNull(e.target.value) })}>
          <option value="">All machines</option>
          {options.machines.map((m) => (
            <option key={m.id} value={m.id}>
              {m.hostname} · {m.virtualization === 'none' ? 'bare metal' : m.virtualization} · {m.runs} run{m.runs === 1 ? '' : 's'}
            </option>
          ))}
        </select>
      </label>

      <label className="filter">
        <span className="filter-label">Environment</span>
        <select name="environment" value={filter.environment} onChange={(e) => update({ environment: e.target.value as EnvironmentFilter })}>
          <option value="all">All</option>
          <option value="bare-metal">Bare metal</option>
          <option value="virtualised">Virtualised</option>
        </select>
      </label>

      <label className="filter">
        <span className="filter-label">Structure</span>
        <select
          name="structure"
          value={filter.structure ?? ''}
          onChange={(e) => {
            const structure = orNull(e.target.value) as Structure | null;
            update({ structure, scenario: structure === 'benchmark' ? null : filter.scenario });
          }}
        >
          <option value="">All</option>
          {options.structures.map((s) => (
            <option key={s} value={s}>
              {s}
            </option>
          ))}
        </select>
      </label>

      <label className="filter">
        <span className="filter-label">Scenario</span>
        <select
          name="scenario"
          value={filter.scenario ?? ''}
          disabled={options.scenarios.length === 0 || filter.structure === 'benchmark'}
          onChange={(e) => update({ scenario: orNull(e.target.value) })}
        >
          <option value="">All</option>
          {options.scenarios.map((s) => (
            <option key={s} value={s}>
              {s}
            </option>
          ))}
        </select>
      </label>

      <label className="filter">
        <span className="filter-label">Trace mode</span>
        <select name="traceMode" value={filter.traceMode ?? ''} onChange={(e) => update({ traceMode: orNull(e.target.value) as TraceMode | null })}>
          <option value="">All</option>
          {options.traceModes.map((m) => (
            <option key={m} value={m}>
              {TRACE_LABEL[m] ?? m}
            </option>
          ))}
        </select>
      </label>

      <label className="filter">
        <span className="filter-label">Set</span>
        <select name="set" value={filter.set ?? ''} onChange={(e) => update({ set: orNull(e.target.value) })}>
          <option value="">All Sets</option>
          {options.sets.map((s) => (
            <option key={s} value={s}>
              {s}
            </option>
          ))}
        </select>
      </label>

      <label className="filter">
        <span className="filter-label">Switch</span>
        <select name="switch" value={filter.switch ?? ''} onChange={(e) => update({ switch: orNull(e.target.value) })}>
          <option value="">All runs</option>
          <option value="none">No switches</option>
          {options.switches.map((s) => (
            <option key={s} value={s}>
              {s}
            </option>
          ))}
        </select>
      </label>

      <div className="filterbar-status">
        <span aria-live="polite">
          {runsInSlice} run{runsInSlice === 1 ? '' : 's'} in slice
        </span>
        {isDefaultFilter(filter) ? null : (
          <button type="button" className="btn" onClick={() => onChange({ ...DEFAULT_FILTER })}>
            Reset
          </button>
        )}
      </div>
    </form>
  );
}
