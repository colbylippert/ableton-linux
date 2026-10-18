import { Badge, DataTable } from 'profiler-dashboard';
import type { BadgeProps, Column } from 'profiler-dashboard';

const noop = () => {};
const setLabel = (name: string) => name.replace(/^Benchmark_/, '');

// ---------------------------------------------------------------------------
// Gains vs baseline — the Overview's table twin. Identity: abletonlinux, bare metal,
// Scarlett 2i4, benchmark; baseline aa-focusrite-1, latest trial-T0002-B3.
// ---------------------------------------------------------------------------

type Significance = 'beyond' | 'within' | 'unknown';

interface GainRow {
  set: string;
  metric: string;
  source: 'outcome' | 'interface';
  unit: '%' | '/min';
  baseline: number | null;
  latest: number | null;
  best: number | null;
  /** Latest vs baseline as a fraction of the baseline, signed so that positive = improvement. */
  deltaPct: number | null;
  significance: Significance;
  runs: number;
}

const GAINS: GainRow[] = [
  { set: 'Benchmark_Inbuilts', metric: 'DSP load avg', source: 'outcome', unit: '%', baseline: 10.495, latest: 10.569, best: 9.818, deltaPct: -0.0071, significance: 'within', runs: 15 },
  { set: 'Benchmark_Inbuilts', metric: 'Live CPU / core', source: 'outcome', unit: '%', baseline: 58.49, latest: 63.05, best: 54.42, deltaPct: -0.078, significance: 'within', runs: 15 },
  { set: 'Benchmark_Max4Live', metric: 'DSP load avg', source: 'outcome', unit: '%', baseline: 10.239, latest: 11.088, best: 9.687, deltaPct: -0.0829, significance: 'within', runs: 15 },
  { set: 'Benchmark_Max4Live', metric: 'Live CPU / core', source: 'outcome', unit: '%', baseline: 57.79, latest: 65.18, best: 56.09, deltaPct: -0.1279, significance: 'within', runs: 15 },
  { set: 'Benchmark_VSTs', metric: 'DSP load avg', source: 'outcome', unit: '%', baseline: 9.456, latest: 10.113, best: 9.117, deltaPct: -0.0695, significance: 'within', runs: 15 },
  { set: 'Benchmark_VSTs', metric: 'Live CPU / core', source: 'outcome', unit: '%', baseline: 52.36, latest: 58.65, best: 50.53, deltaPct: -0.1202, significance: 'within', runs: 15 },
  { set: 'Benchmark_VSTs', metric: 'Late blocks / min', source: 'interface', unit: '/min', baseline: null, latest: 18, best: 4, deltaPct: null, significance: 'unknown', runs: 3 },
];

const value = (r: GainRow, v: number | null) => (v === null ? '—' : r.unit === '%' ? `${v.toFixed(1)}%` : `${v.toFixed(2)}/min`);

/** `▼ 8.3%`: the glyph carries the direction, the number is unsigned. */
const deltaText = (pct: number | null) => (pct === null ? '—' : `${pct > 0 ? '▲' : pct < 0 ? '▼' : ''} ${(Math.abs(pct) * 100).toFixed(1)}%`.trim());

function significanceChip(r: GainRow): BadgeProps {
  if (r.significance === 'unknown') return { kind: 'significance', value: 'no A/A data', status: 'dim', icon: '?' };
  if (r.significance === 'within') return { kind: 'significance', value: 'within noise', status: 'warning', icon: '≈' };
  return (r.deltaPct ?? 0) > 0
    ? { kind: 'significance', value: 'beyond noise', status: 'good', icon: '▲' }
    : { kind: 'significance', value: 'beyond noise', status: 'critical', icon: '▼' };
}

const gainColumns: Column<GainRow>[] = [
  { key: 'set', header: 'Set', render: (r) => setLabel(r.set) },
  { key: 'metric', header: 'Metric', render: (r) => `${r.metric} (${r.source})` },
  { key: 'baseline', header: 'Baseline', numeric: true, render: (r) => value(r, r.baseline) },
  { key: 'latest', header: 'Latest', numeric: true, render: (r) => value(r, r.latest) },
  { key: 'best', header: 'Best', numeric: true, render: (r) => value(r, r.best) },
  { key: 'delta', header: 'Δ', numeric: true, title: 'Positive = improvement', render: (r) => deltaText(r.deltaPct), sortValue: (r) => r.deltaPct },
  { key: 'significance', header: 'Significance', render: (r) => <Badge {...significanceChip(r)} />, sortValue: (r) => r.significance },
  { key: 'runs', header: 'Runs', numeric: true },
];

