import { TrendChart } from 'profiler-dashboard';
import type { TrendPoint, TrendSeries } from 'profiler-dashboard';

const at = (h: number, m: number) => Date.UTC(2026, 9, 17, h, m);
const pct1 = (v: number | null) => (v === null ? '—' : `${v.toFixed(1)}%`);

function points(prefix: string, values: [number, number, number][], arms: ('A' | 'B')[], trial: string): TrendPoint[] {
  return values.map(([h, m, v], i) => ({
    t: at(h, m),
    runId: `${prefix}-${arms[i]}${Math.floor(i / 2) + 1}`,
    tag: `${prefix}-${arms[i]}${Math.floor(i / 2) + 1}`,
    value: v,
    arm: arms[i] ?? null,
    trial,
    switches: arms[i] === 'B' ? { PIPEASIO_REALTIME: '1' } : {},
  }));
}

const ARMS: ('A' | 'B')[] = ['A', 'B', 'A', 'B', 'A', 'B'];

const max4live: TrendSeries = {
  id: 'Benchmark_Max4Live',
  label: 'Max4Live',
  slot: 4,
  points: points('trial-T0002', [[20, 2, 11.5], [20, 9, 9.7], [20, 16, 10.9], [20, 23, 10.0], [20, 30, 11.4], [20, 37, 11.1]], ARMS, 'T0002'),
};
const inbuilts: TrendSeries = {
  id: 'Benchmark_Inbuilts',
  label: 'Inbuilts',
  slot: 3,
  points: points('trial-T0002', [[20, 1, 9.9], [20, 8, 11.2], [20, 15, 10.7], [20, 22, 11.2], [20, 29, 9.8], [20, 36, 10.6]], ARMS, 'T0002'),
};
const vsts: TrendSeries = {
  id: 'Benchmark_VSTs',
  label: 'VSTs',
  slot: 5,
  points: points('trial-T0002', [[20, 4, 10.3], [20, 11, 9.1], [20, 18, 10.1], [20, 25, 11.0], [20, 32, 10.2], [20, 39, 10.1]], ARMS, 'T0002'),
};

/** One Set's DSP load across a trial's ABAB runs, with its baseline, the A/A noise band and the verdict marker. */
export const BaselineNoiseBandAndMarker = () => (
  <TrendChart
    title="DSP load average (%)"
    subtitle="Benchmark_Max4Live · bare metal · untraced runs"
    series={[max4live]}
    baseline={{ value: 10.3, runId: 'aa-focusrite-1', label: 'baseline' }}
    noiseBand={{ center: 10.3, halfWidth: 1.6, pairs: 2 }}
    markers={[{ t: at(20, 37), trial: 'T0002', verdict: 'inconclusive', label: 'T0002 PipeASIO realtime' }]}
    unit="%"
    direction="lower"
    format={pct1}
    table={{ caption: 'Benchmark_Max4Live · DSP load average per run' }}
    width={620}
  />
);

/** Three Sets on one chart with one emphasised; the others recede to context grey. */
export const EmphasisedSeries = () => (
  <TrendChart
    title="DSP load average (%)"
    subtitle="heavy Sets · T0002 · bare metal"
    series={[inbuilts, max4live, vsts]}
    baseline={null}
    noiseBand={null}
    markers={[]}
    emphasis="Benchmark_VSTs"
    unit="%"
    direction="lower"
    format={pct1}
    table={{ caption: 'Heavy Sets · DSP load average per run' }}
    width={620}
  />
);
