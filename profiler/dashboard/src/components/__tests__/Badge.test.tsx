import { afterEach, describe, expect, it } from 'vitest';
import Badge, { EnvironmentBadge, STATUS_ICON, environmentBadge, significanceBadge, traceBadge, verdictBadge, type BadgeStatus } from '../Badge';
import { all, mount, text, type Mounted } from './harness';

const STATUSES: BadgeStatus[] = ['good', 'warning', 'serious', 'critical', 'dim', 'none'];

describe('Badge', () => {
  let mounted: Mounted | null = null;
  afterEach(() => {
    mounted?.unmount();
    mounted = null;
  });

  it('renders a dot, an icon and a label for every status (colour never alone)', () => {
    mounted = mount(
      <div>
        {STATUSES.map((status) => (
          <Badge key={status} kind="neutral" value={`label-${status}`} status={status} />
        ))}
      </div>,
    );
    const chips = all(mounted.container, '.chip');
    expect(chips).toHaveLength(STATUSES.length);
    for (const chip of chips) {
      const status = chip.getAttribute('data-status') as BadgeStatus;
      expect(chip.classList.contains(`chip-${status}`)).toBe(true);
      expect(chip.querySelector('.dot')).not.toBeNull();
      expect(text(chip.querySelector('.chip-label'))).toBe(`label-${status}`);
      if (status === 'none') expect(chip.querySelector('.chip-icon')).toBeNull();
      else expect(text(chip.querySelector('.chip-icon'))).toBe(STATUS_ICON[status]);
    }
  });

  it('maps verdicts to status + icon + label', () => {
    expect(verdictBadge('keep')).toMatchObject({ status: 'good', icon: '✓', value: 'keep' });
    expect(verdictBadge('revert')).toMatchObject({ status: 'critical', icon: '✗', value: 'revert' });
    expect(verdictBadge('inconclusive')).toMatchObject({ status: 'warning', icon: '≈' });
    expect(verdictBadge('tooling')).toMatchObject({ status: 'dim' });
    expect(verdictBadge('mechanism-confirmed')).toMatchObject({ status: 'dim' });
  });

  it('maps significance × direction: wins are only coloured beyond the noise', () => {
    expect(significanceBadge('beyond', 'better')).toMatchObject({ status: 'good', icon: '▲', value: 'beyond noise' });
    expect(significanceBadge('beyond', 'worse')).toMatchObject({ status: 'critical', icon: '▼', value: 'beyond noise' });
    expect(significanceBadge('within', 'better')).toMatchObject({ status: 'warning', icon: '≈', value: 'within noise' });
    expect(significanceBadge('unknown', 'better')).toMatchObject({ status: 'dim', icon: '?', value: 'no A/A data' });
    expect(significanceBadge('beyond', 'neutral')).toMatchObject({ status: 'none', value: 'informational' });
  });

  it('describes trace modes and environments', () => {
    expect(traceBadge('off').value).toBe('untraced');
    expect(traceBadge('interface').value).toContain('interface');
    expect(environmentBadge('none')).toMatchObject({ status: 'none', value: 'bare metal' });
    expect(environmentBadge('vmware')).toMatchObject({ status: 'serious', icon: '⚠' });
  });

  it('EnvironmentBadge names the host, the machine id and the virtualisation', () => {
    mounted = mount(<EnvironmentBadge machineId="m1" hostname="abletonlinux" virtualization="vmware" />);
    const badge = mounted.container.querySelector('.env-badge');
    expect(text(badge)).toContain('virtualised · vmware');
    expect(text(badge)).toContain('abletonlinux');
    expect(text(badge)).toContain('(m1)');
    expect(badge?.querySelector('.chip')?.getAttribute('data-status')).toBe('serious');

    mounted.rerender(<EnvironmentBadge machineId="m1" hostname="box" virtualization="none" />);
    expect(text(mounted.container)).toContain('bare metal');
    expect(mounted.container.querySelector('.chip')?.getAttribute('data-status')).toBe('none');
  });
});
