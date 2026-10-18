import { Badge, ChartFrame, DataTable, DeltaBars, DeltaBarsTable, KpiTile, PairedDots, PairedDotsTable } from 'profiler-dashboard';
import type { BadgeProps, Column, PairedDotsPair } from 'profiler-dashboard';

const pct1 = (v: number | null) => (v === null ? '—' : `${v.toFixed(1)}%`);
const share = (v: number | null) => (v === null ? '—' : `${(v * 100).toFixed(1)}%`);
const shareTick = (v: number) => `${Math.round(v * 100)}%`;

// T0002 (PIPEASIO_REALTIME=1), Max4Live DSP load average per ABAB pair; A/A spread 0.82 pt.
const PAIRS: PairedDotsPair[] = [
  { index: 1, a: 11.49, b: 9.69, runA: 'trial-T0002-A1', runB: 'trial-T0002-B1' },
  { index: 2, a: 10.91, b: 9.98, runA: 'trial-T0002-A2', runB: 'trial-T0002-B2' },
  { index: 3, a: 11.43, b: 11.09, runA: 'trial-T0002-A3', runB: 'trial-T0002-B3' },
];
const SPREAD = 0.82;
const card = { maxWidth: 640 };

/** The A / B / wash key the Trials card shows above its dumbbells, plus the significance chip. */
const pairsKey = (
  <div className="tc-keyrow">
    <div className="chart-key pd-key">
      <span>
        <span className="pd-key-dot pd-key-a" aria-hidden="true" /> A (before)
      </span>
      <span>
        <span className="pd-key-dot pd-key-b" aria-hidden="true" /> B (after)
      </span>
      <span>
        <span className="pd-key-delta" aria-hidden="true">▲▼</span> Δ = B vs A, positive = improvement
      </span>
      <span>
        <span className="key-band pd-key-wash" aria-hidden="true" /> A ± 2 × A/A spread ({pct1(SPREAD)})
      </span>
    </div>
    <Badge kind="significance" value="within noise" status="warning" icon="≈" title="|Δ| ≤ 2 × the A/A spread" />
  </div>
);

const pairsFrame = (defaultView: 'chart' | 'table') => (
  <ChartFrame
    title="Max4Live — DSP load avg"
    subtitle="median Δ ▲ 0.9% over 3 pairs · A/A spread 0.8% · 1.8× spread"
    keyRow={pairsKey}
    chart={<PairedDots pairs={PAIRS} unit="%" direction="lower" format={pct1} spread={SPREAD} label="Max4Live DSP load avg: 3 ABAB pairs" width={600} />}
    table={<PairedDotsTable pairs={PAIRS} direction="lower" format={pct1} caption="Max4Live — DSP load avg, A vs B per pair" captionHidden />}
    defaultView={defaultView}
  />
);

/** A trial's ABAB pairs as the Trials card frames them: title, gate summary, key row, Chart | Table toggle. */
export const ChartViewWithKeyRow = () => <div style={card}>{pairsFrame('chart')}</div>;

/** The same frame opened on its table twin: every value and run id the chart plots. */
export const TableView = () => <div style={card}>{pairsFrame('table')}</div>;

const CONFIRMATION = 'NtWaitForSingleObject share of lost slack (VSTs)';

/** Traced confirmation as before/after bars, with the provenance footer. */
export const WithFooter = () => (
  <div style={card}>
    <ChartFrame
      title="Traced confirmation"
      subtitle={`${CONFIRMATION}: 96.5% → 41.2% (▼ 55.3 pts)`}
      chart={<DeltaBars before={0.9651} after={0.412} label={CONFIRMATION} format={share} formatTick={shareTick} width={600} />}
      table={<DeltaBarsTable before={0.9651} after={0.412} label={CONFIRMATION} format={share} caption={`Traced confirmation: ${CONFIRMATION}`} captionHidden />}
      footer={<span className="muted">from the ledger line (traced runs agree in history)</span>}
    />
  </div>
);

/** T0002 has no traced run per arm yet: the empty state replaces chart and table and hides the toggle. */
export const EmptyState = () => (
  <div style={card}>
    <ChartFrame
      title="Traced confirmation"
      subtitle="call-site share of lost slack"
      chart={null}
      table={null}
      empty="No traced confirmation recorded (no traced run per arm yet)."
    />
  </div>
);

interface GainRow {
  metric: string;
  baseline: string;
  latest: string;
  best: string;
  delta: string;
  significance: BadgeProps;
}

const WITHIN: BadgeProps = { kind: 'significance', value: 'within noise', status: 'warning', icon: '≈' };
const NO_AA: BadgeProps = { kind: 'significance', value: 'no A/A data', status: 'dim', icon: '?' };

const GAINS: GainRow[] = [
  { metric: 'Late blocks / min (interface)', baseline: '—', latest: '18.00/min', best: '—', delta: '—', significance: NO_AA },
  { metric: 'PipeWire errors (outcome)', baseline: '3', latest: '4', best: '0', delta: '▼ 33.3%', significance: WITHIN },
  { metric: 'Live CPU / core (outcome)', baseline: '52.4%', latest: '58.7%', best: '50.5%', delta: '▼ 12.0%', significance: WITHIN },
];

const GAIN_COLUMNS: Column<GainRow>[] = [
  { key: 'metric', header: 'Metric' },
  { key: 'baseline', header: 'Baseline', numeric: true },
  { key: 'latest', header: 'Latest', numeric: true },
  { key: 'best', header: 'Best', numeric: true },
  { key: 'delta', header: 'Δ', numeric: true, title: 'Positive = improvement' },
  { key: 'significance', header: 'Significance', render: (r) => <Badge {...r.significance} /> },
];

/** The Overview's plain variant: no card chrome, stat tiles as the "chart", a DataTable as the twin. */
export const PlainWithTiles = () => (
  <div style={{ maxWidth: 780 }}>
    <ChartFrame
      className="chart-frame-plain"
      title="Sets vs baseline"
      subtitle="VSTs · interface tiles from traced runs, outcome tiles from untraced runs; delta signed so that positive = improvement."
      chart={
        <div className="grid-kpi">
          <KpiTile label="Late blocks / min" value="18.00/min" source="interface" slot={5} trend={[4, 20, 18]} note="no baseline" />
          <KpiTile label="PipeWire errors / xruns" value="4 / 0" source="outcome" slot={5} guard={{ reject: true, label: 'reject' }} />
          <KpiTile
            label="Live CPU / core"
            value="58.7%"
            source="outcome"
            slot={5}
            baseline={{ value: '52.4%', label: 'baseline 2026-10-18 00:05' }}
            best={{ value: '50.5%', runId: 'trial-T0001-A2' }}
            delta={{ pct: -0.12, abs: -6.3, direction: 'worse', significance: 'within', text: '▼ 12.0%' }}
            trend={[51.8, 51.1, 50.5, 59.2, 63.7, 53.1, 58.7, 51.4, 56.6, 64.6, 58.3, 58.7]}
          />
        </div>
      }
      table={<DataTable caption="Baseline, latest and best per metric (VSTs)" captionHidden columns={GAIN_COLUMNS} rows={GAINS} rowKey={(r) => r.metric} dense />}
    />
  </div>
);
