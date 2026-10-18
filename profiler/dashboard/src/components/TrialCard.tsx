/**
 * TrialCard: the detail of one ledger line joined to its history records
 * (DESIGN.md §4.3 "TrialDetail" + the charts of that view).
 *
 * Sections: header (id, date, host, verdict chip, branch, commit, minutes, guard chips),
 * hypothesis + rationale, the change (kind / patch / switch / probe / note) with the probe
 * result, evidence table, run references (A/A, ABAB, traced; links to run dirs, missing
 * records called out), then per Set the ABAB pairs as `PairedDots` (A vs B per pair on one
 * axis, wash = A ± 2 × A/A spread) and the traced confirmation as `DeltaBars` (call-site
 * share of lost slack before / after). Every chart has its table twin through ChartFrame.
 *
 * The metric plotted defaults to the ledger's primary when the ABAB runs carry it (the
 * ABAB runs are untraced, so an interface primary falls back to the outcome primary); the
 * select lists every metric with at least one value in those runs.
 */
import { useState } from 'react';
import type { MetricKey, Run, Trial, TrialJoin } from '../data/types';
import {
  aaSpread,
  findMetric,
  formatDate,
  formatInt,
  formatNumber,
  formatShare,
  identityOf,
  METRICS,
  metric,
  metricValue,
  NULL_TEXT,
  orderSets,
  PRIMARY_METRIC,
  setLabel,
} from '../data';
import Badge, { significanceBadge, verdictBadge } from './Badge';
import ChartFrame from './ChartFrame';
import DataTable, { type Column } from './DataTable';
import NoTimingRibbon from './NoTimingRibbon';
import { parseCallSiteKey } from './CallSiteTrend';
import DeltaBars, { DeltaBarsTable, deltaBarsChange } from './DeltaBars';
import PairedDots, { PairedDotsKey, PairedDotsTable, formatRatio, pairedDotsSummary, type PairedDotsPair } from './PairedDots';
import './TrialCard.css';

export interface TrialCardProps {
  join: TrialJoin;
  /** Every run in history (for the A/A spread of the plotted metric). */
  runs: readonly Run[];
  /** Every ledger line (explicit A/A pairs). */
  trials: readonly Trial[];
}

function nonNull<T>(v: T | null | undefined): v is T {
  return v !== null && v !== undefined;
}

/** `file://` link for an absolute run directory; relative paths (repo-relative) have no link. */
export function runDirHref(run: Pick<Run, 'source_dir'>): string | null {
  const dir = run.source_dir;
  if (!dir) return null;
  if (dir.startsWith('/')) return `file://${dir}`;
  if (/^[A-Za-z]:[\\/]/u.test(dir)) return `file:///${dir.replace(/\\/gu, '/')}`;
  return null;
}

/** Metrics with at least one non-null value in the given runs, registry order. */
export function metricOptionsFor(runs: readonly Run[]): MetricKey[] {
  return METRICS.filter((def) => runs.some((run) => Object.keys(run.sets).some((set) => metricValue(run, set, def.key) !== null))).map((d) => d.key);
}

/** The ledger primary when plottable, else the outcome primary, else the first option. */
export function defaultMetricFor(trial: Trial, options: readonly MetricKey[]): MetricKey | null {
  const primary = findMetric(trial.metrics?.primary ?? '')?.key;
  if (primary && options.includes(primary)) return primary;
  if (options.includes(PRIMARY_METRIC.outcome)) return PRIMARY_METRIC.outcome;
  return options[0] ?? null;
}

/** `5 ✓ 0 ✗ 1 ↷` */
export function probeText(trial: Trial): string {
  const p = trial.probe_result;
  if (!p) return NULL_TEXT;
  return `${p.pass} ✓ ${p.fail} ✗ ${p.skip} ↷`;
}

/**
 * Dropout guard (DESIGN.md §4.3): per Set, the PipeWire errors and the xruns summed over every ABAB pair
 * whose A and B runs are both in history; a Set fails when B's total is higher than A's.
 */
