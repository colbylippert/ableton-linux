/**
 * CallSites — "which crossings lose the slack, and which trial went after them?"
 * (DESIGN.md §4.4; form per the D3 brief: bar per traced run, small multiples per Set).
 *
 * Only traced runs carry call sites, and a comparison never crosses an identity, so the
 * view is one card per (identity, Set) within one machine (the filter's, else the machine
 * of the latest traced run). Colour is categorical per call-site key and fixed across all
 * cards of the view (`assignCallSiteSlots`: top 8 keys by maximum share in the slice,
 * computed before the Set filter so narrowing never repaints a survivor); clicking a site
 * in any legend isolates it everywhere. Trials that targeted a site (ledger evidence) are
 * chips in the legend and the table twin.
 */
import { useMemo, useState } from 'react';
import type { ViewProps } from './ViewProps';
import type { Run } from '../data/types';
import { applyFilter, baselineKeyOf, identitiesOf, identityKeyOf, isTraced, latestRun, orderSets, sameIdentity, setLabel, sortRuns, targetedBy } from '../data';
import ChartFrame from '../components/ChartFrame';
import NoTimingRibbon from '../components/NoTimingRibbon';
import CallSiteTrend, { CallSiteTrendTable, assignCallSiteSlots, type TargetedBy } from '../components/CallSiteTrend';

function setsWithCallSites(runs: readonly Run[]): string[] {
  const names: string[] = [];
  for (const run of runs) {
    for (const [name, set] of Object.entries(run.sets)) {
      if (Array.isArray(set.call_sites_top) && set.call_sites_top.length > 0) names.push(name);
    }
  }
  return orderSets(names);
}

export default function CallSitesView({ data, filter, onFilterChange }: ViewProps) {
  // The colour map is built from the slice *without* the Set filter: narrowing to one Set
  // must not repaint the surviving call sites (colour follows the entity, not its rank).
  const tracedAllSets = useMemo(() => {
    const slice = applyFilter(data.runs, { ...filter, set: null }).filter(isTraced);
    const machine = filter.machine ?? latestRun(slice)?.machine_id ?? null;
    return sortRuns(machine ? slice.filter((r) => r.machine_id === machine) : slice);
  }, [data.runs, filter]);
  const traced = useMemo(
    () => (filter.set === null ? tracedAllSets : tracedAllSets.filter((r) => Object.prototype.hasOwnProperty.call(r.sets, filter.set as string))),
    [tracedAllSets, filter.set],
  );

  const slots = useMemo(() => assignCallSiteSlots(tracedAllSets), [tracedAllSets]);
  const identities = useMemo(() => identitiesOf(traced), [traced]);
  const [emphasis, setEmphasis] = useState<string | null>(null);

  const virtualised = traced.filter((r) => r.virtualization !== 'none');
  const latestVirtualised = latestRun(virtualised);
  const targetedFor = (set: string): TargetedBy => (key) => targetedBy(data.trials, set, key);

  return (
    <section className="view view-callsites">
      <h2 className="view-title">Call sites</h2>
      <p className="view-lead">
        Share of lost slack per call site, one bar per traced run. Colours are fixed per call site across every card below (top 8 by maximum share in this slice); gray folds the rest. Click a site to isolate it.
      </p>
      {latestVirtualised ? <NoTimingRibbon virtualization={latestVirtualised.virtualization} hostname={latestVirtualised.hostname} runs={virtualised.length} /> : null}
      {traced.length === 0 ? (
        <div className="empty">
          No traced runs in this slice. Call sites come from <code>profiler/bin/bench --tag &lt;tag&gt; --trace interface</code>; untraced runs carry no interface metrics.
        </div>
      ) : (
        identities.map((identity) => {
          const runs = traced.filter((r) => sameIdentity(r, identity));
          const sets = setsWithCallSites(runs).filter((s) => filter.set === null || s === filter.set);
          const where = `${baselineKeyOf(identity)} · ${identity.trace_mode}`;
          return (
            <div className="section" key={identityKeyOf(identity)}>
              <div className="section-head">
                <h3>{where}</h3>
                <span className="muted">
                  {runs.length} traced run{runs.length === 1 ? '' : 's'} · {identity.machine_id}
                </span>
              </div>
              {sets.length === 0 ? (
                <p className="empty">The traced runs of this identity list no call sites.</p>
              ) : (
                <div className="cs-sets">
                  {sets.map((set) => (
                    <ChartFrame
                      key={set}
                      id={`callsites.${identityKeyOf(identity)}.${set}`}
                      title={setLabel(set)}
                      subtitle={`share of lost slack by call site · ${runs.filter((r) => Array.isArray(r.sets[set]?.call_sites_top)).length} runs`}
                      chart={
                        <CallSiteTrend runs={runs} set={set} slots={slots} targeted={targetedFor(set)} emphasis={emphasis} onEmphasis={setEmphasis} />
                      }
                      table={<CallSiteTrendTable runs={runs} set={set} slots={slots} targeted={targetedFor(set)} caption={`${setLabel(set)}: call-site share of lost slack per traced run`} captionHidden />}
                      footer={
                        <span className="muted">
                          Bar length = share attributed to the listed call sites; the gap to 100 % is unattributed or unlisted. {' '}
                          <button type="button" className="btn" style={{ minHeight: 24, padding: '1px 8px' }} onClick={() => onFilterChange({ ...filter, set: filter.set === set ? null : set })}>
                            {filter.set === set ? 'All Sets' : `Only ${setLabel(set)}`}
                          </button>
                        </span>
                      }
                    />
                  ))}
                </div>
              )}
            </div>
          );
        })
      )}
    </section>
  );
}
