/**
 * Ledger ↔ history joins (DESIGN.md §3 "Trial markers", §6 `trials.ts`).
 *
 * Kept / reverted come from the ledger (`verdict === 'keep' | 'revert'`); the other
 * verdicts (`inconclusive`, `tooling`, `mechanism-confirmed`) are shown dimmed.
 */
import type { Identity, Run, Trial, TrialJoin, Verdict } from './types';
import { compareRuns, sameIdentity, startedMs } from './gains';

/** Vertical marker on a trend chart: x = when the trial started on this identity. */
export interface TrendMarker {
  t: number;
  trial: string;
  verdict: Verdict;
  /** `✓ T0007` / `✗ T0008`; dim verdicts carry the bare id (shown on hover only). */
  label: string;
}

export type VerdictStatus = 'good' | 'critical' | 'warning' | 'dim';

/** Status colour per verdict (DESIGN.md §5 Badge mapping); always paired with the glyph. */
export const VERDICT_STATUS: Readonly<Record<Verdict, VerdictStatus>> = {
  keep: 'good',
  revert: 'critical',
  inconclusive: 'warning',
  tooling: 'dim',
  'mechanism-confirmed': 'dim',
};

export const VERDICT_GLYPH: Readonly<Record<Verdict, string>> = {
  keep: '✓',
  revert: '✗',
  inconclusive: '≈',
  tooling: '',
  'mechanism-confirmed': '',
};

export const VERDICTS: readonly Verdict[] = ['keep', 'revert', 'inconclusive', 'tooling', 'mechanism-confirmed'];

export function isVerdict(v: unknown): v is Verdict {
  return typeof v === 'string' && (VERDICTS as readonly string[]).includes(v);
}

export function markerLabel(trial: Pick<Trial, 'trial' | 'verdict'>): string {
  const glyph = VERDICT_GLYPH[trial.verdict] ?? '';
  return glyph ? `${glyph} ${trial.trial}` : trial.trial;
}

function uniqueIds(...groups: unknown[][]): string[] {
  const ids: string[] = [];
  const seen = new Set<string>();
  for (const group of groups) {
    for (const id of group) {
      if (typeof id === 'string' && id !== '' && !seen.has(id)) {
        seen.add(id);
        ids.push(id);
      }
    }
  }
  return ids;
}

/** The trial's own runs (A/A, ABAB, traced confirmation), unique, in that order. */
export function trialRunIds(trial: Trial): string[] {
  const runs = trial.runs;
  return uniqueIds(
    (runs?.aa ?? []).flatMap((pair) => [pair[0], pair[1]]),
    (runs?.abab ?? []).flatMap((pair) => [pair.a, pair.b]),
    runs?.traced ? [runs.traced.a, runs.traced.b] : [],
  );
}

/** Runs the trial's evidence cites (the traced run whose call sites motivated it). */
export function evidenceRunIds(trial: Trial): string[] {
  return uniqueIds((trial.evidence ?? []).map((e) => e.run));
}

/** Every run_id a ledger line cites (own runs first, then evidence), unique. */
export function citedRunIds(trial: Trial): string[] {
  return uniqueIds(trialRunIds(trial), evidenceRunIds(trial));
}

function runIndex(runs: readonly Run[]): Map<string, Run> {
  return new Map(runs.map((r) => [r.run_id, r] as const));
}

/** Resolves every run reference of every ledger line; unresolved ids are listed in `missing`. */
export function joinTrials(trials: readonly Trial[], runs: readonly Run[]): TrialJoin[] {
  const byId = runIndex(runs);
  return trials.map((trial) => {
    const missing: string[] = [];
    const seen = new Set<string>();
    const get = (id: string | null | undefined): Run | null => {
      if (typeof id !== 'string' || id === '') return null;
      const run = byId.get(id) ?? null;
      if (run === null && !seen.has(id)) {
        seen.add(id);
        missing.push(id);
      }
      return run;
    };
    const aa = (trial.runs?.aa ?? []).map(([a, b]) => [get(a), get(b)] as [Run | null, Run | null]);
    const abab = (trial.runs?.abab ?? []).map((p) => ({ a: get(p.a), b: get(p.b) }));
    const traced = trial.runs?.traced ? { a: get(trial.runs.traced.a), b: get(trial.runs.traced.b) } : null;
    for (const e of trial.evidence ?? []) get(e.run);
    return { trial, runs: { aa, abab, traced }, missing };
  });
}

