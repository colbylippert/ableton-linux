import { afterEach, describe, expect, it } from 'vitest';
import KpiTile, { HeroFigure, Sparkline, deltaGlyphStatus, type KpiDelta } from '../KpiTile';
import { mount, text, type Mounted } from './harness';

function delta(overrides: Partial<KpiDelta>): KpiDelta {
  return { pct: 0.184, abs: 1.2, direction: 'better', significance: 'beyond', text: '▲ 18.4%', ...overrides };
}

describe('KpiTile', () => {
  let mounted: Mounted | null = null;
  afterEach(() => {
    mounted?.unmount();
    mounted = null;
  });

  it('shows label, value, baseline, best and a beyond-noise improvement in the good status', () => {
    mounted = mount(
      <KpiTile
        label="Late blocks / min"
        value="2.60/min"
        source="interface"
        slot={1}
        baseline={{ value: '3.20/min', label: 'baseline 2026-10-16 12:00' }}
        best={{ value: '2.40/min', runId: 'r7' }}
        delta={delta({})}
        trend={[3.2, 3.1, 2.9, 2.6]}
      />,
    );
    const tile = mounted.container.querySelector('.kpi');
    expect(text(tile?.querySelector('.kpi-label'))).toBe('Late blocks / min');
    expect(text(tile?.querySelector('.kpi-value'))).toBe('2.60/min');
    expect(text(tile?.querySelector('.kpi-source'))).toBe('interface');
    expect(text(tile?.querySelector('.kpi-meta'))).toContain('baseline 2026-10-16 12:00 3.20/min');
    expect(text(tile?.querySelector('.kpi-meta'))).toContain('best 2.40/min r7');
    const glyph = tile?.querySelector('.delta-glyph');
    expect(text(glyph)).toBe('▲');
    expect(glyph?.classList.contains('glyph-good')).toBe(true);
    expect(text(tile?.querySelector('.delta-text'))).toContain('18.4%');
    expect(text(tile?.querySelector('.delta-text'))).not.toContain('▲');
    const chip = tile?.querySelector('.chip');
    expect(chip?.getAttribute('data-status')).toBe('good');
    expect(text(chip)).toContain('beyond noise');
    expect(tile?.querySelector('svg.sparkline')).not.toBeNull();
  });

  it('maps direction × significance to the glyph status', () => {
    expect(deltaGlyphStatus({ direction: 'better', significance: 'beyond' })).toBe('good');
    expect(deltaGlyphStatus({ direction: 'worse', significance: 'beyond' })).toBe('critical');
    expect(deltaGlyphStatus({ direction: 'better', significance: 'within' })).toBe('warning');
    expect(deltaGlyphStatus({ direction: 'worse', significance: 'unknown' })).toBe('none');
    expect(deltaGlyphStatus({ direction: 'neutral', significance: 'beyond' })).toBe('none');

    mounted = mount(<KpiTile label="CPU" value="41.0%" source="outcome" delta={delta({ direction: 'worse', text: '▼ 3.1%', significance: 'within' })} />);
    const glyph = mounted.container.querySelector('.delta-glyph');
    expect(text(glyph)).toBe('▼');
    expect(glyph?.classList.contains('glyph-warning')).toBe(true);
    expect(mounted.container.querySelector('.chip')?.getAttribute('data-status')).toBe('warning');

    mounted.rerender(<KpiTile label="CPU" value="41.0%" source="outcome" delta={delta({ direction: 'better', significance: 'unknown' })} />);
    expect(mounted.container.querySelector('.delta-glyph')?.classList.contains('glyph-none')).toBe(true);
    expect(text(mounted.container.querySelector('.chip'))).toContain('no A/A data');
  });

  it('turns the guard tile critical with the label "reject" on any non-zero value', () => {
    mounted = mount(<KpiTile label="PipeWire errors / xruns" value="0 / 2" source="outcome" guard={{ reject: true, label: 'reject' }} />);
    const tile = mounted.container.querySelector('.kpi');
    expect(tile?.classList.contains('kpi-reject')).toBe(true);
    const chip = tile?.querySelector('.chip');
    expect(chip?.getAttribute('data-status')).toBe('critical');
    expect(text(chip)).toContain('reject');

    mounted.rerender(<KpiTile label="PipeWire errors / xruns" value="0 / 0" source="outcome" guard={{ reject: false, label: 'clean' }} />);
    expect(mounted.container.querySelector('.kpi-reject')).toBeNull();
    expect(mounted.container.querySelector('.chip')?.getAttribute('data-status')).toBe('good');
  });

  it('shows the note when there is no baseline and no sparkline for a single point', () => {
    mounted = mount(<KpiTile label="Slack p01" value="12.4 µs" source="interface" note="no baseline" trend={[12.4]} />);
    expect(text(mounted.container.querySelector('.kpi-note'))).toBe('no baseline');
    expect(mounted.container.querySelector('.delta-glyph')).toBeNull();
    expect(mounted.container.querySelector('svg.sparkline')).toBeNull();
  });

  it('Sparkline draws the body and accents the last point', () => {
    mounted = mount(<Sparkline values={[1, 2, 3, 2, 5]} slot={3} label="Late blocks" />);
    const svg = mounted.container.querySelector('svg.sparkline');
    expect(svg?.getAttribute('role')).toBe('img');
    expect(svg?.getAttribute('aria-label')).toContain('latest 5');
    expect(svg?.querySelector('path')?.getAttribute('d')).toMatch(/^M/);
    expect(svg?.querySelector('circle')?.getAttribute('r')).toBe('4');
    expect((svg?.querySelector('circle') as SVGElement | null)?.style.fill).toBe('var(--series-3)');
  });

  it('HeroFigure renders the value, the chip and the kept count; success colour only beyond the noise', () => {
    mounted = mount(
      <HeroFigure label="Cumulative gain" value="▲ 18.4%" direction="better" significant sub="late blocks / min" chip={<span className="c">chip</span>} kept={3} />,
    );
    expect(text(mounted.container.querySelector('.hero-label'))).toBe('Cumulative gain');
    const figure = mounted.container.querySelector('.hero-figure');
    expect(text(figure)).toBe('▲ 18.4%');
    expect(figure?.classList.contains('hero-better')).toBe(true);
    expect(text(mounted.container.querySelector('.hero-kept'))).toBe('3 kept trials');
    expect(mounted.container.querySelector('.c')).not.toBeNull();

    mounted.rerender(<HeroFigure label="Cumulative gain" value="▲ 18.4%" direction="better" kept={0} />);
    expect(mounted.container.querySelector('.hero-figure')?.classList.contains('hero-better')).toBe(false);
    expect(text(mounted.container.querySelector('.hero-kept'))).toBe('0 kept trials');
  });
});
