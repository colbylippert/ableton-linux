# Profiler gains dashboard — design

Status: scaffold (D0). Sources: `plans/wine-interface-profiler-plan.md` §11, the ledger
schema in `plans/design-C-control-suite-agent-loop.md` §D, and the `dataviz` skill
(`SKILL.md`, `references/{choosing-a-form,color-formula,marks-and-anatomy,interaction,
components,anti-patterns,palette}.md`, `scripts/validate_palette.js`). Everything chart-
related below follows that skill; where this document is silent, the skill decides.

Stack: Vite 8 + React 18 + TypeScript (strict), Recharts 3, Vitest 5 (jsdom). No backend,
no router (tabs), no CSS framework (plain CSS tokens in `src/theme.css`).

Reading order for implementers: §1 rules → §2 metrics → §3 gains math → §4 views → §5
component contracts → §6 data-layer API → §7 palette & validator output → §8 marks and
interaction → §9 layout → §10 tests → §11 ownership → §12 VERIFY.

---

## 1. Rules that shape every view

Comparison rules (from the plan; the dashboard never bends them):

1. **Outcome vs interface.** Outcome metrics (CPU, IRQs, switches, xruns, PipeWire errors,
   DSP) are authoritative only from **untraced** runs (`trace_mode === 'off'`). Interface
   metrics (late / near-late blocks, slack, lost slack, call sites) exist only in **traced**
   runs. A comparison, a trend line, a KPI tile or a noise band never mixes the two; runs
   with different `trace_mode` are different identities (same refusal as
   `bench-report.py compare`: "trace mode mismatch").
2. **No timing claims under virtualisation.** Runs with `virtualization !== 'none'` carry the
   `NoTimingRibbon` wherever they are shown and are never compared with bare-metal runs
   (`virtualization` is part of the identity).
