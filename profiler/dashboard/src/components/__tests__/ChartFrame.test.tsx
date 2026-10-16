import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import ChartFrame, { ChartCard } from '../ChartFrame';
import { byText, click, mount, text, type Mounted } from './harness';

describe('ChartFrame', () => {
  let mounted: Mounted | null = null;
  beforeEach(() => {
    localStorage.clear();
  });
  afterEach(() => {
    mounted?.unmount();
    mounted = null;
  });

  it('shows the chart by default and toggles to the table twin', () => {
    mounted = mount(
      <ChartFrame title="Late blocks" subtitle="per minute" keyRow={<span className="key">key</span>} chart={<div className="the-chart" />} table={<div className="the-table" />} />,
    );
    const figure = mounted.container.querySelector('figure.chart-frame');
    expect(figure?.getAttribute('data-view')).toBe('chart');
    expect(text(figure?.querySelector('h3'))).toBe('Late blocks');
    expect(text(figure?.querySelector('.card-subtitle'))).toBe('per minute');
    expect(figure?.querySelector('.the-chart')).not.toBeNull();
    expect(figure?.querySelector('.key')).not.toBeNull();
    expect(figure?.querySelector('.the-table')).toBeNull();

    click(byText(mounted.container, '.chart-frame-toggle button', 'Table'));
    expect(figure?.getAttribute('data-view')).toBe('table');
    expect(figure?.querySelector('.the-table')).not.toBeNull();
    expect(figure?.querySelector('.the-chart')).toBeNull();
    expect(figure?.querySelector('.key')).toBeNull();
    expect(byText(mounted.container, '.chart-frame-toggle button', 'Table')?.getAttribute('aria-pressed')).toBe('true');
  });

  it('renders the empty state without a toggle', () => {
    mounted = mount(<ChartFrame title="Empty" chart={<div className="the-chart" />} table={<div className="the-table" />} empty="No runs in this slice." />);
    expect(mounted.container.querySelector('.chart-frame-toggle')).toBeNull();
    expect(text(mounted.container.querySelector('.chart-frame-empty'))).toBe('No runs in this slice.');
    expect(mounted.container.querySelector('.the-chart')).toBeNull();
  });

  it('remembers the chosen view per id', () => {
    mounted = mount(<ChartFrame id="t1" title="Remembered" chart={<div className="the-chart" />} table={<div className="the-table" />} />);
    click(byText(mounted.container, '.chart-frame-toggle button', 'Table'));
    expect(localStorage.getItem('profiler-dashboard.chartview.t1')).toBe('table');
    mounted.unmount();
    mounted = mount(<ChartCard id="t1" title="Remembered" chart={<div className="the-chart" />} table={<div className="the-table" />} />);
    expect(mounted.container.querySelector('.the-table')).not.toBeNull();
  });
});
