/**
 * CompareDrawer: two picked runs side by side (DESIGN.md §4.6 "RunDelta").
 *
 * The identity guard is the data layer's `runDelta()` — the same refusals as
 * `bench-report.py compare` (machine, virtualisation, structure/scenario, trace mode), shown
 * as a ribbon with the reason. Otherwise one row per Set × metric the pair's trace mode is
 * authoritative for: A, B, Δ (signed, positive = improvement, with a diverging cell bar),
 * the A/A spread of that identity and the within / beyond-noise chip; guard metrics with a
 * non-zero B value carry the reject chip. The number stays in ink; only the glyph, the bar
 * and the chip dot wear colour.
 */
import { useMemo } from 'react';
import type { NoiseSpread, Run, Significance, Trial } from '../data/types';
import {
  aaSpread,
  deltaDirection,
  formatDate,
  formatShare,
  identityOf,
  isGuardReject,
  metric,
  runDelta,
  setLabel,
  NULL_TEXT,
  type DeltaDirection,
  type RunDeltaRow,
} from '../data';
import Badge, { environmentBadge, significanceBadge, traceBadge } from './Badge';
import DataTable, { type Column } from './DataTable';
import NoTimingRibbon from './NoTimingRibbon';
import { switchesText } from './RunTable';
import './CompareDrawer.css';

export interface CompareRow extends RunDeltaRow {
  spread: NoiseSpread | null;
  significance: Significance;
  deltaDirection: DeltaDirection;
  /** Guard metric with a non-zero B value. */
  reject: boolean;
}

export type CompareResult = { ok: true; rows: CompareRow[] } | { ok: false; reason: string };

/** `runDelta()` rows enriched with the identity's A/A spread and the noise verdict. */
export function compareRows(a: Run, b: Run, runs: readonly Run[], trials: readonly Trial[]): CompareResult {
  const result = runDelta(a, b);
  if (!result.ok) return result;
  const identity = identityOf(a);
  const rows: CompareRow[] = result.rows.map((row) => {
    const spread = row.direction === 'neutral' ? null : aaSpread(runs, trials, identity, row.set, row.metric);
    const s = spread?.spread ?? null;
    const significance: Significance =
      row.direction === 'neutral' || row.deltaAbs === null || s === null ? 'unknown' : Math.abs(row.deltaAbs) > 2 * s ? 'beyond' : 'within';
    return { ...row, spread, significance, deltaDirection: deltaDirection(row), reject: isGuardReject(row.metric, row.b) };
  });
  return { ok: true, rows };
}

/** `▲ 1.3% (3.2%)`: absolute change in the metric's unit, relative change in parentheses. */
export function deltaCellText(row: RunDeltaRow): { glyph: string; status: 'good' | 'critical' | 'none'; text: string } {
  const format = metric(row.metric).format;
  if (row.deltaAbs === null) return { glyph: '', status: 'none', text: NULL_TEXT };
  const magnitude = format(Math.abs(row.deltaAbs));
  const rel = row.deltaPct === null ? '' : ` (${formatShare(Math.abs(row.deltaPct))})`;
  if (row.direction === 'neutral') {
    const raw = row.deltaAbs;
    return { glyph: '', status: 'none', text: `${raw > 0 ? '+' : raw < 0 ? '-' : ''}${magnitude}${rel}` };
  }
  if (row.deltaAbs > 0) return { glyph: '▲', status: 'good', text: `${magnitude}${rel}` };
  if (row.deltaAbs < 0) return { glyph: '▼', status: 'critical', text: `${magnitude}${rel}` };
  return { glyph: '', status: 'none', text: `${magnitude}${rel}` };
}

function RunSummary({ run, arm }: { run: Run; arm: 'A' | 'B' }) {
  return (
    <div className="cd-run" data-arm={arm}>
      <span className="cd-arm">{arm}</span>
      <span className="cell-mono">{run.run_id}</span>
      <span className="muted">
        {formatDate(run.started_at)}
        {run.tag ? ` · ${run.tag}` : ''}
        {run.trial || run.arm ? ` · ${[run.trial, run.arm].filter(Boolean).join(' ')}` : ''}
      </span>
      <span className="cell-switches">{switchesText(run.switches)}</span>
    </div>
  );
}

export interface CompareDrawerProps {
  a: Run;
  b: Run;
  runs: readonly Run[];
  trials: readonly Trial[];
  onClose?: () => void;
  onSwap?: () => void;
}

