/**
 * Overview — "where are we vs the baseline?" (DESIGN.md §4.1; layout from the Claude Design
 * "Spectrum overview" template, 2026-10-17)
 *
 * Headline identity = the most recent run of the scoped machine; interface tiles come from
 * the latest traced identity with the same structure / scenario / environment, outcome
 * tiles from the latest untraced one — the two are never mixed. Top to bottom:
 *  - view head (title, slice note, environment badge) and the Set chips, which narrow the
 *    shared filter to one Set;
 *  - the hero card (cumulative gain on the primary metric with its significance chip, the
 *    kept-trial count and the switches the kept trials carry; its top rule takes the status
 *    colour) beside "DSP load by Set" (latest untraced run, one tinted row per Set);
 *  - headline metrics: one tile row per Set — late blocks / min · PipeWire errors + xruns
 *    (guard) · Live CPU / core · slack p01 — with a table twin;
 *  - DSP load average across the untraced runs of the identity (trial markers) beside the
 *    dropouts of the latest trial (PipeWire errors, arm A vs arm B over its ABAB runs);
 *  - recent trials from the ledger.
 */
import { useMemo, type CSSProperties } from 'react';
import type { ViewProps } from './ViewProps';
import type { DeltaDirection } from '../components/Badge';
import Badge, { EnvironmentBadge, significanceBadge, verdictBadge, type BadgeStatus } from '../components/Badge';
import ChartFrame from '../components/ChartFrame';
import DataTable, { type Column } from '../components/DataTable';
import { DeltaBars, DeltaBarsTable } from '../components/DeltaBars';
import KpiTile, { HeroFigure, type KpiTileProps } from '../components/KpiTile';
import NoTimingRibbon from '../components/NoTimingRibbon';
import TrendChart from '../components/TrendChart';
import { seriesVar } from '../palette';
import type { FilterState, GainRow, MetricKey, Run, Significance, Trial, TrialJoin } from '../data/types';
import {
  applyFilter,
  computeGains,
  cumulativeGain,
  findMetric,
  formatDate,
  formatDelta,
  identityKeyOf,
  identityOf,
  isTraced,
  joinTrials,
  keptCount,
  metric,
  NULL_TEXT,
  orderSets,
  PRIMARY_METRIC,
  setLabel,
  setSlot,
  trendSeries,
  trialMachine,
  trialMarkers,
} from '../data';
import { ratioChip } from './Trials';

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

/** The hero card's top rule: status colour of the cumulative gain. */
export function heroStatus(significance: Significance, direction: DeltaDirection): BadgeStatus {
  if (significance === 'beyond') return direction === 'better' ? 'good' : direction === 'worse' ? 'critical' : 'dim';
  if (significance === 'within') return 'warning';
  return 'dim';
}

/** Smallest multiple of `step` at or above `value × headroom` (at least `step`). */
export function niceCeil(value: number, step = 5, headroom = 1.12): number {
  if (!Number.isFinite(value) || value <= 0) return step;
  return Math.max(step, Math.ceil((value * headroom) / step) * step);
}

/**
 * Domain [0, 4·step] whose quarter ticks are round numbers (step ∈ {1, 2, 2.5, 5}·10^k),
 * with at least 5 % headroom above `max` — for charts that tick at quarters (DeltaBars).
 */