export function dropoutGuardHits(join: TrialJoin): string[] {
  const totals = new Map<string, { ea: number; eb: number; xa: number; xb: number }>();
  for (const p of join.runs.abab) {
    if (!p.a || !p.b) continue;
    for (const [set, mb] of Object.entries(p.b.sets)) {
      const ma = p.a.sets[set];
      if (!ma) continue;
      const t = totals.get(set) ?? { ea: 0, eb: 0, xa: 0, xb: 0 };
      t.ea += ma.pipewire_errors ?? 0;
      t.eb += mb.pipewire_errors ?? 0;
      t.xa += ma.xruns ?? 0;
      t.xb += mb.xruns ?? 0;
      totals.set(set, t);
    }
  }
  const hits: string[] = [];
  for (const set of orderSets(totals.keys())) {
    const t = totals.get(set)!;
    if (t.eb > t.ea) hits.push(`${setLabel(set)}: PipeWire errors ${formatInt(t.ea)} → ${formatInt(t.eb)} on B`);
    if (t.xb > t.xa) hits.push(`${setLabel(set)}: xruns ${formatInt(t.xa)} → ${formatInt(t.xb)} on B`);
  }
  return hits;
}

/** Share of `key` in `run.sets[set].call_sites_top`, or null. */
export function shareOf(run: Run | null, set: string, key: string): number | null {
  const entry = run?.sets[set]?.call_sites_top?.find((cs) => cs.key === key);
  return entry ? entry.share : null;
}

interface RunRefProps {
  id: string;
  run: Run | null;
  arm: string;
}

function RunRef({ id, run, arm }: RunRefProps) {
  const href = run ? runDirHref(run) : null;
  return (
    <li className="tc-runref">
      <span className="tc-arm">{arm}</span>
      {run ? (
        <>
          {href ? (
            <a className="cell-mono" href={href} title={run.source_dir ?? undefined}>
              {run.run_id}
            </a>
          ) : (
            <span className="cell-mono" title={run.source_dir ?? undefined}>
              {run.run_id}
            </span>
          )}
          <span className="muted">
            {formatDate(run.started_at)}
            {run.tag ? ` · ${run.tag}` : ''}
          </span>
          {run.source_dir && !href ? <span className="mono muted tc-dir">{run.source_dir}</span> : null}
        </>
      ) : (
        <>
          <span className="cell-mono">{id}</span>
          <Badge kind="neutral" value="missing record" status="warning" icon="?" title="No history record for this run id (run history-add)" />
        </>
      )}
    </li>
  );
}

interface EvidenceRow {
  index: number;
  run: string;
  set: string;
  call_site: string;
  share: number;
}

