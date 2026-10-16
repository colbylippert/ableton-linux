/**
 * Scenarios — "what do the diagnostic scenarios show over time?" (DESIGN.md §4.5)
 *
 * A scenario selector (diagnostic runs in the slice; the choice is written to the shared
 * filter so every view agrees), then per Set of the scenario the late and near-late blocks
 * per minute over run time from the traced runs (`TrendChart`: own baseline and A/A band,
 * trial markers) — or, when the scenario has no traced runs, the outcome primary and the
 * voluntary switches from the untraced ones — and the `hotspots_non_audio_top` entries of
 * the latest traced run as a table (a table by spec, so no chart | table toggle) with the
 * change against the previous run.
 */
import { useMemo } from 'react';
import type { ViewProps } from './ViewProps';
import type { HotspotTop, MetricKey, Run, TraceMode } from '../data/types';
import {
  applyFilter,
  computeGains,
  formatDate,
  formatDurationNs,
  formatInt,
  hotspotKey,
  identityOf,
  isTraced,
  latestRun,
  metric,
  NULL_TEXT,
  orderSets,
  sameIdentity,
  setLabel,
  setSlot,
  signedDelta,
  sortRuns,
  trendSeries,
  trialMarkers,
} from '../data';
import DataTable, { type Column } from '../components/DataTable';
import NoTimingRibbon from '../components/NoTimingRibbon';
import TrendChart from '../components/TrendChart';

const TRACED_METRICS: readonly MetricKey[] = ['late_blocks_per_min', 'near_late_blocks_per_min'];
const UNTRACED_METRICS: readonly MetricKey[] = ['live_cpu_pct_per_core', 'voluntary_switches_per_s'];

export interface HotspotRow {
  rank: number;
  key: string;
  hotspot: HotspotTop;
  previous: number | null;
}

/** Latest run with hotspot entries for `set`, and the one before it (for the change column). */
export function hotspotRows(runs: readonly Run[], set: string): { latest: Run | null; previous: Run | null; rows: HotspotRow[] } {
  const withHotspots = sortRuns(runs).filter((r) => (r.sets[set]?.hotspots_non_audio_top?.length ?? 0) > 0);
  const latest = withHotspots[withHotspots.length - 1] ?? null;
  const previous = withHotspots[withHotspots.length - 2] ?? null;
  if (!latest) return { latest: null, previous: null, rows: [] };
  const prevByKey = new Map<string, number>();
  for (const h of previous?.sets[set]?.hotspots_non_audio_top ?? []) prevByKey.set(hotspotKey(h), h.total_ns);
  const rows = [...(latest.sets[set]?.hotspots_non_audio_top ?? [])]
    .sort((a, b) => b.total_ns - a.total_ns)
    .slice(0, 10)
    .map((h, i) => ({ rank: i + 1, key: hotspotKey(h), hotspot: h, previous: prevByKey.get(hotspotKey(h)) ?? null }));
  return { latest, previous, rows };
}

function changeText(current: number, previous: number | null): { glyph: string; status: 'good' | 'critical' | 'none'; text: string } {
  if (previous === null) return { glyph: '', status: 'none', text: 'new' };
  const { abs } = signedDelta(current, previous, 'lower');
  const magnitude = formatDurationNs(Math.abs(current - previous), 1);
  if (abs > 0) return { glyph: '▲', status: 'good', text: magnitude };
  if (abs < 0) return { glyph: '▼', status: 'critical', text: magnitude };
  return { glyph: '', status: 'none', text: magnitude };
}

