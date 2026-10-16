/**
 * Public entry of the data layer: `import { computeGains, METRICS, … } from '../data'`.
 *
 * DESIGN.md §6 lists the API by concern (history / baselines / ledger / metrics / identity /
 * filter / sets / gains / trials / series / format / stats); the implementation groups
 * those concerns into five modules and this index re-exports all of them, so views and
 * components import from `src/data` without caring about the split:
 *
 *   types.ts    schema + dashboard contracts (D0)
 *   format.ts   formatters, median
 *   metrics.ts  registry, Set slots/labels/order
 *   gains.ts    identity, filter, baseline/spread/delta/significance, computeGains,
 *               cumulative gain, trend/overlay/call-site/hotspot series, runDelta
 *   trials.ts   ledger joins, trial markers, targetedBy, keptCount
 *   load.ts     the loaders (the only module with side effects) and the pure parsers
 */
export * from './types';
export * from './format';
export * from './metrics';
export * from './gains';
export * from './trials';
export * from './load';
