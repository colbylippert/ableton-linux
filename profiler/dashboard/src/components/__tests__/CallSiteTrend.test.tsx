import { afterEach, describe, expect, it, vi } from 'vitest';
import { isTraced, targetedBy } from '../../data';
import { CALL_SITE, RUN, SET, fixtureRuns, fixtureTrials, runById } from '../../data/__fixtures__';
import CallSiteTrend, { CallSiteTrendTable, OTHER_ID, assignCallSiteSlots, buildCallSiteRows, callSiteSeries, inkOnFill, parseCallSiteKey } from '../CallSiteTrend';
import { click, mount, type Mounted } from './d3-harness';

/** The m1 bare-metal traced benchmark runs: baseline-traced, T0007 traced A, T0007 traced B. */
const TRACED = [runById(RUN.baselineTraced), runById(RUN.tracedA), runById(RUN.tracedB)];

describe('parseCallSiteKey / inkOnFill', () => {
  it('splits kind | name | caller and keeps unknown shapes readable', () => {
    expect(parseCallSiteKey(CALL_SITE.ntsync)).toEqual({
      kind: 'ntsync_wait',
      name: 'NtWaitForSingleObject',
      caller: 'ntdll+0x7f3a1',
      label: 'NtWaitForSingleObject',
      detail: 'ntsync_wait · ntdll+0x7f3a1',
    });
    expect(parseCallSiteKey('plain').label).toBe('plain');
    expect(parseCallSiteKey('a|b')).toMatchObject({ name: 'a', caller: 'b', label: 'a', detail: 'b' });
  });

  it('picks white or ink by the fill luminance (white only when it clears 4.5:1 or beats ink)', () => {
    expect(inkOnFill('#4a3aa7')).toBe('#ffffff'); // violet: white 8.5:1
    expect(inkOnFill('#008300')).toBe('#ffffff'); // green: white 4.9:1
    expect(inkOnFill('#2a78d6')).toBe('#0b0b0b'); // blue: white 4.4:1 < ink 4.8:1
    expect(inkOnFill('#eda100')).toBe('#0b0b0b');
    expect(inkOnFill('#898781')).toBe('#0b0b0b');
  });
});

describe('assignCallSiteSlots', () => {
  it('ranks keys by their maximum share across the runs and Sets given, capped at 8', () => {
    const slots = assignCallSiteSlots(TRACED);
    expect(slots.get(CALL_SITE.setEvent)).toBe(1); // 0.70 on Empty
    expect(slots.get(CALL_SITE.ntsync)).toBe(2); // 0.62 on VSTs
    expect(slots.get(CALL_SITE.readFile)).toBe(3); // 0.58 on Max4Live after T0007
    const vstsOnly = assignCallSiteSlots(TRACED, [SET.vsts]);
    expect(vstsOnly.get(CALL_SITE.ntsync)).toBe(1);
    expect(vstsOnly.get(CALL_SITE.readFile)).toBe(2);
    expect(vstsOnly.get(CALL_SITE.setEvent)).toBe(3);
    expect(assignCallSiteSlots(TRACED, undefined, 2).size).toBe(2);
  });

  it('ignores runs without call sites', () => {
    expect(assignCallSiteSlots(fixtureRuns.filter((r) => !isTraced(r))).size).toBe(0);
  });
});

