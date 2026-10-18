import { DeltaBarsTable } from 'profiler-dashboard';

/** `95.7%`: a call-site share of lost slack (0..1). */
const share = (v: number | null) => (v === null ? '—' : `${(v * 100).toFixed(1)}%`);
/** `796.6 µs`: slack percentiles are stored in ns. */
const micros = (v: number | null) => (v === null ? '—' : `${(v / 1000).toFixed(1)} µs`);

// The twin sits in a chart-card column in the Trial card; keep that width here.
const column = { maxWidth: 460 };

const WAIT_SITE = 'NtWaitForSingleObject share of lost slack (VSTs)';

/** A trial's traced confirmation: the targeted call site's share before (arm A) and after (arm B); the change is in percentage points. */
export const TracedConfirmation = () => (
  <div style={column}>
    <DeltaBarsTable before={0.9573} after={0.412} label={WAIT_SITE} format={share} caption={`Traced confirmation: ${WAIT_SITE}`} />
  </div>
);

/** Only arm A has a traced run so far: the after value and the change stay "—". */
export const NoTracedRunOnB = () => (
  <div style={column}>
    <DeltaBarsTable before={0.9651} after={null} label={WAIT_SITE} format={share} caption={`Traced confirmation: ${WAIT_SITE} (no traced run on arm B yet)`} />
  </div>
);

/** A before / after in the metric's own unit (share = false), with the run ids as the row names. */
export const SlackP01InMicroseconds = () => (
  <div style={column}>
    <DeltaBarsTable
      before={796554}
      after={837330}
      label="Slack p01 (Inbuilts)"
      format={micros}
      names={{ before: 'b5c-verifier-traced', after: 'b5c-final-traced' }}
      share={false}
      caption="Slack p01 (Inbuilts) across two traced diagnostic runs"
    />
  </div>
);
