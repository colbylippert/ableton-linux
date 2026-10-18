import { afterEach, describe, expect, it, vi } from 'vitest';
import { RUN, runById } from '../../data/__fixtures__';
import RunTable, { audioDeviceLabel, runTableColumns, switchesText, toggleSelection } from '../RunTable';
import { click, mount, type Mounted } from './d3-harness';

describe('toggleSelection / switchesText', () => {
  it('keeps at most `max` picks, dropping the oldest', () => {
    expect(toggleSelection([], 'a')).toEqual(['a']);
    expect(toggleSelection(['a'], 'b')).toEqual(['a', 'b']);
    expect(toggleSelection(['a', 'b'], 'c')).toEqual(['b', 'c']);
    expect(toggleSelection(['a', 'b'], 'a')).toEqual(['b']);
    expect(toggleSelection(['a'], 'b', 1)).toEqual(['b']);
  });

  it('renders switches as ENV=value', () => {
    expect(switchesText({ WINE_FOO: '1' })).toBe('WINE_FOO=1');
    expect(switchesText({ A: '', B: '2' })).toBe('A, B=2');
    expect(switchesText({})).toBe('—');
  });
});

describe('<RunTable>', () => {
  let m: Mounted | null = null;
  afterEach(() => {
    m?.unmount();
    m = null;
  });
  const runs = [runById(RUN.baseline), runById(RUN.b1), runById(RUN.vmTraced)];

  it('lists the identity columns, newest first, with a checkbox per run', () => {
    const onSelect = vi.fn();
    m = mount(<RunTable runs={runs} selected={[]} onSelect={onSelect} />);
    expect(runTableColumns().map((c) => c.key)).toEqual(['started', 'run_id', 'tag', 'machine', 'environment', 'audio', 'structure', 'trace', 'switches', 'trial', 'commit', 'duration', 'sets']);
    const rows = m.$$('tbody tr');
    expect(rows).toHaveLength(3);
    expect(rows[0]?.textContent).toContain(RUN.b1);
    expect(rows[0]?.textContent).toContain('WINE_FOO=1');
    expect(rows[0]?.textContent).toContain('T0007 · B');
    expect(rows[0]?.textContent).toContain('bare metal');
    expect(rows[0]?.textContent).toContain('untraced');
    const vm = rows.find((r) => r.textContent?.includes(RUN.vmTraced));
    expect(vm?.textContent).toContain('virtualised · vmware');
    expect(vm?.textContent).toContain('traced · interface');
    expect(m.$$('input[type="checkbox"]')).toHaveLength(3);
    click(m.$$('input[type="checkbox"]')[0]);
    expect(onSelect).toHaveBeenCalledWith([RUN.b1]);
  });

  it('marks selected rows and shows the empty message without runs', () => {
    m = mount(<RunTable runs={runs} selected={[RUN.baseline]} onSelect={() => undefined} />);
    expect(m.$$('tr.is-selected')).toHaveLength(1);
    expect(m.$('tr.is-selected')?.textContent).toContain(RUN.baseline);
    m.rerender(<RunTable runs={[]} selected={[]} onSelect={() => undefined} />);
    expect(m.text()).toContain('No runs in this slice.');
  });

  it('shortens PipeWire node names to a readable device label', () => {
    expect(audioDeviceLabel('alsa_output.usb-Focusrite_Scarlett_2i4_USB-00.pro-output-0')).toBe('Focusrite_Scarlett_2i4 · pro-output-0');
    expect(audioDeviceLabel('alsa_output.pci-0000_00_1f.3-platform-skl_hda_dsp_generic.HiFi__Speaker__sink').endsWith('…')).toBe(true);
  });
});
