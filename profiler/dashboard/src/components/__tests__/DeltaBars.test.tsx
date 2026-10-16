import { afterEach, describe, expect, it } from 'vitest';
import { formatShare } from '../../data';
import DeltaBars, { DeltaBarsTable, deltaBarsChange } from '../DeltaBars';
import { focusIn, mount, type Mounted } from './d3-harness';

describe('deltaBarsChange', () => {
  it('formats before → after with the change in percentage points for shares', () => {
    expect(deltaBarsChange(0.62, 0.11, formatShare)).toBe('62.0% → 11.0% (▼ 51.0 pts)');
    expect(deltaBarsChange(0.1, 0.3, formatShare)).toBe('10.0% → 30.0% (▲ 20.0 pts)');
    expect(deltaBarsChange(0.2, 0.2, formatShare)).toBe('20.0% → 20.0% (0.0 pts)');
    expect(deltaBarsChange(null, 0.2, formatShare)).toBe('— → 20.0%');
  });
});

describe('<DeltaBars>', () => {
  let m: Mounted | null = null;
  afterEach(() => {
    m?.unmount();
    m = null;
  });

  it('draws two bars in the ordinal pair with the values as direct labels', () => {
    m = mount(<DeltaBars before={0.62} after={0.11} label="NtWaitForSingleObject share" format={formatShare} formatTick={(v) => `${Math.round(v * 100)}%`} width={600} />);
    expect(m.$$('.db-bar')).toHaveLength(2);
    expect(m.$('.db-bar-before')).not.toBeNull();
    expect(m.$('.db-bar-after')).not.toBeNull();
    const values = m.$$('.db-value').map((el) => el.textContent);
    expect(values).toEqual(['62.0%', '11.0%']);
    expect(m.$('svg')?.getAttribute('aria-label')).toContain('62.0% → 11.0%');
    expect(m.$$('.db-tick').map((el) => el.textContent)).toEqual(['0%', '25%', '50%', '75%', '100%']);
    const rows = m.$$('.db-row');
    expect(rows[0]?.getAttribute('aria-label')).toBe('before (A): 62.0%');
    expect(rows[1]?.getAttribute('aria-label')).toBe('after (B): 11.0%');
  });

  it('shows the tooltip on focus, draws one bar when a side is missing and an empty state when both are', () => {
    m = mount(<DeltaBars before={0.62} after={null} label="share" format={formatShare} width={600} />);
    expect(m.$$('.db-bar')).toHaveLength(1);
    expect(m.$$('.db-value').map((el) => el.textContent)).toEqual(['62.0%', '—']);
    focusIn(m.$$('.db-row')[0]);
    expect(m.$('[role="tooltip"]')?.textContent).toContain('62.0%');
    m.rerender(<DeltaBars before={null} after={null} label="share" format={formatShare} width={600} />);
    expect(m.$('.empty')).not.toBeNull();
  });

  it('has a table twin with before, after and the change', () => {
    m = mount(<DeltaBarsTable before={0.62} after={0.11} label="share" format={formatShare} caption="confirmation" />);
    const rows = m.$$('tbody tr').map((tr) => tr.textContent);
    expect(rows).toHaveLength(3);
    expect(rows[0]).toContain('62.0%');
    expect(rows[1]).toContain('11.0%');
    expect(rows[2]).toContain('▼ 51.0 pts');
  });
});