const gainKey = (r: GainRow) => `${r.set}|${r.metric}`;

/** Baseline, latest and best per Set and metric, in suite order; nulls render as "—". */
export const GainsVsBaseline = () => (
  <DataTable caption="Baseline, latest and best per Set and metric · abletonlinux · Scarlett 2i4" columns={gainColumns} rows={GAINS} rowKey={gainKey} />
);

/** The dense twin sorted by Δ (descending): the header shows the sort glyph and the row without a baseline sorts last. */
export const SortedByDeltaDense = () => (
  <DataTable
    caption="Gains sorted by Δ vs baseline aa-focusrite-1 (positive = improvement)"
    columns={gainColumns}
    rows={GAINS}
    rowKey={gainKey}
    defaultSort={{ key: 'delta', dir: 'desc' }}
    dense
  />
);

// ---------------------------------------------------------------------------
// The Trials ledger: one row per ledger line, pick one to open its card.
// ---------------------------------------------------------------------------

interface LedgerRow {
  trial: string;
  date: string;
  host: string;
  verdict: 'revert' | 'inconclusive';
  hypothesis: string;
  switch: string;
  primary: string;
  minutes: number;
}

const LEDGER: LedgerRow[] = [
  {
    trial: 'T0001',
    date: '2026-10-18 00:22',
    host: 'bare-metal',
    verdict: 'revert',
    hypothesis: 'Deep CPU idle states (C2 127 us, C3 1048 us exit latency) on the audio cores add wake-up latency…',
    switch: '/dev/cpu_dma_latency = 10 us (PM QoS)',
    primary: 'dsp_avg',
    minutes: 40,
  },
  {
    trial: 'T0002',
    date: '2026-10-18 00:56',
    host: 'bare-metal',
    verdict: 'inconclusive',
    hypothesis: 'pipeasio-rt, the thread that starts every audio block, runs SCHED_OTHER under PipeASIO’s shipped…',
    switch: 'PIPEASIO_REALTIME=1',
    primary: 'dsp_avg',
    minutes: 42,
  },
];

const VERDICT: Record<LedgerRow['verdict'], BadgeProps> = {
  revert: { kind: 'verdict', value: 'revert', status: 'critical', icon: '✗' },
  inconclusive: { kind: 'verdict', value: 'inconclusive', status: 'warning', icon: '≈' },
};

const ledgerColumns: Column<LedgerRow>[] = [
  { key: 'trial', header: 'Trial', render: (r) => <span className="cell-mono">{r.trial}</span> },
  { key: 'date', header: 'Date (UTC)', render: (r) => <span style={{ whiteSpace: 'nowrap' }}>{r.date}</span> },
  { key: 'host', header: 'Host', render: (r) => <span style={{ whiteSpace: 'nowrap' }}>{r.host}</span> },
  { key: 'verdict', header: 'Verdict', render: (r) => <Badge {...VERDICT[r.verdict]} /> },
  { key: 'hypothesis', header: 'Hypothesis', width: '34%' },
  { key: 'switch', header: 'Switch', render: (r) => <span className="cell-switches">{r.switch}</span> },
  { key: 'primary', header: 'Primary', render: (r) => <span className="cell-mono">{r.primary}</span> },
  { key: 'minutes', header: 'Minutes', numeric: true },
];

/** Single selection (max 1) as on the Trials tab: the newest trial is picked, newest first. */
export const LedgerPickOne = () => (
  <DataTable
    caption="Ledger · 2 trials · 0 kept · 1 reverted"
    columns={ledgerColumns}
    rows={LEDGER}
    rowKey={(r) => r.trial}
    defaultSort={{ key: 'date', dir: 'desc' }}
    selectable={{ selected: ['T0002'], max: 1, onChange: noop }}
    dense
  />
);

/** No rows in the slice: the table keeps its header and says so. */
export const EmptySlice = () => (
  <DataTable
    caption="Baseline, latest and best per Set and metric · virtualised · vmware"
    columns={gainColumns}
    rows={[]}
    rowKey={gainKey}
    emptyMessage="No rows for this slice."
  />
);
