import { afterEach, describe, expect, it, vi } from 'vitest';
import { aaSpread, identityOf } from '../../data';
import { RUN, SET, fixtureRuns, fixtureTrials, runById } from '../../data/__fixtures__';
import CompareDrawer, { compareRows, deltaCellText } from '../CompareDrawer';
import { click, mount, type Mounted } from './d3-harness';

const a1 = runById(RUN.a1);
const b1 = runById(RUN.b1);

describe('compareRows', () => {
  it('enriches runDelta rows with the identity A/A spread and the noise verdict', () => {
    const result = compareRows(a1, b1, fixtureRuns, fixtureTrials);
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    const vsts = result.rows.find((r) => r.set === SET.vsts && r.metric === 'live_cpu_pct_per_core');
    expect(vsts).toBeDefined();
    expect(vsts?.a).toBe(41.1);
    expect(vsts?.b).toBe(39.8);
    expect(vsts?.deltaAbs).toBeCloseTo(1.3, 9);
    expect(vsts?.deltaDirection).toBe('better');
    const spread = aaSpread(fixtureRuns, fixtureTrials, identityOf(a1), SET.vsts, 'live_cpu_pct_per_core');
    expect(spread).not.toBeNull();
    expect(vsts?.spread?.spread).toBe(spread?.spread);
    expect(vsts?.significance).toBe(Math.abs(1.3) > 2 * (spread?.spread ?? 0) ? 'beyond' : 'within');
    expect(vsts?.reject).toBe(false);
    const workers = result.rows.find((r) => r.set === SET.vsts && r.metric === 'audio_workers');
    expect(workers?.significance).toBe('unknown');
    expect(workers?.deltaDirection).toBe('neutral');
    // interface metrics never appear for untraced runs
    expect(result.rows.some((r) => r.source === 'interface')).toBe(false);
  });

  it('refuses identity mismatches with the reason', () => {
    const traced = compareRows(a1, runById(RUN.tracedA), fixtureRuns, fixtureTrials);
    expect(traced.ok).toBe(false);
    if (!traced.ok) expect(traced.reason).toContain('trace mode mismatch');
    const machine = compareRows(runById(RUN.vmBaseline), runById(RUN.baseline), fixtureRuns, fixtureTrials);
    expect(machine.ok).toBe(false);
    if (!machine.ok) expect(machine.reason).toContain('machine mismatch');
  });

  it('flags the xrun guard on arm B', () => {
    const result = compareRows(runById(RUN.t8a1), runById(RUN.t8b1), fixtureRuns, fixtureTrials);
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.rows.find((r) => r.set === SET.vsts && r.metric === 'xruns')?.reject).toBe(true);
  });

  it('formats the delta cell with the glyph, the unit and the relative change', () => {
    const result = compareRows(a1, b1, fixtureRuns, fixtureTrials);
    if (!result.ok) throw new Error('expected ok');
    const vsts = result.rows.find((r) => r.set === SET.vsts && r.metric === 'live_cpu_pct_per_core')!;
    expect(deltaCellText(vsts)).toEqual({ glyph: '▲', status: 'good', text: '1.3% (3.2%)' });
    const zero = result.rows.find((r) => r.set === SET.zero && r.metric === 'live_cpu_pct_per_core')!;
    expect(deltaCellText(zero)).toEqual({ glyph: '', status: 'none', text: '0.0% (0.0%)' });
  });
});

describe('<CompareDrawer>', () => {
  let m: Mounted | null = null;
  afterEach(() => {
    m?.unmount();
    m = null;
  });

  it('renders the per-Set table with status chips and the action buttons', () => {
    const onClose = vi.fn();
    const onSwap = vi.fn();
    m = mount(<CompareDrawer a={a1} b={b1} runs={fixtureRuns} trials={fixtureTrials} onClose={onClose} onSwap={onSwap} />);
    expect(m.$('section[aria-label="Compare runs"]')).not.toBeNull();
    expect(m.text()).toContain(RUN.a1);
    expect(m.text()).toContain(RUN.b1);
    expect(m.text()).toContain('outcome metrics (untraced runs)');
    expect(m.$$('tbody tr').length).toBeGreaterThan(5);
    const vstsRow = m.$$('tbody tr').find((tr) => tr.textContent?.includes('VSTs') && tr.textContent.includes('Live CPU / core'));
    expect(vstsRow?.textContent).toContain('41.1%');
    expect(vstsRow?.textContent).toContain('39.8%');
    expect(vstsRow?.textContent).toContain('1.3% (3.2%)');
    expect(vstsRow?.querySelector('.cd-bar-pos')).not.toBeNull();
    expect(vstsRow?.querySelector('.chip')?.textContent).toMatch(/beyond noise|within noise/u);
    click(m.$$('button.btn').find((b) => b.textContent?.includes('Swap')));
    expect(onSwap).toHaveBeenCalled();
    click(m.$$('button.btn').find((b) => b.textContent?.includes('Clear')));
    expect(onClose).toHaveBeenCalled();
  });

  it('shows the refusal ribbon for a trace-mode mismatch', () => {
    m = mount(<CompareDrawer a={a1} b={runById(RUN.tracedA)} runs={fixtureRuns} trials={fixtureTrials} />);
    expect(m.$('.cd-refuse')?.textContent).toContain('trace mode mismatch');
    expect(m.$('table')).toBeNull();
  });

  it('shows the reject chip for the guard and the ribbon for virtualised runs', () => {
    m = mount(<CompareDrawer a={runById(RUN.t8a1)} b={runById(RUN.t8b1)} runs={fixtureRuns} trials={fixtureTrials} />);
    const xruns = m.$$('tbody tr').find((tr) => tr.textContent?.includes('VSTs') && tr.textContent.includes('Xruns'));
    expect(xruns?.textContent).toContain('reject');
    m.rerender(<CompareDrawer a={runById(RUN.vmBaseline)} b={runById(RUN.vmBaseline)} runs={fixtureRuns} trials={fixtureTrials} />);
    expect(m.text()).toContain('NO TIMING CLAIMS');
  });
});
