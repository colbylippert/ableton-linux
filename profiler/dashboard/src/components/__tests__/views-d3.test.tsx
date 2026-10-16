/**
 * Smoke tests for the four D3 views (Trials, CallSites, Scenarios, Runs) against the
 * shared fixtures. They live here because D3 owns src/components/__tests__/.
 */
import { afterEach, describe, expect, it } from 'vitest';
import { DEFAULT_FILTER, type DashboardData, type FilterState } from '../../data/types';
import { trialMachine } from '../../data';
import { M1, M2, fixtureBaselines, fixtureRuns, fixtureTrials } from '../../data/__fixtures__';
import TrialsView from '../../views/Trials';
import CallSitesView from '../../views/CallSites';
import ScenariosView from '../../views/Scenarios';
import RunsView from '../../views/Runs';
import { click, mount, type Mounted } from './d3-harness';

const data: DashboardData = { runs: [...fixtureRuns], baselines: fixtureBaselines, trials: [...fixtureTrials], loadErrors: [] };
const empty: DashboardData = { runs: [], baselines: {}, trials: [], loadErrors: [] };
const noop = () => undefined;

describe('Trials view', () => {
  let m: Mounted | null = null;
  afterEach(() => {
    m?.unmount();
    m = null;
  });

  /** Rows of the ledger table only (the TrialCard below it has tables of its own). */
  const ledgerRows = () => Array.from(m?.$$('table')[0]?.querySelectorAll('tbody tr') ?? []);

  it('lists every ledger line with verdict chips and opens the latest trial', () => {
    m = mount(<TrialsView data={data} filter={DEFAULT_FILTER} onFilterChange={noop} />);
    expect(m.$('h2.view-title')?.textContent).toBe('Trials');
    expect(ledgerRows()).toHaveLength(fixtureTrials.length);
    const kept = fixtureTrials.filter((t) => t.verdict === 'keep').length;
    const reverted = fixtureTrials.filter((t) => t.verdict === 'revert').length;
    expect(m.text()).toContain(`${fixtureTrials.length} trials · ${kept} kept · ${reverted} reverted`);
    expect(m.$$('tbody .chip-good').length).toBeGreaterThan(0);
    expect(m.$$('tbody .chip-critical').length).toBeGreaterThan(0);
    const last = fixtureTrials[fixtureTrials.length - 1]!;
    expect(m.$('article.tc')?.getAttribute('aria-label')).toBe(`Trial ${last.trial}`);
    const t7 = m.$$('input[type="checkbox"]').find((cb) => cb.getAttribute('aria-label') === 'Select T0007');
    click(t7);
    expect(m.$('article.tc')?.getAttribute('aria-label')).toBe('Trial T0007');
    expect(m.$('article.tc')?.textContent).toContain('Coalescing ntsync waits');
  });

  it('scopes trials by the machine of their cited runs and shows an empty state without a ledger', () => {
    const vm: FilterState = { ...DEFAULT_FILTER, machine: M2 };
    m = mount(<TrialsView data={data} filter={vm} onFilterChange={noop} />);
    // trials whose cited runs resolve to the VM, plus trials with no run in history (machine unknown)
    const expected = fixtureTrials.filter((t) => {
      const machine = trialMachine(t, fixtureRuns);
      return machine === null || machine === M2;
    });
    expect(ledgerRows()).toHaveLength(expected.length);
    expect(m.text()).toContain('T0001');
    expect(m.text()).not.toContain('Coalescing ntsync waits');
    m.rerender(<TrialsView data={empty} filter={DEFAULT_FILTER} onFilterChange={noop} />);
    expect(m.$('.empty')?.textContent).toContain('ledger.jsonl');
  });
});

