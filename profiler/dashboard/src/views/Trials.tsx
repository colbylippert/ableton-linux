/**
 * Trials — "what did each trial change and did it clear the noise?" (DESIGN.md §4.3)
 *
 * The ledger table: trial, date, host, verdict chip (status colour + icon + label; kept /
 * reverted in colour, the other verdicts dimmed), hypothesis, switch, probe result,
 * primary metric, per-Set ratio-to-spread chips (≥ 2× = beyond noise, ▲ / ▼ by the primary
 * metric's direction), commit, minutes. Selecting a row (one at a time) opens its
 * `TrialCard`: ABAB pairs as paired dots per Set, the traced confirmation as before/after
 * bars, evidence, run references. The machine filter applies through the trial's cited
 * runs; trials whose runs are not in history stay visible.
 */
import { useMemo, useState } from 'react';
import type { ViewProps } from './ViewProps';
import type { MetricDirection, Trial, TrialJoin } from '../data/types';
import { findMetric, formatDate, formatInt, joinTrials, NULL_TEXT, setLabel, trialMachine } from '../data';
import Badge, { verdictBadge, type BadgeProps } from '../components/Badge';
import DataTable, { type Column } from '../components/DataTable';
import TrialCard, { probeText } from '../components/TrialCard';
import { formatRatio } from '../components/PairedDots';

/** Per-Set ratio-to-spread chip: `VSTs 3.3×` with ▲ / ▼ when the ratio clears 2, ≈ within noise, ? without a spread. */
export function ratioChip(set: string, delta: number | null, ratio: number | null, direction: MetricDirection): BadgeProps {
  const value = `${setLabel(set)} ${formatRatio(ratio)}`;
  if (ratio === null || delta === null) {
    return { kind: 'significance', value, status: 'dim', icon: '?', title: `${setLabel(set)}: no A/A spread recorded` };
  }
  const improvement = direction === 'higher' ? delta > 0 : direction === 'neutral' ? false : delta < 0;
  if (ratio >= 2 && delta !== 0 && direction !== 'neutral') {
    return improvement
      ? { kind: 'significance', value, status: 'good', icon: '▲', title: `${setLabel(set)}: improvement ${formatRatio(ratio)} the A/A spread (beyond noise)` }
      : { kind: 'significance', value, status: 'critical', icon: '▼', title: `${setLabel(set)}: regression ${formatRatio(ratio)} the A/A spread (beyond noise)` };
  }
  return { kind: 'significance', value, status: 'warning', icon: '≈', title: `${setLabel(set)}: within noise (${formatRatio(ratio)} the A/A spread)` };
}

export function truncate(text: string, max = 96): string {
  if (text.length <= max) return text;
  return `${text.slice(0, max - 1).trimEnd()}…`;
}

function primaryDirection(trial: Trial): MetricDirection {
  return findMetric(trial.metrics?.primary ?? '')?.direction ?? 'lower';
}

