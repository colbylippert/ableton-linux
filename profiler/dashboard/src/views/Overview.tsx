/**
 * Overview — "where are we vs the baseline?" (DESIGN.md §4.1)
 *
 * Headline identity = the most recent run of the scoped machine; interface tiles come from
 * the latest traced identity with the same structure / scenario / environment, outcome
 * tiles from the latest untraced one — the two are never mixed. The hero is the cumulative
 * gain on the primary metric (interface primary when traced runs exist, else the outcome
 * primary), with its significance chip and the kept-trial count. One tile row per Set:
 * late blocks / min · PipeWire errors + xruns (guard) · Live CPU / core · slack p01, each
 * with baseline → latest, best since baseline, delta and the noise chip, plus a table twin.
 */
import { useMemo } from 'react';
import type { ViewProps } from './ViewProps';
import type { DeltaDirection } from '../components/Badge';
import Badge, { EnvironmentBadge, significanceBadge } from '../components/Badge';
import ChartFrame from '../components/ChartFrame';
import DataTable, { type Column } from '../components/DataTable';
import KpiTile, { HeroFigure, type KpiTileProps } from '../components/KpiTile';
import NoTimingRibbon from '../components/NoTimingRibbon';
import { seriesVar } from '../palette';
import type { FilterState, GainRow, MetricKey, Run } from '../data/types';
import {
  applyFilter,
  computeGains,
  cumulativeGain,
  formatDate,
  formatDelta,
  identityKeyOf,
  identityOf,
  isTraced,
  keptCount,
  metric,
  orderSets,
  PRIMARY_METRIC,
  setLabel,
  setSlot,
  trendSeries,
} from '../data';

export interface ScopedSlice {
  /** Filtered runs narrowed to one machine. */
  runs: Run[];
  machine: string | null;
  latest: Run | null;
  /** The filter with `machine` resolved, for `computeGains`. */
  filter: FilterState;
}

/** Most recent run by `started_at` (tie → `run_id`). */
export function latestOf(runs: Run[]): Run | null {
  let best: Run | null = null;
  for (const run of runs) {
    if (!best || run.started_at > best.started_at || (run.started_at === best.started_at && run.run_id > best.run_id)) best = run;
  }
  return best;
}

/**
 * Cross-machine charts are meaningless, so a slice is always one machine: the filter's,
 * else the machine of the most recent run in the filtered slice.
 */
export function scopeSlice(allRuns: Run[], filter: FilterState): ScopedSlice {
  const slice = applyFilter(allRuns, filter);
  const machine = filter.machine ?? latestOf(slice)?.machine_id ?? null;
  const runs = machine ? slice.filter((r) => r.machine_id === machine) : slice;
  return { runs, machine, latest: latestOf(runs), filter: { ...filter, machine } };
}

function unique<T>(values: T[]): T[] {
  return Array.from(new Set(values));
}

function sameBase(a: Run, b: Run): boolean {
  return a.virtualization === b.virtualization && a.structure === b.structure && a.scenario === b.scenario;
}

function deltaDirection(row: GainRow): DeltaDirection {
  if (row.direction === 'neutral') return 'neutral';
  if (row.deltaAbs === null || row.deltaAbs === 0) return 'flat';
  return row.deltaAbs > 0 ? 'better' : 'worse';
}

function pctDirection(pct: number | null): DeltaDirection {
  if (pct === null || pct === 0) return 'flat';
  return pct > 0 ? 'better' : 'worse';
}

function formatPctSigned(pct: number | null): string {
  if (pct === null) return '—';
  const glyph = pct > 0 ? '▲ ' : pct < 0 ? '▼ ' : '';
  return `${glyph}${(Math.abs(pct) * 100).toFixed(1)}%`;
}

/** Builds the tile for one (set, metric) row; a missing row yields an informative empty tile. */
function tileFor(row: GainRow | undefined, key: MetricKey, set: string, identityRuns: Run[], missingNote: string): KpiTileProps {
  const def = metric(key);
  const slot = setSlot(set);
  if (!row) return { label: def.label, value: '—', source: def.source, slot, note: missingNote };
  const trend = trendSeries(identityRuns, set, key, slot)
    .points.map((p) => p.value)
    .filter((v): v is number => v !== null)
    .slice(-12);
  const tile: KpiTileProps = {
    label: def.label,
    value: def.format(row.latest ? row.latest.value : null),
    source: def.source,
    slot,
  };
  if (row.baseline) tile.baseline = { value: def.format(row.baseline.value), label: `baseline ${formatDate(row.baseline.startedAt)}` };
  else tile.note = 'no baseline';
  if (row.best) tile.best = { value: def.format(row.best.value), runId: row.best.runId };
  if (row.baseline && row.latest) {
    tile.delta = { pct: row.deltaPct, abs: row.deltaAbs, direction: deltaDirection(row), significance: row.significance, text: formatDelta(row) };
  }
  if (trend.length >= 2) tile.trend = trend;
  return tile;
}

