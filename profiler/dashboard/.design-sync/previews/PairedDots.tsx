import { PairedDots } from 'profiler-dashboard';
import type { PairedDotsPair } from 'profiler-dashboard';

const pct1 = (v: number | null) => (v === null ? '—' : `${v.toFixed(1)}%`);
const int0 = (v: number | null) => (v === null ? '—' : String(Math.round(v)));

/** T0002 (PIPEASIO_REALTIME=1) ABAB pairs: arm A run → arm B run, one row per interleaved pair. */
function t0002(values: [number | null, number | null][]): PairedDotsPair[] {
  return values.map(([a, b], i) => ({ index: i + 1, a, b, runA: `trial-T0002-A${i + 1}`, runB: `trial-T0002-B${i + 1}` }));
}

/** Max4Live DSP load, with the acceptance-gate wash (A ± 2 × the 0.82 pt A/A spread) behind each A dot. */
export const DspLoadWithGate = () => (
  <PairedDots
    pairs={t0002([[11.49, 9.69], [10.91, 9.98], [11.43, 11.09]])}
    unit="%"
    direction="lower"
    format={pct1}
    spread={0.82}
    label="Max4Live DSP load avg: 3 ABAB pairs"
    width={600}
  />
);

/** Inbuilts got worse on every pair: the ▼ glyphs wear the critical status, the numbers stay ink. */
export const RegressionOnEveryPair = () => (
  <PairedDots
    pairs={t0002([[9.86, 11.18], [10.68, 11.23], [9.82, 10.57]])}
    unit="%"
    direction="lower"
    format={pct1}
    spread={1.18}
    label="Inbuilts DSP load avg: 3 ABAB pairs"
    width={600}
  />
);

/** A guard metric in counts: Max4Live PipeWire errors per 30 s run, no A/A spread drawn. */
export const GuardMetricCounts = () => (
  <PairedDots
    pairs={t0002([[11, 6], [11, 6], [14, 3]])}
    unit=""
    direction="lower"
    format={int0}
    label="Max4Live PipeWire errors: 3 ABAB pairs"
    width={600}
  />
);

/** Mixed pairs, and pair 3's B run has no history record yet: half a dumbbell, Δ reads "—". */
export const MixedPairsMissingRun = () => (
  <PairedDots
    pairs={t0002([[10.29, 9.12], [10.14, 10.97], [10.19, null]])}
    unit="%"
    direction="lower"
    format={pct1}
    spread={0.86}
    label="VSTs DSP load avg: 3 ABAB pairs"
    width={600}
  />
);
