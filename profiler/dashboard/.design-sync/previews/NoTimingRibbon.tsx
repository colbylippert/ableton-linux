import { EnvironmentBadge, NoTimingRibbon } from 'profiler-dashboard';

const VM_ID = '5c1e0a77d02b4f6e9a3c6b2d8e4f1a09';
const view = { maxWidth: 760 };

/** The Runs view of a VMware slice: the ribbon sits under the view lead, above the run table. */
export const VirtualisedSlice = () => (
  <section style={view}>
    <h2 className="view-title">Runs</h2>
    <p className="view-lead">
      Every run in the slice with its identity. Tick two to compare them inline; the comparison refuses pairs that differ in machine, environment,
      structure / scenario or trace mode.
    </p>
    <NoTimingRibbon virtualization="vmware" hostname="abletonlinux-vm" runs={5} />
    <p className="app-meta">5 runs in the slice · pick two runs to compare</p>
  </section>
);

/** Scenarios with one traced run from a KVM guest (singular wording), under the scenario picker. */
export const SingleKvmRun = () => (
  <section style={view}>
    <h2 className="view-title">Scenarios</h2>
    <p className="view-lead">
      Diagnostic scenario runs: late and near-late blocks per minute over run time (traced runs), and the non-audio hotspots of the latest traced run.
    </p>
    <div className="view-controls">
      <label className="filter">
        <span className="filter-label">Scenario</span>
        <select defaultValue="view-flip" aria-label="Scenario">
          <option value="clip-launch-storm">clip-launch-storm</option>
          <option value="view-flip">view-flip</option>
        </select>
      </label>
      <span className="muted">1 run · 1 traced (interface) · 0 untraced</span>
    </div>
    <NoTimingRibbon virtualization="kvm" hostname="abletonlinux-kvm" runs={1} />
  </section>
);

/** The ribbon's shortest form, hypervisor only (no host, no run count), under the Call sites view head. */
export const HypervisorOnly = () => (
  <section style={view}>
    <h2 className="view-title">Call sites</h2>
    <p className="view-lead">
      Share of lost slack per call site, one bar per traced run. Colours are fixed per call site across every card below (top 8 by maximum share in
      this slice); gray folds the rest. Click a site to isolate it.
    </p>
    <NoTimingRibbon virtualization="vmware" />
  </section>
);

/** Where it sits: under the Overview's identity line, above every chart of the virtualised slice. */
export const UnderOverviewHeader = () => (
  <section style={view}>
    <h2 className="view-title">Overview</h2>
    <div className="view-head">
      <EnvironmentBadge machineId={VM_ID} hostname="abletonlinux-vm" virtualization="vmware" />
      <span className="note">benchmark · latest run 2026-10-16 22:41 · 3 runs in slice</span>
    </div>
    <NoTimingRibbon virtualization="vmware" hostname="abletonlinux-vm" runs={3} />
  </section>
);
