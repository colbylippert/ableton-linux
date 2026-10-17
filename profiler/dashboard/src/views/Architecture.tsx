/**
 * Architecture — "how does the profiler measure Live, and how does code reach the laptop?"
 * (DESIGN.md §4.7)
 *
 * Three hand-drawn diagrams (src/architecture/*.svg: classes only, coloured by
 * architecture.css from the theme tokens) and the status of each part
 * (src/architecture/status.ts). A static reference: it reads neither the run data nor the
 * filter, so App hides the FilterBar on this tab. The SVG markup is a bundled source file,
 * never data or user input, which is what makes the innerHTML injection safe.
 */
import runtimeSvg from '../architecture/runtime.svg?raw';
import benchRunSvg from '../architecture/bench-run.svg?raw';
import buildLoopSvg from '../architecture/build-loop.svg?raw';
import { STATUS_AS_OF, STATUS_ROWS, type PartState, type PartStatus } from '../architecture/status';
import Badge, { type BadgeStatus } from '../components/Badge';
import DataTable, { type Column } from '../components/DataTable';
import '../architecture/architecture.css';

export interface ArchitectureFigure {
  id: string;
  title: string;
  lead: string;
  svg: string;
  caption: string;
}

export const FIGURES: readonly ArchitectureFigure[] = [
  {
    id: 'runtime',
    title: 'Runtime stack and trace points',
    lead: 'What runs on the laptop during a measurement, and where the profiler listens.',
    svg: runtimeSvg,
    caption:
      "Windows code reaches Wine's Linux side through two doors: the NT syscall dispatcher ① and the unix-call dispatcher ②. From there the costly paths are wineserver requests ③ and NTSync waits ④. USDT trace points at ①–③ and kernel fentry hooks at ④ each run a small BPF program that stamps the crossing; reduce.py joins every crossing to the PipeASIO block in progress and symbolize.py names the caller. Live itself is never modified: its frames appear only as module plus offset.",
  },
  {
    id: 'bench-run',
    title: 'One benchmark run',
    lead: 'From one command to a point on this dashboard.',
    svg: benchRunSvg,
    caption:
      'Each Set is launched, measured for one window (30 s by default) and quit gracefully, so no crash-recovery state carries into the next Set; a Set takes about a minute. The same window governs every collector and the tracer. Traced runs add the Interface section to the report, and the comparison step refuses to put a traced run next to an untraced one.',
  },
  {
    id: 'build-loop',
    title: 'Machines, build and the agent loop',
    lead: 'Where code is written, how it reaches the laptop, and how trials will run.',
    svg: buildLoopSvg,
    caption:
      'Code is edited and committed on Windows, shipped to the laptop as git bundles, built in a pinned rootless container and audited before it is installed. The golden snapshot is the state every trial restores to. The planned agent loop will run on the laptop itself: it builds each trial with wine-dev, measures it with untraced A/B runs, confirms the mechanism with a traced run, and records the verdict in the ledger.',
  },
];

const STATE_STATUS: Readonly<Record<PartState, BadgeStatus>> = {
  working: 'good',
  'in progress': 'warning',
  'written, not run': 'dim',
  planned: 'dim',
};

const STATUS_COLUMNS: Column<PartStatus>[] = [
  { key: 'part', header: 'Part', render: (r) => r.part, sortValue: (r) => r.part },
  {
    key: 'where',
    header: 'Where',
    render: (r) => (
      <span className="arch-paths">
        {r.paths.map((p) => (
          <code key={p}>{p}</code>
        ))}
      </span>
    ),
    sortValue: (r) => r.paths[0] ?? null,
  },
  { key: 'state', header: 'State', render: (r) => <Badge kind="neutral" value={r.state} status={STATE_STATUS[r.state]} />, sortValue: (r) => r.state },
  { key: 'note', header: 'Note', render: (r) => r.note },
];

function Legend() {
  return (
    <ul className="arch-legend" aria-label="Legend">
      <li>
        <svg width="16" height="16" viewBox="0 0 16 16" aria-hidden="true">
          <polygon className="lg-probe" points="8,2 14,8 8,14 2,8" />
        </svg>
        trace point: USDT in Wine (patch 0108) and PipeASIO (patch 0017), fentry in the ntsync driver
      </li>
      <li>
        <svg width="34" height="12" viewBox="0 0 34 12" aria-hidden="true">
          <line className="lg-audio" x1="1" y1="6" x2="33" y2="6" />
        </svg>
        audio path: samples and the device clock
      </li>
      <li>
        <svg width="34" height="12" viewBox="0 0 34 12" aria-hidden="true">
          <line className="lg-line" x1="1" y1="6" x2="26" y2="6" />
          <polygon className="lg-head" points="25,2 33,6 25,10" />
        </svg>
        call or data flow
      </li>
      <li>
        <svg width="34" height="12" viewBox="0 0 34 12" aria-hidden="true">
          <line className="lg-dash" x1="1" y1="6" x2="26" y2="6" />
          <polygon className="lg-head" points="25,2 33,6 25,10" />
        </svg>
        control or lookup
      </li>
    </ul>
  );
}

export default function ArchitectureView() {
  return (
    <section className="view view-architecture">
      <h2 className="view-title">Architecture</h2>
      <p className="view-lead">
        How the profiler measures Ableton Live 12 under Wine on the CachyOS laptop: where the trace points sit, what one benchmark run does, and how code is built, deployed and, soon,
        optimised by agents.
      </p>
      <Legend />
      {FIGURES.map((figure, i) => (
        <section className="section" key={figure.id} aria-labelledby={`arch-${figure.id}`}>
          <div className="section-head">
            <h3 id={`arch-${figure.id}`}>
              Figure {i + 1}. {figure.title}
            </h3>
          </div>
          <p className="note">{figure.lead}</p>
          <figure className="card arch-figure">
            <p className="arch-hint">Scroll sideways to see the whole diagram.</p>
            <div className="arch-scroll" tabIndex={0} role="region" aria-label={`Figure ${i + 1} (scrolls sideways)`} dangerouslySetInnerHTML={{ __html: figure.svg }} />
            <figcaption>{figure.caption}</figcaption>
          </figure>
        </section>
      ))}
      <section className="section arch-status" aria-labelledby="arch-status">
        <div className="section-head">
          <h3 id="arch-status">Status by part</h3>
          <span className="muted">as of {STATUS_AS_OF}</span>
        </div>
        <DataTable caption="Status of each profiler part" captionHidden columns={STATUS_COLUMNS} rows={[...STATUS_ROWS]} rowKey={(r) => r.part} />
      </section>
    </section>
  );
}