3. **Identity** = `(machine_id, virtualization, audio_device, structure/scenario, trace_mode)`.
   Every baseline, delta, spread and trend is computed inside one identity. `audio_device`
   (the PipeWire default sink's node.name) keeps runs on different interfaces apart, e.g. the
   built-in speaker and the USB Focusrite; absent and `null` both mean unknown (older records).
4. **Positive delta = improvement**, whatever the metric's direction. The sign flip is done
   once, in `signedDelta()`; the UI never re-derives it.
5. **Noise before claims.** Significance is `|deltaAbs| > 2 × A/A spread` → "beyond noise",
   else "within noise"; without an A/A estimate the chip says "no A/A data" and nothing is
   coloured as a win.
6. **Guard metrics** (`xruns`, `pipewire_errors`): any non-zero value is an automatic reject
   and is shown with the critical status + "reject" label, never as a trend to celebrate.
7. **Kept / reverted** come from the ledger (`verdict === 'keep' | 'revert'`); other verdicts
   (`inconclusive`, `tooling`, `mechanism-confirmed`) are shown dimmed.

Chart rules (mandatory, from the dataviz skill and the task):

- one y-axis per chart, never dual axes — two measures = two charts or a common base
  (delta % vs baseline);
- categorical hues in a fixed order per Set, never cycled, never reassigned when a filter
  removes a Set ("colour follows the entity");
- a legend for ≥ 2 series plus **selective** direct labels (end value, baseline), never a
  number on every point; a single-series chart has no legend box, the title names it;
- 2 px lines, ≥ 8 px markers (r ≥ 4) with a 2 px surface ring, bars ≤ 24 px with a 2 px
  surface gap, hairline solid gridlines, area/band washes at ~10 % opacity;
- hover crosshair + one tooltip listing every series on line charts; per-mark tooltips on
  bars and dots; hit targets ≥ 24 px; keyboard focus shows the same as hover;
- text wears text tokens only (never a series colour); identity comes from a mark beside
  the text;
- status colours (good / warning / serious / critical) are reserved for keep / revert /
  within-noise / beyond-noise / reject / no-timing-claims and always ship with an icon +
  label;
- every chart has a table view twin (the `ChartCard` toggle) — a value is never reachable
  only by hovering; contrast WARNs on the light surface (aqua, yellow, magenta) are relieved
  by exactly this plus direct labels;
- light and dark are both selected palettes (dark = the same hues re-stepped), validated
  separately (§7).

---

## 2. Metric registry (`src/data/metrics.ts`)

`key` is the `SetMetrics` field (or a derived key); `source` says which runs are
authoritative; `direction` says which way is better; `formatter` names the function in
`src/data/format.ts`; `decimals` is the display precision of the natural unit.

| key | label | unit | direction | source | formatter | decimals | notes |
|---|---|---|---|---|---|---|---|
| `host_cpu_pct` | Host CPU | % | lower | outcome | `formatPct` | 1 | whole machine |
| `live_cpu_pct_per_core` | Live CPU / core | % | lower | outcome | `formatPct` | 1 | **outcome primary** |
| `wine_cpu_pct_per_core` | Wine CPU / core | % | lower | outcome | `formatPct` | 1 | wineserver + Wine threads |
| `pipewire_cpu_pct` | PipeWire CPU | % | lower | outcome | `formatPct` | 1 | |
| `irq_per_s` | IRQs | /s | lower | outcome | `formatRate` | 0 | |
| `softirq_per_s` | SoftIRQs | /s | lower | outcome | `formatRate` | 0 | |
| `pipewire_errors` | PipeWire errors | count | lower | outcome | `formatInt` | 0 | **guard** — non-zero = reject |
| `xruns` | Xruns | count | lower | outcome | `formatInt` | 0 | **guard** — non-zero = reject |
| `dsp_avg` | DSP load avg | % | lower | outcome | `formatPct` | 1 | null on idle sets |
| `dsp_peak` | DSP load peak | % | lower | outcome | `formatPct` | 1 | null on idle sets |
| `audio_workers` | Audio workers | count | neutral | outcome | `formatInt` | 0 | informational; no delta colour, no significance |
| `voluntary_switches_per_s` | Voluntary switches | /s | lower | outcome | `formatRate` | 0 | |
| `late_blocks` | Late blocks | count | lower | interface | `formatInt` | 0 | raw count over the window |
| `late_blocks_per_min` | Late blocks / min | /min | lower | interface | `formatRate2` | 2 | derived: `late_blocks × 60 / duration_s`; null if `duration_s` is null/0 — **interface primary** |
| `near_late_blocks` | Near-late blocks | count | lower | interface | `formatInt` | 0 | |
| `near_late_blocks_per_min` | Near-late blocks / min | /min | lower | interface | `formatRate2` | 2 | derived as above |
| `slack_p01_ns` | Slack p01 | µs | **higher** | interface | `formatDurationNs` | 1 | stored in ns; displayed auto-scaled (ns / µs / ms) |
| `slack_p50_ns` | Slack p50 | µs | **higher** | interface | `formatDurationNs` | 1 | as above |
| `lost_slack_total_ns` | Lost slack (total) | ms | lower | interface | `formatDurationNs` | 2 | as above |

Not scalar metrics (own views): `call_sites_top[]` (CallSites view, share 0..1 via
`formatShare`, 1 decimal as a percentage) and `hotspots_non_audio_top[]` (Scenarios view,
`total_ns` via `formatDurationNs`, `n` via `formatInt`).

Formatters (`src/data/format.ts`): `formatPct(v, d=1)` → `41.2%`; `formatInt(v)` →
`1,284` (compact `12.9K` above 9,999 in tiles only); `formatRate(v)` → `1,204/s`;
`formatRate2(v)` → `3.20/min`; `formatDurationNs(v, d)` → `812 ns` / `12.4 µs` /
`3.21 ms` / `1.20 s`; `formatShare(v)` → `62.0%`; `formatDelta(row)` → `▲ 18.4%` /
`▼ 3.1%` / `0.0%` (glyph carries direction, status colour on the glyph only);
`formatDate(iso)` → `2026-10-16 12:00` (UTC, labelled). `null` always renders as `—`.

Primary metric: `PRIMARY_METRIC = { interface: 'late_blocks_per_min', outcome:
'live_cpu_pct_per_core' }` — the Overview hero uses the interface primary when the slice has
traced runs, else the outcome primary (plan priority: 0 guards → 1 late/near-late → 2 CPU).

---

## 3. Gains model (`src/data/gains.ts`)

```
identityOf(run)      = { machine_id, virtualization, audio_device, structure, scenario, trace_mode }
identityKeyOf(id)    = `${machine_id}|${virtualization}|${structure}/${scenario ?? '-'}|${trace_mode}|${audio_device ?? '-'}`
baselineKeyOf(run)   = `${structure}/${scenario ?? '-'}`          // baselines.json inner key
```

**Baseline resolution** — `resolveBaseline(runs, baselines, identity)`:

1. `id = baselines[identity.machine_id]?.[baselineKeyOf(identity)]`; the run with that
   `run_id` is the baseline **if** it has the same identity (same `trace_mode` and
   `virtualization`; baselines.json is keyed without trace mode, so a traced identity whose
   recorded baseline is untraced falls through to 2);
2. otherwise the earliest run (by `started_at`, then `run_id`) of that identity with no
   switches (`Object.keys(switches).length === 0`), `trial === null` and `arm === null`;
3. otherwise `null` → the row has no baseline, no delta, no band; tiles say "no baseline".

**Signed delta** — `signedDelta(value, baseline, direction)`:

```
raw   = value − baseline
abs   = direction === 'lower' ? −raw : raw           // positive = improvement; neutral → raw
pct   = baseline === 0 ? null : abs / |baseline|
```

**A/A spread** — `aaSpread(runs, trials, identity, set, metric)`:

- pairs = explicit pairs from ledger lines (`runs.aa`, both members resolve to runs of this
  identity) ∪ implicit pairs: runs with `arm === 'AA'` of this identity not covered by an
  explicit pair, sorted by `started_at`, grouped by `trial`, paired consecutively (an odd
  leftover is ignored);
- diffs = `|a − b|` for pairs where both values are non-null;
- `spread = median(diffs)`, `pairs = diffs.length`; `null` when there are no pairs.

**Significance** — `deltaAbs === null || spread === null` → `unknown`;
`|deltaAbs| > 2 × spread` → `beyond`; else `within` (a spread of exactly 0 makes any change
"beyond"; that is what the data says and the chip shows `pairs`).

**Latest / best** — within the filtered slice of the identity: `latest` = max `started_at`
(tie → `run_id`); `best` = min (lower-is-better) or max (higher-is-better) over runs with
`started_at ≥ baseline.started_at`, the baseline included; `null` for neutral metrics.

**computeGains(runs, baselines, filter, trials = [])** → one `GainRow` per
(identity, set, metric) with ≥ 1 run in the slice. Outcome metrics are produced only for
identities with `trace_mode === 'off'`, interface metrics only for traced identities; the
filter's `switch` narrows the runs that compete for latest/best but never the baseline.

**Cumulative gain (Overview hero)** = median over Sets of `deltaPct` on the primary metric
for the *headline identity* (the identity of the most recent run in the slice, with
`trace_mode` taken from the metric's source: the latest traced identity for the interface
primary, the latest untraced one for the outcome primary). Shown with the kept-trial count
(`trials.filter(t => t.verdict === 'keep')` whose cited runs belong to the slice's machine).

**Trial markers** — `trialMarkers(trials, runs, identity)`: x = `started_at` of the trial's
first run on this identity (fallback `trial.date`); verdict → status (keep = good ✓,
revert = critical ✗, others dim with no label until hovered).

---

## 4. Views

All seven views are default-exported components with the same props
(`src/views/ViewProps.ts`):

```ts
interface ViewProps { data: DashboardData; filter: FilterState; onFilterChange(next: FilterState): void }
```

The `FilterBar` is mounted **once** by `App` above the panel (one row; it scopes every
view). Views never own filter state; they may narrow it (clicking a Set name sets
`filter.set`).

### 4.1 Overview — "where are we vs the baseline?"

| Component | Props (summary) | Data |
|---|---|---|
| `EnvironmentBadge` | `{ machineId, hostname, virtualization }` | headline identity |
| `NoTimingRibbon` | `{ virtualization, hostname, runs }` | shown when the slice contains virtualised runs |
| `HeroFigure` | `{ label: 'Cumulative gain', value: '▲ 95.6%', sub: 'Fewer dropouts: PipeWire errors per minute 11.3 → 0.50; DSP load 11.0% → 10.5% (untraced, T0003 arm A → T0007 arm A)', kept: 2 }` | `keptTrialGain`: the earliest kept trial's A arm (none of the kept changes) against the latest trial's A arm (every kept change on). Dropouts are normalised per minute of audio. The badge reads "kept by pre-registered trials". Falls back to the §3 cumulative gain when no kept trial has its runs in history. |
| `KpiTile` × 4 per Set (one `grid-kpi` row per Set, Set name as the row heading with its colour dot) | late blocks / min · PipeWire errors + xruns (guard tile, `value: '0 / 0'`) · Live CPU / core · slack p01 | `computeGains` rows for the Set |
| `DataTable` (tile twin) | columns: Set, metric, baseline, latest, best, delta, significance, runs | same rows |
| Set chips (`.set-chips`) | one `.chip.set-chip` button per Set (`aria-pressed` = filtered) | the slice's Sets; click narrows the shared filter |
| DSP load by Set (`.set-load`) | one row per Set, tinted with `color-mix(in oklch, <Set hue> var(--set-tint), var(--surface-1))`, bars on one shared scale | latest untraced run's `dsp_avg` |
| `TrendChart` | DSP load average per Set over the identity's untraced runs, trial markers | `trendSeries` + `trialMarkers` |
| `ChartFrame` + `DeltaBars` / `DeltaBarsTable` | dropouts of the latest trial: PipeWire errors summed over its ABAB runs, arm A vs arm B | `joinTrials` |
| `DataTable` (recent trials) | trial, change, verdict, primary metric, per-Set ratio-to-spread chips | ledger, newest first, max 5 |

Layout (Claude Design "Spectrum overview" template, 2026-10-17), top to bottom:
1. The view head: title and slice note on the left, environment badge on the right.
2. The Set chips.
3. The hero card beside "DSP load by Set". The hero card's top rule takes the status colour of
   the cumulative gain, and its chips are the significance badge plus each kept trial's switch.
4. "Headline metrics": the tile rows with their table twin.
5. The DSP trend beside the latest trial's dropouts.
6. Recent trials.

Each tile: baseline → latest, best since baseline, delta (`▲`/`▼` glyph in status colour,
number in ink), a 12-point sparkline (`--series-dim` line, current point in the Set's hue),
and the significance chip. Interface tiles say "no traced runs in slice" when the slice has
none; the guard tile turns critical with the label "reject" on any non-zero value.

### 4.2 Trends — "how did each metric move over run time?"

| Component | Props | Data |
|---|---|---|
| `MetricSelect` | `{ value: MetricKey, onChange, groups: { outcome, interface } }` — interface group disabled without traced runs | registry |
| `TrendChart` per Set (small multiples, `grid`) | `series: [one TrendSeries in the Set's slot]`, `baseline`, `noiseBand (±2 × spread)`, `markers`, `unit`, `direction`, `format` | `trendSeries()` + `computeGains` + `trialMarkers` |
| overlay toggle → one `TrendChart` | `series: canonical Sets (≤ 5) + other`, y = delta % vs each Set's own baseline, `baseline: { value: 0 }`, `noiseBand: null`, legend + end labels | `overlaySeries()` |
| `DataTable` twin per chart | run, started, tag, trial/arm, switches, value, delta, significance | |

Default = small multiples (one Set per card, its own baseline and band — the only honest way
to show per-Set noise). Overlay is for "which Set moved most" and uses the common base rule
(one axis). Non-canonical Sets are left out of the overlay (listed in the caption) and keep
their own card.

### 4.3 Trials — "what did each trial change and did it clear the noise?"

| Component | Props | Data |
|---|---|---|
| `DataTable` (ledger) | columns: trial, date, host, verdict `Badge`, hypothesis (truncated, full on hover/focus), switch, probe (`5 ✓ 0 ✗ 1 ↷`), primary, per-Set ratio-to-spread (`2.0×` with ▲/▼ when ≥ 2), commit, minutes; `selectable: { max: 1 }` | `joinTrials()` |
| `TrialDetail` | `{ join: TrialJoin }` — hypothesis, change (kind / patch / switch / probe / note), rationale, evidence table, missing-run list | |
| `PairedDots` per Set | `{ pairs: { index, a, b }[], unit, direction, format }` — dumbbell per ABAB pair, A → B, `--ord-before` → `--ord-after`, per-mark tooltip | `join.runs.abab` + metric values |
| `BeforeAfterBars` | `{ before, after, label: 'call-site share of lost slack' }` — two horizontal bars ≤ 24 px, same ordinal pair | `traced_confirmation` |
| `DataTable` twins | pair, run A, run B, value A, value B, Δ | |

Kept and reverted rows carry the status colour on the verdict chip only (icon + label);
`inconclusive` / `tooling` / `mechanism-confirmed` rows are dimmed (`.chip-dim`).

### 4.4 CallSites — "which crossings lose the slack, and which trial went after them?"

| Component | Props | Data |
|---|---|---|
| `ShareTrend` per Set (= `TrendChart` with `emphasis`) | `series: top-N call sites (N ≤ 8) by max share, all in slot 'dim' except the emphasised one in the Set's hue`, `markers: trials whose evidence names a call site of this Set`, y = share 0..1 | `callSiteTrends()` |
| `CallSiteTable` (the twin and the selector) | rank, key (kind · name · caller, monospace), latest share, total ns in late blocks, trend sparkline, targeted-by `Badge`s (trial + verdict); clicking a row sets the emphasis | `targetedBy()` |

Emphasis form on purpose: call sites are a second categorical dimension and must not borrow
the Set hues; the Set's hue marks "this Set's data", the gray lines are context, the legend
list + table carry identity.

Layout (2026-10-18):
- One Set per full-width row (`.cs-sets`).
- Inside a row, `CallSiteTrend` is a container-query grid. At 720 px or wider, the stacked share bars
  take 3/5 and the legend 2/5 beside them; narrower cards put the legend below.
- The legend lists one call site per line: swatch, name, then the `kind · caller chain` in monospace,
  wrapping anywhere inside its own column. A three-across grid let unbreakable chains like
  `kernelbase.dll!WaitForSingleObject+0x49` spill into the neighbouring card.

### 4.5 Scenarios — "what do the diagnostic scenarios show over time?"

| Component | Props | Data |
|---|---|---|
| `ScenarioSelect` | `{ value, onChange, scenarios }` (diagnostic identities only) | `filterOptions` |
| `TrendChart` per scenario × Set | as in Trends, metric from `MetricSelect` | `computeGains` on the diagnostic identity |
| `HotspotBars` | `{ rows: HotspotTop[] (latest run, sorted by total_ns, top 10), format }` — horizontal bars, one hue (the Set's), per-mark tooltip | latest run's `hotspots_non_audio_top` |
| `HotspotTrend` (= `TrendChart` with `emphasis`) | total ns of the selected hotspot key `role|kind|caller` across runs | `hotspotTrends()` |
| `DataTable` twins | | |

### 4.6 Runs — "every run, with its identity; pick two to compare"

| Component | Props | Data |
|---|---|---|
| `DataTable` (runs) | started (UTC), run id, tag, machine/hostname, environment `Badge`, structure/scenario, trace `Badge`, switches, trial/arm `Badge`, commit, duration, Sets; `selectable: { max: 2 }`; default sort started desc | `applyFilter` (machine `null` allowed here) |
| `RunDelta` | `{ a: Run, b: Run }` → identity guard (`runDelta()` returns `{ ok: false, reason }` for trace-mode / virtualisation / structure-scenario / machine mismatch, rendered as a `.ribbon`) or a table: Set × metric, A, B, Δ (signed, positive = improvement, diverging cell bar), source column | `runDelta()` |

### 4.7 Architecture — "how does the profiler measure Live, and how does code reach the laptop?"

A static reference page: it reads neither the runs nor the filter, so its `TabDef` sets
`filtered: false` and `App` hides the `FilterBar` on this tab.

| Component | Props | Data |
|---|---|---|
| legend | trace point (diamond), audio path, call or data flow, control or lookup | — |
| three figures | `FIGURES` in `src/views/Architecture.tsx`: runtime stack and trace points, one benchmark run, machines + build + agent loop; each a `.card` with the drawing (horizontal scroll inside the card under 1040 px, never the page) and a caption | `src/architecture/*.svg`, imported with `?raw` |
| status table | `DataTable`: part, paths, state `Badge` (working → good, in progress → warning, written / planned → dim), note | `src/architecture/status.ts` (hand-maintained; bump `STATUS_AS_OF`) |

The drawings are hand-written SVG with classes only: no inline colour, no `<style>`,
`<script>` or `<foreignObject>`. `src/architecture/architecture.css` colours every class from
the theme tokens (diamonds `--series-2`, audio path `--series-1`, layer bands mixed from
`--text-primary` into `--surface-1`, status colours on dots only), so the drawings follow
light / dark like the charts. Marker ids are unique per figure (`f1a`, `f2a`, …) because all
three share one document. `Architecture.test.tsx` enforces these rules (no inline colour,
every class styled, unique ids).

---

## 5. Shared component contracts (`src/components/`)

```ts
// FilterBar — one row above the panel; standard <select>s styled to the chrome.
interface FilterOptions {
  machines: { id: string; hostname: string; virtualization: Virtualization; runs: number }[];
  structures: Structure[]; scenarios: string[]; traceModes: TraceMode[]; sets: string[]; switches: string[];
}
interface FilterBarProps { filter: FilterState; options: FilterOptions; onChange(next: FilterState): void; runsInSlice: number }
// FilterState (src/data/types.ts): { machine, environment, structure, scenario, traceMode, set, switch } — null = all;
// environment: 'all' | 'bare-metal' | 'virtualised'; switch: ENV_NAME | 'none' | null.
// defaultFilterFor(runs) sets machine = machine of the most recent run (cross-machine charts are meaningless).

// TrendChart — line chart over run time; one series (small multiple) or ≤ 6 (overlay / emphasis up to 8 with one highlighted).
type SeriesSlot = 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 'dim';
interface TrendPoint { t: number; runId: string; tag: string; value: number | null; arm: Arm | null; trial: string | null; switches: Record<string, string> }
interface TrendSeries { id: string; label: string; slot: SeriesSlot; points: TrendPoint[] }
interface TrendMarker { t: number; trial: string; verdict: Verdict; label: string }
interface TrendChartProps {
  title: string; subtitle?: string;
  series: TrendSeries[];
  baseline: { value: number; runId: string; label?: string } | null;      // ReferenceLine, solid 1 px --text-secondary, end label
  noiseBand: { center: number; halfWidth: number; pairs: number } | null; // ReferenceArea center ± halfWidth (= 2 × spread), hue @ 10 %
  markers: TrendMarker[];                                                  // vertical ReferenceLines, status colour + icon/label; others dim
  unit: string; direction: MetricDirection; format(v: number | null): string;
  emphasis?: string | null;                                                // series id drawn in its slot; others forced to 'dim'
  height?: number;                                                         // includes the x-axis band (default 240)
  table: { caption: string };                                              // the twin, rendered by ChartCard's toggle
}

// KpiTile — the stat-tile contract (label · value · delta · trend).
interface KpiTileProps {
  label: string; value: string; unit?: string;
  baseline?: { value: string; label: string };     // "12.0", "baseline 2026-10-16"
  best?: { value: string; runId: string };
  delta?: { pct: number | null; abs: number | null; direction: 'better' | 'worse' | 'flat' | 'neutral'; significance: Significance; text: string };
  trend?: number[]; slot?: SeriesSlot;             // sparkline: --series-dim, last point in the slot hue
  source: MetricSource; note?: string;
  guard?: { reject: boolean; label: string };       // xruns / errors tile
}

// Badge / chips — status colour only on the dot, text in ink, icon + label always.
type BadgeStatus = 'good' | 'warning' | 'serious' | 'critical' | 'dim' | 'none';
interface BadgeProps { kind: 'verdict' | 'significance' | 'environment' | 'structure' | 'trace' | 'arm' | 'switch' | 'neutral'; value: string; status?: BadgeStatus; icon?: string; title?: string }
// verdict → keep: good ✓ · revert: critical ✗ · inconclusive: warning ≈ · tooling / mechanism-confirmed: dim ·
// significance → beyond & better: good ▲ · beyond & worse: critical ▼ · within: warning ≈ · unknown: dim ?
interface NoTimingRibbonProps { virtualization: Virtualization; hostname?: string | null; runs?: number }   // ⚠ "NO TIMING CLAIMS — virtualised host (vmware)"
interface EnvironmentBadgeProps { machineId: string; hostname: string; virtualization: Virtualization }

// DataTable — the WCAG twin of every chart and the main table views.
interface Column<T> { key: string; header: string; numeric?: boolean; render?(row: T): ReactNode; sortValue?(row: T): number | string | null; width?: string }
interface DataTableProps<T> {
  caption: string; columns: Column<T>[]; rows: T[]; rowKey(row: T): string;
  defaultSort?: { key: string; dir: 'asc' | 'desc' };
  selectable?: { selected: string[]; max?: number; onChange(next: string[]): void };
  dense?: boolean; emptyMessage?: string;
}

// ChartCard — <figure> owning title, key row, the chart|table toggle and responsive sizing.
interface ChartCardProps { title: string; subtitle?: string; keyRow?: ReactNode; chart: ReactNode; table: ReactNode; defaultView?: 'chart' | 'table'; footer?: ReactNode }

// PairedDots / BeforeAfterBars / HotspotBars — see §4.3 / §4.5.
interface PairedDotsProps { pairs: { index: number; a: number | null; b: number | null; runA: string; runB: string }[]; unit: string; direction: MetricDirection; format(v: number | null): string }
interface BeforeAfterBarsProps { before: number | null; after: number | null; label: string; format(v: number | null): string }
interface HotspotBarsProps { rows: HotspotTop[]; slot: SeriesSlot; format(v: number | null): string }
interface SparklineProps { values: number[]; slot?: SeriesSlot; width?: number; height?: number }   // 12 points, no axes, last point accented

// Theme → hex: Recharts needs concrete colours; src/palette.ts mirrors theme.css and useThemeMode() watches data-theme + prefers-color-scheme.
```

---

## 6. Data-layer API (`src/data/`)

```ts
// history.ts
loadHistory(): { runs: Run[]; errors: string[] }
//   import.meta.glob('../../../history/runs/*.json', { eager: true }) — path relative to src/data/ → profiler/history/runs/
//   keeps records with schema 'ableton-linux-profiler-history/v1' (or no schema key), reports others; sorted by started_at, run_id
// baselines.ts
loadBaselines(): Baselines
//   import.meta.glob('../../../history/baselines.json', { eager: true }) — {} when the file does not exist yet (a static import would break the build)
// ledger.ts
loadLedger(): { trials: Trial[]; errors: string[] }
parseLedger(raw: string): { trials: Trial[]; errors: string[] }     // one JSON object per line; blank lines skipped; bad lines reported with their number
//   import raw from '../../../ledger.jsonl?raw' — file exists, possibly empty
// load.ts (scaffold stub → D1)
loadDashboardData(): DashboardData                                   // { runs, baselines, trials, loadErrors }
// metrics.ts
METRICS: readonly MetricDef[]; metric(key: MetricKey): MetricDef; metricValue(run, setName, key): number | null
PRIMARY_METRIC; GUARD_METRICS: MetricKey[]; metricsFor(source: MetricSource): MetricDef[]
// identity.ts
identityOf(run): Identity; identityKeyOf(id): string; baselineKeyOf(run | Identity): string; sameIdentity(a, b): boolean
environmentOf(run): 'bare-metal' | 'virtualised'; isTraced(run): boolean
// filter.ts
applyFilter(runs, filter): Run[]; filterOptions(runs): FilterOptions; defaultFilterFor(runs): FilterState
// sets.ts
CANONICAL_SETS = ['Benchmark_Zero', 'Benchmark_Empty', 'Benchmark_Inbuilts', 'Benchmark_Max4Live', 'Benchmark_VSTs']
setSlot(name): SeriesSlot (1..5, else 6); setLabel(name): string ('Benchmark_VSTs' → 'VSTs'); orderSets(names): string[]
// gains.ts
resolveBaseline(runs, baselines, identity): Run | null
aaPairs(runs, trials, identity): [Run, Run][]
aaSpread(runs, trials, identity, set, metric): NoiseSpread | null
signedDelta(value, baseline, direction): { abs: number; pct: number | null }
significanceOf(deltaAbs, spread): Significance
computeGains(runs, baselines, filter, trials?): GainRow[]
cumulativeGain(rows, metric): { medianPct: number | null; sets: number; significance: Significance }
// trials.ts
joinTrials(trials, runs): TrialJoin[]; trialMarkers(trials, runs, identity): TrendMarker[]
targetedBy(trials, set, callSiteKey): { trial: string; verdict: Verdict }[]; keptCount(trials, machineId | null): number
// series.ts (view models)
trendSeries(runs, set, metric, slot): TrendSeries; overlaySeries(rows: GainRow[], runs): TrendSeries[]
callSiteTrends(runs, set, topN): TrendSeries[]; hotspotTrends(runs, set, topN): TrendSeries[]
runDelta(a: Run, b: Run): { ok: true; rows: RunDeltaRow[] } | { ok: false; reason: string }
// format.ts / stats.ts
formatPct, formatInt, formatRate, formatRate2, formatDurationNs, formatShare, formatDelta, formatDate; median(values): number | null
```

All functions are pure; the only module-level side effects are the three imports in the
loaders, which is what gives HMR on `history-add` and ledger appends.

---

## 7. Palette and tokens

Palettes chosen in Claude Design on 2026-10-17 (project "Profiler Dashboard Design System",
templates `bright-theme` → **Spectrum** for light and `dark-abyss` → **Abyss** for dark). They
replace the original dataviz reference instance; token names and every rule below are
unchanged. Tokens live in `src/theme.css` on `:root`, with the dark set declared under
`@media (prefers-color-scheme: dark) { :root:not([data-theme="light"]) }` and again under
`:root[data-theme="dark"]` (viewer toggle wins both ways). `src/palette.ts` mirrors the same
hex values for Recharts.

### 7.1 Categorical order per Set (fixed, never cycled)

| Slot | Hue | Light (Spectrum) | Dark (Abyss) | Set (suite order) | token |
|---|---|---|---|---|---|
| 1 | indigo / cyan | `#4f46e5` | `#3fe0e6` | Benchmark_Zero | `--set-zero` |
| 2 | tangerine / coral | `#ff6b35` | `#ff8a5c` | Benchmark_Empty | `--set-empty` |
| 3 | teal / periwinkle | `#00c2a8` | `#7aa8ff` | Benchmark_Inbuilts | `--set-inbuilts` |
| 4 | amber | `#ffc233` | `#ffd257` | Benchmark_Max4Live | `--set-max4live` |
| 5 | pink | `#ff4fa3` | `#ff74b8` | Benchmark_VSTs | `--set-vsts` |
| 6 | sky / lime | `#22a6f2` | `#a6e85a` | other (any non-canonical Set) | `--set-other` |
| 7 | violet | `#9b5de5` | `#c79bff` | reserved (unused) | `--series-7` |
| 8 | red | `#f2545b` | `#ff6b72` | reserved (unused) | `--series-8` |
| — | de-emphasis | `#8a8fb0` | `#5f7f87` | context series in the emphasis form, sparkline body | `--series-dim` |

A Set keeps its slot in every view and whatever the filter removes. Several non-canonical
Sets in one overlay would share slot 6, so the overlay excludes them (they keep their own
small-multiple card, where one series needs no hue distinction).

The table twin on every chart and the end-value direct label are both mandatory, never
optional: in light mode, slots 2, 3, 4 and 6 sit below 3:1 on the surface (§7.4).

In dark mode, the Abyss template's slots 3 and 6 are swapped (user decision, 2026-10-18).
Inbuilts takes periwinkle `#7aa8ff` and "other Sets" takes lime `#a6e85a`, because the
template's lime Inbuilts was hard to tell from amber Max4Live.

### 7.2 Sequential, diverging, ordinal, status

| Job | Assignment | Where |
|---|---|---|
| Sequential (blue 100→700) | `--seq-100 … --seq-700` (unchanged) | reserved; no view uses it today |
| Ordinal before/after pair | light `--ord-before #a5a1f5` → `--ord-after #3730a3`; dark `#1f7f86` → `#8ff2f5` | `PairedDots` (A → B), `DeltaBars`, architecture "busy" marks |
| Diverging | `--div-neg #f2545b` (regression) · `--div-mid #e8edff` · `--div-pos #4f46e5` (improvement); dark `#ff6b72` · `#1a3a44` · `#3fe0e6` | delta cell bars in `CompareDrawer` (bar only; the number stays in ink) |
| Status good | light `#00b37e` · dark `#2ed398` | keep ✓, beyond-noise improvement ▲ |
| Status warning | light `#ffc233` · dark `#ffd257` | within noise ≈, inconclusive |
| Status serious | light `#ff8a3d` · dark `#ffa05c` | `NoTimingRibbon` ⚠ |
| Status critical | light `#ef4444` · dark `#ff5c5c` | revert ✗, beyond-noise regression ▼, guard reject |

Status colours never touch text. They sit on the chip dot, the glyph, the marker line, the
ribbon border or the hero card's top rule, and the label text is always ink. In light mode,
warning and serious are below 3:1 by design; the icon and label carry the meaning.
`--delta-good-text` (`#047857` / `#4be3a0`) is the one coloured text token, used only for
positive deltas.

### 7.3 Token tables

Contrast is WCAG 2.x against the chart surface (`--surface-1`: `#ffffff` / `#0c2129`).

| Role | token | Light | Dark | contrast light / dark |
|---|---|---|---|---|
| Page plane | `--page` | `#f3f5ff` | `#061419` | — |
| Chart surface / cards | `--surface-1` | `#ffffff` | `#0c2129` | — |
| Raised rows, chips, diverging midpoint | `--surface-2` | `#e8edff` | `#133039` | — |
| Primary ink | `--text-primary` | `#0b1033` | `#eafcff` | 18.5 / 15.7 |
| Secondary ink | `--text-secondary` | `#434a75` | `#aed3db` | 8.5 / 10.4 |
| Muted (axis ticks, captions ≥ 12 px) | `--text-muted` | `#666c94` | `#7fa5ae` | 5.1 / 6.2 |
| Gridline (hairline) | `--grid` | `#e1e6fa` | `#1a3a44` | recessive by design |
| Baseline / axis | `--axis` | `#c3c9ea` | `#255059` | recessive by design |
| Border ring | `--border` | `rgba(11,16,51,.10)` | `rgba(255,255,255,.12)` | — |
| Delta up good (text) | `--delta-good-text` | `#047857` | `#4be3a0` | 5.5 / 10.1 |
| Focus ring | `--focus` | `#4f46e5` | `#3fe0e6` | 6.3 / 10.3 |
| Links | `--link` / `--link-hover` | `#4f46e5` / `#3730a3` | `#3fe0e6` / `#8ff2f5` | 6.3 / 10.3 |
| Series 1–8 | `--series-N` | §7.1 | §7.1 | light 6.3 · 2.8 · 2.3 · 1.6 · 3.0 · 2.7 · 4.1 · 3.4; dark all ≥ 6.0 |
| De-emphasis | `--series-dim` | `#8a8fb0` | `#5f7f87` | 3.2 / 3.9 |
| Ordinal pair | `--ord-before/after` | `#a5a1f5` / `#3730a3` | `#1f7f86` / `#8ff2f5` | 2.33 / 9.93 — 3.51 / 12.79 |
| Diverging | `--div-neg/mid/pos` | `#f2545b` / `#e8edff` / `#4f46e5` | `#ff6b72` / `#1a3a44` / `#3fe0e6` | — |
| Status | `--status-*` | good `#00b37e` · warning `#ffc233` · serious `#ff8a3d` · critical `#ef4444` | `#2ed398` · `#ffd257` · `#ffa05c` · `#ff5c5c` | 2.7 · 1.6 · 2.3 · 3.8 / 8.6 · 11.5 · 8.2 · 5.5 |
| App bar | `--appbar-bg` / `-ink` / `-accent` / `-accent-ink` / `-border` | `#1a1f5c` / `#ffffff` / `#00c2a8` / `#06201c` / transparent | `#030d10` / `#ffffff` / `#3fe0e6` / `#022225` / `#1a3a44` | ink 15.1 / 19.6; accent pill text 7.5 / 10.3 |
| Set-row tint | `--set-tint` | 12 % | 22 % | `color-mix(in oklch, <Set hue> var(--set-tint), var(--surface-1))` |
| Radius | `--radius` / `--radius-sm` | 12 px / 6 px | same | — |
| Typeface | `--font` | `system-ui, -apple-system, "Segoe UI", sans-serif` | same | proportional figures; `tabular-nums` only in table columns and axis ticks |

### 7.4 Validator output (recorded verbatim, 2026-10-17)

Script: `node C:/Users/colby/AppData/Local/Temp/claude/bundled-skills/2.1.292/89eebd4548465f2d7df474971b3b3dd1/dataviz/scripts/validate_palette.js`

```
$ validate_palette.js "#4f46e5,#ff6b35,#00c2a8,#ffc233,#ff4fa3,#22a6f2,#9b5de5,#f2545b" --mode light --surface "#ffffff"
  [FAIL] Lightness band         outside band: [["#ffc233",0.847]]
  [PASS] Chroma floor           all 8 >= 0.1
  [PASS] CVD separation         worst adjacent #9b5de5↔#22a6f2 ΔE 8.7 (deutan) · tritan 18.4
  [PASS] Normal-vision floor    worst adjacent #9b5de5↔#22a6f2 ΔE 20.0 (normal)
  [WARN] Contrast vs surface    below 3:1 — relief required (visible labels or table view): [["#ff6b35",2.84],["#00c2a8",2.26],["#ffc233",1.61],["#22a6f2",2.69]]
exit=1

$ validate_palette.js "#3fe0e6,#ff8a5c,#a6e85a,#ffd257,#ff74b8,#7aa8ff,#c79bff,#ff6b72" --mode dark --surface "#0c2129"
  [FAIL] Lightness band         outside band: [["#3fe0e6",0.829],["#ff8a5c",0.753],["#a6e85a",0.859],["#ffd257",0.881],["#ff74b8",0.743],["#7aa8ff",0.735],["#c79bff",0.768],["#ff6b72",0.713]]
  [PASS] Chroma floor           all 8 >= 0.1
  [FAIL] CVD separation         worst adjacent #c79bff↔#7aa8ff ΔE 0.5 (protan) · tritan 12.7
  [FAIL] Normal-vision floor    worst adjacent #c79bff↔#7aa8ff ΔE 10.4 (normal) — below 15, hard to tell apart even with full color vision
  [PASS] Contrast vs surface    all 8 >= 3:1
exit=1

$ validate_palette.js "#4f46e5,#ff6b35,#00c2a8,#ffc233,#ff4fa3,#22a6f2" --mode light --surface "#ffffff"      # the 6 slots actually assigned
  [FAIL] Lightness band         outside band: [["#ffc233",0.847]]
  [PASS] Chroma floor           all 6 >= 0.1
  [PASS] CVD separation         worst adjacent #00c2a8↔#ff6b35 ΔE 14.0 (deutan) · tritan 21.2
  [PASS] Normal-vision floor    worst adjacent #ffc233↔#00c2a8 ΔE 24.8 (normal)
  [WARN] Contrast vs surface    below 3:1 — relief required (visible labels or table view): [["#ff6b35",2.84],["#00c2a8",2.26],["#ffc233",1.61],["#22a6f2",2.69]]
exit=1

$ validate_palette.js "#3fe0e6,#ff8a5c,#a6e85a,#ffd257,#ff74b8,#7aa8ff" --mode dark --surface "#0c2129"
  [FAIL] Lightness band         outside band: [["#3fe0e6",0.829],["#ff8a5c",0.753],["#a6e85a",0.859],["#ffd257",0.881],["#ff74b8",0.743],["#7aa8ff",0.735]]
  [PASS] Chroma floor           all 6 >= 0.1
  [FAIL] CVD separation         worst adjacent #ffd257↔#a6e85a ΔE 2.6 (protan) · tritan 12.7
  [FAIL] Normal-vision floor    worst adjacent #ffd257↔#a6e85a ΔE 12.6 (normal) — below 15, hard to tell apart even with full color vision
  [PASS] Contrast vs surface    all 6 >= 3:1
exit=1

$ validate_palette.js "#4f46e5,#ff6b35,#00c2a8" --mode light --surface "#ffffff" --pairs all
  [PASS] Lightness band · [PASS] Chroma floor · [PASS] CVD separation (ΔE 14.0 deutan) · [PASS] Normal-vision floor (ΔE 30.7)
  [WARN] Contrast vs surface    below 3:1: [["#ff6b35",2.84],["#00c2a8",2.26]]
exit=0
$ validate_palette.js "#3fe0e6,#ff8a5c,#a6e85a" --mode dark --surface "#0c2129" --pairs all
  [FAIL] Lightness band (all 3 above L 0.67) · [PASS] CVD separation (ΔE 10.0 deutan) · [PASS] Normal-vision floor (ΔE 18.4) · [PASS] Contrast
exit=1
$ validate_palette.js "#a5a1f5,#3730a3" --ordinal --mode light --surface "#ffffff"
  [PASS] Lightness monotone · [PASS] Adjacent ΔL · [PASS] Light-end contrast #a5a1f5 at 2.33:1 · [PASS] Single hue (8°)   exit=0
$ validate_palette.js "#1f7f86,#8ff2f5" --ordinal --mode dark --surface "#0c2129"
  [PASS] Lightness monotone · [PASS] Adjacent ΔL · [PASS] Light-end contrast #1f7f86 at 3.51:1 · [PASS] Single hue (4°)   exit=0
```

These are the designer's palettes, shipped as chosen. What the failures mean:
- **Dark lightness band.** Abyss's neon series are brighter than the validator's dark band
  (L 0.48–0.67). That is a deliberate look; contrast on the surface is ≥ 6:1 for every slot.
- **Inbuilts vs Max4Live in dark (fixed 2026-10-18 by swapping slots 3 and 6).** Lime `#a6e85a` vs amber `#ffd257` were hard to tell apart:
  ΔE 12.6 for normal vision and 2.6 for protan. This is the one failure that bites, because the
  heavy-Set overlay draws them together. With Inbuilts on periwinkle the 6-slot check passes:
  `validate_palette.js "#3fe0e6,#ff8a5c,#7aa8ff,#ffd257,#ff74b8,#a6e85a" --mode dark --surface "#0c2129"`
  gives CVD separation PASS (worst adjacent ΔE 17.2, deutan), normal-vision PASS (ΔE 27.3) and
  contrast PASS. Only the stylistic lightness band still fails.
- **Slots 6/7 in dark.** Near-identical for protan, but slot 7 is reserved and unused, so the
  pair never meets.
- **Light amber.** `#ffc233` is too light (1.6:1). Max4Live marks rely on their labels.

---

## 8. Marks and interaction (Recharts mapping)

| Spec | Implementation |
|---|---|
| Line 2 px, round joins | `<Line type="linear" strokeWidth={2} strokeLinejoin="round" strokeLinecap="round" connectNulls={false} isAnimationActive={false} />` — `linear`, never `monotone` (smoothing invents values between runs) |
| Marker ≥ 8 px + 2 px surface ring | `dot={{ r: 4, strokeWidth: 2, stroke: surface, fill: seriesHex }}`, `activeDot={{ r: 6, strokeWidth: 2, stroke: surface }}` |
| Crosshair + one tooltip, every series | `<Tooltip cursor={{ stroke: axis, strokeWidth: 1 }} content={<TrendTooltip />} />`; rows: value (strong, ink) · label (secondary) · 12 px line key in the series hue; run id, tag, trial/arm, switches, delta vs baseline, significance chip |
| Bars ≤ 24 px, 4 px rounded data-end, 2 px gap | `<Bar barSize={24} radius={[0, 4, 4, 0]} />` (horizontal), category gap ≥ 2 px, per-mark `<Tooltip>` with `cursor={false}`; hovered bar lifts via `activeBar` |
| Gridlines hairline solid | `<CartesianGrid stroke={grid} strokeDasharray="" vertical={false} />` |
| Axes | `<XAxis type="number" dataKey="t" domain={['dataMin','dataMax']} tickFormatter={formatDate} tick={{ fill: muted, fontSize: 11 }} axisLine={{ stroke: axis }} tickLine={false} />`, `<YAxis tickFormatter={format} width={56} />`, clean ticks, thousands-comma |
| Baseline reference | `<ReferenceLine y={baseline.value} stroke={textSecondary} strokeWidth={1} label={{ value: 'baseline', position: 'right', fill: textSecondary }} />` |
| A/A noise band | `<ReferenceArea y1={c − hw} y2={c + hw} fill={seriesHex} fillOpacity={0.1} stroke="none" />` |
| Trial markers | `<ReferenceLine x={t} stroke={statusHex} strokeWidth={1} label={{ value: '✓ T0007', position: 'top', fill: textSecondary }} />`; dim verdicts: `stroke={seriesDim} strokeOpacity={0.6}` without label |
| Legend (≥ 2 series) | custom `<Legend content>` with line keys, click = isolate (toggle), keyboard reachable; single series: none, a key row explains baseline/band/markers instead |
| Direct labels | end value of each line (`<LabelList>` on the last point only) and the baseline label; nothing else |
| Hit target ≥ 24 px | the crosshair snaps to the nearest run on line charts; bars/dots get a transparent 24 px hit rect (`shape` wrapper) |
| Responsive, no nested scroll | `<ResponsiveContainer width="100%" height={height}>` where `height` includes the x-axis band; cards grow with content |
| Table twin | `ChartCard` toggle renders `DataTable` from the same series; the toggle state is per card and remembered per viewer (`localStorage`, guarded) |
| Text tokens | every `tick`, `label`, legend and tooltip text uses `--text-*`; series hex only on strokes/fills |
| Refetch | data is static per module evaluation; on HMR the previous render stays until the new module mounts (no skeleton) |
| Reduced motion | `isAnimationActive={false}` everywhere; CSS transitions disabled under `prefers-reduced-motion` |

Colours reach Recharts as hex via `src/palette.ts` (`PALETTE[mode]`) with `useThemeMode()`
(observes `document.documentElement[data-theme]` and `matchMedia('(prefers-color-scheme:
dark)')`) so a theme switch re-renders charts; jsdom tests get the same hex without CSS.

---

## 9. Layout, theme and responsiveness

- `.app` max-width 1280 px, 16 px side gutters (`--gutter`), `body { overflow-x: hidden }`;
  the tab row scrolls horizontally on phones, never the page.
- Header: title, counts (`N runs · M trials · K load warnings`), theme toggle
  (System / Light / Dark; stored as `profiler-dashboard.theme`, applied before first paint by
  the inline script in `index.html`). Dark is a selected palette, not an inverted one.
- `FilterBar` row under the tabs (one row, wraps; hidden on Architecture, which ignores the
  filter), then the panel. Views use `.grid`
  (`auto-fit, minmax(280px, 1fr)`) for cards and `.grid-kpi` (`minmax(180px, 1fr)`) for tiles.
- Cards: `--surface-1`, hairline border ring, 8 px radius, 16 px padding (12 px ≤ 480 px).
- Exactly one hero figure per view (Overview only); 48 px (40 px on phones), proportional
  figures; tables and axis ticks use `tabular-nums`.
- Focus rings `--focus` on every interactive element; tabs are a WAI-ARIA tablist with
  arrow/Home/End keys; the active tab mirrors into the URL hash (`#trends`) for links.

---

## 10. Test plan (Vitest, jsdom)

Data layer (`src/data/*.test.ts`, fixtures in `src/data/fixtures.ts`: one machine `m1`
(bare metal), one `m2` (`vmware`); runs: untraced baseline, traced baseline, an A/A pair,
ABAB × 3 for trial T0007 with the switch on arm B, a diagnostic scenario run, a run with
nulls everywhere; ledger: T0007 keep, T0008 revert, one `tooling` line, one bad line):

- `ledger.test.ts`: empty file → 0 trials, 0 errors; blank lines skipped; a malformed line
  reports its line number and the rest still parses; unknown schema reported.
- `history.test.ts`: glob records sorted by `started_at`; a record with a foreign schema is
  reported, not loaded; `loadBaselines` returns `{}` when the file is absent.
- `metrics.test.ts`: every registry key resolves on a full record; derived per-minute metrics
  use `duration_s` and return `null` for null/0 duration; formatters (`null` → `—`, ns
  auto-scaling, compact ints, delta glyphs).
- `identity.test.ts`: trace mode and virtualisation split identities; `baselineKeyOf` uses
  `-` for no scenario.
- `gains.test.ts`: baseline from `baselines.json` when the identity matches; fallback to the
  earliest clean run when it does not (traced identity with an untraced recorded baseline);
  no baseline → row without delta; sign convention for lower / higher / neutral; zero baseline
  → `pct: null`, `abs` present; outcome rows only from untraced identities and interface
  rows only from traced ones; virtualised and bare-metal never share a row; `best` respects
  direction and includes the baseline; `switch` filter narrows latest/best but not the
  baseline; `cumulativeGain` median over Sets.
- `aa.test.ts`: explicit pairs from the ledger; implicit consecutive pairing of `AA` runs per
  trial with an odd leftover ignored; median over pairs; null values skipped; no pairs →
  `null` → significance `unknown`; `beyond` / `within` boundaries (`> 2 × spread`, spread 0).
- `trials.test.ts`: `joinTrials` resolves every run reference and lists missing ones;
  `trialMarkers` uses the first run's `started_at` with `trial.date` fallback; `targetedBy`
  matches evidence by set + call-site key; `keptCount`.
- `series.test.ts`: `trendSeries` keeps nulls (no connect), slot from `setSlot`; overlay series
  are delta % with canonical Sets only; `callSiteTrends` top-N by max share; `runDelta`
  refuses trace-mode / virtualisation / structure mismatches with a reason and otherwise
  returns signed per-Set rows.
- `filter.test.ts`: `applyFilter` on every key incl. `switch: 'none'`; `filterOptions`
  sorted and de-duplicated; `defaultFilterFor` picks the latest run's machine.

Components (`src/components/*.test.tsx`, React 18 `act` + `react-dom/client`, no
testing-library):

- `App.test.tsx` (scaffold, exists): seven tabs in order, default Overview, click + hash,
  hash deep link, FilterBar hidden on Architecture, empty state vs counts, theme attribute.
- `Architecture.test.tsx`: one labelled, captioned figure per drawing, status rows, unique
  ids, no inline colour / style / script in the SVG sources, every SVG class styled.
- `TrendChart`: renders one `<path>` per series, the baseline line and band only when
  provided, markers with status class, no legend for a single series and a legend for two,
  table twin lists every point with formatted values, nulls as `—`.
- `KpiTile`: delta glyph/direction/status mapping, guard reject state, "no baseline" note.
- `Badge` / `NoTimingRibbon`: icon + label present for every status; ribbon text names the
  virtualisation.
- `DataTable`: sort by numeric and string columns, selection cap, empty message.
- `FilterBar`: options rendered, change events produce a full `FilterState`.

Gates: `npm run build` (typecheck + Vite build), `npm test`, and the palette validator output
above (re-run whenever a hex changes). Manual pass (dataviz step 7): open the dev server in
light and dark, check label collisions, converging end labels (fall back to legend +
tooltip past ~4 series), axis band inside the card height, phone width (no horizontal page
scroll).

---

## 11. File ownership and handoff

| Owner | Files |
|---|---|
| D0 (this scaffold) | `package.json`, `vite.config.ts`, `tsconfig.json`, `index.html`, `README.md`, `DESIGN.md`, `src/main.tsx`, `src/App.tsx`, `src/App.test.tsx`, `src/theme.css`, `src/data/types.ts` (contracts — change only with a DESIGN.md update), `src/views/ViewProps.ts`, `src/views/ViewScaffold.tsx`, placeholder bodies of the six views |
| D1 | `src/data/{history,baselines,ledger,metrics,identity,filter,sets,gains,trials,series,format,stats,fixtures}.ts` + tests; replaces the body of `src/data/load.ts` |
| D2 | `src/components/{FilterBar,ChartCard,TrendChart,TrendTooltip,KpiTile,HeroFigure,Badge,NoTimingRibbon,EnvironmentBadge,DataTable,Sparkline}.tsx` + tests, `src/palette.ts`, `src/components/components.css`; `src/views/Overview.tsx`, `src/views/Trends.tsx`; mounts `FilterBar` in the marked slot of `src/App.tsx` (the only App edit) |
| D3 | `src/components/{PairedDots,BeforeAfterBars,HotspotBars,RunDelta,TrialDetail,CallSiteTable}.tsx` + tests; `src/views/{Trials,CallSites,Scenarios,Runs}.tsx` |

`ViewScaffold.tsx` is deleted once no view imports it.

---

## 12. VERIFY

1. `profiler/bin/history-add` output: whether records carry a top-level `schema` key
   (typed optional), the exact `null` conventions for top-level fields (`duration_s`,
   `commit`, `harness_sha`, `source_dir` are typed nullable), and that `baselines.json`
   uses `"<structure>/-"` for runs without a scenario.
2. `baselines.json` is keyed without trace mode: either run `history-add --baseline` once
   per trace mode and extend the key (e.g. `"benchmark/-@interface"`), or rely on the
   dashboard's fallback (earliest clean traced run). The gains code must accept both.
3. Ledger `traced_confirmation` field names: design-C §D says
   `{ call_site_share_before, after }`, plan §10 says `{ before, after }`. Types follow
   design-C; `parseLedger` should accept `before` as an alias.
4. Node on the VM must satisfy `^22.22.2 || ^24.15.0 || >=26` (jsdom 30 sets the floor); if
   the distro package is older, pin `jsdom@^26` instead of downgrading Node.
5. HMR for a **new** file under `profiler/history/runs/` (glob addition outside the Vite
   root) on Linux inotify — if a new run needs a restart, add `server.watch` for the
   directory or restart the user unit from `history-add`.
6. The systemd unit in `README.md` must match `profiler/setup/templates/` from design-A
   (name, `WorkingDirectory`, npm path on CachyOS).
7. `react-is` is a peer of Recharts 3 that npm installs automatically; confirm `npm ci` on
   the VM is clean (it is in `package-lock.json`).
8. Dev-server `fs.allow` was verified on Windows (profiler files served via `/@fs/`, files
   outside refused with 403); re-check on the VM where the path contains no drive letter.
