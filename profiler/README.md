# profiler/ — Wine interface profiler for Ableton Live on Linux

This directory holds the workbench that measures and improves how Ableton Live runs under
this repository's Wine fork. It sets up the machine, drives Live without a person
(AbletonOSC), traces the Wine ↔ Linux interface (eBPF/USDT), keeps a ledger of trials and
shows the results on a dashboard. Upstream never touches `profiler/`, so rebasing the fork
does not conflict. Wine and PipeASIO patches still go where the build audit expects them
(`patches/NNNN-*.patch`, `patches/pipeasio/NNNN-*.patch`).

**Runtime state never lives in the repository.** `build.sh` snapshots every non-ignored
file into `/tmp` and aborts if the tree changes while it builds. Logs, runs, snapshots
and caches therefore all live under `~/.local/{state,share}/profiler` and
`~/.cache/profiler` (see "Where state lives" below).

## Layout

| Path | What it is |
|---|---|
| `setup/setup-machine.sh` | machine setup, phase by phase (table below); idempotent, resumable |
| `setup/verify.sh` | read-only post-setup gate: every phase check plus extra probes; exit 0 only when all hard checks pass |
| `setup/bootstrap.md` | the Windows-side steps: SSH alias, git bundle, installer media, the setup command |
| `setup/lib/` | `log.sh` (colour, log, summary table, `run`), `phase.sh` (registry, runner, markers, `--dry-run`; its header documents the phase conventions), `host.sh` (read-only PipeWire and power-supply probes) |
| `setup/phases/NN-name.sh` | one file per phase |
| `setup/templates/` | files written to the host (`@@VAR@@` tokens) |
| `setup/root-helper/profiler-root-helper` | the allowlisted root entry point (`/usr/local/sbin/`, `sudo -n`): host-knob baseline/reset, knobs, trace start/stop |
| `setup/plugins.lock` | pinned URLs and sha256 digests of the Dexed and K1v VST3 fixtures |
| `bin/with-session-env` | run a command inside the logged-in Plasma session (DISPLAY, XAUTHORITY, DBUS) from SSH |
| `bin/state` | `snapshot` / `restore` / `diff` / `list` / `remove` / `clean-crash` of the prefix and Live state ("golden") |
| `bin/bench` | `scripts/bench-suite.sh` wrapper: AbletonOSC ports, session env, run dir outside the repo, speaker mute, battery refusal |
| `bin/trace-prereqs` | tracer prerequisites table (BTF, uprobes, bpftrace, USDT notes, NTSync, privilege route) |
| `bin/wine-trace` | the tracer front end (bpftrace prototype / libbpf loader) |
| `bin/history-add`, `bin/ledger-report` | append run results to `history/`, report the trial ledger |
| `dev/wine-dev.sh` | persistent-container dev loop for Wine/PipeASIO (20–60 s iterations) |
| `dev/build-official.sh` | the "keep" gate: locked `./build.sh` + `installer.sh runtime install` + build audit |
| `control/` | AbletonOSC (vendored + bench handler overlay), `liveosc.py` client, scenario runner, smoke test |
| `scenarios/` | scripted Live workloads (JSON, `SCHEMA.md`) |
| `tracer/` | BPF programs, probe tables, symbolizer |
| `dashboard/` | Vite + React gains dashboard (served by the `profiler-dashboard` user unit, port 5173) |
| `history/`, `ledger.jsonl`, `LEDGER.md` | run history and the trial ledger (committed) |
| `AGENT-PROMPT.md` | the loop Claude Code follows on the profiler machine |

## Setup phase map

`profiler/setup/setup-machine.sh --profile baremetal --passwordless-sudo --autologin` (the
laptop) or `--profile vm`. Options persist to `~/.config/profiler/setup.conf`, so re-runs
need no flags. `--list-phases` prints this table along with each phase's done-marker.

