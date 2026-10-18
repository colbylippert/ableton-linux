import { KpiTile } from 'profiler-dashboard';

const grid = { display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(200px, 1fr))', gap: 12 };

/** A gain that clears the A/A noise floor: Max4Live DSP load with PipeASIO realtime on. */
export const Improved = () => (
  <div style={grid}>
    <KpiTile
      label="DSP load average"
      value="10.0"
      unit="%"
      baseline={{ value: "11.4", label: "baseline aa-focusrite-1" }}
      best={{ value: "9.7", runId: "trial-T0002-B1" }}
      delta={{ pct: 0.123, abs: 1.4, direction: 'better', significance: 'beyond', text: '▲ 12.3%' }}
      trend={[11.5, 10.9, 11.4, 11.1, 10.4, 10.0]}
      slot={4}
      source="outcome"
      note="Benchmark_Max4Live · T0002 arm B"
    />
  </div>
);

/** A change that stays inside the noise band, and one that regressed. */
export const WithinNoiseAndRegressed = () => (
  <div style={grid}>
    <KpiTile
      label="Live CPU / core"
      value="58.7"
      unit="%"
      baseline={{ value: "58.3", label: "baseline" }}
      delta={{ pct: -0.007, abs: -0.4, direction: 'flat', significance: 'within', text: '≈ 0.7%' }}
      trend={[52.4, 58.7, 52.2, 56.6, 58.3, 58.7]}
      slot={5}
      source="outcome"
      note="Benchmark_VSTs"
    />
    <KpiTile
      label="DSP load average"
      value="11.2"
      unit="%"
      baseline={{ value: "9.9", label: "baseline" }}
      delta={{ pct: -0.131, abs: -1.3, direction: 'worse', significance: 'within', text: '▼ 13.1%' }}
      trend={[9.9, 10.7, 9.8, 11.2, 11.2, 10.6]}
      slot={3}
      source="outcome"
      note="Benchmark_Inbuilts"
    />
  </div>
);

/** Guard metrics: any PipeWire error is a reject, whatever the other numbers say. */
export const GuardRejected = () => (
  <div style={grid}>
    <KpiTile
      label="PipeWire errors"
      value="6"
      baseline={{ value: "11", label: "baseline" }}
      delta={{ pct: 0.455, abs: 5, direction: 'better', significance: 'beyond', text: '▲ 45.5%' }}
      trend={[11, 11, 14, 6, 6, 3]}
      slot={4}
      source="outcome"
      guard={{ reject: true, label: 'PipeWire errors > 0 — reject' }}
      note="Benchmark_Max4Live, 30 s window"
    />
  </div>
);

/** A traced (interface) metric with no baseline for this identity yet. */
export const NoBaseline = () => (
  <div style={grid}>
    <KpiTile
      label="Late blocks / min"
      value="20.0"
      unit="/min"
      trend={[34.0, 26.5, 20.0]}
      slot={3}
      source="interface"
      note="first traced runs on the Focusrite — no baseline recorded"
    />
  </div>
);
