/**
 * Trends — "how did each metric move over run time?" (DESIGN.md §4.2)
 *
 * A metric selector (outcome metrics from untraced runs, interface metrics from traced
 * runs; a group is disabled when the slice has no such runs) drives small multiples: one
 * `TrendChart` per Set with its own baseline, A/A band (±2 × spread) and trial markers —
 * the only honest way to show per-Set noise. The overlay toggle draws the canonical Sets on
 * one axis as delta % vs each Set's own baseline (common base; non-canonical Sets are
 * listed in the footer and keep their own card). Runs are grouped by identity, so a slice
 * that spans scenarios or trace modes renders one group per identity, never a mixed chart.
 */
import { useMemo, useState } from 'react';
import type { ViewProps } from './ViewProps';
import { scopeSlice } from './Overview';
import { EnvironmentBadge } from '../components/Badge';
import NoTimingRibbon from '../components/NoTimingRibbon';
import TrendChart, { type TrendBaseline, type TrendNoiseBand } from '../components/TrendChart';
import type { GainRow, Identity, MetricDef, MetricKey, Run } from '../data/types';
import {
  CANONICAL_SETS,
  computeGains,
  identityKeyOf,
  identityOf,
  isTraced,
  metric,
  metricsFor,
  orderSets,
  overlaySeries,
  PRIMARY_METRIC,
  setLabel,
  setSlot,
  trendSeries,
  trialMarkers,
} from '../data';

interface IdentityGroup {
  key: string;
  identity: Identity;
  runs: Run[];
  latest: Run;
}

function groupByIdentity(runs: Run[]): IdentityGroup[] {
  const groups = new Map<string, IdentityGroup>();
  for (const run of runs) {
    const identity = identityOf(run);
    const key = identityKeyOf(identity);
    const group = groups.get(key);
    if (group) {
      group.runs.push(run);
      if (run.started_at > group.latest.started_at) group.latest = run;
    } else {
      groups.set(key, { key, identity, runs: [run], latest: run });
    }
  }
  const out = Array.from(groups.values());
  for (const group of out) group.runs.sort((a, b) => (a.started_at < b.started_at ? -1 : a.started_at > b.started_at ? 1 : a.run_id.localeCompare(b.run_id)));
  return out.sort((a, b) => (a.latest.started_at > b.latest.started_at ? -1 : a.latest.started_at < b.latest.started_at ? 1 : 0));
}

function identityLabel(identity: Identity): string {
  const where = identity.scenario ? `${identity.structure} / ${identity.scenario}` : identity.structure;
  const trace = identity.trace_mode === 'off' ? 'untraced' : `traced · ${identity.trace_mode}`;
  return `${where} · ${trace}`;
}

/** Overlay values are signed fractions (positive = improvement); shown as a signed percentage. */
export function formatSignedPct(value: number | null): string {
  if (value === null || !Number.isFinite(value)) return '—';
  const sign = value > 0 ? '+' : value < 0 ? '−' : '';
  return `${sign}${(Math.abs(value) * 100).toFixed(1)}%`;
}

function directionText(def: MetricDef): string {
  if (def.direction === 'lower') return 'lower is better';
  if (def.direction === 'higher') return 'higher is better';
  return 'informational (no direction)';
}