describe('buildCallSiteRows / callSiteSeries', () => {
  it('builds one chronological row per run with shares per slot id and the rounded last segment', () => {
    const slots = assignCallSiteSlots(TRACED, [SET.vsts]);
    const rows = buildCallSiteRows(TRACED, SET.vsts, slots);
    expect(rows.map((r) => r.runId)).toEqual([RUN.baselineTraced, RUN.tracedA, RUN.tracedB]);
    const first = rows[0]!;
    expect(first.values).toEqual({ s1: 0.62, s2: 0.21, s3: 0.09 });
    expect(first.total).toBeCloseTo(0.92, 9);
    expect(first.lastId).toBe('s3');
    expect(first.label).toBe('10-10 12:00');
    expect(rows[2]?.label).toBe('10-11 14:00 · T0007 B');
    const series = callSiteSeries(TRACED, SET.vsts, slots);
    expect(series.map((s) => s.id)).toEqual(['s1', 's2', 's3']);
    expect(series[0]?.label).toBe('NtWaitForSingleObject');
  });

  it('folds keys without a slot into "other listed sites"', () => {
    const slots = new Map([[CALL_SITE.ntsync, 1 as const]]);
    const rows = buildCallSiteRows(TRACED, SET.vsts, slots);
    expect(rows[0]?.values).toEqual({ s1: 0.62, [OTHER_ID]: 0.3 });
    expect(rows[0]?.lastId).toBe(OTHER_ID);
    const series = callSiteSeries(TRACED, SET.vsts, slots);
    expect(series.map((s) => s.id)).toEqual(['s1', OTHER_ID]);
    expect(series[1]?.slot).toBe('dim');
  });

  it('skips Sets without call sites', () => {
    expect(buildCallSiteRows(TRACED, SET.zero, assignCallSiteSlots(TRACED))).toHaveLength(3);
    expect(callSiteSeries(TRACED, SET.zero, assignCallSiteSlots(TRACED))).toHaveLength(0);
    expect(buildCallSiteRows(TRACED, 'Nope', assignCallSiteSlots(TRACED))).toHaveLength(0);
  });
});

describe('<CallSiteTrend>', () => {
  let m: Mounted | null = null;
  afterEach(() => {
    m?.unmount();
    m = null;
  });
  const slots = assignCallSiteSlots(TRACED);
  const targeted = (key: string) => targetedBy(fixtureTrials, SET.vsts, key);

  it('renders a stacked bar per run, a legend with targeted-by chips, and isolates on click', () => {
    const onEmphasis = vi.fn();
    m = mount(<CallSiteTrend runs={TRACED} set={SET.vsts} slots={slots} targeted={targeted} width={640} onEmphasis={onEmphasis} />);
    expect(m.$('svg.recharts-surface')).not.toBeNull();
    expect(m.$$('.cst-segment')).toHaveLength(9);
    const legend = m.$$('.cst-legend > li');
    expect(legend).toHaveLength(3);
    expect(m.$('.cst-legend')?.textContent).toContain('NtWaitForSingleObject');
    const chips = m.$$('.cst-legend .chip').map((c) => c.textContent?.trim());
    expect(chips.some((c) => c?.includes('T0007') && c.includes('keep'))).toBe(true);
    expect(chips.some((c) => c?.includes('T0008') && c.includes('revert'))).toBe(true);
    click(m.$$('.cst-legend button')[1]);
    expect(onEmphasis).toHaveBeenCalledWith(CALL_SITE.ntsync);
  });

  it('dims every other series when one is emphasised', () => {
    m = mount(<CallSiteTrend runs={TRACED} set={SET.vsts} slots={slots} emphasis={CALL_SITE.ntsync} width={640} />);
    const dimmed = m.$$('.cst-segment path').filter((p) => p.getAttribute('fill-opacity') === '0.25');
    expect(dimmed).toHaveLength(6);
    expect(m.$$('.cst-legend button.is-muted')).toHaveLength(2);
    expect(m.$('.cst-legend button[aria-pressed="true"]')?.textContent).toContain('NtWaitForSingleObject');
  });

  it('shows an empty state for a Set without call sites', () => {
    m = mount(<CallSiteTrend runs={TRACED} set={SET.zero} slots={slots} width={640} />);
    expect(m.$('.empty')).not.toBeNull();
  });

  it('has a table twin: one row per site, one column per run', () => {
    m = mount(<CallSiteTrendTable runs={TRACED} set={SET.vsts} slots={slots} targeted={targeted} caption="VSTs call sites" />);
    const headers = m.$$('thead th').map((th) => th.textContent?.trim());
    expect(headers.slice(0, 2)).toEqual(['Call site', 'Targeted by']);
    expect(headers).toHaveLength(5);
    const rows = m.$$('tbody tr');
    expect(rows).toHaveLength(3);
    const ntsync = rows.find((r) => r.textContent?.includes('NtWaitForSingleObject'));
    expect(ntsync?.textContent).toContain('62.0%');
    const chips = Array.from(ntsync?.querySelectorAll('.chip') ?? []).map((c) => c.textContent?.trim());
    expect(chips.some((c) => c?.includes('T0007') && c.includes('keep'))).toBe(true);
  });
});