export default function CompareDrawer({ a, b, runs, trials, onClose, onSwap }: CompareDrawerProps) {
  const result = useMemo(() => compareRows(a, b, runs, trials), [a, b, runs, trials]);
  const scale = useMemo(() => {
    if (!result.ok) return 1;
    const m = Math.max(0, ...result.rows.map((r) => Math.abs(r.deltaPct ?? 0)));
    return m > 0 ? m : 1;
  }, [result]);

  const columns: Column<CompareRow>[] = [
    { key: 'set', header: 'Set', render: (r) => setLabel(r.set), sortValue: (r) => r.set },
    {
      key: 'metric',
      header: 'Metric',
      render: (r) => (
        <span className="cd-metric">
          {r.label}
          {r.unit ? <span className="muted"> {r.unit}</span> : null}
          <span className="cd-source muted"> {r.source}</span>
        </span>
      ),
      sortValue: (r) => r.label,
    },
    { key: 'a', header: 'A', numeric: true, render: (r) => metric(r.metric).format(r.a), sortValue: (r) => r.a },
    { key: 'b', header: 'B', numeric: true, render: (r) => metric(r.metric).format(r.b), sortValue: (r) => r.b },
    {
      key: 'delta',
      header: 'Δ (B vs A)',
      numeric: true,
      title: 'Signed so that positive = improvement; relative change in parentheses',
      render: (r) => {
        const d = deltaCellText(r);
        const pct = r.deltaPct ?? 0;
        const widthPct = Math.min(100, (Math.abs(pct) / scale) * 100);
        return (
          <span className="cd-delta">
            <span className="cd-bar" aria-hidden="true">
              {r.direction !== 'neutral' && r.deltaPct !== null && pct !== 0 ? (
                <span className={`cd-bar-fill ${pct > 0 ? 'cd-bar-pos' : 'cd-bar-neg'}`} style={{ width: `${widthPct / 2}%` }} />
              ) : null}
            </span>
            {d.glyph ? (
              <span className={`cd-glyph glyph-${d.status}`} aria-hidden="true">
                {d.glyph}
              </span>
            ) : null}
            <span className="cd-delta-text">{d.text}</span>
          </span>
        );
      },
      sortValue: (r) => r.deltaPct ?? r.deltaAbs,
    },
    {
      key: 'spread',
      header: 'A/A spread',
      numeric: true,
      title: 'Median |a − b| over the identity’s A/A pairs',
      render: (r) => (r.spread ? `${metric(r.metric).format(r.spread.spread)} (${r.spread.pairs})` : NULL_TEXT),
      sortValue: (r) => r.spread?.spread ?? null,
    },
    {
      key: 'status',
      header: 'Status',
      render: (r) =>
        r.reject ? (
          <Badge kind="neutral" value="reject" status="critical" icon="✗" title="Guard metric: non-zero on B" />
        ) : (
          <Badge {...significanceBadge(r.significance, r.deltaDirection)} />
        ),
      sortValue: (r) => (r.reject ? 'reject' : `${r.significance}-${r.deltaDirection}`),
    },
  ];

  const virtualised = a.virtualization !== 'none' ? a : b.virtualization !== 'none' ? b : null;
  const counts = result.ok
    ? {
        better: result.rows.filter((r) => r.significance === 'beyond' && r.deltaDirection === 'better').length,
        worse: result.rows.filter((r) => r.significance === 'beyond' && r.deltaDirection === 'worse').length,
        within: result.rows.filter((r) => r.significance === 'within').length,
        unknown: result.rows.filter((r) => r.significance === 'unknown' && r.direction !== 'neutral').length,
        reject: result.rows.filter((r) => r.reject).length,
      }
    : null;

  return (
    <section className="card cd" aria-label="Compare runs">
      <div className="cd-head">
        <h3 className="card-title">Compare</h3>
        <div className="cd-runs">
          <RunSummary run={a} arm="A" />
          <span className="cd-arrow" aria-hidden="true">
            →
          </span>
          <RunSummary run={b} arm="B" />
        </div>
        <div className="cd-actions">
          {onSwap ? (
            <button type="button" className="btn" onClick={onSwap}>
              Swap A ↔ B
            </button>
          ) : null}
          {onClose ? (
            <button type="button" className="btn" onClick={onClose}>
              Clear
            </button>
          ) : null}
        </div>
      </div>
      {!result.ok ? (
        <>
          <div className="ribbon cd-refuse" role="status">
            <span className="icon" aria-hidden="true">
              ⚠
            </span>
            <span>
              <strong>Cannot compare</strong> — {result.reason}.
            </span>
          </div>
          <p className="note">
            Pick two runs of one identity: same machine, environment, structure / scenario and trace mode — the same refusal as <code>bench-report.py compare</code>.
          </p>
        </>
      ) : (
        <>
          {virtualised ? <NoTimingRibbon virtualization={virtualised.virtualization} hostname={virtualised.hostname} runs={2} /> : null}
          <div className="cd-summary">
            <Badge {...environmentBadge(a.virtualization)} />
            <Badge {...traceBadge(a.trace_mode)} />
            <span className="muted">
              {a.trace_mode === 'off' ? 'outcome metrics (untraced runs)' : 'interface metrics (traced runs)'} · {result.rows.length} rows
            </span>
            {counts ? (
              <span className="cd-counts">
                {counts.reject > 0 ? <Badge kind="neutral" value={`${counts.reject} reject`} status="critical" icon="✗" /> : null}
                <Badge kind="significance" value={`${counts.better} beyond noise, better`} status="good" icon="▲" />
                <Badge kind="significance" value={`${counts.worse} beyond noise, worse`} status="critical" icon="▼" />
                <Badge kind="significance" value={`${counts.within} within noise`} status="warning" icon="≈" />
                {counts.unknown > 0 ? <Badge kind="significance" value={`${counts.unknown} no A/A data`} status="dim" icon="?" /> : null}
              </span>
            ) : null}
          </div>
          <DataTable caption={`Per-Set deltas, ${b.run_id} vs ${a.run_id}`} captionHidden columns={columns} rows={result.rows} rowKey={(r) => `${r.set}|${r.metric}`} dense emptyMessage="No metric has a value in either run." />
        </>
      )}
    </section>
  );
}
