# profiler/ledger.jsonl — the trial ledger (`ableton-linux-profiler-ledger/v1`)

One JSON object per line, one line per trial, append-only. `profiler/bin/ledger-report` validates
every line (exit 2 on any problem, the bad lines named on stderr) and renders the Markdown summary;
the dashboard reads the same file. Run ids are history run ids (`profiler/history/README.md`).

## Fields

All 16 keys are present on every line; `null` is allowed only where stated. Unknown keys, at any
level, are rejected.

| Key | Type | Rule |
|---|---|---|
| `schema` | string | `ableton-linux-profiler-ledger/v1` |
| `trial` | string | `T` + four digits, unique in the file; the next id is the "Next trial id" line of `ledger-report` |
| `date` | string | UTC ISO 8601 with `Z`, e.g. `2026-10-17T10:00:00Z`: when the verdict was written |
| `host` | string | `bare-metal`, or `vm:<value>` where `<value>` is `profile.json` `system.virtualization.value` of the cited runs (`vm:vmware`, `vm:kvm`, `vm:unknown`) |
| `branch` | string | `trial/<trial>-<slug>`, slug in `A-Za-z0-9._-` |
| `hypothesis` | string | one falsifiable sentence: mechanism, change, expected move of the primary metric |
| `evidence` | list | `{run, set, call_site, share_of_lost_slack}` per targeted call site; `share_of_lost_slack` in 0..1; may be empty for a `tooling` trial |
| `change` | object | `kind` in `wine-patch`, `pipeasio-patch`, `launcher`, `config`, `tooling`; `patch`, `probe`, `note`: repo-relative paths or `null`; `switch`: `NAME=value` or `null` |
| `probe_result` | object or null | `{pass, fail, skip, log}`: counts of the PE probe's PASS/FAIL/SKIP lines, `log` path or `null` |
| `runs` | object | `aa`: list of `[run, run]` A/A pairs; `abab`: list of `{a, b}` untraced interleaved pairs in run order; `traced`: `{a, b}` or `null` |
| `metrics` | object or null | `primary`: history metric key measured by untraced runs (`live_cpu_pct_per_core`, `voluntary_switches_per_s`, `dsp_peak`, …); `per_set`: `{<Set>: {a_median, b_median, aa_spread, delta, ratio_to_spread}}` with `delta = b_median - a_median` and `ratio_to_spread = |delta| / aa_spread`; `xruns` and `cpu_live_pct`: `{a, b}` or `null` |
| `traced_confirmation` | object or null | `{call_site_share_before, after}`: `share_of_lost_slack` of the targeted call site in the traced A and B runs |
| `verdict` | string | `keep`, `revert`, `inconclusive`, `tooling`, `mechanism-confirmed` |
| `rationale` | string | the numbers behind the verdict |
| `commit` | string or null | 7–40 hex characters: the commit that holds the change on the trial branch (made before the measurements; the ledger line and the history files follow in the record commit); `null` when the trial changed no tracked file |
| `minutes` | number or null | wall-clock minutes from branch creation to the record commit |

Paths and ids: runs are cited by history run id (`profiler/history/runs/<run_id>.json`), never by
directory; `change.patch`, `change.probe` and `change.note` are repo-relative; `probe_result.log`
is `~/`-relative (`~/.local/state/profiler/logs/…`). No absolute machine paths.

## Verdict rules (enforced by `ledger-report`)

- `keep` needs at least one A/A pair, at least three A/B pairs, `runs.traced`, `metrics` with
  `per_set` and `xruns = {a: 0, b: 0}`, `probe_result` with `fail = 0`, and `change.switch`,
  `change.probe` and `change.note` set. The gate itself (median improvement of the primary metric
  beyond 2 × the A/A spread, no Set regressing beyond the spread, PipeWire `ERR` = 0, official
  runtime) is the agent's judgement and goes into `rationale`.
- `mechanism-confirmed` needs `runs.traced` and `traced_confirmation`.
- On a virtualised host (`host` = `vm:…`) only `tooling` and `mechanism-confirmed` exist: every
  other verdict is a timing claim. A VM trial whose mechanism did not confirm is `tooling` with
  the traced numbers in `rationale` (`AGENT-PROMPT.md` counts it towards the stop rule).
- `revert` records a regression, a guard hit (xrun, `ERR`) or a probe FAIL; `inconclusive` a
  result inside the noise or a trial the budget cut short.

## Appending a line

```bash
python3 - <<'EOF' >> profiler/ledger.jsonl
import json
line = {
    "schema": "ableton-linux-profiler-ledger/v1", "trial": "T0007", "date": "2026-10-17T10:00:00Z",
    # ... every field from the table above ...
}
print(json.dumps(line, separators=(",", ":")))
EOF
profiler/bin/ledger-report > /dev/null        # must exit 0 before the record commit
```

Never edit or delete a line. A correction is a new trial whose `rationale` names the old one.
Commit the line together with the `profiler/history/runs/*.json` files it cites (`CLAUDE.md`).

## Example (one line in the file; shown wrapped)

```json
{"schema":"ableton-linux-profiler-ledger/v1","trial":"T0007","date":"2026-10-17T10:00:00Z","host":"bare-metal",
 "branch":"trial/T0007-ntsync-wait-coalesce",
 "hypothesis":"Coalescing NtWaitForSingleObject wake-ups on the audio workers lowers Live CPU per core on Benchmark_VSTs",
 "evidence":[{"run":"20261016T120000Z-baseline-traced","set":"Benchmark_VSTs","call_site":"ntsync_wait|NtWaitForSingleObject|ntdll+0x7f3a1","share_of_lost_slack":0.62}],
 "change":{"kind":"wine-patch","patch":"patches/0108-ntdll-coalesce-waits.patch","switch":"WINE_WAIT_COALESCE=1","probe":"tools/waitprobe.c","note":"notes/ABLETON-WINE-WAIT-COALESCE.md"},
 "probe_result":{"pass":5,"fail":0,"skip":1,"log":"~/.local/state/profiler/logs/20261017T100000Z-waitprobe.log"},
 "runs":{"aa":[["20261017T100000Z-T0007-AA1","20261017T101000Z-T0007-AA2"]],
         "abab":[{"a":"20261017T102000Z-T0007-A1","b":"20261017T103000Z-T0007-B1"},{"a":"20261017T104000Z-T0007-A2","b":"20261017T105000Z-T0007-B2"},{"a":"20261017T110000Z-T0007-A3","b":"20261017T111000Z-T0007-B3"}],
         "traced":{"a":"20261017T112000Z-T0007-traced-A","b":"20261017T113000Z-T0007-traced-B"}},
 "metrics":{"primary":"live_cpu_pct_per_core",
            "per_set":{"Benchmark_VSTs":{"a_median":41.2,"b_median":39.9,"aa_spread":0.5,"delta":-1.3,"ratio_to_spread":2.6}},
            "xruns":{"a":0,"b":0},"cpu_live_pct":{"a":41.2,"b":39.9}},
 "traced_confirmation":{"call_site_share_before":0.62,"after":0.11},
 "verdict":"keep",
 "rationale":"Median Live CPU on Benchmark_VSTs fell 1.3 points, 2.6x the A/A spread of 0.5; no Set moved beyond its spread; xruns and ERR 0 in every B run; traced share 0.62 -> 0.11 on the official runtime.",
 "commit":"abc1234def56","minutes":95}
```
