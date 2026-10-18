import { DeltaBars } from 'profiler-dashboard';

const share = (v: number | null) => (v === null ? '—' : `${(v * 100).toFixed(1)}%`);
const shareTick = (v: number) => `${Math.round(v * 100)}%`;
const count = (v: number | null) => (v === null ? '—' : String(Math.round(v)));

/** A trial's traced confirmation: the targeted call site's share of lost slack, arm A vs arm B. */
export const TracedConfirmation = () => (
  <DeltaBars
    before={0.9651}
    after={0.412}
    label="NtWaitForSingleObject share of lost slack (VSTs)"
    format={share}
    formatTick={shareTick}
    width={600}
  />
);

/** The B5c attribution fix: the ntsync WAIT_ANY duplicate merged into its syscall site, so the share rises. */
export const AttributionFixRise = () => (
  <DeltaBars
    before={0.1177}
    after={0.9651}
    label="NtWaitForSingleObject ← Ableton Live 12 Trial.exe+0x4f8c119, share of lost slack (VSTs)"
    format={share}
    formatTick={shareTick}
    names={{ before: 'b5b traced', after: 'b5c traced' }}
    width={600}
  />
);

/** Raw values instead of shares: T0002 PipeWire errors summed over 15 Set-runs per arm, on a 0–80 axis. */
export const CountsOnCustomDomain = () => (
  <DeltaBars
    before={67}
    after={32}
    label="PipeWire errors, 15 Set-runs per arm (T0002 PIPEASIO_REALTIME=1)"
    format={count}
    formatTick={(v) => String(Math.round(v))}
    domain={[0, 80]}
    names={{ before: 'arm A', after: 'arm B' }}
    width={600}
  />
);

/** Only the A-arm traced run is in history yet: one bar, the missing side reads "—". */
export const AfterArmMissing = () => (
  <DeltaBars
    before={0.9366}
    after={null}
    label="NtWaitForSingleObject share of lost slack (Inbuilts)"
    format={share}
    formatTick={shareTick}
    width={600}
  />
);

/** Neither traced run recorded: the component's own empty state. */
export const NoValues = () => (
  <div style={{ width: 600 }}>
    <DeltaBars before={null} after={null} label="NtWaitForSingleObject share of lost slack (VSTs)" format={share} width={600} />
  </div>
);
