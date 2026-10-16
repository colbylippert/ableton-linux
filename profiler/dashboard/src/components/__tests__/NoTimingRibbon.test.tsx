import { afterEach, describe, expect, it } from 'vitest';
import NoTimingRibbon from '../NoTimingRibbon';
import { mount, text, type Mounted } from './harness';

describe('NoTimingRibbon', () => {
  let mounted: Mounted | null = null;
  afterEach(() => {
    mounted?.unmount();
    mounted = null;
  });

  it('names the virtualisation, the host and the run count with an icon', () => {
    mounted = mount(<NoTimingRibbon virtualization="vmware" hostname="abletonlinux" runs={3} />);
    const ribbon = mounted.container.querySelector('.ribbon');
    expect(ribbon).not.toBeNull();
    expect(ribbon?.getAttribute('role')).toBe('status');
    expect(text(ribbon?.querySelector('.icon'))).toBe('⚠');
    const content = text(ribbon);
    expect(content).toContain('NO TIMING CLAIMS');
    expect(content).toContain('virtualised host (vmware)');
    expect(content).toContain('abletonlinux');
    expect(content).toContain('3 runs');
  });

  it('renders nothing on bare metal', () => {
    mounted = mount(<NoTimingRibbon virtualization="none" />);
    expect(mounted.container.querySelector('.ribbon')).toBeNull();
  });
});