export default function TrialCard({ join, runs, trials }: TrialCardProps) {
  const { trial } = join;
  const ababRuns = join.runs.abab.flatMap((p) => [p.a, p.b]).filter(nonNull);
  const options = metricOptionsFor(ababRuns);
  const [chosen, setChosen] = useState<MetricKey | null>(null);
  const metricKey = chosen && options.includes(chosen) ? chosen : defaultMetricFor(trial, options);
  const def = metricKey ? metric(metricKey) : null;
  const ledgerPrimary = findMetric(trial.metrics?.primary ?? '')?.key ?? null;
  const sets = orderSets(ababRuns.flatMap((r) => Object.keys(r.sets)));
  const identity = ababRuns[0] ? identityOf(ababRuns[0]) : null;
  const resolved = [...ababRuns, ...join.runs.aa.flatMap((p) => [p[0], p[1]]), join.runs.traced?.a ?? null, join.runs.traced?.b ?? null].filter(nonNull);
  // No timing claims: the ledger's own host says "vm:<x>", or any cited run (own or evidence) is virtualised.
  const evidenceRuns = trial.evidence.map((e) => runs.find((r) => r.run_id === e.run) ?? null).filter(nonNull);
  const virtualisedRuns = [...resolved, ...evidenceRuns].filter((r) => r.virtualization !== 'none');
  const hostVirt = typeof trial.host === 'string' && trial.host.startsWith('vm:') ? trial.host.slice(3) || 'unknown' : null;
  const virtualisation = virtualisedRuns[0]?.virtualization ?? hostVirt;

  // Guard: the dropout counts must not be worse on B than on A. Totals per Set over the ABAB pairs
  // whose two runs are both in history (one chip per Set and metric); the ledger's own totals are the
  // fallback when no pair resolves.
  const guardHits = dropoutGuardHits(join);
  const ledgerErrors = trial.metrics?.pipewire_errors ?? null;
  const ledgerXruns = trial.metrics?.xruns ?? null;
  if (guardHits.length === 0 && !join.runs.abab.some((p) => p.a && p.b)) {
    if (ledgerErrors && ledgerErrors.a !== null && ledgerErrors.b !== null && ledgerErrors.b > ledgerErrors.a) {
      guardHits.push(`PipeWire errors ${formatInt(ledgerErrors.a)} → ${formatInt(ledgerErrors.b)} on B (ledger)`);
    }
    if (ledgerXruns && ledgerXruns.a !== null && ledgerXruns.b !== null && ledgerXruns.b > ledgerXruns.a) {
      guardHits.push(`xruns ${formatInt(ledgerXruns.a)} → ${formatInt(ledgerXruns.b)} on B (ledger)`);
    }
  }

  // Traced confirmation: ledger values first, else derived from the traced runs' call sites.
  const evidence = trial.evidence[0] ?? null;
  const tc = trial.traced_confirmation;
  const derivedBefore = evidence ? shareOf(join.runs.traced?.a ?? null, evidence.set, evidence.call_site) : null;
  const derivedAfter = evidence ? shareOf(join.runs.traced?.b ?? null, evidence.set, evidence.call_site) : null;
  const before = tc?.call_site_share_before ?? derivedBefore;
  const after = tc?.after ?? derivedAfter;
  const confirmationLabel = evidence ? `${parseCallSiteKey(evidence.call_site).label} share of lost slack (${setLabel(evidence.set)})` : 'call-site share of lost slack';

  const evidenceRows: EvidenceRow[] = trial.evidence.map((e, i) => ({ index: i + 1, run: e.run, set: e.set, call_site: e.call_site, share: e.share_of_lost_slack }));
  const evidenceColumns: Column<EvidenceRow>[] = [
    { key: 'run', header: 'Run', render: (r) => <span className="cell-mono">{r.run}</span> },
    { key: 'set', header: 'Set', render: (r) => setLabel(r.set), sortValue: (r) => r.set },
    {
      key: 'call_site',
      header: 'Call site',
      render: (r) => {
        const parts = parseCallSiteKey(r.call_site);
        return (
          <span title={r.call_site}>
            {parts.label} <span className="mono muted">{parts.detail}</span>
          </span>
        );
      },
      sortValue: (r) => r.call_site,
    },
    { key: 'share', header: 'Share of lost slack', numeric: true, render: (r) => formatShare(r.share), sortValue: (r) => r.share },
  ];

  const vb = verdictBadge(trial.verdict);
  const dimmed = vb.status === 'dim';

  return (
    <article className={`card tc${dimmed ? ' tc-dim' : ''}`} aria-label={`Trial ${trial.trial}`} data-verdict={trial.verdict}>
      <header className="tc-head">
        <h3 className="tc-title">
          <span className="mono">{trial.trial}</span>
          <Badge {...vb} />
        </h3>
        <div className="tc-meta">
          <span>{formatDate(trial.date)} UTC</span>
          <span>{trial.host}</span>
          {trial.branch ? <span className="mono">{trial.branch}</span> : null}
          <span>
            commit <span className="mono">{trial.commit ?? NULL_TEXT}</span>
          </span>
          <span>{trial.minutes !== null ? `${formatInt(trial.minutes)} min` : `${NULL_TEXT} min`}</span>
        </div>
        {guardHits.length > 0 ? (
          <div className="tc-guard">
            {guardHits.map((hit) => (
              <Badge key={hit} kind="neutral" value={`reject · ${hit}`} status="critical" icon="✗" title="Guard metric: any non-zero value is an automatic reject" />
            ))}
          </div>
        ) : null}
      </header>
      {virtualisation ? <NoTimingRibbon virtualization={virtualisation} hostname={virtualisedRuns[0]?.hostname ?? null} runs={virtualisedRuns.length} /> : null}

      <div className="tc-grid">
        <section className="tc-section" aria-label="Hypothesis">
          <h4>Hypothesis</h4>
          <p>{trial.hypothesis || NULL_TEXT}</p>
          <h4>Rationale</h4>
          <p>{trial.rationale || NULL_TEXT}</p>
        </section>
        <section className="tc-section" aria-label="Change">
          <h4>Change</h4>
          <dl className="tc-dl">
            <dt>kind</dt>
            <dd>{trial.change.kind}</dd>
            <dt>patch</dt>
            <dd className="mono">{trial.change.patch ?? NULL_TEXT}</dd>
            <dt>switch</dt>
            <dd className="mono">{trial.change.switch ?? NULL_TEXT}</dd>
            <dt>probe</dt>
            <dd>
              <span className="mono">{trial.change.probe ?? NULL_TEXT}</span>
              {trial.probe_result ? (
                <>
                  {' '}
                  <span className="tc-probe" title="pass ✓ · fail ✗ · skip ↷">
                    {probeText(trial)}
                  </span>
                  {trial.probe_result.log ? <span className="mono muted"> {trial.probe_result.log}</span> : null}
                </>
              ) : null}
            </dd>
            <dt>note</dt>
            <dd className="mono">{trial.change.note ?? NULL_TEXT}</dd>
            {trial.metrics ? (
              <>
                <dt>primary</dt>
                <dd className="mono">{trial.metrics.primary || NULL_TEXT}</dd>
                {trial.metrics.pipewire_errors ? (
                  <>
                    <dt>PipeWire errors A / B</dt>
                    <dd>
                      {formatInt(trial.metrics.pipewire_errors.a)} / {formatInt(trial.metrics.pipewire_errors.b)}
                    </dd>
                  </>
                ) : null}
                <dt>xruns A / B</dt>
                <dd>
                  {formatInt(trial.metrics.xruns?.a ?? null)} / {formatInt(trial.metrics.xruns?.b ?? null)}
                </dd>
                <dt>Live CPU A / B</dt>
                <dd>
                  {trial.metrics.cpu_live_pct ? `${formatNumber(trial.metrics.cpu_live_pct.a, 1)}% / ${formatNumber(trial.metrics.cpu_live_pct.b, 1)}%` : NULL_TEXT}
                </dd>
              </>
            ) : null}
          </dl>
        </section>
        <section className="tc-section" aria-label="Runs">
          <h4>Runs</h4>
          {join.runs.aa.length > 0 ? (
            <ul className="tc-runs">
              {join.runs.aa.map((pair, i) => (
                <li key={`aa-${i}`}>
                  <span className="tc-group">A/A pair {i + 1}</span>
                  <ul className="tc-runs">
                    <RunRef id={trial.runs.aa[i]?.[0] ?? '?'} run={pair[0]} arm="AA" />
                    <RunRef id={trial.runs.aa[i]?.[1] ?? '?'} run={pair[1]} arm="AA" />
                  </ul>
                </li>
              ))}
            </ul>
          ) : null}
          {join.runs.abab.length > 0 ? (
            <ul className="tc-runs">
              {join.runs.abab.map((pair, i) => (
                <li key={`abab-${i}`}>
                  <span className="tc-group">ABAB pair {i + 1}</span>
                  <ul className="tc-runs">
                    <RunRef id={trial.runs.abab[i]?.a ?? '?'} run={pair.a} arm="A" />
                    <RunRef id={trial.runs.abab[i]?.b ?? '?'} run={pair.b} arm="B" />
                  </ul>
                </li>
              ))}
            </ul>
          ) : null}
          {join.runs.traced ? (
            <ul className="tc-runs">
              <li>
                <span className="tc-group">traced confirmation</span>
                <ul className="tc-runs">
                  <RunRef id={trial.runs.traced?.a ?? '?'} run={join.runs.traced.a} arm="A" />
                  <RunRef id={trial.runs.traced?.b ?? '?'} run={join.runs.traced.b} arm="B" />
                </ul>
              </li>
            </ul>
          ) : null}
          {join.runs.aa.length === 0 && join.runs.abab.length === 0 && !join.runs.traced ? <p className="muted">No runs recorded for this trial.</p> : null}
          {join.missing.length > 0 ? (
            <p className="tc-missing">
              <Badge kind="neutral" value={`${join.missing.length} run reference${join.missing.length === 1 ? '' : 's'} without a history record`} status="warning" icon="?" />
            </p>
          ) : null}
        </section>
      </div>

      {evidenceRows.length > 0 ? (
        <section className="tc-section" aria-label="Evidence">
          <h4>Evidence</h4>
          <DataTable caption={`Evidence cited by ${trial.trial}`} captionHidden columns={evidenceColumns} rows={evidenceRows} rowKey={(r) => String(r.index)} dense />
        </section>
      ) : null}

      <section className="tc-section tc-charts" aria-label="ABAB pairs">
        <div className="section-head">
          <h3>ABAB pairs</h3>
          {options.length > 0 ? (
            <label className="tc-metric">
              <span className="muted">metric</span>{' '}
              <select value={metricKey ?? ''} onChange={(e) => setChosen(e.target.value as MetricKey)} aria-label="Metric for the ABAB pairs">
                {options.map((key) => {
                  const m = metric(key);
                  return (
                    <option key={key} value={key}>
                      {m.label}
                      {m.unit ? ` (${m.unit})` : ''} · {m.source}
                    </option>
                  );
                })}
              </select>
            </label>
          ) : null}
        </div>
        {def && metricKey && sets.length > 0 ? (
          <div className="grid tc-pairs">
            {sets.map((set) => {
              const pairs: PairedDotsPair[] = join.runs.abab.map((p, i) => ({
                index: i + 1,
                a: p.a ? metricValue(p.a, set, metricKey) : null,
                b: p.b ? metricValue(p.b, set, metricKey) : null,
                runA: p.a?.run_id ?? trial.runs.abab[i]?.a ?? '?',
                runB: p.b?.run_id ?? trial.runs.abab[i]?.b ?? '?',
              }));
              const ledgerSet = metricKey === ledgerPrimary ? (trial.metrics?.per_set[set] ?? null) : null;
              const spread = ledgerSet?.aa_spread ?? (identity ? (aaSpread(runs, trials, identity, set, metricKey)?.spread ?? null) : null);
              const summary = pairedDotsSummary(pairs, def.direction, spread);
              const sig = significanceBadge(summary.significance, summary.direction);
              const ratio = ledgerSet?.ratio_to_spread ?? summary.ratio;
              const medianText =
                summary.medianDelta === null
                  ? NULL_TEXT
                  : `${summary.direction === 'better' ? '▲ ' : summary.direction === 'worse' ? '▼ ' : ''}${def.format(Math.abs(summary.medianDelta))}`;
              const subtitle = `median Δ ${medianText} over ${summary.n} pair${summary.n === 1 ? '' : 's'} · A/A spread ${def.format(spread)} · ${formatRatio(ratio)} spread`;
              const hasValues = pairs.some((p) => p.a !== null || p.b !== null);
              return (
                <ChartFrame
                  key={set}
                  id={`trial.${trial.trial}.${set}`}
                  title={`${setLabel(set)} — ${def.label}`}
                  subtitle={subtitle}
                  keyRow={
                    <div className="tc-keyrow">
                      <PairedDotsKey spread={spread} format={def.format} />
                      <Badge {...sig} />
                    </div>
                  }
                  chart={<PairedDots pairs={pairs} unit={def.unit} direction={def.direction} format={def.format} spread={spread} label={`${setLabel(set)} ${def.label}: ${pairs.length} ABAB pairs`} />}
                  table={<PairedDotsTable pairs={pairs} direction={def.direction} format={def.format} caption={`${setLabel(set)} — ${def.label}, A vs B per pair`} captionHidden />}
                  empty={hasValues ? undefined : `No ${def.label} values in the ABAB runs of ${setLabel(set)}.`}
                />
              );
            })}
          </div>
        ) : (
          <p className="empty">No ABAB runs in history for this trial{join.missing.length > 0 ? ' (run references are missing their history records)' : ''}.</p>
        )}
      </section>

      <section className="tc-section" aria-label="Traced confirmation">
        <ChartFrame
          id={`trial.${trial.trial}.confirmation`}
          title="Traced confirmation"
          subtitle={before !== null || after !== null ? `${confirmationLabel}: ${deltaBarsChange(before, after, formatShare)}` : confirmationLabel}
          chart={<DeltaBars before={before} after={after} label={confirmationLabel} format={formatShare} formatTick={(v) => `${Math.round(v * 100)}%`} />}
          table={<DeltaBarsTable before={before} after={after} label={confirmationLabel} format={formatShare} caption={`Traced confirmation: ${confirmationLabel}`} captionHidden />}
          empty={before === null && after === null ? 'No traced confirmation recorded (no traced run per arm yet).' : undefined}
          footer={
            tc ? <span className="muted">from the ledger line{derivedBefore !== null || derivedAfter !== null ? ' (traced runs agree in history)' : ''}</span> : <span className="muted">derived from the traced runs&apos; call sites</span>
          }
        />
      </section>
    </article>
  );
}
