# Profiler gains dashboard

A static Vite + React 18 + TypeScript site that shows the gains the profiler loop achieves
over time: benchmark outcomes (CPU, context switches, xruns), interface metrics (late and
near-late audio blocks, slack, lost slack per call site), the trials in the ledger and
their verdicts. There is no backend: the site reads the committed data files directly.

Design, metric registry, chart rules and component contracts: [`DESIGN.md`](./DESIGN.md).

## How data gets in

| File | Written by | What it holds |
|---|---|---|
| `profiler/history/runs/<run_id>.json` | `profiler/bin/history-add RUN_DIR [--trial T --arm A\|B\|AA] [--baseline]` after every suite run | one compact summary per run (`ableton-linux-profiler-history/v1`) |
| `profiler/history/baselines.json` | `history-add … --baseline` | `{ machine_id: { "<structure>/<scenario or ->": run_id } }` |
| `profiler/ledger.jsonl` | the agent loop, one JSON line per trial (`ableton-linux-profiler-ledger/v1`) | hypothesis, runs, metrics, verdict |

The site imports these with `import.meta.glob('../../../history/runs/*.json', { eager: true })`
and `import ledger from '../../../ledger.jsonl?raw'` (paths relative to `src/data/`), so with
the dev server running a new run or ledger line appears through HMR as soon as the file is
written — no exporter, no restart. `vite.config.ts` allows the dev server to serve files from
the parent `profiler/` directory (`server.fs.allow`) and sets `base: './'` so the built
`dist/` works from any static host or sub-path.

Rules the dashboard follows (see `DESIGN.md` for the full list):

- **Outcome** metrics come from untraced runs, **interface** metrics from traced runs; the
  two are never mixed in one comparison, and runs with different trace modes are never
  compared (same rule as `bench-report.py compare`).
- Runs from a virtualised host (`virtualization != "none"`) carry a **NO TIMING CLAIMS**
  ribbon and are never compared with bare-metal runs.
- The baseline for a (machine, structure/scenario, Set, metric) is the run named in
  `baselines.json`; without one, the earliest run of that identity with no switches and no
  trial. Positive delta = improvement, whatever the metric's direction. Significance is
  judged against the A/A spread (`|delta| > 2 × spread` = beyond noise).

## Running

Requirements: Node `^22.22.2 || ^24.15.0 || >=26` (the `engines` field; jsdom sets the floor)
and npm. Everything runs from this directory.

```bash
cd profiler/dashboard
npm install            # once (and after dependency changes); node_modules/ is gitignored
npm run dev            # http://localhost:5173, HMR on history/ and ledger.jsonl
npm run build          # typecheck + production build into dist/ (gitignored)
npm run preview        # serve dist/ locally
npm test               # Vitest (jsdom)
npm run typecheck      # tsc --noEmit
```

### On the Linux VM (served to the Windows host)

The setup script installs a user unit `profiler-dashboard.service` that runs the dev server
bound to all interfaces so `http://abletonlinux:5173` works from Windows:

```ini
# ~/.config/systemd/user/profiler-dashboard.service
[Unit]
Description=Profiler gains dashboard (Vite dev server)
After=network.target

[Service]
WorkingDirectory=%h/Projects/ableton-linux/profiler/dashboard
ExecStart=/usr/bin/npm run dev -- --host 0.0.0.0 --port 5173
Restart=on-failure
Environment=NODE_ENV=development

[Install]
WantedBy=default.target
```

```bash
systemctl --user daemon-reload
systemctl --user enable --now profiler-dashboard.service
journalctl --user -u profiler-dashboard -f      # logs
```

`npm install` must have been run once in `profiler/dashboard` before enabling the unit.
Because the data files are imported at module evaluation, `history-add` and ledger appends
show up live; a `git pull` that brings new history files does too.

For a static deployment (no Node on the host), run `npm run build` and serve `dist/` with any
static file server (`python3 -m http.server --directory dist 8080`, nginx, …). The build
inlines the data files, so rebuild after new runs land.

### On Windows (development)

Node and npm are on `PATH`. Fetch the VM's history first so the data is current:

```powershell
git fetch vm                                     # remote vm = ssh://abletonlinux/home/colby/Projects/ableton-linux
git merge --ff-only vm/profiler                  # or check out the branch you want to look at
cd profiler\dashboard
npm install
npm run dev
```

The repo's `.gitattributes` keeps `profiler/**` at LF endings on every platform; do not
let an editor convert the dashboard sources to CRLF.

## Layout

```
profiler/dashboard/
├── DESIGN.md            metric registry, views, component contracts, data-layer API, palette + validator output, test plan
├── README.md            this file
├── index.html           title "Profiler gains"; theme applied before first paint
├── package.json         scripts: dev / build / preview / test / typecheck
├── tsconfig.json        strict TypeScript, bundler resolution
├── vite.config.ts       react plugin, base './', server.host, server.fs.allow (profiler/), vitest (jsdom)
└── src/
    ├── main.tsx         mounts <App data={loadDashboardData()} />
    ├── App.tsx          tab shell (hash-linked tabs, theme toggle, FilterBar state)
    ├── App.test.tsx     shell smoke tests
    ├── theme.css        design tokens (light + dark) and base layout
    ├── data/
    │   ├── types.ts     Run, SetMetrics, Baselines, Trial + dashboard contracts (FilterState, MetricDef, GainRow, …)
    │   └── load.ts      loadDashboardData() seam — replaced by the real loaders (history / baselines / ledger)
    └── views/           Overview, Trends, Trials, CallSites, Scenarios, Runs (default-exported components, props = ViewProps)
```

Dependencies are deliberately minimal: `react`, `react-dom`, `recharts` at runtime;
`vite`, `typescript`, `vitest`, `@vitejs/plugin-react`, `@types/react`, `@types/react-dom`,
`jsdom` for development. No CSS framework — plain CSS with tokens in `src/theme.css`.
