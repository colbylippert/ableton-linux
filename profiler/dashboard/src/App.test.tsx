import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { act } from 'react';
import { createRoot, type Root } from 'react-dom/client';
import App, { FILTER_STORAGE_KEY, TABS } from './App';
import { DEFAULT_FILTER, type DashboardData, type Run } from './data/types';
import { loadDashboardData } from './data/load';
import { EMPTY_DATA, FIXTURE_DATA } from './components/__tests__/fixtures';
import { choose } from './components/__tests__/harness';

// React 18 warns unless the test environment opts in to act().
(globalThis as unknown as { IS_REACT_ACT_ENVIRONMENT: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

const emptyData: DashboardData = { runs: [], baselines: {}, trials: [], loadErrors: [] };

function fixtureRun(overrides: Partial<Run> = {}): Run {
  return {
    schema: 'ableton-linux-profiler-history/v1',
    run_id: '20261016T120000Z-baseline',
    tag: 'baseline',
    started_at: '2026-10-16T12:00:00Z',
    machine_id: 'm-test',
    hostname: 'abletonlinux',
    virtualization: 'vmware',
    structure: 'benchmark',
    scenario: null,
    trace_mode: 'off',
    duration_s: 120,
    runtime: { dist_version: '11.13', source_tree_sha: 'abc', dev_info: null },
    switches: {},
    harness_sha: 'h',
    commit: 'c',
    trial: null,
    arm: null,
    source_dir: 'runs/x',
    sets: {},
    ...overrides,
  };
}

function text(element: Element | null | undefined): string {
  return (element?.textContent ?? '').replace(/\s+/g, ' ').trim();
}

function tabButton(container: ParentNode, label: string): HTMLButtonElement {
  const button = Array.from(container.querySelectorAll<HTMLButtonElement>('[role="tab"]')).find((el) => el.textContent === label);
  if (!button) throw new Error(`tab "${label}" not found`);
  return button;
}

function selectNamed(container: ParentNode, name: string): HTMLSelectElement {
  const select = container.querySelector<HTMLSelectElement>(`select[name="${name}"]`);
  if (!select) throw new Error(`select "${name}" not found`);
  return select;
}

describe('App shell', () => {
  let container: HTMLDivElement;
  let root: Root;

  beforeEach(() => {
    window.location.hash = '';
    localStorage.clear();
    sessionStorage.clear();
    container = document.createElement('div');
    document.body.appendChild(container);
    root = createRoot(container);
  });

  afterEach(() => {
    act(() => root.unmount());
    container.remove();
  });

  it('renders the seven tabs in reading order and opens Overview by default', () => {
    act(() => root.render(<App data={emptyData} />));
    const tabs = Array.from(container.querySelectorAll('[role="tab"]')).map((el) => el.textContent);
    expect(tabs).toEqual(['Overview', 'Trends', 'Trials', 'Call sites', 'Scenarios', 'Runs', 'Architecture']);
    expect(TABS.map((t) => t.id)).toEqual(['overview', 'trends', 'trials', 'callsites', 'scenarios', 'runs', 'architecture']);
    const selected = container.querySelector('[role="tab"][aria-selected="true"]');
    expect(selected?.textContent).toBe('Overview');
    expect(container.querySelector('[role="tabpanel"] h2')?.textContent).toBe('Overview');
  });

  it('switches panels on click and mirrors the tab in the URL hash', () => {
    act(() => root.render(<App data={emptyData} />));
    const trials = tabButton(container, 'Trials');
    act(() => trials.click());
    expect(container.querySelector('[role="tabpanel"] h2')?.textContent).toBe('Trials');
    expect(window.location.hash).toBe('#trials');
  });

  it('opens the tab named in the URL hash', () => {
    window.location.hash = '#runs';
    act(() => root.render(<App data={emptyData} />));
    expect(container.querySelector('[role="tab"][aria-selected="true"]')?.textContent).toBe('Runs');
  });

  it('hides the FilterBar on the Architecture tab, which ignores the filter', () => {
    act(() => root.render(<App data={emptyData} />));
    expect(container.querySelector('.filterbar-slot')).not.toBeNull();
    act(() => tabButton(container, 'Architecture').click());
    expect(container.querySelector('.filterbar-slot')).toBeNull();
    expect(window.location.hash).toBe('#architecture');
    act(() => tabButton(container, 'Overview').click());
    expect(container.querySelector('.filterbar-slot')).not.toBeNull();
  });

  it('shows the empty state without runs and the counts with data', () => {
    act(() => root.render(<App data={emptyData} />));
    expect(container.querySelector('.empty')?.textContent).toContain('history-add');

    const withData: DashboardData = { ...emptyData, runs: [fixtureRun()] };
    act(() => root.render(<App data={withData} />));
    expect(container.querySelector('.app-meta')?.textContent).toContain('1 run');
    expect(container.querySelector('.empty')).toBeNull();
  });

  it('applies the theme choice to <html data-theme>', () => {
    act(() => root.render(<App data={emptyData} />));
    const dark = Array.from(container.querySelectorAll<HTMLButtonElement>('.theme-toggle button')).find(
      (el) => el.textContent === 'Dark',
    );
    act(() => dark!.click());
    expect(document.documentElement.getAttribute('data-theme')).toBe('dark');
    expect(localStorage.getItem('profiler-dashboard.theme')).toBe('dark');
    const system = Array.from(container.querySelectorAll<HTMLButtonElement>('.theme-toggle button')).find(
      (el) => el.textContent === 'System',
    );
    act(() => system!.click());
    expect(document.documentElement.hasAttribute('data-theme')).toBe(false);
    expect(localStorage.getItem('profiler-dashboard.theme')).toBeNull();
  });

  it('lists load warnings under the header', () => {
    act(() => root.render(<App data={{ ...emptyData, loadErrors: ['bad.json: missing sets', 'ledger.jsonl:3: invalid JSON; skipped'] }} />));
    expect(text(container.querySelector('.app-meta'))).toContain('2 load warnings');
    const details = container.querySelector('details.load-warnings');
    expect(text(details?.querySelector('summary'))).toContain('2 load warnings');
    expect(Array.from(details?.querySelectorAll('li') ?? []).map(text)).toEqual(['bad.json: missing sets', 'ledger.jsonl:3: invalid JSON; skipped']);

    act(() => root.render(<App data={emptyData} />));
    expect(container.querySelector('.load-warnings')).toBeNull();
  });
});

describe('App integration (seven views, one filter)', () => {
  let container: HTMLDivElement;
  let root: Root;
  let consoleError: ReturnType<typeof vi.spyOn>;
  let consoleWarn: ReturnType<typeof vi.spyOn>;

  beforeEach(() => {
    window.location.hash = '';
    localStorage.clear();
    sessionStorage.clear();
    container = document.createElement('div');
    document.body.appendChild(container);
    root = createRoot(container);
    consoleError = vi.spyOn(console, 'error').mockImplementation(() => {});
    consoleWarn = vi.spyOn(console, 'warn').mockImplementation(() => {});
  });

  afterEach(() => {
    act(() => root.unmount());
    container.remove();
    consoleError.mockRestore();
    consoleWarn.mockRestore();
  });

  it('renders every tab with fixture data and writes nothing to console.error / console.warn', () => {
    act(() => root.render(<App data={FIXTURE_DATA} />));
    for (const tab of TABS) {
      act(() => tabButton(container, tab.label).click());
      const panel = container.querySelector('[role="tabpanel"]');
      expect(text(panel?.querySelector('h2'))).toBe(tab.label);
      expect(panel?.getAttribute('aria-labelledby')).toBe(`tab-${tab.id}`);
      expect(text(panel?.querySelector('.empty'))).not.toContain('No runs yet');
    }
    expect(consoleError.mock.calls).toEqual([]);
    expect(consoleWarn.mock.calls).toEqual([]);
  });

  it('renders every tab without runs and writes nothing to the console', () => {
    act(() => root.render(<App data={EMPTY_DATA} />));
    for (const tab of TABS) {
      act(() => tabButton(container, tab.label).click());
      expect(text(container.querySelector('[role="tabpanel"] h2'))).toBe(tab.label);
    }
    expect(consoleError.mock.calls).toEqual([]);
    expect(consoleWarn.mock.calls).toEqual([]);
  });

  it('shares one filter across tabs and remembers it for the reload a new run triggers', () => {
    act(() => root.render(<App data={FIXTURE_DATA} />));
    const status = () => text(container.querySelector('.filterbar-status'));
    expect(status()).toContain(`${FIXTURE_DATA.runs.length} runs in slice`);

    choose(selectNamed(container, 'machine'), 'm2');
    expect(status()).toContain('1 run in slice');
    expect(JSON.parse(sessionStorage.getItem(FILTER_STORAGE_KEY) ?? 'null')).toEqual({ ...DEFAULT_FILTER, machine: 'm2' });

    // the same FilterBar state scopes the next view
    act(() => tabButton(container, 'Runs').click());
    expect(selectNamed(container, 'machine').value).toBe('m2');
    expect(status()).toContain('1 run in slice');
    expect(container.querySelectorAll('[role="tabpanel"] table tbody tr')).toHaveLength(1);

    // a fresh mount (what the HMR page reload does) restores it
    act(() => root.unmount());
    root = createRoot(container);
    act(() => root.render(<App data={FIXTURE_DATA} />));
    expect(selectNamed(container, 'machine').value).toBe('m2');
    expect(status()).toContain('1 run in slice');

    // Reset clears the state and the stored copy
    const reset = Array.from(container.querySelectorAll<HTMLButtonElement>('.filterbar-status button')).find((el) => el.textContent === 'Reset');
    act(() => reset!.click());
    expect(status()).toContain(`${FIXTURE_DATA.runs.length} runs in slice`);
    expect(sessionStorage.getItem(FILTER_STORAGE_KEY)).toBeNull();
    expect(consoleError.mock.calls).toEqual([]);
  });

  it('drops remembered filter values the data no longer offers', () => {
    sessionStorage.setItem(
      FILTER_STORAGE_KEY,
      JSON.stringify({ ...DEFAULT_FILTER, machine: 'retired-machine', set: 'Benchmark_VSTs', environment: 'bogus', switch: 'none', traceMode: 'drilldown' }),
    );
    act(() => root.render(<App data={FIXTURE_DATA} />));
    expect(selectNamed(container, 'machine').value).toBe('');
    expect(selectNamed(container, 'environment').value).toBe('all');
    expect(selectNamed(container, 'traceMode').value).toBe('');
    expect(selectNamed(container, 'set').value).toBe('Benchmark_VSTs');
    expect(selectNamed(container, 'switch').value).toBe('none');

    sessionStorage.setItem(FILTER_STORAGE_KEY, '{not json');
    act(() => root.unmount());
    root = createRoot(container);
    act(() => root.render(<App data={FIXTURE_DATA} />));
    expect(selectNamed(container, 'set').value).toBe('');
  });

  it('views can narrow the shared filter (clicking a Set heading in Overview)', () => {
    act(() => root.render(<App data={FIXTURE_DATA} />));
    const heading = container.querySelector<HTMLButtonElement>('.overview-set .set-heading');
    expect(heading).not.toBeNull();
    act(() => heading!.click());
    expect(selectNamed(container, 'set').value).not.toBe('');
    expect(container.querySelectorAll('.overview-set')).toHaveLength(1);
  });

  it('boots with the committed history, baselines and ledger without console errors', () => {
    const data = loadDashboardData();
    act(() => root.render(<App data={data} />));
    expect(text(container.querySelector('.app-meta'))).toContain(`${data.runs.length} run`);
    expect(container.querySelector('[role="tabpanel"] h2')?.textContent).toBe('Overview');
    expect(consoleError.mock.calls).toEqual([]);
  });
});