describe('CallSites view', () => {
  let m: Mounted | null = null;
  afterEach(() => {
    m?.unmount();
    m = null;
  });

  it('renders one card per identity × Set with fixed call-site colours and targeted-by chips', () => {
    m = mount(<CallSitesView data={data} filter={{ ...DEFAULT_FILTER, machine: M1 }} onFilterChange={noop} />);
    // benchmark/interface: Empty, Inbuilts, Max4Live, VSTs (Zero lists no call sites) + diagnostic/clip-launch-storm: Inbuilts
    expect(m.$$('figure.chart-frame')).toHaveLength(5);
    expect(m.$$('svg.recharts-surface').length).toBe(5);
    expect(m.text()).toContain('benchmark/- · interface');
    expect(m.text()).toContain('diagnostic/clip-launch-storm · interface');
    const chips = m.$$('.cst-legend .chip').map((c) => c.textContent);
    expect(chips.some((c) => c?.includes('T0007') && c.includes('keep'))).toBe(true);
    // the same key wears the same swatch colour in every card
    const swatches = m.$$('.cst-legend button').filter((b) => b.textContent?.includes('NtWaitForSingleObject')).map((b) => (b.querySelector('.cst-swatch') as HTMLElement).style.background);
    expect(new Set(swatches).size).toBe(1);
  });

  it('narrows to one Set without repainting its call sites, and shows the empty state without traced runs', () => {
    m = mount(<CallSitesView data={data} filter={{ ...DEFAULT_FILTER, machine: M1 }} onFilterChange={noop} />);
    const swatchOf = () =>
      (m?.$$('.cst-legend button').find((b) => b.textContent?.includes('NtWaitForSingleObject'))?.querySelector('.cst-swatch') as HTMLElement | undefined)?.style.background;
    const before = swatchOf();
    m.rerender(<CallSitesView data={data} filter={{ ...DEFAULT_FILTER, machine: M1, set: 'Benchmark_VSTs' }} onFilterChange={noop} />);
    expect(m.$$('figure.chart-frame')).toHaveLength(1);
    expect(swatchOf()).toBe(before);
    m.rerender(<CallSitesView data={data} filter={{ ...DEFAULT_FILTER, traceMode: 'off' }} onFilterChange={noop} />);
    expect(m.$('.empty')?.textContent).toContain('--trace interface');
  });

  it('raises the no-timing-claims ribbon for the virtualised machine', () => {
    m = mount(<CallSitesView data={data} filter={{ ...DEFAULT_FILTER, machine: M2 }} onFilterChange={noop} />);
    expect(m.text()).toContain('NO TIMING CLAIMS');
  });
});

describe('Scenarios view', () => {
  let m: Mounted | null = null;
  afterEach(() => {
    m?.unmount();
    m = null;
  });

  it('offers the diagnostic scenarios, plots late / near-late per Set and tabulates the hotspots', () => {
    m = mount(<ScenariosView data={data} filter={{ ...DEFAULT_FILTER, machine: M1 }} onFilterChange={noop} />);
    const select = m.$<HTMLSelectElement>('select[aria-label="Scenario"]');
    expect(Array.from(select?.options ?? []).map((o) => o.value)).toEqual(['clip-launch-storm']);
    expect(m.text()).toContain('2 runs · 2 traced (interface)');
    const frames = m.$$('figure.chart-frame');
    expect(frames).toHaveLength(2);
    expect(frames[0]?.textContent).toContain('Late blocks / min');
    expect(frames[1]?.textContent).toContain('Near-late blocks / min');
    const hotspots = m.$('section[aria-label="Non-audio hotspots"]');
    expect(hotspots?.textContent).toContain('Non-audio hotspots');
    expect(hotspots?.textContent).toContain('user32+0x1c3f0');
    expect(hotspots?.querySelectorAll('tbody tr')).toHaveLength(3);
    expect(hotspots?.textContent).toContain('▲'); // user32 fell from 48 ms to 36 ms: an improvement
    expect(hotspots?.textContent).toContain('new'); // gdi32 appeared in the latest run
  });

  it('shows an empty state without diagnostic runs', () => {
    m = mount(<ScenariosView data={data} filter={{ ...DEFAULT_FILTER, machine: M2 }} onFilterChange={noop} />);
    expect(m.$('.empty')?.textContent).toContain('--scenario');
  });
});

describe('Runs view', () => {
  let m: Mounted | null = null;
  afterEach(() => {
    m?.unmount();
    m = null;
  });

  it('lists every run in the slice and compares two picks inline', () => {
    m = mount(<RunsView data={data} filter={DEFAULT_FILTER} onFilterChange={noop} />);
    expect(m.$$('tbody tr')).toHaveLength(fixtureRuns.length);
    expect(m.text()).toContain('pick two runs to compare');
    expect(m.text()).toContain('NO TIMING CLAIMS');
    const boxes = m.$$<HTMLInputElement>('input[type="checkbox"]');
    const pick = (id: string) => click(boxes.find((cb) => cb.getAttribute('aria-label') === `Select ${id}`));
    pick('20261011T100000Z-T0007-a1');
    expect(m.text()).toContain('pick one more run');
    pick('20261011T103000Z-T0007-b1');
    const drawer = m.$('section[aria-label="Compare runs"]');
    expect(drawer).not.toBeNull();
    expect(drawer?.textContent).toContain('1.3% (3.2%)');
    click(m.$$('button.btn').find((b) => b.textContent?.includes('Clear')));
    expect(m.$('section[aria-label="Compare runs"]')).toBeNull();
  });

  it('shows the empty state without runs', () => {
    m = mount(<RunsView data={empty} filter={DEFAULT_FILTER} onFilterChange={noop} />);
    expect(m.$('.empty')?.textContent).toContain('history-add');
  });
});
