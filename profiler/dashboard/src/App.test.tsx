import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { act } from 'react';
import { createRoot, type Root } from 'react-dom/client';
import App, { TABS } from './App';
import type { DashboardData, Run } from './data/types';

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

describe('App shell', () => {
  let container: HTMLDivElement;
  let root: Root;

  beforeEach(() => {
    window.location.hash = '';
    container = document.createElement('div');
    document.body.appendChild(container);
    root = createRoot(container);
  });

  afterEach(() => {
    act(() => root.unmount());
    container.remove();
  });

  it('renders the six tabs in reading order and opens Overview by default', () => {
    act(() => root.render(<App data={emptyData} />));
    const tabs = Array.from(container.querySelectorAll('[role="tab"]')).map((el) => el.textContent);
    expect(tabs).toEqual(['Overview', 'Trends', 'Trials', 'Call sites', 'Scenarios', 'Runs']);
    expect(TABS.map((t) => t.id)).toEqual(['overview', 'trends', 'trials', 'callsites', 'scenarios', 'runs']);
    const selected = container.querySelector('[role="tab"][aria-selected="true"]');
    expect(selected?.textContent).toBe('Overview');
    expect(container.querySelector('[role="tabpanel"] h2')?.textContent).toBe('Overview');
  });

  it('switches panels on click and mirrors the tab in the URL hash', () => {
    act(() => root.render(<App data={emptyData} />));
    const trials = Array.from(container.querySelectorAll<HTMLButtonElement>('[role="tab"]')).find(
      (el) => el.textContent === 'Trials',
    );
    expect(trials).toBeDefined();
    act(() => trials!.click());
    expect(container.querySelector('[role="tabpanel"] h2')?.textContent).toBe('Trials');
    expect(window.location.hash).toBe('#trials');
  });

  it('opens the tab named in the URL hash', () => {
    window.location.hash = '#runs';
    act(() => root.render(<App data={emptyData} />));
    expect(container.querySelector('[role="tab"][aria-selected="true"]')?.textContent).toBe('Runs');
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
    const system = Array.from(container.querySelectorAll<HTMLButtonElement>('.theme-toggle button')).find(
      (el) => el.textContent === 'System',
    );
    act(() => system!.click());
    expect(document.documentElement.hasAttribute('data-theme')).toBe(false);
  });
});
