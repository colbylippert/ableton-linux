import { afterEach, describe, expect, it } from 'vitest';
import { formatPct } from '../../data';
import PairedDots, { PairedDotsTable, niceTicks, pairDeltaText, pairedDotsSummary, type PairedDotsPair } from '../PairedDots';
import { focusIn, mount, type Mounted } from './d3-harness';

const fmt = (v: number | null) => formatPct(v, 1);

const PAIRS: PairedDotsPair[] = [
  { index: 1, a: 41.1, b: 39.8, runA: 'a1', runB: 'b1' },
  { index: 2, a: 41.0, b: 39.9, runA: 'a2', runB: 'b2' },
  { index: 3, a: 41.2, b: 40.0, runA: 'a3', runB: 'b3' },
];

describe('pairedDotsSummary', () => {
  it('takes the median signed delta over pairs and judges it against 2 × spread', () => {
    const s = pairedDotsSummary(PAIRS, 'lower', 0.4);
    expect(s.n).toBe(3);
    expect(s.medianDelta).toBeCloseTo(1.2, 6);
    expect(s.ratio).toBeCloseTo(3, 6);
    expect(s.significance).toBe('beyond');
    expect(s.direction).toBe('better');
  });

  it('is unknown without a spread, worse for a regression, neutral for neutral metrics', () => {
    expect(pairedDotsSummary(PAIRS, 'lower').significance).toBe('unknown');
    expect(pairedDotsSummary(PAIRS, 'lower').ratio).toBeNull();
    expect(pairedDotsSummary(PAIRS, 'higher', 0.4).direction).toBe('worse');
    expect(pairedDotsSummary(PAIRS, 'neutral', 0.4).direction).toBe('neutral');
    expect(pairedDotsSummary([{ index: 1, a: null, b: 1, runA: 'a', runB: 'b' }], 'lower', 1).n).toBe(0);
  });
});

describe('pairDeltaText / niceTicks', () => {
  it('puts the direction on the glyph and keeps the number unsigned', () => {
    expect(pairDeltaText(41.1, 39.8, 'lower', fmt)).toEqual({ glyph: '▲', status: 'good', text: '1.3%' });
    expect(pairDeltaText(41.1, 39.8, 'higher', fmt)).toEqual({ glyph: '▼', status: 'critical', text: '1.3%' });
    expect(pairDeltaText(2, 2, 'lower', fmt)).toEqual({ glyph: '', status: 'none', text: '0.0%' });
    expect(pairDeltaText(null, 1, 'lower', fmt).text).toBe('—');
    expect(pairDeltaText(8, 10, 'neutral', fmt).text).toBe('+2.0%');
  });

  it('produces clean tick values', () => {
    expect(niceTicks(0, 1)).toEqual([0, 0.25, 0.5, 0.75, 1]);
    expect(niceTicks(39, 42)).toEqual([39, 40, 41, 42]);
    expect(niceTicks(5, 5)).toEqual([5]);
  });
});

describe('<PairedDots>', () => {
  let m: Mounted | null = null;
  afterEach(() => {
    m?.unmount();
    m = null;
  });

  it('draws one dumbbell per pair with the wash, 24 px hit targets and a delta label per row', () => {
    m = mount(<PairedDots pairs={PAIRS} unit="%" direction="lower" format={fmt} spread={0.4} width={600} />);
    expect(m.$$('.pd-dot')).toHaveLength(6);
    expect(m.$$('.pd-connector')).toHaveLength(3);
    expect(m.$$('.pd-wash')).toHaveLength(3);
    const hits = m.$$('.pd-hit');
    expect(hits).toHaveLength(6);
    expect(hits[0]?.getAttribute('r')).toBe('12');
    expect(hits[0]?.getAttribute('aria-label')).toContain('pair 1 arm A: 41.1% %');
    const deltas = m.$$('.pd-delta').map((el) => el.textContent?.replace(/\s+/gu, ' ').trim());
    expect(deltas).toEqual(['▲ 1.3%', '▲ 1.1%', '▲ 1.2%']);
    expect(m.$('.pd-glyph-good')).not.toBeNull();
    expect(m.$('svg')?.getAttribute('width')).toBe('600');
  });

  it('shows the same tooltip on keyboard focus as on hover', () => {
    m = mount(<PairedDots pairs={PAIRS} unit="%" direction="lower" format={fmt} width={600} />);
    expect(m.$('[role="tooltip"]')).toBeNull();
    focusIn(m.$$('.pd-hit')[1]);
    const tip = m.$('[role="tooltip"]');
    expect(tip?.textContent).toContain('39.8% %');
    expect(tip?.textContent).toContain('b1');
  });

  it('keeps a half pair and renders — for its delta; no values → empty state', () => {
    const pairs: PairedDotsPair[] = [PAIRS[0]!, { index: 2, a: 41.0, b: null, runA: 'a2', runB: 'b2' }];
    m = mount(<PairedDots pairs={pairs} unit="%" direction="lower" format={fmt} width={600} />);
    expect(m.$$('.pd-dot')).toHaveLength(3);
    expect(m.$$('.pd-connector')).toHaveLength(1);
    expect(m.$$('.pd-delta')[1]?.textContent?.trim()).toBe('—');
    m.rerender(<PairedDots pairs={[{ index: 1, a: null, b: null, runA: 'a', runB: 'b' }]} unit="%" direction="lower" format={fmt} width={600} />);
    expect(m.$('.empty')).not.toBeNull();
  });

  it('has a table twin listing every value and run id', () => {
    m = mount(<PairedDotsTable pairs={PAIRS} direction="lower" format={fmt} caption="pairs" />);
    const rows = m.$$('tbody tr');
    expect(rows).toHaveLength(3);
    expect(rows[0]?.textContent).toContain('a1');
    expect(rows[0]?.textContent).toContain('41.1%');
    expect(rows[0]?.textContent).toContain('▲ 1.3%');
  });
});
