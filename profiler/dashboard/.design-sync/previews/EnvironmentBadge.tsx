import { EnvironmentBadge, NoTimingRibbon } from 'profiler-dashboard';

const LAPTOP_ID = 'd65f2ea0b816442a8d38bcb991cc7fd2';
const VM_ID = '5c1e0a77d02b4f6e9a3c6b2d8e4f1a09';

/** The bench laptop: bare metal, timing claims allowed (no status colour on the chip). */
export const BareMetal = () => <EnvironmentBadge machineId={LAPTOP_ID} hostname="abletonlinux" virtualization="none" />;

/** A run header line from the retired VMware guest: run id first, then where it ran; the chip turns serious. */
export const Virtualised = () => (
  <div className="section-head" style={{ maxWidth: 760 }}>
    <h3>20261016T224100Z-vm-baseline-untraced</h3>
    <EnvironmentBadge machineId={VM_ID} hostname="abletonlinux-vm" virtualization="vmware" />
    <span className="note">benchmark · untraced · 2026-10-16 22:41</span>
  </div>
);

/** The Overview's headline identity line: machine, then the slice it describes. */
export const OverviewHeadline = () => (
  <section style={{ maxWidth: 760 }}>
    <h2 className="view-title">Overview</h2>
    <div className="view-head">
      <EnvironmentBadge machineId={LAPTOP_ID} hostname="abletonlinux" virtualization="none" />
      <span className="note">benchmark · latest run 2026-10-18 01:21 · 21 runs in slice</span>
    </div>
  </section>
);

/** Trends with two identities in the slice: one head per group; the virtualised group brings its ribbon. */
export const TrendsIdentityGroups = () => (
  <div style={{ maxWidth: 760, display: 'grid', gap: 20 }}>
    <section>
      <div className="section-head">
        <h3>benchmark · untraced</h3>
        <EnvironmentBadge machineId={LAPTOP_ID} hostname="abletonlinux" virtualization="none" />
        <span className="note">17 runs</span>
      </div>
    </section>
    <section>
      <div className="section-head">
        <h3>benchmark · untraced</h3>
        <EnvironmentBadge machineId={VM_ID} hostname="abletonlinux-vm" virtualization="vmware" />
        <span className="note">3 runs</span>
      </div>
      <NoTimingRibbon virtualization="vmware" hostname="abletonlinux-vm" runs={3} />
    </section>
  </div>
);
