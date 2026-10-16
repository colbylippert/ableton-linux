import type { ReactNode } from 'react';
import type { DashboardData } from '../data/types';

interface ViewScaffoldProps {
  title: string;
  /** One sentence: what the reader does here. */
  lead: string;
  /** Planned components in render order (from DESIGN.md). */
  components: string[];
  data: DashboardData;
  children?: ReactNode;
}

/**
 * Placeholder body used by every view until D2/D3 replace it. It proves the shell wiring
 * (data counts flow through) and lists the components the view will be built from.
 */
export default function ViewScaffold({ title, lead, components, data, children }: ViewScaffoldProps) {
  const runs = data.runs.length;
  const trials = data.trials.length;
  return (
    <section className="view-scaffold">
      <h2>{title}</h2>
      <p className="lead">{lead}</p>
      {runs === 0 ? (
        <div className="empty">
          No runs yet. Run the suite with <code>profiler/bin/bench --tag &lt;tag&gt;</code> and add it with{' '}
          <code>profiler/bin/history-add RUN_DIR</code>; this page updates live.
        </div>
      ) : (
        <p className="app-meta">
          {runs} run{runs === 1 ? '' : 's'} · {trials} trial{trials === 1 ? '' : 's'} loaded.
        </p>
      )}
      <div className="card" style={{ marginTop: 16 }}>
        <h3 className="card-title">Planned components</h3>
        <ul>
          {components.map((c) => (
            <li key={c}>
              <code>{c}</code>
            </li>
          ))}
        </ul>
      </div>
      {children}
    </section>
  );
}
