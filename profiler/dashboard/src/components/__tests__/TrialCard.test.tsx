import { afterEach, describe, expect, it } from 'vitest';
import { joinTrials } from '../../data';
import { RUN, fixtureRuns, fixtureTrials, runById, trialById } from '../../data/__fixtures__';
import TrialCard, { defaultMetricFor, metricOptionsFor, probeText, runDirHref, shareOf } from '../TrialCard';
import { change, mount, type Mounted } from './d3-harness';

const joins = joinTrials(fixtureTrials, fixtureRuns);
const joinOf = (id: string) => {
  const j = joins.find((x) => x.trial.trial === id);
  if (!j) throw new Error(`no join for ${id}`);
  return j;
};

describe('TrialCard helpers', () => {
  it('links absolute run directories only', () => {
    expect(runDirHref({ source_dir: '/home/colby/.local/share/profiler/runs/x' })).toBe('file:///home/colby/.local/share/profiler/runs/x');
    expect(runDirHref({ source_dir: 'C:\\runs\\x' })).toBe('file:///C:/runs/x');
    expect(runDirHref({ source_dir: 'profiler/runs/x' })).toBeNull();
    expect(runDirHref({ source_dir: null })).toBeNull();
  });

  it('offers the metrics the ABAB runs carry and defaults to the ledger primary', () => {
    const abab = [runById(RUN.a1), runById(RUN.b1)];
    const options = metricOptionsFor(abab);
    expect(options).toContain('live_cpu_pct_per_core');
    expect(options).toContain('voluntary_switches_per_s');
    expect(options).not.toContain('late_blocks_per_min');
    expect(defaultMetricFor(trialById('T0007'), options)).toBe('live_cpu_pct_per_core');
    expect(defaultMetricFor({ ...trialById('T0007'), metrics: null }, ['voluntary_switches_per_s'])).toBe('voluntary_switches_per_s');
    expect(defaultMetricFor(trialById('T0007'), [])).toBeNull();
  });

  it('formats the probe result and reads a call-site share', () => {
    expect(probeText(trialById('T0007'))).toBe('5 ✓ 0 ✗ 1 ↷');
    expect(probeText(trialById('T0001'))).toBe('—');
    expect(shareOf(runById(RUN.tracedB), 'Benchmark_VSTs', 'ntsync_wait|NtWaitForSingleObject|ntdll+0x7f3a1')).toBe(0.11);
    expect(shareOf(runById(RUN.tracedB), 'Benchmark_Zero', 'x')).toBeNull();
    expect(shareOf(null, 'Benchmark_Zero', 'x')).toBeNull();
  });
});

describe('<TrialCard>', () => {
  let m: Mounted | null = null;
  afterEach(() => {
    m?.unmount();
    m = null;
  });

  it('shows the kept trial with its pairs per Set, the traced confirmation and the run references', () => {
    m = mount(<TrialCard join={joinOf('T0007')} runs={fixtureRuns} trials={fixtureTrials} />);
    expect(m.$('article.tc')?.getAttribute('data-verdict')).toBe('keep');
    expect(m.$('.tc-title .chip-good')?.textContent).toContain('keep');
    expect(m.text()).toContain('Coalescing ntsync waits');
    expect(m.text()).toContain('5 ✓ 0 ✗ 1 ↷');
    expect(m.text()).toContain('WINE_FOO=1');
    // 5 Sets × PairedDots + 1 traced confirmation
    expect(m.$$('figure.chart-frame')).toHaveLength(6);
    expect(m.$$('.pd-dot')).toHaveLength(30);
    expect(m.$('select[aria-label="Metric for the ABAB pairs"]')?.getAttribute('value') ?? (m.$('select') as HTMLSelectElement).value).toBe('live_cpu_pct_per_core');
    expect(m.text()).toContain('62.0% → 11.0%');
    expect(m.$$('.db-bar')).toHaveLength(2);
    expect(m.$$('.tc-runref')).toHaveLength(10);
    expect(m.text()).not.toContain('missing record');
    expect(m.$('.tc-guard')).toBeNull();
    const vsts = m.$$('figure.chart-frame').find((f) => f.textContent?.includes('VSTs — Live CPU / core'));
    expect(vsts?.textContent).toContain('beyond noise');
  });

  it('switches the plotted metric', () => {
    m = mount(<TrialCard join={joinOf('T0007')} runs={fixtureRuns} trials={fixtureTrials} />);
    change(m.$<HTMLSelectElement>('select'), 'voluntary_switches_per_s');
    expect(m.$$('figure.chart-frame')[0]?.textContent).toContain('Voluntary switches');
  });

  it('calls out missing run records and the xrun guard on the reverted trial', () => {
    m = mount(<TrialCard join={joinOf('T0008')} runs={fixtureRuns} trials={fixtureTrials} />);
    expect(m.$('article.tc')?.getAttribute('data-verdict')).toBe('revert');
    expect(m.$$('.tc-runref .chip').filter((c) => c.textContent?.includes('missing record'))).toHaveLength(2);
    expect(m.$('.tc-missing')?.textContent).toContain('2 run references');
    expect(m.$('.tc-guard')?.textContent).toContain('reject');
    // the guard compares B with A per Set (xruns 0 on A, 1 on B)
    expect(m.$('.tc-guard')?.textContent).toContain('xruns 0 → 1 on B');
  });

  it('dims a tooling trial and reports no runs', () => {
    m = mount(<TrialCard join={joinOf('T0001')} runs={fixtureRuns} trials={fixtureTrials} />);
    expect(m.$('article.tc-dim')).not.toBeNull();
    expect(m.text()).toContain('No ABAB runs in history');
    expect(m.text()).toContain('NO TIMING CLAIMS');
  });
});
