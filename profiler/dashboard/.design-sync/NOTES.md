# design-sync notes — profiler dashboard

## Setup
- The dashboard is an app, not a published library: `npm run build:lib` (vite.lib.config.ts +
  tsconfig.lib.json) builds `src/lib.ts` — the 19 synced components plus `theme.css` — into
  `dist-lib/` (`index.js`, `style.css`, `types/`). The converter runs with
  `--entry ./dist-lib/index.js --node-modules ./node_modules`; `cfg.cssEntry` = `dist-lib/style.css`.
- Excluded on purpose (not exported from `src/lib.ts`): chart-internal tooltips and legends
  (CallSiteTooltip, TrendTooltip, SvgTooltip, CallSiteLegend, PairedDotsKey) and the 7 page views,
  which need the whole DashboardData.
- Playwright for the render check: the converter folder pins `playwright@1.62.0`, matching the
  cached `chromium-1234` / `chromium_headless_shell-1234` under `%LOCALAPPDATA%\ms-playwright`.
- npm 12 skips esbuild's install script by default; esbuild still works (its Windows binary comes
  from the optional `@esbuild/win32-x64` package) — verified with a transform before the build.

## Decisions
- Fonts (user decision, 2026-10-17): keep system fonts. The dashboard's stacks are
  `system-ui, -apple-system, 'Segoe UI', sans-serif` and
  `ui-monospace, 'Cascadia Mono', 'Consolas', 'DejaVu Sans Mono', monospace`; no webfont ships,
  exactly like the real site. `[FONT_MISSING] "Cascadia Mono"` is expected and accepted.
- Palettes (user decision, 2026-10-17, made in Claude Design): light = **Spectrum** (template
  `templates/bright-theme`, tokens `spectrum-tokens.css`), dark = **Abyss** (`templates/dark-abyss`,
  `abyss-tokens.css`). The Overview layout and the app bar come from `templates/spectrum-overview`.
  All of this is synced back into `src/theme.css`, `src/palette.ts`, `src/App.tsx` and
  `src/views/Overview.tsx`. Token names are unchanged. Series and status colours keep their rules
  (fixed Set slots, status on dots only). The dataviz validator fails these palettes on some checks
  (DESIGN.md §7.4). The one that matters: in dark mode, Inbuilts lime and Max4Live amber are hard to
  tell apart. That is an open design question for the user.
- `templates/**` in the Claude Design project is the user's design work. It is not produced by
  this build. Never delete it (the plan's delete globs exclude it), and never overwrite it.

## Card layout (cfg.overrides, first sync 2026-10-17)
- **Column mode for wide components.** The capture viewport is 900 px, and a product grid cell has only
  ~306–390 px of content (cells clip). So every chart, table and table twin uses
  `{"cardMode":"column"}`: CallSiteTrend, DeltaBars, PairedDots, ChartFrame, DataTable, RunTable,
  FilterBar, CompareDrawer, TrialCard, CallSiteTrendTable, DeltaBarsTable, PairedDotsTable.
- **`primaryStory`.** DeltaBars needs `primaryStory: TracedConfirmation`, because cells sort
  alphabetically.
- **Grade keys.** `cardMode` and `primaryStory` are outside the grade key; `viewport` is inside it.
- **TrialCard: `viewport 1200x1900`.** The full card is 2.15k px tall at 900 px wide. At 1280 px its five
  PairedDots frames go four per row and the tick labels collide; at 1200 px they go three per row. Height
  1900 fits the longest story, because `~/…` run directories add a line under each run reference.
- **RunTable: `viewport 1280x700`** (the app's max width). The table's minimum width is ~1.75k px (machine
  id, device and run id cells are `nowrap`), so it scrolls sideways past Structure, as the Runs tab does.
  `viewport 2000x700` would show every column but scale to ~0.36× in the product.

## Authoring previews
- **Story order.** Cells follow the exports in alphabetical order, whatever the source order. In grid
  mode the canonical story is wherever its name sorts; in column mode, set `primaryStory`.
- **Never let a story's first rendered text be "⚠".** `package-capture` and `package-validate` read a
  mount whose text starts with U+26A0 as a caught render error, and the validator marks the component
  `bad`. `NoTimingRibbon` and the virtualised `EnvironmentBadge` chip render ⚠ first, so their stories
  open with a visible view title or run header, as in the app.
- **Story height.** Per-story captures are viewport shots (900×700), so keep stories under ~650 px tall
  unless the component has a `viewport` override.
- **Data.**
  - Previews inline compact copies of the real `profiler/history/runs/*.json` and `profiler/ledger.jsonl`;
    nothing is imported from the repo.
  - Call-site keys are `kind|name|frame <- frame …`, joined with ASCII ` <- `. Example:
    `syscall|NtWaitForSingleObject|kernelbase.dll!WaitForSingleObject+0x49 <- Ableton Live 12 Trial.exe+0x4f8c119`.
  - Some values are illustrative, as each story's comment says: the `abletonlinux-vm` runs, the
    "targeted by" evidence, and the traced-confirmation shares.
- **Unexported types** come from prop types: `RunTableProps['runs'][number]`, `TrialCardProps['join']`,
  `FilterBarProps['filter']`, `Run['sets'][string]`, `CallSiteTrendTableProps['slots']`.
- **Unexported helpers.**
  - `assignCallSiteSlots`: the previews re-rank inline (max share over runs × Sets, top 8 get slots 1–8).
  - `PairedDotsKey`: the ChartFrame key row rebuilds it from the shipped `tc-keyrow` / `pd-key-*` classes.
- **Type-check.** The preview build is esbuild-only. To type-check, use a scratch tsconfig with
  `paths: {"profiler-dashboard": ["dist-lib/types/lib.d.ts"]}`, strict and `noUncheckedIndexedAccess`.
- **No `id` on ChartFrame.** An `id` persists the chart/table choice in localStorage, so the card would
  change with what the viewer last clicked. Use `defaultView="table"` instead.
- **Table-twin widths.** DeltaBarsTable and PairedDotsTable are `width: 100%`. Wrap them in a
  460–520 px `maxWidth` div.
- **CompareDrawer.** At most 12 rows fit 900×700.

## Component findings (src/, not fixed by the sync — candidates for design work)
- **RunTable** never fits the app's 1280 px max width, so 5-Set rows are 5 lines tall. A fix:
  `white-space: nowrap` on `.rt-sets`, or Set initials.
- **TrialCard** keys guard chips by their text, so equal counts on two B runs (real T0002 data) render
  duplicate chips and duplicate React keys.
- **TrialCard's guard** treats any PipeWire error on B as a reject, which is wrong for dropout trials
  like T0003. It should be "not worse than A".
- **DataTable** empty-state centring loses to `table.data td { text-align: left }`.
- **PairedDots** tick labels overlap in frames narrower than ~290 px.
- **CallSiteTrend** legend buttons centre long caller chains: `.legend button` sets no `text-align`.
- **Ledger:** `metrics.xruns` of T0001/T0002 holds PipeWire error totals; T0003 onward records
  `xruns` and `pipewire_errors` separately.

## Known render warns
- `[FONT_MISSING] "Cascadia Mono"` — accepted (see Decisions).

## Re-sync risks
- `viewport` overrides are part of the grade key. Changing the TrialCard or RunTable viewport clears that component's grades.
- New stories that open with a serious-status chip or a ribbon trip the ⚠ check (see Authoring previews).