/** `'bare-metal'` ↔ `virtualization === 'none'`; `'vm:<x>'` ↔ `virtualization === x`; anything else is compatible. */
function hostCompatible(host: string, virtualization: string): boolean {
  if (host === 'bare-metal') return virtualization === 'none';
  if (host.startsWith('vm:')) return virtualization !== 'none' && (host.slice(3) === virtualization || host.slice(3) === '');
  return true;
}

/**
 * One marker per trial that belongs on this identity's chart. The trial's own runs
 * (A/A, ABAB, traced) place it; its evidence runs are used only when none of the own
 * runs is in history (a tooling trial that cites a baseline, say):
 *  - x = `started_at` of the trial's first run on this identity;
 *  - else the first run on the same machine (e.g. the untraced ABAB runs of a trial, so
 *    the marker still shows on the traced chart and vice versa);
 *  - else, when none of the cited runs is in history, `trial.date` — provided the ledger
 *    `host` is compatible with the identity's environment;
 *  - trials whose cited runs all resolve to other machines are left out.
 * Sorted by x.
 */
export function trialMarkers(trials: readonly Trial[], runs: readonly Run[], identity: Identity): TrendMarker[] {
  const byId = runIndex(runs);
  const resolve = (ids: string[]): Run[] => {
    const out: Run[] = [];
    for (const id of ids) {
      const run = byId.get(id);
      if (run) out.push(run);
    }
    return out;
  };
  const markers: TrendMarker[] = [];
  for (const trial of trials) {
    const own = resolve(trialRunIds(trial));
    const resolved = own.length > 0 ? own : resolve(evidenceRunIds(trial));
    let t: number | null = null;
    const onIdentity = resolved.filter((r) => sameIdentity(r, identity)).sort(compareRuns);
    const onMachine = resolved.filter((r) => r.machine_id === identity.machine_id).sort(compareRuns);
    if (onIdentity.length > 0) t = startedMs(onIdentity[0]!);
    else if (onMachine.length > 0) t = startedMs(onMachine[0]!);
    else if (resolved.length === 0 && hostCompatible(String(trial.host ?? ''), identity.virtualization)) t = Date.parse(trial.date);
    if (t === null || Number.isNaN(t)) continue;
    markers.push({ t, trial: trial.trial, verdict: trial.verdict, label: markerLabel(trial) });
  }
  return markers.sort((a, b) => a.t - b.t || (a.trial < b.trial ? -1 : a.trial > b.trial ? 1 : 0));
}

/** Trials whose evidence names this Set + call-site key, in ledger order. */
export function targetedBy(trials: readonly Trial[], set: string, callSiteKey: string): { trial: string; verdict: Verdict }[] {
  const hits: { trial: string; verdict: Verdict }[] = [];
  for (const trial of trials) {
    if ((trial.evidence ?? []).some((e) => e.set === set && e.call_site === callSiteKey)) {
      hits.push({ trial: trial.trial, verdict: trial.verdict });
    }
  }
  return hits;
}

/** The machine a trial ran on: the machine of its first cited run found in history, else `null`. */
export function trialMachine(trial: Trial, runs: readonly Run[]): string | null {
  const byId = runIndex(runs);
  for (const id of citedRunIds(trial)) {
    const run = byId.get(id);
    if (run) return run.machine_id;
  }
  return null;
}

/**
 * Number of kept trials. With a `machineId`, only trials whose cited runs resolve to that
 * machine count (pass `runs` for the join); with `null`, every kept trial counts.
 */
export function keptCount(trials: readonly Trial[], machineId: string | null, runs: readonly Run[] = []): number {
  const kept = trials.filter((t) => t.verdict === 'keep');
  if (machineId === null) return kept.length;
  const byId = runIndex(runs);
  return kept.filter((t) => citedRunIds(t).some((id) => byId.get(id)?.machine_id === machineId)).length;
}

/** Trials attributable to `machineId` through their cited runs (ledger order). */
export function trialsForMachine(trials: readonly Trial[], runs: readonly Run[], machineId: string): Trial[] {
  const byId = runIndex(runs);
  return trials.filter((t) => citedRunIds(t).some((id) => byId.get(id)?.machine_id === machineId));
}