export default function TrialsView({ data, filter }: ViewProps) {
  const joins = useMemo(() => {
    const all = joinTrials(data.trials, data.runs);
    if (filter.machine === null) return all;
    return all.filter((j) => {
      const machine = trialMachine(j.trial, data.runs);
      return machine === null || machine === filter.machine;
    });
  }, [data.trials, data.runs, filter.machine]);

  const [picked, setPicked] = useState<string | null>(null);
  const selected: TrialJoin | null = useMemo(() => {
    const byPick = picked ? joins.find((j) => j.trial.trial === picked) : undefined;
    return byPick ?? joins[joins.length - 1] ?? null;
  }, [joins, picked]);

  const columns: Column<TrialJoin>[] = [
    { key: 'trial', header: 'Trial', render: (j) => <span className="cell-mono">{j.trial.trial}</span>, sortValue: (j) => j.trial.trial },
    { key: 'date', header: 'Date (UTC)', render: (j) => <span style={{ whiteSpace: 'nowrap' }}>{formatDate(j.trial.date)}</span>, sortValue: (j) => Date.parse(j.trial.date) },
    { key: 'host', header: 'Host', render: (j) => j.trial.host, sortValue: (j) => j.trial.host },
    { key: 'verdict', header: 'Verdict', render: (j) => <Badge {...verdictBadge(j.trial.verdict)} />, sortValue: (j) => j.trial.verdict },
    {
      key: 'hypothesis',
      header: 'Hypothesis',
      render: (j) => (
        <span className="trials-hypothesis" title={j.trial.hypothesis} tabIndex={0}>
          {truncate(j.trial.hypothesis) || NULL_TEXT}
        </span>
      ),
      sortValue: (j) => j.trial.hypothesis,
    },
    { key: 'switch', header: 'Switch', render: (j) => <span className="cell-switches">{j.trial.change.switch ?? NULL_TEXT}</span>, sortValue: (j) => j.trial.change.switch },
    { key: 'probe', header: 'Probe', title: 'pass ✓ · fail ✗ · skip ↷', render: (j) => <span style={{ whiteSpace: 'nowrap' }}>{probeText(j.trial)}</span>, sortValue: (j) => j.trial.probe_result?.fail ?? null },
    { key: 'primary', header: 'Primary', render: (j) => <span className="cell-mono">{j.trial.metrics?.primary || NULL_TEXT}</span>, sortValue: (j) => j.trial.metrics?.primary ?? null },
    {
      key: 'sets',
      header: 'Per-Set ratio to spread',
      title: '|Δ| / A/A spread per Set; ≥ 2× clears the acceptance gate',
      render: (j) => {
        const per = j.trial.metrics?.per_set ?? {};
        const names = Object.keys(per);
        if (names.length === 0) return NULL_TEXT;
        const direction = primaryDirection(j.trial);
        return (
          <span className="trials-chips">
            {names.map((set) => (
              <Badge key={set} {...ratioChip(set, per[set]?.delta ?? null, per[set]?.ratio_to_spread ?? null, direction)} />
            ))}
          </span>
        );
      },
      sortValue: (j) => Math.max(0, ...Object.values(j.trial.metrics?.per_set ?? {}).map((m) => m.ratio_to_spread ?? 0)),
    },
    { key: 'commit', header: 'Commit', render: (j) => <span className="cell-mono">{j.trial.commit ?? NULL_TEXT}</span>, sortValue: (j) => j.trial.commit },
    { key: 'minutes', header: 'Minutes', numeric: true, render: (j) => formatInt(j.trial.minutes), sortValue: (j) => j.trial.minutes },
  ];

  const kept = joins.filter((j) => j.trial.verdict === 'keep').length;
  const reverted = joins.filter((j) => j.trial.verdict === 'revert').length;

  return (
    <section className="view view-trials">
      <h2 className="view-title">Trials</h2>
      <p className="view-lead">
        One ledger line per trial. Kept and reverted verdicts carry status colour; other verdicts are dimmed. Pick a row to see its ABAB pairs, traced confirmation and run references.
      </p>
      {joins.length === 0 ? (
        <div className="empty">
          No trials yet{data.trials.length > 0 ? ' for this machine' : ''}. The agent loop appends one JSON line per trial to <code>profiler/ledger.jsonl</code>; this page updates live.
        </div>
      ) : (
        <>
          <p className="app-meta">
            {joins.length} trial{joins.length === 1 ? '' : 's'} · {kept} kept · {reverted} reverted
          </p>
          <div className="card" style={{ padding: 0 }}>
            <DataTable
              caption="Ledger"
              captionHidden
              columns={columns}
              rows={joins}
              rowKey={(j) => j.trial.trial}
              defaultSort={{ key: 'date', dir: 'desc' }}
              selectable={{ selected: selected ? [selected.trial.trial] : [], max: 1, onChange: (next) => setPicked(next[0] ?? null) }}
              dense
            />
          </div>
          {selected ? (
            <div className="section">
              <TrialCard key={selected.trial.trial} join={selected} runs={data.runs} trials={data.trials} />
            </div>
          ) : null}
        </>
      )}
    </section>
  );
}
