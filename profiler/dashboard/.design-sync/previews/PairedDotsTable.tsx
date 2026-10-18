import { PairedDotsTable } from 'profiler-dashboard';
import type { PairedDotsPair } from 'profiler-dashboard';

const pct1 = (v: number | null) => (v === null ? '—' : `${v.toFixed(1)}%`);
const count = (v: number | null) => (v === null ? '—' : String(Math.round(v)));

// The twin sits in a chart-card column of the Trial card; keep that width here.
const column = { maxWidth: 520 };

/** T0002 (PIPEASIO_REALTIME=1 on arm B): the three interleaved ABAB pairs. */
function t0002(values: [number | null, number | null][]): PairedDotsPair[] {
  return values.map(([a, b], i) => ({ index: i + 1, a, b, runA: `trial-T0002-A${i + 1}`, runB: `trial-T0002-B${i + 1}` }));
}

/** Max4Live DSP load average: every pair improves on arm B (▲, lower is better). */
export const Max4LiveDspAverage = () => (
  <div style={column}>
    <PairedDotsTable
      pairs={t0002([
        [11.49, 9.69],
        [10.91, 9.98],
        [11.43, 11.09],
      ])}
      direction="lower"
      format={pct1}
      caption="Max4Live — DSP load avg, A vs B per pair (T0002)"
    />
  </div>
);

/** VSTs DSP load average: the pairs disagree — ▲ ▼ ▲, which is why the median stays within the A/A spread. */
export const VstsMixedPairs = () => (
  <div style={column}>
    <PairedDotsTable
      pairs={t0002([
        [10.29, 9.12],
        [10.14, 10.97],
        [10.19, 10.11],
      ])}
      direction="lower"
      format={pct1}
      caption="VSTs — DSP load avg, A vs B per pair (T0002)"
    />
  </div>
);

/** A guard metric as counts: Max4Live PipeWire errors per 30 s window fall on every B run. */
export const PipeWireErrorCounts = () => (
  <div style={column}>
    <PairedDotsTable
      pairs={t0002([
        [11, 6],
        [11, 6],
        [14, 3],
      ])}
      direction="lower"
      format={count}
      caption="Max4Live — PipeWire errors, A vs B per pair (T0002)"
    />
  </div>
);

/** T0001 with the third B run missing from history: its value and the pair's Δ render as "—". */
export const PairWithoutHistoryRecord = () => (
  <div style={column}>
    <PairedDotsTable
      pairs={[
        { index: 1, a: 9.42, b: 9.33, runA: 'trial-T0001-A1', runB: 'trial-T0001-B1' },
        { index: 2, a: 9.29, b: 10.27, runA: 'trial-T0001-A2', runB: 'trial-T0001-B2' },
        { index: 3, a: 10.9, b: null, runA: 'trial-T0001-A3', runB: 'trial-T0001-B3' },
      ]}
      direction="lower"
      format={pct1}
      caption="VSTs — DSP load avg, A vs B per pair (T0001, B3 not in history yet)"
    />
  </div>
);
