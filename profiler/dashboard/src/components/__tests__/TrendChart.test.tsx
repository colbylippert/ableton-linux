import { afterEach, describe, expect, it } from 'vitest';
import { PALETTE } from '../../palette';
import TrendChart, {
  buildRows,
  formatSignedDelta,
  groupMarkers,
  niceTicks,
  paddedDomain,
  sampleTicks,
  signedDeltaOf,
  significanceFor,
  type TrendMarker,
  type TrendSeries,
} from '../TrendChart';
import { all, byText, click, mount, text, type Mounted } from './harness';

const T0 = Date.UTC(2026, 9, 16, 12, 0, 0);
const HOUR = 3600e3;

function series(id: string, slot: 1 | 2 | 3, values: (number | null)[], extra: Partial<TrendSeries> = {}): TrendSeries {
  return {
    id,
    label: id,
    slot,
    points: values.map((value, i) => {
      const switches: Record<string, string> = i === 2 ? { WINE_FOO: '1' } : {};
      return {
        t: T0 + i * HOUR,
        runId: `r${i + 1}`,
        tag: `tag${i + 1}`,
        value,
        arm: i === 2 ? 'B' : null,
        trial: i === 2 ? 'T0007' : null,
        switches,
      };
    }),
    ...extra,
  };
}

const fmt = (v: number | null) => (v === null ? '—' : `${v.toFixed(2)}/min`);
const markers: TrendMarker[] = [
  { t: T0 + 2 * HOUR, trial: 'T0007', verdict: 'keep', label: 'T0007' },
  { t: T0 + 3 * HOUR, trial: 'T0008', verdict: 'revert', label: 'T0008' },
  { t: T0 + 1 * HOUR, trial: 'T0006', verdict: 'tooling', label: 'T0006' },
];

const base = {
  unit: '/min',
  direction: 'lower' as const,
  format: fmt,
  table: { caption: 'Zero: late blocks per run' },
  width: 640,
};

describe('TrendChart helpers', () => {
  it('merges series by run with nulls for missing values', () => {
    const rows = buildRows([series('a', 1, [1, 2, 3]), series('b', 2, [4, null])]);
    expect(rows.map((r) => r.runId)).toEqual(['r1', 'r2', 'r3']);
    expect(rows.map((r) => r.v0)).toEqual([1, 2, 3]);
    expect(rows.map((r) => r.v1)).toEqual([4, null, null]);
  });

  it('signs the delta so that positive = improvement and gates significance at 2 × spread', () => {
    expect(signedDeltaOf(8, 10, 'lower')).toEqual({ abs: 2, pct: 0.2 });
    expect(signedDeltaOf(12, 10, 'higher')).toEqual({ abs: 2, pct: 0.2 });
    expect(signedDeltaOf(12, 10, 'lower').abs).toBe(-2);
    expect(signedDeltaOf(5, 0, 'lower').pct).toBeNull();
    expect(significanceFor(2.1, 2)).toBe('beyond');
    expect(significanceFor(2, 2)).toBe('within');
    expect(significanceFor(2, null)).toBe('unknown');
    expect(formatSignedDelta(2, 0.2, fmt)).toBe('+2.00/min (+20.0%)');
    expect(formatSignedDelta(-2, null, fmt)).toBe('−2.00/min');
    expect(sampleTicks([5, 1, 3, 3], 10)).toEqual([1, 3, 5]);
    expect(sampleTicks(Array.from({ length: 50 }, (_, i) => i), 5)).toEqual([0, 12, 25, 37, 49]);
  });

  it('drops markers outside the plotted runs and merges markers sharing one x', () => {
    const groups = groupMarkers(
      [
        { t: 10, trial: 'T1', verdict: 'keep', label: 'T1' },
        { t: 10, trial: 'T2', verdict: 'revert', label: 'T2' },
        { t: 10, trial: 'T3', verdict: 'tooling', label: 'T3' },
        { t: 20, trial: 'T4', verdict: 'inconclusive', label: 'T4' },
        { t: 99, trial: 'T5', verdict: 'keep', label: 'T5' },
        { t: 1, trial: 'T6', verdict: 'keep', label: 'T6' },
        { t: 25, trial: 'T7', verdict: 'revert', label: '✗ T7' },
      ],
      5,
      30,
    );
    expect(groups).toEqual([
      { t: 10, status: 'good', label: '✓ T1 · ✗ T2' },
      { t: 20, status: 'dim', label: '' },
      { t: 25, status: 'critical', label: '✗ T7' },
    ]);
  });

  it('snaps y ticks to clean steps covering the padded range', () => {
    expect(niceTicks(2.76, 6.24)).toEqual([2, 3, 4, 5, 6, 7]);
    expect(niceTicks(0, 10.8)).toEqual([0, 5, 10, 15]);
    expect(niceTicks(0, 9)).toEqual([0, 2.5, 5, 7.5, 10]);
    expect(niceTicks(0.9, 1.1)).toEqual([0.9, 0.95, 1, 1.05, 1.1]);
    expect(niceTicks(812_000, 950_000)).toEqual([800_000, 850_000, 900_000, 950_000]);
    expect(niceTicks(4, 4)).toEqual([4, 4.1, 4.2, 4.3, 4.4]);
    expect(niceTicks(-0.3, 0.2)).toEqual([-0.4, -0.2, 0, 0.2]);
  });

  it('pads the y domain without dipping a non-negative range below zero', () => {
    expect(paddedDomain([0, 10])).toEqual([0, 10.8]);
    expect(paddedDomain([2, 12])).toEqual([1.2, 12.8]);
    expect(paddedDomain([-5, 5])).toEqual([-5.8, 5.8]);
    expect(paddedDomain([4, 4])).toEqual([3.6, 4.4]);
    expect(paddedDomain([0, 0])).toEqual([0, 1]);
  });
});