export function quarterDomain(max: number): [number, number] {
  if (!Number.isFinite(max) || max <= 0) return [0, 4];
  const need = (max * 1.05) / 4;
  const k = Math.floor(Math.log10(need));
  for (const exp of [k, k + 1]) {
    for (const m of [1, 2, 2.5, 5]) {
      const step = m * 10 ** exp;
      if (step >= need) return [0, 4 * step];
    }
  }
  return [0, 4 * 10 ** (k + 1)];
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

/** One chip per Set: its hue on the dot; a click narrows the shared filter to that Set (again = all). */
function SetChips({ sets, filter, onFilterChange }: { sets: string[]; filter: FilterState; onFilterChange: ViewProps['onFilterChange'] }) {
  if (sets.length === 0) return null;
  return (
    <div className="set-chips" role="group" aria-label="Sets">
      {sets.map((set) => (
        <button
          key={set}
          type="button"
          className="chip set-chip"
          aria-pressed={filter.set === set}
          title={filter.set === set ? 'Show all Sets' : `Only ${setLabel(set)}`}
          onClick={() => onFilterChange({ ...filter, set: filter.set === set ? null : set })}
        >
          <span className="dot" style={{ background: seriesVar(setSlot(set)) }} aria-hidden="true" />
          {setLabel(set)}
        </button>
      ))}
    </div>
  );
}

/** "DSP load by Set": one tinted row per Set of the run, bars on one shared scale. */
function SetLoadBars({ run, sets }: { run: Run; sets: string[] }) {
  const def = metric('dsp_avg');
  const rows = sets.map((set) => ({ set, value: run.sets[set]?.dsp_avg ?? null }));
  const max = Math.max(0, ...rows.map((r) => r.value ?? 0));
  const domain = niceCeil(max);
  return (
    <div className="set-load" role="list">
      {rows.map(({ set, value }) => {
        const style = { '--row-hue': seriesVar(setSlot(set)) } as CSSProperties;
        const width = value === null ? 0 : Math.max(0, Math.min(100, (value / domain) * 100));
        return (
          <div key={set} className="set-load-row" role="listitem" style={style} data-set={set}>
            <span className="set-load-name">
              <span className="set-load-dot" aria-hidden="true" />
              {set}
            </span>
            <span className="set-load-track" aria-hidden="true">
              <span className="set-load-bar" style={{ width: `${width}%` }} />
            </span>
            <span className="set-load-value">{value === null ? NULL_TEXT : def.format(value)}</span>
          </div>
        );
      })}
      <p className="set-load-scale note">scale 0–{domain}% · one bar length per Set, same scale</p>
    </div>
  );
}

function primaryDirection(trial: Trial) {
  return findMetric(trial.metrics?.primary ?? '')?.direction ?? 'lower';
}

/** PipeWire errors summed over every Set of a trial's resolved ABAB runs, per arm. */
export function armDropouts(join: TrialJoin): { a: number; b: number; setRuns: number } | null {
  let a = 0;
  let b = 0;
  let setRuns = 0;
  for (const pair of join.runs.abab) {
    if (!pair.a || !pair.b) continue;
    const sets = Object.keys(pair.a.sets).filter((s) => pair.b !== null && s in pair.b.sets);
    for (const set of sets) {
      const ea = pair.a.sets[set]?.pipewire_errors;
      const eb = pair.b.sets[set]?.pipewire_errors;
      if (typeof ea !== 'number' || typeof eb !== 'number') continue;
      a += ea;
      b += eb;
      setRuns += 1;
    }
  }
  return setRuns > 0 ? { a, b, setRuns } : null;
}

const countFormat = (v: number | null): string => (v === null ? NULL_TEXT : String(Math.round(v)));

export default function OverviewView({ data, filter, onFilterChange }: ViewProps) {
  const scoped = useMemo(() => scopeSlice(data.runs, filter), [data.runs, filter]);
  const { runs, machine, latest } = scoped;
  const rows = useMemo(
    () => (machine ? computeGains(data.runs, data.baselines, scoped.filter, data.trials) : []),
    [data.runs, data.baselines, data.trials, machine, scoped.filter],
  );
  const joins = useMemo(() => {
    if (!machine) return [];
    // Same rule as the Trials view: trials whose runs are not in history stay visible.
    return joinTrials(data.trials, data.runs)
      .filter((j) => {
        const owner = trialMachine(j.trial, data.runs);
        return owner === null || owner === machine;
      })
      .sort((x, y) => Date.parse(y.trial.date) - Date.parse(x.trial.date) || (x.trial.trial < y.trial.trial ? 1 : -1));
  }, [data.trials, data.runs, machine]);

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
  const keptTrials = joins.filter((j) => j.trial.verdict === 'keep').reverse();

  let setNames = orderSets(unique([...ifaceRows, ...outRows].map((r) => r.set)));
  const allSetNames = setNames;
  if (filter.set) setNames = setNames.filter((s) => s === filter.set);

  const virtualised = runs.filter((r) => r.virtualization !== 'none');
  const ribbonRun = latestOf(virtualised);
  const scenarioText = latest.scenario ? `${latest.structure} / ${latest.scenario}` : latest.structure;
  const envText = latest.virtualization === 'none' ? 'bare metal' : latest.virtualization;

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

  // DSP load: Sets with a DSP meter in the latest untraced run, and the same Sets over time.
  const dspSets = untracedLatest ? setNames.filter((s) => untracedLatest.sets[s]?.dsp_avg !== null && untracedLatest.sets[s]?.dsp_avg !== undefined) : [];
  const dspSeries = dspSets.map((set) => ({ ...trendSeries(outRuns, set, 'dsp_avg', setSlot(set)), label: setLabel(set) }));
  const dspMarkers = untracedLatest ? trialMarkers(data.trials, data.runs, identityOf(untracedLatest)) : [];

  // Dropouts of the latest trial whose ABAB runs are in history.
  const dropoutJoin = joins.find((j) => armDropouts(j) !== null) ?? null;
  const dropouts = dropoutJoin ? armDropouts(dropoutJoin) : null;
  const dropoutLabel = dropoutJoin && dropouts
    ? `PipeWire errors over ${dropouts.setRuns} Set-runs per arm (${dropoutJoin.trial.trial}${dropoutJoin.trial.change.switch ? ` ${dropoutJoin.trial.change.switch}` : ''})`
    : '';

  const recent = joins.slice(0, 5);
  const trialColumns: Column<TrialJoin>[] = [
    { key: 'trial', header: 'Trial', render: (j) => <span className="cell-mono">{j.trial.trial}</span>, sortValue: (j) => j.trial.trial },
    { key: 'change', header: 'Change', render: (j) => <span className="cell-switches">{j.trial.change.switch ?? j.trial.change.kind ?? NULL_TEXT}</span>, sortValue: (j) => j.trial.change.switch },
    { key: 'verdict', header: 'Verdict', render: (j) => <Badge {...verdictBadge(j.trial.verdict)} />, sortValue: (j) => j.trial.verdict },
    { key: 'primary', header: 'Primary', render: (j) => findMetric(j.trial.metrics?.primary ?? '')?.label ?? j.trial.metrics?.primary ?? NULL_TEXT, sortValue: (j) => j.trial.metrics?.primary ?? null },
    {
      key: 'sets',
      header: 'Per-Set ratio to spread',
      title: '|Δ| / A/A spread per Set; ≥ 2× clears the acceptance gate',
      render: (j) => {
        const per = j.trial.metrics?.per_set ?? {};
        const names = Object.keys(per).filter((s) => per[s]?.delta !== null && per[s]?.delta !== undefined);
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
    },
  ];

  const heroTone = heroStatus(hero.significance, heroDirection);

  return (
    <section className="view view-overview">
      <div className="view-head overview-head">
        <div className="overview-head-text">
          <h2 className="view-title">Overview</h2>
          <p className="note">
            {scenarioText} · latest run {formatDate(latest.started_at)} · {runs.length} run{runs.length === 1 ? '' : 's'} in slice
            {heroBaseline ? ` · baseline ${heroBaseline.runId}` : ''}
          </p>
        </div>
        <EnvironmentBadge machineId={machine} hostname={latest.hostname} virtualization={latest.virtualization} />
      </div>
      {ribbonRun ? <NoTimingRibbon virtualization={ribbonRun.virtualization} hostname={ribbonRun.hostname} runs={virtualised.length} /> : null}

      <SetChips sets={allSetNames} filter={filter} onFilterChange={onFilterChange} />

      <div className="overview-top">
        <section className={`card overview-hero tone-${heroTone}`}>
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
            kept={kept}
          />
          <div className="overview-hero-chips">
            <Badge {...significanceBadge(hero.significance, heroDirection)} />
            {keptTrials.map((j) => (
              <Badge key={j.trial.trial} kind="switch" value={j.trial.change.switch ?? j.trial.trial} title={`${j.trial.trial} kept`} />
            ))}
          </div>
        </section>
        <section className="card overview-load">
          <h3 className="card-title">DSP load by Set</h3>
          <p className="card-subtitle">
            {untracedLatest ? `latest untraced run · ${envText} · ${formatDate(untracedLatest.started_at)}` : 'no untraced runs in this slice'}
          </p>
          {untracedLatest && dspSets.length > 0 ? <SetLoadBars run={untracedLatest} sets={dspSets} /> : <p className="note">No DSP meter values in this slice.</p>}
        </section>
      </div>

      <div className="section-head">
        <h3 className="section-title">Headline metrics</h3>
      </div>
      {setNames.length === 0 ? (
        <p className="note">No Set data in this slice.</p>
      ) : (
        <div className="overview-tiles">
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
        </div>
      )}

      <div className="overview-charts">
        <div className="overview-chart">
          {dspSeries.length > 0 ? (
            <TrendChart
              title="DSP load average (%)"
              subtitle={`${dspSets.map(setLabel).join(', ')} · untraced runs · ${envText}`}
              series={dspSeries}
              baseline={null}
              noiseBand={null}
              markers={dspMarkers}
              unit="%"
              direction="lower"
              format={metric('dsp_avg').format}
              table={{ caption: 'DSP load average per untraced run and Set' }}
              id="overview.dsp-trend"
            />
          ) : (
            <div className="card">
              <p className="note">No DSP load values across the untraced runs of this slice.</p>
            </div>
          )}
        </div>
        <div className="overview-chart">
          {dropoutJoin && dropouts ? (
            <ChartFrame
              title="Dropouts, latest trial"
              subtitle={`${dropoutJoin.trial.trial} · ${dropoutJoin.trial.verdict} · arm A vs arm B`}
              chart={
                <DeltaBars
                  before={dropouts.a}
                  after={dropouts.b}
                  label={dropoutLabel}
                  format={countFormat}
                  formatTick={(v) => String(Math.round(v))}
                  domain={quarterDomain(Math.max(dropouts.a, dropouts.b))}
                  names={{ before: 'arm A', after: 'arm B' }}
                />
              }
              table={<DeltaBarsTable before={dropouts.a} after={dropouts.b} label={dropoutLabel} format={countFormat} names={{ before: 'arm A', after: 'arm B' }} caption="PipeWire errors per arm" captionHidden />}
              id="overview.dropouts"
            />
          ) : (
            <div className="card">
              <p className="note">No trial with its ABAB runs in history yet.</p>
            </div>
          )}
        </div>
      </div>

      <section className="card overview-trials">
        <h3 className="card-title">Recent trials</h3>
        <p className="card-subtitle">A/B against the A/A noise floor · newest first</p>
        <DataTable
          caption="Recent trials"
          captionHidden
          columns={trialColumns}
          rows={recent}
          rowKey={(j) => j.trial.trial}
          dense
          emptyMessage="No trials for this machine yet."
        />
      </section>
    </section>
  );
}
