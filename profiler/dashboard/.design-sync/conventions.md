# Profiler dashboard — building with these components

The dashboard of the Wine interface profiler for Ableton Live on Linux. It shows benchmark runs, A/B trials and Wine call sites. It is data-dense and calm: system fonts, colour only where it carries meaning, and two palettes: **Spectrum** (light: cool indigo base, rainbow Set hues) and **Abyss** (dark: deep teal, cyan accents).

## Setup
- **No provider or root wrapper.** All styling comes from `styles.css`, which imports `_ds_bundle.css`. That file holds the tokens, the `body` base (page background, ink, 14 px system font) and every component class. Without it, components render as bare HTML.
- **Theme.** Light by default. Dark follows the OS (`prefers-color-scheme`) unless `<html data-theme="light">` is set; `<html data-theme="dark">` forces dark.
  - To switch themes, set `data-theme` on `document.documentElement`. Charts watch that attribute and redraw with the matching palette.
  - Never override colour tokens to make a theme.
- **Chart width.** Charts (`TrendChart`, `DeltaBars`, `PairedDots`, `CallSiteTrend`) fill their container's width when `width` is omitted. Put them in a container that has a width, such as a `.card` in a `.grid`, not in a shrink-to-fit flex item. Pass `width` (px) only for fixed exports.

## Styling idiom: CSS custom properties plus a few layout classes
- **Surfaces and ink:** `--page`, `--surface-1` (cards), `--surface-2` (raised rows, chips), `--text-primary`, `--text-secondary`, `--text-muted` (captions and ticks only, never body text), `--border`, `--grid`, `--axis`, `--focus`.
- **Series:** `--series-1` … `--series-8` and `--series-dim`. Each benchmark Set keeps a fixed slot everywhere:

  | Set | Slot | Token |
  |---|---|---|
  | Benchmark_Zero | 1 | `--set-zero` |
  | Benchmark_Empty | 2 | `--set-empty` |
  | Benchmark_Inbuilts | 3 | `--set-inbuilts` |
  | Benchmark_Max4Live | 4 | `--set-max4live` |
  | Benchmark_VSTs | 5 | `--set-vsts` |
  | any other Set | 6 | `--set-other` |

  Component `slot` props take the same numbers (`1`–`8`, or `'dim'`).
- **Colour rules:** never cycle or invent hues, and never use a 9th. Every chart keeps its table twin (`ChartFrame`'s chart | table toggle), because light slots 3–5 are below 3:1 contrast.
- **Status:** `--status-good`, `--status-warning`, `--status-serious`, `--status-critical`.
  - Status colours go on dots, marks and borders only; text stays in ink.
  - Positive deltas written as text use `--delta-good-text`.
- **Shape and type:** `--radius` (12 px), `--radius-sm`, `--gutter`, `--font`, `--mono`.
- **App bar and links:** `--appbar-bg`, `--appbar-ink`, `--appbar-accent` (the active pill and brand dot), `--appbar-accent-ink`, `--appbar-border`; `--link`, `--link-hover`.
- **Set rows:** `--set-tint` (12 % light, 22 % dark) tints a row with its Set's hue: `color-mix(in oklch, var(--set-vsts) var(--set-tint), var(--surface-1))`.
- **Shipped classes for your own layout:**
  - Cards: `.card`, `.card-title`, `.card-subtitle`.
  - Grids: `.grid` (auto-fit, 280 px columns) and `.grid-kpi` (180 px).
  - Tables: `.table-wrap` around `table.data`, with `td.num` / `th.num` for numbers.
  - Chips: `.chip` with `.dot` and the `.chip-good` / `-warning` / `-serious` / `-critical` / `-dim` variants.
  - Other: `.empty` (empty state) and `.sr-only`.
  - View composition: `.view-title` (page `h2`), `.view-head`, `.section-head`, `.note` (lead text), `.muted` and `.mono` (ids, hashes and call sites).
  - App shell: `.appbar` > `.appbar-inner` with `.appbar-brand` (`.appbar-dot`, `.app-title`) and `.appbar-nav` (`.tablist` of `.tab` pills, `.theme-toggle`).
  - Set legend: `.set-chips` of `.chip.set-chip` buttons (`aria-pressed` = filtered). Per-Set bars: `.set-load` > `.set-load-row` with `--row-hue` set to the Set token.

  Don't invent class names; for other glue, use inline styles built from the tokens.

## Where the truth lives
- **Styles:** `styles.css` and its import `_ds_bundle.css`. Read them before styling.
- **Per component:** `<Name>.d.ts` (the props contract) and `<Name>.prompt.md` (usage).
- **Where to look first:**
  - Verdicts, significance and run identity: `Badge` / `EnvironmentBadge`.
  - Headline numbers: `KpiTile` / `HeroFigure`.
  - Charts: `TrendChart`, `DeltaBars`, `PairedDots`, `CallSiteTrend`, inside `ChartFrame`.

## Example
```tsx
import { KpiTile } from 'profiler-dashboard';

<section className="card">
  <h2 className="card-title">Benchmark_Max4Live</h2>
  <p className="card-subtitle">T0002 · PipeASIO realtime · bare metal</p>
  <div className="grid-kpi">
    <KpiTile label="DSP load average" value="10.0" unit="%" slot={4} source="outcome"
      baseline={{ value: '11.4', label: 'baseline aa-focusrite-1' }}
      delta={{ pct: 0.123, abs: 1.4, direction: 'better', significance: 'beyond', text: '▲ 12.3%' }}
      trend={[11.5, 10.9, 11.4, 11.1, 10.4, 10.0]} />
  </div>
</section>
```