function guardTile(errors: GainRow | undefined, xruns: GainRow | undefined, set: string): KpiTileProps {
  const errorValue = errors?.latest ? errors.latest.value : null;
  const xrunValue = xruns?.latest ? xruns.latest.value : null;
  const reject = (errorValue ?? 0) > 0 || (xrunValue ?? 0) > 0;
  const tile: KpiTileProps = {
    label: 'PipeWire errors / xruns',
    value: `${metric('pipewire_errors').format(errorValue)} / ${metric('xruns').format(xrunValue)}`,
    source: 'outcome',
    slot: setSlot(set),
    guard: { reject, label: reject ? 'reject' : 'clean' },
  };
  if (!errors && !xruns) tile.note = 'no untraced runs in slice';
  return tile;
}

const TABLE_METRICS: MetricKey[] = ['late_blocks_per_min', 'pipewire_errors', 'xruns', 'live_cpu_pct_per_core', 'slack_p01_ns'];

export default function OverviewView({ data, filter, onFilterChange }: ViewProps) {
  const scoped = useMemo(() => scopeSlice(data.runs, filter), [data.runs, filter]);
  const { runs, machine, latest } = scoped;
  const rows = useMemo(
    () => (machine ? computeGains(data.runs, data.baselines, scoped.filter, data.trials) : []),
    [data.runs, data.baselines, data.trials, machine, scoped.filter],
  );

  if (data.runs.length === 0) {
    return (
      <section className="view view-overview">
        <h2 className="view-title">Overview</h2>
        <div className="empty">
          No runs yet. Run the suite with <code>profiler/bin/bench --tag &lt;tag&gt;</code> and add it with <code>profiler/bin/history-add RUN_DIR</code>;
          this page updates live.
        </div>
      </section>
    );
  }
  if (!latest || !machine) {
    return (
      <section className="view view-overview">
        <h2 className="view-title">Overview</h2>
        <p className="note">No runs match the current filter.</p>
      </section>
    );
  }

  const tracedLatest = latestOf(runs.filter((r) => isTraced(r) && sameBase(r, latest)));
  const untracedLatest = latestOf(runs.filter((r) => !isTraced(r) && sameBase(r, latest)));
  const ifaceKey = tracedLatest ? identityKeyOf(identityOf(tracedLatest)) : null;
  const outKey = untracedLatest ? identityKeyOf(identityOf(untracedLatest)) : null;
  const ifaceRows = ifaceKey ? rows.filter((r) => r.identityKey === ifaceKey) : [];
  const outRows = outKey ? rows.filter((r) => r.identityKey === outKey) : [];
  const ifaceRuns = ifaceKey ? runs.filter((r) => identityKeyOf(identityOf(r)) === ifaceKey) : [];
  const outRuns = outKey ? runs.filter((r) => identityKeyOf(identityOf(r)) === outKey) : [];

  const heroSource = tracedLatest ? 'interface' : 'outcome';
  const heroKey = PRIMARY_METRIC[heroSource];
  const heroDef = metric(heroKey);
  const heroRows = (heroSource === 'interface' ? ifaceRows : outRows).filter((r) => r.metric === heroKey);
  const hero = cumulativeGain(heroRows, heroKey);
  const heroBaseline = heroRows.find((r) => r.baseline)?.baseline ?? null;
  const heroDirection = pctDirection(hero.medianPct);
  const kept = keptCount(data.trials, machine, data.runs);

  let setNames = orderSets(unique([...ifaceRows, ...outRows].map((r) => r.set)));
  if (filter.set) setNames = setNames.filter((s) => s === filter.set);

  const virtualised = runs.filter((r) => r.virtualization !== 'none');
  const ribbonRun = latestOf(virtualised);
  const scenarioText = latest.scenario ? `${latest.structure} / ${latest.scenario}` : latest.structure;

  const rowOf = (source: GainRow[], set: string, key: MetricKey) => source.find((r) => r.set === set && r.metric === key);
  const tableRows = setNames.flatMap((set) =>
    TABLE_METRICS.map((key) => rowOf(metric(key).source === 'interface' ? ifaceRows : outRows, set, key)).filter((r): r is GainRow => r !== undefined),
  );

  const tableColumns: Column<GainRow>[] = [
    { key: 'set', header: 'Set', render: (r) => setLabel(r.set) },
    { key: 'metric', header: 'Metric', render: (r) => `${metric(r.metric).label} (${r.source})`, sortValue: (r) => metric(r.metric).label },
    { key: 'baseline', header: 'Baseline', numeric: true, render: (r) => metric(r.metric).format(r.baseline ? r.baseline.value : null), sortValue: (r) => r.baseline?.value ?? null },
    { key: 'latest', header: 'Latest', numeric: true, render: (r) => metric(r.metric).format(r.latest ? r.latest.value : null), sortValue: (r) => r.latest?.value ?? null },
    { key: 'best', header: 'Best', numeric: true, render: (r) => metric(r.metric).format(r.best ? r.best.value : null), sortValue: (r) => r.best?.value ?? null },
    { key: 'delta', header: 'Δ', numeric: true, title: 'Positive = improvement', render: (r) => (r.deltaAbs === null ? '—' : formatDelta(r)), sortValue: (r) => r.deltaPct ?? r.deltaAbs },
    { key: 'significance', header: 'Significance', render: (r) => <Badge {...significanceBadge(r.significance, deltaDirection(r))} />, sortValue: (r) => r.significance },
    { key: 'runs', header: 'Runs', numeric: true },
  ];

  const tiles = (
    <div className="overview-sets">
      {setNames.map((set) => {
        const slot = setSlot(set);
        return (
          <section key={set} className="section overview-set" data-set={set}>
            <div className="section-head">
              <button
                type="button"
                className="set-heading"
                title={filter.set === set ? 'Show all Sets' : `Only ${setLabel(set)}`}
                onClick={() => onFilterChange({ ...filter, set: filter.set === set ? null : set })}
              >
                <span className="set-dot" style={{ background: seriesVar(slot) }} aria-hidden="true" />
                {setLabel(set)}
              </button>
              {filter.set === set ? <span className="note">(filtered to this Set — click to show all)</span> : null}
            </div>
            <div className="grid-kpi">
              <KpiTile {...tileFor(rowOf(ifaceRows, set, 'late_blocks_per_min'), 'late_blocks_per_min', set, ifaceRuns, 'no traced runs in slice')} />
              <KpiTile {...guardTile(rowOf(outRows, set, 'pipewire_errors'), rowOf(outRows, set, 'xruns'), set)} />
              <KpiTile {...tileFor(rowOf(outRows, set, 'live_cpu_pct_per_core'), 'live_cpu_pct_per_core', set, outRuns, 'no untraced runs in slice')} />
              <KpiTile {...tileFor(rowOf(ifaceRows, set, 'slack_p01_ns'), 'slack_p01_ns', set, ifaceRuns, 'no traced runs in slice')} />
            </div>
          </section>
        );
      })}
    </div>
  );

  return (
    <section className="view view-overview">
      <h2 className="view-title">Overview</h2>
      <div className="view-head">
        <EnvironmentBadge machineId={machine} hostname={latest.hostname} virtualization={latest.virtualization} />
        <span className="note">
          {scenarioText} · latest run {formatDate(latest.started_at)} · {runs.length} run{runs.length === 1 ? '' : 's'} in slice
        </span>
      </div>
      {ribbonRun ? <NoTimingRibbon virtualization={ribbonRun.virtualization} hostname={ribbonRun.hostname} runs={virtualised.length} /> : null}

      <HeroFigure
        label="Cumulative gain"
        value={formatPctSigned(hero.medianPct)}
        direction={heroDirection}
        significant={hero.significance === 'beyond'}
        sub={
          hero.medianPct === null
            ? `${heroDef.label}: no baseline or no latest value in the slice`
            : `${heroDef.label}, median of ${hero.sets} Set${hero.sets === 1 ? '' : 's'} vs baseline${heroBaseline ? ` ${formatDate(heroBaseline.startedAt)}` : ''}`
        }
        chip={<Badge {...significanceBadge(hero.significance, heroDirection)} />}
        kept={kept}
      />

      {setNames.length === 0 ? (
        <p className="note">No Set data in this slice.</p>
      ) : (
        <ChartFrame
          title="Sets vs baseline"
          subtitle="Interface tiles from traced runs, outcome tiles from untraced runs; delta signed so that positive = improvement."
          chart={tiles}
          table={
            <DataTable
              caption="Baseline, latest and best per Set and metric"
              captionHidden
              columns={tableColumns}
              rows={tableRows}
              rowKey={(r) => `${r.identityKey}|${r.set}|${r.metric}`}
              dense
              emptyMessage="No rows for this slice."
            />
          }
          id="overview.tiles"
          className="chart-frame-plain"
        />
      )}
    </section>
  );
}