export default function ScenariosView({ data, filter, onFilterChange }: ViewProps) {
  // Scenario options come from the slice without the scenario key, else the select would collapse to one entry.
  const diagnostic = useMemo(() => {
    const slice = applyFilter(data.runs, { ...filter, structure: 'diagnostic', scenario: null, set: null });
    const machine = filter.machine ?? latestRun(slice)?.machine_id ?? null;
    return sortRuns(machine ? slice.filter((r) => r.machine_id === machine) : slice);
  }, [data.runs, filter]);
  const scenarios = useMemo(() => Array.from(new Set(diagnostic.map((r) => r.scenario).filter((s): s is string => s !== null))).sort(), [diagnostic]);
  const selected = filter.scenario && scenarios.includes(filter.scenario) ? filter.scenario : (latestRun(diagnostic)?.scenario ?? scenarios[0] ?? null);

  const scenarioRuns = useMemo(() => (selected ? diagnostic.filter((r) => r.scenario === selected && (filter.set === null || Object.prototype.hasOwnProperty.call(r.sets, filter.set))) : []), [diagnostic, selected, filter.set]);
  const tracedAll = scenarioRuns.filter(isTraced);
  const mode: TraceMode | null = filter.traceMode ?? (tracedAll.some((r) => r.trace_mode === 'interface') ? 'interface' : (tracedAll[0]?.trace_mode ?? null));
  const tracedRuns = mode && mode !== 'off' ? tracedAll.filter((r) => r.trace_mode === mode) : [];
  const untracedRuns = scenarioRuns.filter((r) => !isTraced(r));
  const seriesRuns = tracedRuns.length > 0 ? tracedRuns : untracedRuns;
  const metricKeys = tracedRuns.length > 0 ? TRACED_METRICS : UNTRACED_METRICS;
  const identity = seriesRuns[0] ? identityOf(seriesRuns[0]) : null;
  const narrowed = useMemo(
    () => ({ ...filter, machine: identity?.machine_id ?? filter.machine, structure: 'diagnostic' as const, scenario: selected, traceMode: identity?.trace_mode ?? filter.traceMode }),
    [filter, identity, selected],
  );
  const gains = useMemo(() => (identity ? computeGains(data.runs, data.baselines, narrowed, data.trials) : []), [data.runs, data.baselines, data.trials, narrowed, identity]);
  const markers = useMemo(() => (identity ? trialMarkers(data.trials, data.runs, identity) : []), [data.trials, data.runs, identity]);
  const sets = orderSets(seriesRuns.flatMap((r) => Object.keys(r.sets))).filter((s) => filter.set === null || s === filter.set);

  const virtualised = scenarioRuns.filter((r) => r.virtualization !== 'none');
  const latestVirtualised = latestRun(virtualised);

  const hotspotColumns: Column<HotspotRow>[] = [
    { key: 'rank', header: '#', numeric: true, render: (r) => String(r.rank), sortValue: (r) => r.rank },
    { key: 'role', header: 'Role', render: (r) => r.hotspot.role || NULL_TEXT, sortValue: (r) => r.hotspot.role },
    { key: 'kind', header: 'Kind', render: (r) => r.hotspot.kind || NULL_TEXT, sortValue: (r) => r.hotspot.kind },
    { key: 'caller', header: 'Caller', render: (r) => <span className="cell-mono">{r.hotspot.caller || NULL_TEXT}</span>, sortValue: (r) => r.hotspot.caller },
    { key: 'n', header: 'n', numeric: true, render: (r) => formatInt(r.hotspot.n), sortValue: (r) => r.hotspot.n },
    { key: 'total', header: 'Total', numeric: true, render: (r) => formatDurationNs(r.hotspot.total_ns, 1), sortValue: (r) => r.hotspot.total_ns },
    { key: 'previous', header: 'Previous run', numeric: true, render: (r) => formatDurationNs(r.previous, 1), sortValue: (r) => r.previous },
    {
      key: 'change',
      header: 'Change',
      numeric: true,
      title: 'vs the previous run with hotspots; lower is better, positive = improvement',
      render: (r) => {
        const c = changeText(r.hotspot.total_ns, r.previous);
        return (
          <span style={{ whiteSpace: 'nowrap' }}>
            {c.glyph ? (
              <span className={`glyph-${c.status}`} aria-hidden="true">
                {c.glyph}{' '}
              </span>
            ) : null}
            {c.text}
          </span>
        );
      },
      sortValue: (r) => (r.previous === null ? null : r.previous - r.hotspot.total_ns),
    },
  ];

  return (
    <section className="view view-scenarios">
      <h2 className="view-title">Scenarios</h2>
      <p className="view-lead">Diagnostic scenario runs: late and near-late blocks per minute over run time (traced runs), and the non-audio hotspots of the latest traced run.</p>
      {scenarios.length === 0 ? (
        <div className="empty">
          No diagnostic runs in this slice. Scenario runs come from <code>profiler/bin/bench --tag &lt;tag&gt; --scenario &lt;name&gt; [--trace interface]</code>.
        </div>
      ) : (
        <>
          <div className="view-controls">
            <label className="filter">
              <span className="filter-label">Scenario</span>
              <select value={selected ?? ''} onChange={(e) => onFilterChange({ ...filter, scenario: e.target.value || null })} aria-label="Scenario">
                {scenarios.map((s) => (
                  <option key={s} value={s}>
                    {s}
                  </option>
                ))}
              </select>
            </label>
            <span className="muted">
              {scenarioRuns.length} run{scenarioRuns.length === 1 ? '' : 's'} · {tracedRuns.length} traced{mode && mode !== 'off' ? ` (${mode})` : ''} · {untracedRuns.length} untraced
            </span>
          </div>
          {latestVirtualised ? <NoTimingRibbon virtualization={latestVirtualised.virtualization} hostname={latestVirtualised.hostname} runs={virtualised.length} /> : null}
          {tracedRuns.length === 0 && untracedRuns.length > 0 ? (
            <p className="note">No traced runs for this scenario in the slice: late / near-late blocks need <code>--trace interface</code>. Showing outcome metrics from the untraced runs instead.</p>
          ) : null}
          {sets.map((set) => {
            const hotspots = hotspotRows(tracedAll.length > 0 ? tracedAll : scenarioRuns, set);
            return (
              <div className="section" key={set}>
                <div className="section-head">
                  <h3>
                    <span className="set-dot" style={{ background: `var(--series-${setSlot(set)})`, display: 'inline-block', marginRight: 8 }} aria-hidden="true" />
                    {setLabel(set)}
                  </h3>
                  <span className="muted">{selected}</span>
                </div>
                <div className="grid">
                  {identity
                    ? metricKeys.map((key) => {
                        const def = metric(key);
                        const row = gains.find((g) => g.set === set && g.metric === key && sameIdentity(g.identity, identity));
                        const series = trendSeries(seriesRuns, set, key, setSlot(set));
                        return (
                          <TrendChart
                            key={key}
                            id={`scenario.${selected}.${set}.${key}`}
                            title={`${def.label}${def.unit ? ` (${def.unit})` : ''}`}
                            subtitle={`${selected} · ${setLabel(set)} · ${identity.trace_mode === 'off' ? 'untraced' : identity.trace_mode} runs`}
                            series={[series]}
                            baseline={row?.baseline ? { value: row.baseline.value, runId: row.baseline.runId, label: 'baseline' } : null}
                            noiseBand={row?.baseline && row.spread ? { center: row.baseline.value, halfWidth: 2 * row.spread.spread, pairs: row.spread.pairs } : null}
                            markers={markers}
                            unit={def.unit}
                            direction={def.direction}
                            format={def.format}
                            table={{ caption: `${selected} · ${setLabel(set)} · ${def.label} per run` }}
                          />
                        );
                      })
                    : null}
                </div>
                <section className="card section scenarios-hotspots" aria-label="Non-audio hotspots">
                  <h3 className="card-title">Non-audio hotspots</h3>
                  <p className="card-subtitle">
                    {hotspots.latest
                      ? `latest traced run ${formatDate(hotspots.latest.started_at)} (${hotspots.latest.run_id})${hotspots.previous ? ` vs ${formatDate(hotspots.previous.started_at)}` : ''}`
                      : 'hotspots_non_audio_top of the latest traced run'}
                  </p>
                  {hotspots.rows.length === 0 ? (
                    <p className="empty">No non-audio hotspots recorded for this Set (traced runs only).</p>
                  ) : (
                    <>
                      <DataTable caption={`${selected} · ${setLabel(set)} · non-audio hotspots`} captionHidden columns={hotspotColumns} rows={hotspots.rows} rowKey={(r) => r.key} dense />
                      <p className="note">Top 10 by total time; change vs the previous traced run (lower is better, positive = improvement).</p>
                    </>
                  )}
                </section>
              </div>
            );
          })}
          {sets.length === 0 ? <p className="empty">No Sets with data for this scenario in the slice.</p> : null}
        </>
      )}
    </section>
  );
}