describe('TrendChart', () => {
  let mounted: Mounted | null = null;
  afterEach(() => {
    mounted?.unmount();
    mounted = null;
  });

  it('renders one path per series, the baseline, the band and status-coloured markers; no legend for one series', () => {
    mounted = mount(
      <TrendChart
        {...base}
        title="Zero"
        series={[series('Zero', 1, [3.2, 3.1, null, 2.6])]}
        baseline={{ value: 3.2, runId: 'r1', label: 'baseline' }}
        noiseBand={{ center: 3.2, halfWidth: 0.4, pairs: 2 }}
        markers={markers}
      />,
    );
    const c = mounted.container;
    expect(all(c, '.recharts-line-curve')).toHaveLength(1);
    expect(all(c, '.recharts-line-curve')[0]?.getAttribute('stroke')).toBe(PALETTE.light.series[0]);
    expect(all(c, '.recharts-line-curve')[0]?.getAttribute('stroke-width')).toBe('2');
    expect(c.querySelector('.trend-baseline')).not.toBeNull();
    expect(c.querySelector('.trend-band')).not.toBeNull();
    expect(all(c, '.trend-marker-good')).toHaveLength(1);
    expect(all(c, '.trend-marker-critical')).toHaveLength(1);
    expect(all(c, '.trend-marker-dim')).toHaveLength(1);
    expect(all(c, '.trend-marker-label').map(text)).toEqual(['✓ T0007', '✗ T0008']);
    expect(all(c, '.trend-baseline-label').map(text)).toEqual(['baseline']);
    expect(c.querySelector('.legend')).toBeNull();
    const key = text(c.querySelector('.chart-key'));
    expect(key).toContain('baseline 3.20/min');
    expect(key).toContain('A/A band ±0.40/min (2 pairs)');
    expect(key).toContain('kept trial');
    expect(all(c, '.trend-end-label').map(text)).toEqual(['2.60/min']);
    expect(all(c, '.recharts-line-dot').length).toBeGreaterThanOrEqual(3);
  });

  it('draws no baseline or band when they are not provided', () => {
    mounted = mount(<TrendChart {...base} title="Zero" series={[series('Zero', 1, [1, 2])]} baseline={null} noiseBand={null} markers={[]} />);
    expect(mounted.container.querySelector('.trend-baseline')).toBeNull();
    expect(mounted.container.querySelector('.trend-band')).toBeNull();
    expect(mounted.container.querySelector('.chart-key')).toBeNull();
    expect(all(mounted.container, '.trend-marker')).toHaveLength(0);
  });

  it('shows a legend for two series, isolates on click and labels every line end', () => {
    mounted = mount(
      <TrendChart {...base} title="Overlay" series={[series('Zero', 1, [1, 2, 3]), series('Empty', 2, [2, 2, 1])]} baseline={null} noiseBand={null} markers={[]} />,
    );
    const c = mounted.container;
    expect(all(c, '.recharts-line-curve')).toHaveLength(2);
    expect(all(c, '.trend-end-label').map(text)).toEqual(['3.00/min', '1.00/min']);
    const buttons = all<HTMLButtonElement>(c, '.legend button');
    expect(buttons.map(text)).toEqual(['Zero', 'Empty']);
    // jsdom (like browsers) normalises an inline hex background to rgb(): #ff6b35 → rgb(255, 107, 53)
    expect((buttons[1]?.querySelector('.legend-key') as HTMLElement | null)?.style.background).toBe('rgb(255, 107, 53)');
    expect(PALETTE.light.series[1]).toBe('#ff6b35');
    click(buttons[0]);
    expect(buttons[0]?.getAttribute('aria-pressed')).toBe('true');
    expect(all(c, '.recharts-line-curve')).toHaveLength(1);
    expect(all(c, '.legend button.is-muted').map(text)).toEqual(['Empty']);
    click(all<HTMLButtonElement>(c, '.legend button')[0]);
    expect(all(c, '.recharts-line-curve')).toHaveLength(2);
  });

  it('emphasis draws the named series in its hue and the rest in the de-emphasis gray, on top', () => {
    mounted = mount(
      <TrendChart
        {...base}
        title="Call sites"
        series={[series('a', 1, [1, 2]), series('b', 1, [2, 3]), series('c', 1, [3, 1])]}
        emphasis="b"
        baseline={null}
        noiseBand={null}
        markers={[]}
      />,
    );
    const strokes = all(mounted.container, '.recharts-line-curve').map((p) => p.getAttribute('stroke'));
    expect(strokes).toEqual([PALETTE.light.seriesDim, PALETTE.light.seriesDim, PALETTE.light.series[0]]);
    expect(all(mounted.container, '.trend-end-label').map(text)).toEqual(['3.00/min']);
  });

  it('table twin lists every run with formatted values, nulls as —, delta and significance', () => {
    mounted = mount(
      <TrendChart
        {...base}
        title="Zero"
        series={[series('Zero', 1, [3.2, 3.1, null, 2.6])]}
        baseline={{ value: 3.2, runId: 'r1' }}
        noiseBand={{ center: 3.2, halfWidth: 0.4, pairs: 2 }}
        markers={markers}
      />,
    );
    click(byText(mounted.container, '.chart-frame-toggle button', 'Table'));
    const rows = all(mounted.container, 'tbody tr');
    expect(rows).toHaveLength(4);
    const cells = (i: number) => all(rows[i]!, 'td').map(text);
    // chip text = icon glyph + label (adjacent spans; the icon is aria-hidden)
    expect(cells(0)).toEqual(['r1 · baseline', '2026-10-16 12:00 UTC', 'tag1', '—', '—', '3.20/min', '0.00/min (0.0%)', '≈within noise']);
    expect(cells(2)).toEqual(['r3', '2026-10-16 14:00 UTC', 'tag3', 'T0007 / B', 'WINE_FOO=1', '—', '—', '—']);
    expect(cells(3).slice(5)).toEqual(['2.60/min', '+0.60/min (+18.8%)', '▲beyond noise']);
    // header text minus the sort glyph on the default-sorted column
    expect(all(mounted.container, 'th').map((th) => text(th).replace(/[▲▼]$/u, ''))).toEqual([
      'Run',
      'Started',
      'Tag',
      'Trial / arm',
      'Switches',
      'Value (/min)',
      'Δ vs baseline',
      'Significance',
    ]);
    expect(mounted.container.querySelectorAll('th')[1]?.getAttribute('aria-sort')).toBe('ascending');
  });

  it('renders the empty state when no series has points', () => {
    mounted = mount(<TrendChart {...base} title="Empty" series={[series('Zero', 1, [])]} baseline={null} noiseBand={null} markers={[]} />);
    expect(text(mounted.container.querySelector('.chart-frame-empty'))).toBe('No runs in this slice.');
    expect(mounted.container.querySelector('svg')).toBeNull();
  });
});