| # | phase | needs | does |
|---|---|---|---|
| 00 | `preflight` | – | read-only host audit: distro, x86-64-v3, kernel ≥ 6.14, NTSync, BTF, uprobes, RAM/disk//tmp, power (AC/battery), hybrid P/E topology, cpufreq/EPP/power profile, ananicy-cpp, GPUs, Wi-Fi vs Ethernet, display manager, lid policy, audio device; records `host-facts.env` |
| 01 | `sudo` | – | one sudo prompt; NOPASSWD rule (`--passwordless-sudo`), root helper + its sudoers rule, host-knob baseline |
| 02 | `packages` | sudo | `pacman -Syu`, then the build/trace/desktop tool set; ananicy-cpp off (through the helper) |
| 03 | `podman` | packages | rootless podman: subuids, migrate, linger, overlay driver |
| 04 | `limits` | packages | `realtime`/`audio` groups, RT limits (`scripts/setup-realtime.sh`), nofile, sysctls |
| 05 | `session` | packages | Plasma Login Manager (or SDDM) autologin, no lock/DPMS/suspend, inhibit unit, laptop lid policy, Wi-Fi power save off, `with-session-env` |
| 06 | `audio` | packages | PipeWire clock (min-quantum 32, 48 kHz), `profiler-null` sink, the PipeASIO device (`--audio-device`: `builtin` = the speaker sink, muted), recorded as `audio_node=` |
| 07 | `repo` | packages | branch `profiler`, `aceb236` ancestry, LF config, `bench/` restored and excluded |
| 08 | `media` | – | Live 12 Trial installer + 3 slices, pinned sha256 |
| 09 | `build` | podman, repo, media | `./build.sh` (Wine + PipeASIO, rootless podman, ~1 h cold) under `build.lock`, then `scripts/build-audit.sh` |
| 10 | `install` | build, session, audio | `scripts/installer.sh install` (runtime, prefix, Live 12; baremetal: `--power=performance --audio-buffer=64`), PipeASIO pointed at `audio_node` |
| 11 | `plugins` | install | Dexed + K1v VST3 from `plugins.lock` |
| 12 | `osc` | install | AbletonOSC into Live's User Library (`control/install.sh`) |
| 13 | `human` | install, osc, session | the one interactive step: first launch, licence, ASIO/PipeASIO, AbletonOSC, Ctrl+Q |
| 14 | `golden` | human | `post-install` and `golden` snapshots (`bin/state`); never replaced implicitly |
| 15 | `tracecheck` | packages, install | `bin/trace-prereqs` + `scripts/check-ntsync.sh` (in a throwaway clone of the prefix) |
| 16 | `claude` | – | Claude Code native install, PATH for fish and bash (`bash -lc`) |
| 17 | `dashboard` | packages | `npm ci` + user unit `profiler-dashboard.service` |
| 18 | `summary` | – | machine state, outstanding actions, next commands |

Exit codes: 0 ok · 1 a phase failed (re-run the same command to resume) · 2 usage ·
3 log out and back in, or reboot, then re-run. `--dry-run` previews every phase and changes
nothing: it never calls sudo, writes no log and saves no options. `--only P[,P]`,
`--skip P[,P]`, `--from P` and `--force` select phases. Each phase has a read-only `check`
and an `apply`; the conventions are at the top of `setup/lib/phase.sh`.

## Running setup and verify

From Windows (the login shell on the target is fish, so everything goes through `bash -lc`):

```powershell
# first run (one sudo prompt; see setup/bootstrap.md for the steps before it)
ssh -t ableton-laptop 'bash -lc "~/Projects/ableton-linux/profiler/setup/setup-machine.sh --profile baremetal --passwordless-sudo --autologin"'
# later runs, e.g. after exit code 3 (re-login/reboot) or to finish deferred phases
ssh -t ableton-laptop 'bash -lc "~/Projects/ableton-linux/profiler/setup/setup-machine.sh"'
# read-only gate; --quick skips the slow probes, --no-sudo never calls sudo, --list shows the checks
ssh -t ableton-laptop 'bash -lc "~/Projects/ableton-linux/profiler/setup/verify.sh"'
```

On the laptop, `profiler/bin/bench --dry-run --tag smoke` and then `--tag baseline` are the
first measurements. `bench` mutes the speaker sink before every run and refuses to measure
on battery (`--allow-battery` overrides).

## Where state lives

