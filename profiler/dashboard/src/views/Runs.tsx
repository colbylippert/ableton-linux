/**
 * Runs — "every run, with its identity; pick two to compare." (DESIGN.md §4.6)
 *
 * `RunTable` lists the filtered slice (all machines when the machine filter is off) with
 * a two-slot selection; once two runs are picked the `CompareDrawer` shows per-Set deltas
 * with the within / beyond-noise status, or the identity-mismatch refusal. Virtualised
 * runs in the slice raise the "no timing claims" ribbon.
 */
import { useMemo, useState } from 'react';
import type { ViewProps } from './ViewProps';
import { applyFilter, latestRun } from '../data';
import NoTimingRibbon from '../components/NoTimingRibbon';
import RunTable from '../components/RunTable';
import CompareDrawer from '../components/CompareDrawer';

export default function RunsView({ data, filter }: ViewProps) {
  const runs = useMemo(() => applyFilter(data.runs, filter), [data.runs, filter]);
  const [selected, setSelected] = useState<string[]>([]);
  const picked = selected.map((id) => data.runs.find((r) => r.run_id === id) ?? null).filter((r): r is NonNullable<typeof r> => r !== null);
  const a = picked[0] ?? null;
  const b = picked[1] ?? null;

  const virtualised = runs.filter((r) => r.virtualization !== 'none');
  const latestVirtualised = latestRun(virtualised);

  return (
    <section className="view view-runs">
      <h2 className="view-title">Runs</h2>
      <p className="view-lead">Every run in the slice with its identity. Tick two to compare them inline; the comparison refuses pairs that differ in machine, environment, structure / scenario or trace mode.</p>
      {latestVirtualised ? <NoTimingRibbon virtualization={latestVirtualised.virtualization} hostname={latestVirtualised.hostname} runs={virtualised.length} /> : null}
      {a && b ? (
        <div className="section" style={{ marginTop: 12, marginBottom: 16 }}>
          <CompareDrawer a={a} b={b} runs={data.runs} trials={data.trials} onClose={() => setSelected([])} onSwap={() => setSelected([b.run_id, a.run_id])} />
        </div>
      ) : (
        <p className="app-meta">
          {runs.length} run{runs.length === 1 ? '' : 's'} in the slice · {selected.length === 1 ? 'pick one more run to compare' : 'pick two runs to compare'}
        </p>
      )}
      {runs.length === 0 ? (
        <div className="empty">
          No runs in this slice. Run the suite with <code>profiler/bin/bench --tag &lt;tag&gt;</code> and add it with <code>profiler/bin/history-add RUN_DIR</code>.
        </div>
      ) : (
        <div className="card" style={{ padding: 0 }}>
          <RunTable runs={runs} selected={selected} onSelect={setSelected} max={2} />
        </div>
      )}
    </section>
  );
}
