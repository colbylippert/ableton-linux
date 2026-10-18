/**
 * Smoke tests for the D2 views against the data layer (`src/data`) with the fixtures in
 * `./fixtures.ts`. Assertions are structural on purpose (what renders, what a click does),
 * not numeric, so they hold for any correct implementation of the DESIGN.md §6 API.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { DEFAULT_FILTER, type FilterState } from '../../data/types';
import OverviewView, { heroStatus, niceCeil, quarterDomain } from '../../views/Overview';
import TrendsView from '../../views/Trends';
import { EMPTY_DATA, FIXTURE_DATA } from './fixtures';
import { all, byText, choose, click, mount, text, type Mounted } from './harness';

// ChartFrame remembers the chart | table choice per viewer; start every test from a clean slate.
beforeEach(() => {
  localStorage.clear();
});

describe('Overview view', () => {
  let mounted: Mounted | null = null;
  afterEach(() => {
    mounted?.unmount();
    mounted = null;
  });

  it('shows the empty state without runs', () => {
    mounted = mount(<OverviewView data={EMPTY_DATA} filter={DEFAULT_FILTER} onFilterChange={() => {}} />);
    expect(text(mounted.container.querySelector('h2'))).toBe('Overview');
    expect(text(mounted.container.querySelector('.empty'))).toContain('history-add');
  });

  it('renders the hero, the environment, a tile row per Set and the table twin', () => {
    const onFilterChange = vi.fn<(next: FilterState) => void>();
    mounted = mount(<OverviewView data={FIXTURE_DATA} filter={DEFAULT_FILTER} onFilterChange={onFilterChange} />);
    const c = mounted.container;
    expect(text(c.querySelector('h2'))).toBe('Overview');
    expect(c.querySelector('.empty')).toBeNull();
    // the most recent run is on the bare-metal machine m1
    expect(text(c.querySelector('.env-badge'))).toContain('bare metal');
    expect(text(c.querySelector('.env-badge'))).toContain('(m1)');
    expect(c.querySelector('.ribbon')).toBeNull();
    expect(c.querySelector('.hero-figure')).not.toBeNull();
    expect(text(c.querySelector('.hero-label'))).toBe('Cumulative gain');
    expect(text(c.querySelector('.hero-kept'))).toBe('1 kept trial');
    const sets = all(c, '.overview-set');
    expect(sets.map((s) => s.getAttribute('data-set'))).toEqual(['Benchmark_Zero', 'Benchmark_VSTs']);
    expect(all(c, '.kpi')).toHaveLength(8);
    expect(all(c, '.kpi .kpi-label').map(text).slice(0, 4)).toEqual(['Late blocks / min', 'PipeWire errors / xruns', 'Live CPU / core', 'Slack p01']);
    // interface and outcome tiles never mix: each tile names its source
    expect(all(c, '.kpi').map((k) => k.getAttribute('data-source'))).toEqual(['interface', 'outcome', 'outcome', 'interface', 'interface', 'outcome', 'outcome', 'interface']);
    // guard tiles are clean
    expect(all(c, '.kpi-reject')).toHaveLength(0);
    // the Live CPU tile has a baseline and a delta chip
    const cpuTile = all(c, '.kpi')[2]!;
    expect(text(cpuTile.querySelector('.kpi-meta'))).toContain('baseline');
    expect(cpuTile.querySelector('.kpi-delta .chip')).not.toBeNull();

    click(byText(c, '.set-heading', 'VSTs'));
    expect(onFilterChange).toHaveBeenLastCalledWith({ ...DEFAULT_FILTER, set: 'Benchmark_VSTs' });

    click(byText(c, '.chart-frame-toggle button', 'Table'));
    expect(all(c, 'tbody tr').length).toBeGreaterThanOrEqual(8);
    expect(all(c, '.overview-tiles th').map(text)).toEqual(['Set', 'Metric', 'Baseline', 'Latest', 'Best', 'Δ', 'Significance', 'Runs']);
  });

  it('shows the Set chips, DSP load by Set, the latest-trial dropouts and the recent trials', () => {
    const onFilterChange = vi.fn<(next: FilterState) => void>();
    mounted = mount(<OverviewView data={FIXTURE_DATA} filter={DEFAULT_FILTER} onFilterChange={onFilterChange} />);
    const c = mounted.container;
    // Set chips name every Set of the slice and narrow the shared filter
    expect(all(c, '.set-chip').map(text)).toEqual(['Zero', 'VSTs']);
    click(byText(c, '.set-chip', 'VSTs'));
    expect(onFilterChange).toHaveBeenLastCalledWith({ ...DEFAULT_FILTER, set: 'Benchmark_VSTs' });
    // DSP load by Set: one tinted row per Set with a DSP meter, from the latest untraced run
    const loadRows = all(c, '.set-load-row');
    expect(loadRows.length).toBeGreaterThan(0);
    expect(loadRows.every((r) => ['Benchmark_Zero', 'Benchmark_VSTs'].includes(r.getAttribute('data-set') ?? ''))).toBe(true);
    // the hero card carries a tone and the kept trial's switch
    expect(c.querySelector('.overview-hero')?.className).toMatch(/tone-(good|warning|critical|dim)/);
    expect(text(c.querySelector('.overview-hero-chips'))).toContain('WINE_FOO=1');
    // dropouts come from the latest trial whose ABAB runs are in history (T0007; T0008 has none)
    expect(text(c.querySelector('.overview-charts'))).toContain('Dropouts, latest trial');
    expect(text(c.querySelector('.overview-charts'))).toContain('T0007');
    // recent trials, newest first
    expect(all(c, '.overview-trials tbody tr').map((r) => text(r.querySelector('td')))).toEqual(['T0008', 'T0007']);
  });

  it('maps the cumulative gain to the hero tone and rounds bar scales up', () => {
    expect(heroStatus('beyond', 'better')).toBe('good');
    expect(heroStatus('beyond', 'worse')).toBe('critical');
    expect(heroStatus('within', 'better')).toBe('warning');
    expect(heroStatus('unknown', 'flat')).toBe('dim');
    expect(niceCeil(31.2)).toBe(35);
    expect(niceCeil(0)).toBe(5);
    expect(niceCeil(204, 10, 1.1)).toBe(230);
    expect(quarterDomain(38)).toEqual([0, 40]);
    expect(quarterDomain(204)).toEqual([0, 400]);
    expect(quarterDomain(17)).toEqual([0, 20]);
    expect(quarterDomain(0)).toEqual([0, 4]);
  });

  it('narrows to the chosen machine and shows the no-timing ribbon on a virtualised host', () => {
    mounted = mount(<OverviewView data={FIXTURE_DATA} filter={{ ...DEFAULT_FILTER, machine: 'm2' }} onFilterChange={() => {}} />);
    const c = mounted.container;
    expect(text(c.querySelector('.env-badge'))).toContain('vmware');
    expect(text(c.querySelector('.ribbon'))).toContain('NO TIMING CLAIMS');
    expect(all(c, '.overview-set')).toHaveLength(2);
    // no traced runs on m2: interface tiles say so
    expect(all(c, '.kpi[data-source="interface"] .kpi-note').map(text)).toContain('no traced runs in slice');
  });
});

describe('Trends view', () => {
  let mounted: Mounted | null = null;
  afterEach(() => {
    mounted?.unmount();
    mounted = null;
  });

  it('renders small multiples for the default (interface) metric, the overlay, and other metrics', () => {
    mounted = mount(<TrendsView data={FIXTURE_DATA} filter={{ ...DEFAULT_FILTER, structure: 'benchmark' }} onFilterChange={() => {}} />);
    const c = mounted.container;
    expect(text(c.querySelector('h2'))).toBe('Trends');
    const select = c.querySelector<HTMLSelectElement>('select[name="metric"]');
    expect(select?.value).toBe('late_blocks_per_min');
    expect(all(c, '.trend-chart')).toHaveLength(2);
    expect(all(c, '.trend-chart h3').map(text)).toEqual(['Zero', 'VSTs']);
    expect(all(c, '.chart-key').length).toBe(2);
    expect(text(c.querySelector('.chart-key'))).toContain('baseline');

    click(byText(c, '.view-controls button', 'Overlay (Δ %)'));
    expect(all(c, '.trend-chart')).toHaveLength(1);
    expect(all(c, '.legend button').map(text)).toEqual(['Zero', 'VSTs']);

    click(byText(c, '.view-controls button', 'Small multiples'));
    choose(select, 'live_cpu_pct_per_core');
    expect(all(c, '.trend-chart')).toHaveLength(2);
    expect(all(c, '.trend-chart .card-subtitle').map(text)[0]).toContain('Live CPU / core');
    // trial markers for the kept trial reach the chart key
    expect(text(c.querySelector('.chart-key'))).toContain('kept trial');
  });

  it('groups a mixed slice by identity and ribbons virtualised ones', () => {
    mounted = mount(<TrendsView data={FIXTURE_DATA} filter={{ ...DEFAULT_FILTER, machine: 'm2' }} onFilterChange={() => {}} />);
    const c = mounted.container;
    expect(c.querySelector<HTMLSelectElement>('select[name="metric"]')?.value).toBe('live_cpu_pct_per_core');
    expect(c.querySelector('.ribbon')).not.toBeNull();
    expect(all(c, '.trend-chart')).toHaveLength(2);
    // every chart has its table twin
    click(all<HTMLButtonElement>(c, '.chart-frame-toggle button').find((b) => text(b) === 'Table'));
    expect(all(c, 'tbody tr').length).toBeGreaterThanOrEqual(1);
  });
});