| Path | Contents |
|---|---|
| `~/.config/profiler/setup.conf` | saved options and recorded facts (`profile`, `audio_device`, `audio_node`, `audio_input`, `audio_mute`, `user_library`, …) |
| `~/.config/profiler/env` | optional `KEY=VALUE` lines sourced by both shells, e.g. `CLAUDE_CODE_OAUTH_TOKEN` (mode 0600) |
| `~/.local/state/profiler/` | `setup-*.log` (`setup-latest.log`), `phases/NN-name.done` markers, `host-facts.env`, `build-*.log`, `build-audit.env`, `tracecheck.env`, `verify/` logs and `verify-last.env`, `build.lock`, `dev/` (dev-loop state) |
| `~/.local/share/profiler/` | `golden/<name>/` snapshots, `runs/<UTC>-<tag>/` bench and trace output |
| `~/.cache/profiler/` | plug-in downloads, audit scratch (kept off the `/tmp` tmpfs) |
| `~/.local/opt/wine-d2d1-nspa-11.13[-dev]` | the official runtime, and the dev runtime that `wine-dev.sh sync` maintains |
| `~/.wine-ableton` | the Wine prefix with Live 12 |
| `/var/lib/profiler/baseline.env`, `/var/log/profiler-root-helper.log` | the root helper's host-knob baseline and its log |

**Snapshots and the runtime.** `bin/state` snapshots the prefix, Live's configuration and
data, the PipeASIO and PipeWire configuration and the User Library. It records the Wine
runtime by identity only (sha256 of its `ABLETON-WINE-BUILD-INFO.txt`) and never copies it
or restores it. A runtime changes only through a deliberate install. `dev/build-official.sh`
is the keep gate, and the `state restore --name golden` before the next trial leaves that
new runtime in place and reports "runtime changed since the snapshot". `state snapshot`
refuses to replace an existing snapshot unless you pass `--rebaseline`, which keeps the
previous one as `NAME.<UTC>`.

## Dev loop in short

1. `profiler/dev/wine-dev.sh init` creates a persistent `wine-dev` container from the
   official build image. It uses the same patch series, configure flags and ccache, and
   tags `series-main` (end of the numbered series) and `series-aceb236`.
2. Edit `~/wine-dev/work/wine-src` on the host, one commit per change.
3. `wine-dev.sh build --dir dlls/ntdll`, then `wine-dev.sh sync --artifacts --dir dlls/ntdll`.
   The sync copies the PE modules and the unix `.so` into
   `~/.local/opt/wine-d2d1-nspa-11.13-dev`.
4. A/B on the dev runtime with one switch flipped (`ABLETON_WINE_ROOT=…-dev`, `WINE_X=0`
   vs `WINE_X=1`, interleaved, n ≥ 3) through `profiler/bin/bench`.
5. `wine-dev.sh format-patch --number NNNN --name slug` exports the patch with host git
   config masked and rehearses the official patch order in a throwaway worktree. It also
   prints the build-audit checklist.
6. Keep gate: `profiler/dev/build-official.sh` runs the official build, the runtime
   install and the audit, and records `build-audit.env`. Repeat the A/B on the official
   runtime and record the verdict in the ledger.

`wine-dev.sh` and `build-official.sh` share `~/.local/state/profiler/build.lock` and
`wine-dev.lock` with setup phase `build`, so only one build runs at a time. None of them
replaces a runtime while Live or a wineserver is using it.

## Plans and design notes

The design documents live outside the repository, next to the checkout on the Windows
host (`../../plans/` relative to this directory):

- `../../plans/wine-interface-profiler-plan.md`: the overall plan
- `../../plans/design-A-setup-and-dev-loop.md`: setup script, root helper, `verify.sh`, dev loop
- `../../plans/design-B-tracer-and-probes.md`: tracer, USDT probes, symbolizer
- `../../plans/design-C-control-suite-agent-loop.md`: AbletonOSC control, scenarios, agent loop
- `../../plans/research-install-and-launch.md`, `../../plans/research-build-system.md`: verified facts about the repository
- `../../plans/resume-plan.md`: the current block plan and the target-machine facts
