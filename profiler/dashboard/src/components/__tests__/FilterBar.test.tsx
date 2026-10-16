import { afterEach, describe, expect, it, vi } from 'vitest';
import { DEFAULT_FILTER, type FilterState } from '../../data/types';
import FilterBar, { isDefaultFilter, type FilterOptions } from '../FilterBar';
import { all, byText, choose, click, mount, text, type Mounted } from './harness';

const options: FilterOptions = {
  machines: [
    { id: 'm1', hostname: 'bare', virtualization: 'none', runs: 5 },
    { id: 'm2', hostname: 'abletonlinux', virtualization: 'vmware', runs: 2 },
  ],
  structures: ['benchmark', 'diagnostic'],
  scenarios: ['clip-launch-storm'],
  traceModes: ['off', 'interface'],
  sets: ['Benchmark_Zero', 'Benchmark_VSTs'],
  switches: ['WINE_APC_FASTPATH'],
};

function selectNamed(parent: ParentNode, name: string): HTMLSelectElement | null {
  return parent.querySelector<HTMLSelectElement>(`select[name="${name}"]`);
}

describe('FilterBar', () => {
  let mounted: Mounted | null = null;
  afterEach(() => {
    mounted?.unmount();
    mounted = null;
  });

  it('renders one row of controls with options derived from the data and the slice count', () => {
    mounted = mount(<FilterBar filter={DEFAULT_FILTER} options={options} onChange={() => {}} runsInSlice={7} />);
    expect(all(mounted.container, 'select')).toHaveLength(7);
    const machine = selectNamed(mounted.container, 'machine');
    expect(all(machine!, 'option').map(text)).toEqual(['All machines', 'bare · bare metal · 5 runs', 'abletonlinux · vmware · 2 runs']);
    expect(all(selectNamed(mounted.container, 'traceMode')!, 'option').map(text)).toEqual(['All', 'untraced (off)', 'traced · interface']);
    expect(all(selectNamed(mounted.container, 'switch')!, 'option').map(text)).toEqual(['All runs', 'No switches', 'WINE_APC_FASTPATH']);
    expect(text(mounted.container.querySelector('.filterbar-status'))).toContain('7 runs in slice');
    expect(byText(mounted.container, 'button', 'Reset')).toBeUndefined();
  });

  it('emits a complete FilterState on every change', () => {
    const onChange = vi.fn<(next: FilterState) => void>();
    mounted = mount(<FilterBar filter={DEFAULT_FILTER} options={options} onChange={onChange} runsInSlice={7} />);
    choose(selectNamed(mounted.container, 'machine'), 'm2');
    expect(onChange).toHaveBeenLastCalledWith({ ...DEFAULT_FILTER, machine: 'm2' });
    choose(selectNamed(mounted.container, 'environment'), 'virtualised');
    expect(onChange).toHaveBeenLastCalledWith({ ...DEFAULT_FILTER, environment: 'virtualised' });
    choose(selectNamed(mounted.container, 'switch'), 'none');
    expect(onChange).toHaveBeenLastCalledWith({ ...DEFAULT_FILTER, switch: 'none' });
    choose(selectNamed(mounted.container, 'set'), 'Benchmark_VSTs');
    expect(onChange).toHaveBeenLastCalledWith({ ...DEFAULT_FILTER, set: 'Benchmark_VSTs' });
    choose(selectNamed(mounted.container, 'machine'), '');
    expect(onChange).toHaveBeenLastCalledWith({ ...DEFAULT_FILTER, machine: null });
  });

  it('clears the scenario when the structure becomes benchmark and offers Reset off the default', () => {
    const onChange = vi.fn<(next: FilterState) => void>();
    const filter: FilterState = { ...DEFAULT_FILTER, structure: 'diagnostic', scenario: 'clip-launch-storm' };
    mounted = mount(<FilterBar filter={filter} options={options} onChange={onChange} runsInSlice={1} />);
    expect(isDefaultFilter(filter)).toBe(false);
    choose(selectNamed(mounted.container, 'structure'), 'benchmark');
    expect(onChange).toHaveBeenLastCalledWith({ ...DEFAULT_FILTER, structure: 'benchmark', scenario: null });
    click(byText(mounted.container, 'button', 'Reset'));
    expect(onChange).toHaveBeenLastCalledWith(DEFAULT_FILTER);
    expect(text(mounted.container.querySelector('.filterbar-status'))).toContain('1 run in slice');
  });
});
