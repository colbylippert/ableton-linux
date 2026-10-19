# profiler/trials: trial drivers and scoring tools

These run on the laptop from the checkout (`~/Projects/ableton-linux`). They are the headroom campaign's drivers and tools (T0021 onward), moved here from `~/.local/state/profiler/` (I0 in `profiler/plans/kernel-plan.md`). Each trial is pre-registered in `profiler/plans/resume-plan.md` or `kernel-plan.md` before it runs.

| File | What it does |
|---|---|
| `trial-lib.sh` | Shared driver code: the session lock, environment, pinning watchers (`shared`, `1to1`, `physcore`), `run_one`, `traced_one`, `campaign_main` (ABAB × 3, history records, traced runs) |
| `trial-T00NN.sh` | One driver per trial: it defines the arm hooks (`arm_env`, `arm_setup`, `arm_teardown`, `pin_for`, `golden_for`, `arm_describe`, `arm_record`, optional `traced_runs`) and calls `campaign_main` |
| `campaign_tools.py` | `affinity`, `audiocpu`, `rule-h TRIAL`, `rule-d TRIAL [G4_POINTS]`, `breakdown`; the scorers print a JSON verdict as their last line |
| `ledger_campaign.py` | Prints a trial's ledger line from a spec JSON and the scorer's JSON (nothing is written) |
| `reboot-lib.sh`, `reboot-waiter.sh` | Reboot-per-run trials (K2, K6), ported from T0015: the laptop runs one step per boot (`DRIVER start\|step\|status\|selftest`; one-shot `grub-reboot` into each run's boot variant, which is checked from `/proc/cmdline`; boot timers stopped and the load settled; RAPL power and temperature sampled); the waiter on the controlling host starts each step after a boot |
| `d0003-capture` | Bench-tracer stand-in (`ABLETON_BENCH_TRACER`, with `ABLETON_BENCH_ROOT_HELPER=/nonexistent`): block markers, scheduler and fault events, perf; `D0003_LIGHT=1`, or a `d0003-capture-light` symlink, records blocks only |
| `d0003_analyze.py`, `d0003_faults.py` | Analyse a `d0003-capture` output directory (late blocks; page-fault sources) |

## Running a trial

```sh
cd ~/Projects/ableton-linux
KEPT_LAYOUT=physcore KEPT_WORKERS=5 setsid -f bash -c \
  'profiler/trials/trial-T0024.sh > ~/.local/state/profiler/trial-T0024.out 2>&1 < /dev/null' > /dev/null 2>&1
```

- The driver takes `~/.local/state/profiler/live-session.lock`, so it never overlaps another Live session.
- Progress goes to the `.out` file: one `RUN` line per run, then `ABAB_DONE` and `TRIAL_DONE`.
- Nothing else heavy may run on the laptop while a trial measures.

## Scoring and recording

```sh
python3 profiler/trials/campaign_tools.py rule-h T0024 | tail -n 1 > /tmp/rule.json   # or: rule-d T0025 15
python3 profiler/trials/ledger_campaign.py spec-T0024.json /tmp/rule.json             # prints the ledger line
```

The ledger line goes into `profiler/ledger.jsonl`, and `profiler/history/runs/trial-T00NN-*.json` into the commit, from the workstation checkout.
