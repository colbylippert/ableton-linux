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
- Chart colours come from the validated dataviz palette in `src/theme.css` (DESIGN.md §7);
  restyling may change layout, type and chrome, but series/status colours keep their rules.

## Known render warns
- `[FONT_MISSING] "Cascadia Mono"` — accepted (see Decisions).
