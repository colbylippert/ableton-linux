import { Badge, EnvironmentBadge } from 'profiler-dashboard';

const row = { display: 'flex', flexWrap: 'wrap' as const, gap: 8, alignItems: 'center' };

/** Trial verdicts as the Trials tab shows them: status colour on the dot, glyph + label in ink. */
export const Verdicts = () => (
  <div style={row}>
    <Badge kind="verdict" value="keep" status="good" />
    <Badge kind="verdict" value="revert" status="critical" />
    <Badge kind="verdict" value="inconclusive" status="warning" />
    <Badge kind="verdict" value="mechanism-confirmed" status="dim" />
    <Badge kind="verdict" value="tooling" status="dim" />
  </div>
);

/** A/B significance against the A/A noise floor. */
export const Significance = () => (
  <div style={row}>
    <Badge kind="significance" value="beyond noise" status="good" icon="▲" title="Max4Live DSP average −1.5 pt, 1.9× the A/A spread" />
    <Badge kind="significance" value="within noise" status="warning" title="Inbuilts DSP average +1.3 pt, 1.1× the A/A spread" />
    <Badge kind="significance" value="worse" status="critical" icon="▼" />
    <Badge kind="significance" value="no baseline" status="dim" icon="?" />
  </div>
);

/** Run identity chips: trace mode, trial arm and the opt-in switch a run carried. */
export const RunIdentity = () => (
  <div style={row}>
    <Badge kind="trace" value="untraced" />
    <Badge kind="trace" value="interface" status="dim" />
    <Badge kind="structure" value="benchmark" />
    <Badge kind="arm" value="A" />
    <Badge kind="arm" value="B" status="good" />
    <Badge kind="switch" value="PIPEASIO_REALTIME=1" />
  </div>
);

/** Where a run was measured: bare metal is timing-valid, a VM never is. */
export const Environments = () => (
  <div style={{ display: 'grid', gap: 8 }}>
    <EnvironmentBadge machineId="d65f2ea0b816442a8d38bcb991cc7fd2" hostname="abletonlinux" virtualization="none" />
    <EnvironmentBadge machineId="5c1e0a77d02b4f6e9a3c6b2d8e4f1a09" hostname="abletonlinux-vm" virtualization="vmware" />
  </div>
);