export default function TrendsView({ data, filter }: ViewProps) {
  const scoped = useMemo(() => scopeSlice(data.runs, filter), [data.runs, filter]);
  const { runs, machine, latest } = scoped;
  const hasTraced = runs.some((r) => isTraced(r));
  const hasUntraced = runs.some((r) => !isTraced(r));
  const [chosen, setChosen] = useState<MetricKey | null>(null);
  const [overlay, setOverlay] = useState(false);

  const defaultKey: MetricKey = hasTraced ? PRIMARY_METRIC.interface : PRIMARY_METRIC.outcome;
  const chosenDef = metric(chosen ?? defaultKey);
  const chosenHasRuns = chosenDef.source === 'interface' ? hasTraced : hasUntraced;
  const def = chosenHasRuns ? chosenDef : metric(defaultKey);

  const rows = useMemo(
    () => (machine ? computeGains(data.runs, data.baselines, scoped.filter, data.trials).filter((r) => r.metric === def.key) : []),
    [data.runs, data.baselines, data.trials, machine, scoped.filter, def.key],
  );
  const sourceRuns = runs.filter((r) => (def.source === 'interface' ? isTraced(r) : !isTraced(r)));
  const groups = useMemo(() => groupByIdentity(sourceRuns), [sourceRuns]);

  if (data.runs.length === 0) {
    return (
      <section className="view view-trends">
        <h2 className="view-title">Trends</h2>
        <div className="empty">
          No runs yet. Run the suite with <code>profiler/bin/bench --tag &lt;tag&gt;</code> and add it with <code>profiler/bin/history-add RUN_DIR</code>.
        </div>
      </section>
    );
  }

  return (
    <section className="view view-trends">
      <h2 className="view-title">Trends</h2>
      <div className="view-controls">
        <label className="filter">
          <span className="filter-label">Metric</span>
          <select name="metric" value={def.key} onChange={(e) => setChosen(e.target.value as MetricKey)}>
            <optgroup label="Outcome (untraced runs)" disabled={!hasUntraced}>
              {metricsFor('outcome').map((m) => (
                <option key={m.key} value={m.key}>
                  {m.label}
                </option>
              ))}
            </optgroup>
            <optgroup label="Interface (traced runs)" disabled={!hasTraced}>
              {metricsFor('interface').map((m) => (
                <option key={m.key} value={m.key}>
                  {m.label}
                </option>
              ))}
            </optgroup>
          </select>
        </label>
        <div className="chart-frame-toggle" role="group" aria-label="Layout">
          <button type="button" aria-pressed={!overlay} onClick={() => setOverlay(false)}>
            Small multiples
          </button>
          <button type="button" aria-pressed={overlay} onClick={() => setOverlay(true)}>
            Overlay (Δ %)
          </button>
        </div>
        <span className="note">
          {def.label}
          {def.unit ? ` (${def.unit})` : ''} · {directionText(def)} · {def.source} metric
        </span>
      </div>

      {!latest || !machine ? (
        <p className="note">No runs match the current filter.</p>
      ) : groups.length === 0 ? (
        <p className="note">
          No {def.source === 'interface' ? 'traced' : 'untraced'} runs in the slice for {def.label}; pick a {def.source === 'interface' ? 'outcome' : 'interface'} metric or
          widen the filter.
        </p>
      ) : (
        groups.map((group) => {
          const groupRows = rows.filter((r) => r.identityKey === group.key);
          let sets = orderSets(Array.from(new Set(groupRows.map((r) => r.set))));
          if (filter.set) sets = sets.filter((s) => s === filter.set);
          const markers = trialMarkers(data.trials, data.runs, group.identity);
          const virtualised = group.identity.virtualization !== 'none';
          const canonicalRows = groupRows.filter((r) => (CANONICAL_SETS as readonly string[]).includes(r.set) && (!filter.set || r.set === filter.set));
          const excluded = sets.filter((s) => !(CANONICAL_SETS as readonly string[]).includes(s));
          return (
            <section key={group.key} className="section trend-group" data-identity={group.key}>
              {groups.length > 1 || virtualised ? (
                <div className="section-head">
                  <h3>{identityLabel(group.identity)}</h3>
                  <EnvironmentBadge machineId={group.identity.machine_id} hostname={group.latest.hostname} virtualization={group.identity.virtualization} />
                  <span className="note">
                    {group.runs.length} run{group.runs.length === 1 ? '' : 's'}
                  </span>
                </div>
              ) : null}
              {virtualised ? <NoTimingRibbon virtualization={group.identity.virtualization} hostname={group.latest.hostname} runs={group.runs.length} /> : null}
              {sets.length === 0 ? (
                <p className="note">No Set values for {def.label} in this identity.</p>
              ) : overlay ? (
                <TrendChart
                  id={`trends.overlay.${group.key}.${def.key}`}
                  title={`All Sets · ${def.label}`}
                  subtitle="Δ % vs each Set's own baseline, one axis; positive = improvement"
                  series={overlaySeries(canonicalRows, group.runs)}
                  baseline={{ value: 0, runId: '', label: 'baseline' }}
                  noiseBand={null}
                  markers={markers}
                  unit="%"
                  direction="higher"
                  format={formatSignedPct}
                  height={320}
                  table={{ caption: `All Sets: ${def.label}, delta % vs baseline per run` }}
                  footer={excluded.length > 0 ? `Not in the overlay (non-canonical Set${excluded.length === 1 ? '' : 's'}): ${excluded.map(setLabel).join(', ')} — switch to small multiples.` : undefined}
                />
              ) : (
                <div className="grid">
                  {sets.map((set) => {
                    const row: GainRow | undefined = groupRows.find((r) => r.set === set);
                    const series = trendSeries(group.runs, set, def.key, setSlot(set));
                    const baseline: TrendBaseline | null = row?.baseline ? { value: row.baseline.value, runId: row.baseline.runId, label: 'baseline' } : null;
                    const noiseBand: TrendNoiseBand | null =
                      row?.baseline && row.spread ? { center: row.baseline.value, halfWidth: 2 * row.spread.spread, pairs: row.spread.pairs } : null;
                    return (
                      <TrendChart
                        key={set}
                        id={`trends.${group.key}.${set}.${def.key}`}
                        title={setLabel(set)}
                        subtitle={`${def.label} · ${series.points.length} run${series.points.length === 1 ? '' : 's'}${baseline ? '' : ' · no baseline'}`}
                        series={[series]}
                        baseline={baseline}
                        noiseBand={noiseBand}
                        markers={markers}
                        unit={def.unit}
                        direction={def.direction}
                        format={def.format}
                        table={{ caption: `${setLabel(set)}: ${def.label} per run` }}
                      />
                    );
                  })}
                </div>
              )}
            </section>
          );
        })
      )}
    </section>
  );
}
