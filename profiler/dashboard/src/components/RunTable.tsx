/**
 * RunTable: every run of the slice with its identity fields, pick two to compare
 * (DESIGN.md §4.6). A thin layer over `DataTable`: the columns are the identity
 * (started, run id, tag, machine, environment, structure/scenario, trace mode, switches,
 * trial/arm, commit, duration, Sets); selection is the table's checkbox column capped at
 * two (FIFO, so picking a third replaces the oldest pick).
 */
import type { Run } from '../data/types';
import { formatDate, formatInt, setLabel, startedMs } from '../data';
import Badge, { environmentBadge, traceBadge } from './Badge';
import DataTable, { type Column } from './DataTable';
import './RunTable.css';

export interface RunTableProps {
  runs: readonly Run[];
  selected: string[];
  onSelect: (next: string[]) => void;
  /** Selection cap (default 2 = "pick two"). */
  max?: number;
  caption?: string;
  dense?: boolean;
}

/** Same FIFO semantics as DataTable's checkbox column; exported so views can drive selection from elsewhere. */
export function toggleSelection(selected: readonly string[], id: string, max = 2): string[] {
  if (selected.includes(id)) return selected.filter((k) => k !== id);
  const next = [...selected, id];
  return max > 0 && next.length > max ? next.slice(next.length - max) : next;
}

export function switchesText(switches: Record<string, string>): string {
  const entries = Object.entries(switches ?? {});
  if (entries.length === 0) return '—';
  return entries.map(([k, v]) => (v === '' ? k : `${k}=${v}`)).join(', ');
}

export function runTableColumns(): Column<Run>[] {
  return [
    { key: 'started', header: 'Started (UTC)', render: (r) => <span className="rt-nowrap">{formatDate(r.started_at)}</span>, sortValue: (r) => startedMs(r) },
    { key: 'run_id', header: 'Run', render: (r) => <span className="cell-mono">{r.run_id}</span>, sortValue: (r) => r.run_id },
    { key: 'tag', header: 'Tag', render: (r) => r.tag || '—', sortValue: (r) => r.tag },
    {
      key: 'machine',
      header: 'Machine',
      render: (r) => (
        <span className="rt-nowrap">
          {r.hostname || '—'} <span className="mono muted">{r.machine_id}</span>
        </span>
      ),
      sortValue: (r) => `${r.hostname}|${r.machine_id}`,
    },
    { key: 'environment', header: 'Environment', render: (r) => <Badge {...environmentBadge(r.virtualization)} />, sortValue: (r) => r.virtualization },
    {
      key: 'audio',
      header: 'Audio device',
      title: 'PipeWire default sink when the run started; runs on different devices never compare',
      render: (r) => (
        <span className="cell-mono" title={r.audio_device ?? 'unknown (recorded before the audio device was part of a run)'}>
          {r.audio_device ? r.audio_device.replace(/^alsa_output\./, '') : '—'}
        </span>
      ),
      sortValue: (r) => r.audio_device ?? null,
    },
    {
      key: 'structure',
      header: 'Structure',
      render: (r) => <Badge kind="structure" value={r.scenario ? `${r.structure} · ${r.scenario}` : r.structure} status="none" icon="" />,
      sortValue: (r) => `${r.structure}/${r.scenario ?? '-'}`,
    },
    { key: 'trace', header: 'Trace', render: (r) => <Badge {...traceBadge(r.trace_mode)} />, sortValue: (r) => r.trace_mode },
    { key: 'switches', header: 'Switches', render: (r) => <span className="cell-switches">{switchesText(r.switches)}</span>, sortValue: (r) => switchesText(r.switches) },
    {
      key: 'trial',
      header: 'Trial / arm',
      render: (r) => (r.trial || r.arm ? <Badge kind="arm" value={[r.trial, r.arm].filter(Boolean).join(' · ')} status="none" icon="" /> : '—'),
      sortValue: (r) => (r.trial || r.arm ? `${r.trial ?? ''}|${r.arm ?? ''}` : null),
    },
    { key: 'commit', header: 'Commit', render: (r) => <span className="cell-mono">{r.commit ? r.commit.slice(0, 9) : '—'}</span>, sortValue: (r) => r.commit },
    { key: 'duration', header: 'Duration', numeric: true, render: (r) => (r.duration_s === null ? '—' : `${formatInt(r.duration_s)} s`), sortValue: (r) => r.duration_s },
    {
      key: 'sets',
      header: 'Sets',
      render: (r) => {
        const names = Object.keys(r.sets);
        return names.length === 0 ? '—' : <span className="rt-sets">{names.map(setLabel).join(', ')}</span>;
      },
      sortValue: (r) => Object.keys(r.sets).length,
    },
  ];
}

export default function RunTable({ runs, selected, onSelect, max = 2, caption, dense = true }: RunTableProps) {
  const columns = runTableColumns();
  return (
    <div className="rt">
      <DataTable
        caption={caption ?? `${runs.length} run${runs.length === 1 ? '' : 's'} — select two to compare`}
        columns={columns}
        rows={[...runs]}
        rowKey={(r) => r.run_id}
        defaultSort={{ key: 'started', dir: 'desc' }}
        selectable={{ selected, max, onChange: onSelect }}
        dense={dense}
        emptyMessage="No runs in this slice."
      />
    </div>
  );
}
