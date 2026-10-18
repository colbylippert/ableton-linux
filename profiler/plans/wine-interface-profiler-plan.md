# Wine Interface Profiler for Ableton Live on Linux — execution plan

Date: 2026-10-16 · Baseline: shibco/ableton-linux `main` @ `aceb236` · Local fork branch: `profiler`

## 1. Context

Ableton Live runs on Linux through this project's patched Wine fork and the PipeASIO driver. The repo measures *outcomes* (benchmark suite: CPU, context switches, xruns) and *callback timing* (PipeASIO telemetry), but nothing explains **why** an audio block ran late: no tool traces the Windows→Wine crossings (NT syscalls, unix calls, wineserver requests, NTSync waits) and joins them to audio blocks. The project's own notes stall on exactly that gap ("did not identify the busy thread's call path"; APC fast-path "awaits loaded-Set evidence").

This plan builds that missing layer and the machinery around it so that **Claude Code agents, running inside a Linux machine, can run the whole loop from one prompt**: set up the machine from a clean state, trace, rank call sites, propose Wine-side fixes behind opt-in switches, rebuild, benchmark, keep/revert, and show gains over time on a web dashboard.

Decisions already made (user):
- Claude Code runs **inside the VM** (native install); human logs in once over SSH / VS Code Remote-SSH.
- **Passwordless sudo** for `colby` on the dev VM; an allowlisted root helper is still built for bare metal.
- Goal: **profile the entire app, with the audio engine and latency as the focus** (all threads, bucketed by role; audio-block join is the primary analysis).
- **Local fork for now**, house style kept so PRs stay possible later.
- **AbletonOSC (MIDI Remote Script)** replaces the deleted Max-for-Live control device and drives scripted test scenarios.
- **Gains over time**: a Vite + npm web dashboard with graphs.
- Setup script: **bash, colourful, meaningful output**.

Non-goals (unchanged from the proposal): never modify/hook/disassemble Live (frames stay `module+offset`; reading the import table is allowed); no timing claims from the VM; no general-purpose Windows profiler.

## 2. Findings from Phase 0 that change the original proposal

| Finding (verified) | Consequence |
|---|---|
| `bench/` (5 Sets, SHA256SUMS, M4L device, guides) was deleted **by `aceb236` itself**, together with the README credit to the Sets' author. Recoverable from `aceb236^` (`72a6492`, 4.6 MB). | Treat as withdrawn upstream: restore locally via `git archive 'aceb236^' bench`, keep it out of git with `.git/info/exclude`, never redistribute. |
| Supported build is a **rootless Podman** build (Ubuntu 22.04 image, pinned LLVM 21.1.8) with **no incremental mode**; every `build.sh` run re-extracts, re-patches, re-configures, recompiles (ccache only). `build.sh` snapshots every non-ignored file into `/tmp` and aborts if the tree changes mid-build. | Add a persistent dev container (`wine-dev`) mirroring `container-build.sh` for sub-minute iterations; official build only for "keep" gates. All run output lives outside the repo. |
| The Windows checkout has CRLF in 482 files (global `core.autocrlf=true`); blobs are LF. | Move code to the VM as a `git bundle`, never scp the worktree. |
| Wine's syscall and unix-call dispatchers are hand-written asm; the PE stub reaches the dispatcher via `callq *(0x7ffe1000)`, so the return address seen is always `ntdll!NtXxx+0x14`. MSVC images have no frame pointers. | USDT in asm via `STAP_PROBE_ASM`; caller attribution needs a captured stack window + offline PE `.pdata` unwinding (not optional). |
| Wine 11.13 already writes `SetThreadDescription` names into `/proc/PID/task/TID/comm` (`thread.c:2034-2069`). `RtlQueryPerformanceCounter` always syscalls. `ws2_32` has no unixlib. | Thread roles come from `comm`; validation probe uses QPC; unix-call validation uses `winscard`/`dwrite`. |
| PipeASIO 64-bit is a winelib ELF (`pipeasio64.dll.so`, gcc-built), so plain C `STAP_PROBEn` works; telemetry ring holds deltas only (no absolute time, deadline or sequence). | Block-marker patch adds `seq`, absolute `clock_nsec`, `next_nsec`-based deadline, and `block_range=`/`late=` on telemetry lines. |
| The old control device only did ping/play/stop/rewind/poll/cpu-period and read `Application.average_process_usage`/`peak_process_usage` — AbletonOSC's own `application.py` already exposes that attribute. | A `bench` handler in an AbletonOSC fork speaks the suite's exact `/abl/bench/*` protocol with no Max runtime. |
| The Live installer is Inno Setup; the project already runs it silently (`/SILENT /SUPPRESSMSGBOXES /NORESTART /MERGETASKS=!audiodriver`). Only three steps are unavoidably manual: first launch (licence/trial), Audio → ASIO → PipeASIO, Control Surface → AbletonOSC. | Setup script has one interactive "human" phase, then takes the golden prefix snapshot. |
| VM: CachyOS, kernel 7.2.9 (NTSync, BTF, uprobes, BPF JIT), PipeWire 1.6.9, 8 vCPU, **8 GiB RAM**, 490 GB btrfs, fish login shell, Plasma Wayland session with Xwayland `:0`, no Xvfb/xdotool/podman/bpftrace/perf/cmake/node yet, sudo needs password, `/tmp` is a 3.9 GB tmpfs, PipeWire `min-quantum` is 1024. Host: 24 threads / 31.7 GiB. | Setup installs everything; recommend raising VM RAM to 16 GiB (power off, `.vmx memsize=16384`); PipeWire quantum limits must be lowered; `DISPLAY` must be injected from the user session for anything launched over SSH. |

## 3. Topology and repository layout

```
Windows host (this session)            CachyOS VM "abletonlinux" (dev, Phase A)      Bare metal (Phase B, later)
C:\src\AbletonLinux\ableton-linux  --bundle-->  ~/Projects/ableton-linux (canonical)     same setup script, --profile baremetal
C:\src\AbletonLinux\AbletonInstaller --scp--->  ~/Proprietary/ableton/
VS Code + Remote-SSH / ssh -t ... claude        Claude Code runs here
http://abletonlinux:5173 (dashboard)  <-------  vite dev server (user systemd unit)
```

New top-level directory **`profiler/`** on branch `profiler` (based on `aceb236`). Reason: `scripts/` is policed by 22 `make test` gates (e.g. `test-installer-ui.sh` dictionary checks), `tools/` is PE probes, `beta/` has its own SHA256SUMS; `profiler/` never conflicts with upstream rebases. Wine/PipeASIO patches still go where the audit expects them (`patches/0108-…`, `patches/pipeasio/0017-…`).

```
profiler/
├── README.md                 overview, bootstrap, phase map
├── .gitignore                *.log runs/ scratch/ __pycache__/ dashboard/node_modules dashboard/dist
├── AGENT-PROMPT.md           the single prompt (§10)
├── ledger.jsonl              one JSON line per trial (committed)
├── history/                  compact per-run summaries + baselines.json (committed; dashboard input)
├── setup/                    setup-machine.sh, verify.sh, lib/{log,phase}.sh, phases/NN-*.sh, templates/, root-helper/, plugins.lock, bootstrap.md
├── bin/                      with-session-env, state, bench (suite wrapper), wine-trace, profile-app, trace-prereqs, history-add, ledger-report
├── dev/                      wine-dev.sh, container/init.sh, container/pipeasio-init.sh, build-official.sh
├── tracer/                   wine-trace.bt, wine-trace.bpf.c, wine-trace.c, Makefile, symbolize.py, reduce.py, roles.toml, tables/, gen_tables.py, validate.py, flamegraph.py, tests
├── control/                  VENDOR.txt, vendor.sh, vendor/AbletonOSC/, overlay/{manager.py,abletonosc/bench.py}, install.sh, liveosc.py, scenario-run.py, smoke-test.sh, tests
├── scenarios/                *.json + SCHEMA.md
├── sets/                     optional saved scenario Sets + SHA256SUMS
└── dashboard/                Vite + React + TS site (§11)
CLAUDE.md                     repo root (§10)
.claude/commands/profiler-loop.md
patches/0108-ntdll-add-static-trace-points.patch, patches/pipeasio/0017-usdt-block-markers.patch
tools/traceprobe.c, tools/build_traceprobe.sh
scripts/bench-suite.sh, bench-run.sh, bench-report.py, bench-osc.py, build-audit.sh (modified; see §8–9)
```

Conventions: `.gitattributes` adds `profiler/** text eol=lf` and `*.sh text eol=lf`. Raw run output goes to `~/.local/share/profiler/runs/<run-id>/` (outside the repo); compact summaries are committed under `profiler/history/`. Windows mirror: `git remote add vm ssh://abletonlinux/home/colby/Projects/ableton-linux` and only `git fetch vm`.

## 4. Workstream A — machine setup script `profiler/setup/setup-machine.sh`

Bash (`#!/usr/bin/env bash`, `set -euo pipefail`, `LC_ALL=C.UTF-8`), run as `colby`; over SSH: `ssh -t abletonlinux 'bash -lc "~/Projects/ableton-linux/profiler/setup/setup-machine.sh --profile vm"'` (login shell is fish, so always `bash -lc`).

**Flags:** `--profile vm|baremetal` · `--live-installer PATH` (default `~/Proprietary/ableton/Ableton Live 12 Trial Installer.exe`) · `--repo-dir` (default `~/Projects/ableton-linux`) · `--jobs N` · `--audio-buffer 64..1024` (vm 128, baremetal 64) · `--passwordless-sudo` (vm default on) · `--autologin` (vm default on) · `--vm-ram-check` · `--yes` · `--dry-run` · `--only P[,P]` / `--skip P[,P]` / `--from P` · `--force` · `--list-phases` · `--no-color`. Options persist to `~/.config/profiler/setup.conf`. Exit: 0 ok · 1 phase failed · 2 usage · 3 re-login/reboot required.

**Output library `setup/lib/log.sh`:** colour only on a tty with `NO_COLOR` unset; UTF-8 glyphs when the locale is UTF-8; every line timestamped; `section N/TOTAL name` (bold cyan rule), `step →`, `ok ✓` green, `warn ⚠` yellow (counted), `fail ✗` red (aborts phase), `skip ↷` dim, `info i`, `kv key value`; `run [--sudo] [--timeout S] -- cmd…` prints the command, honours `--dry-run`, streams output indented into the log (`~/.local/state/profiler/setup-<ts>.log`, `setup-latest.log` symlink; ANSI stripped in the file) and shows the last 20 lines on failure; final **summary table** (phase · status · wall time · note) + WARNINGS + ACTIONS REQUIRED + log path.

**Phase framework `setup/lib/phase.sh`:** each `phases/NN-name.sh` defines `phase_<name>_check` (read-only; 0 = desired state present) and `phase_<name>_apply`; runner skips when check passes (unless `--force`), applies, re-checks, writes an advisory marker `~/.local/state/profiler/phases/NN-name.done`. Idempotent and resumable. `sudo -v` once, then a keepalive loop (killed on EXIT) when NOPASSWD is not active. `need_relogin`/`need_reboot` flags surface in the summary.

**Phases (in order):**

| # | name | what it does (CachyOS/Arch commands; VERIFY package names at first run) |
|---|---|---|
| 00 | preflight | distro `cachyos|arch`, x86_64-v3, kernel ≥ 6.14, `/dev/ntsync` + module, BTF, uprobe pmu, tracefs, BPF JIT, kconfig greps; running kernel vs `pacman -Q $(cat /usr/lib/modules/$(uname -r)/pkgbase)` (mismatch → reboot); RAM < 12 GiB → warn + clamp JOBS (+ `.vmx memsize=16384` hint with `--vm-ram-check`); disk ≥ 60 GiB; `/tmp` ≥ 2 GiB (build.sh hard-codes `/tmp`); network to github, snapshot.ubuntu.com, apt.llvm.org, docker registry, pacman mirror; session env present in `systemctl --user show-environment`; fish note; NTP. |
| 01 | sudo | `sudo -v`; with `--passwordless-sudo` install `/etc/sudoers.d/90-profiler-colby` (`colby ALL=(root) NOPASSWD: ALL`, validated with `visudo -cf`); always install `/usr/local/sbin/profiler-root-helper` + `/etc/sudoers.d/91-profiler-helper`; take the host-knob baseline `profiler-root-helper snapshot`. |
| 02 | packages | `pacman -Syu --noconfirm` then `pacman -S --needed --noconfirm base-devel git binutils zstd cabextract unzip rsync ccache jq python podman passt crun netavark aardvark-dns fuse-overlayfs bpftrace bcc bcc-tools python-bcc perf strace ltrace sysstat libbpf bpf clang llvm lld pahole elfutils "${kpkg}-headers" mingw-w64-gcc xorg-server-xvfb xdotool xorg-xprop xdg-utils desktop-file-utils shared-mime-info alsa-utils inotify-tools tmux socat lsof psmisc wl-clipboard nodejs npm`; optional `qt6-base qt6-wayland firefox`. Disable `ananicy-cpp` through the helper (`knob set ananicy off`) so `reset` can restore it. |
| 03 | podman | `usermod --add-subuids 100000-165535 --add-subgids 100000-165535 colby` (if `getsubids` empty), `podman system migrate`, `loginctl enable-linger colby`; check `podman info` → rootless, driver `overlay`, netavark; `podman run --rm docker.io/library/alpine:3.20 true`. |
| 04 | limits | `usermod -aG realtime,audio colby` (re-login flag); run the repo's `scripts/setup-realtime.sh` (non-interactive under NOPASSWD; writes limits.d/90-ableton-rt.conf, sysctl.d/90-ableton-rt.conf); `limits.d/90-profiler.conf` (`nofile 524288`); vm only: `sysctl.d/90-profiler.conf` (`kernel.perf_event_paranoid=-1`, `kernel.kptr_restrict=0`). |
| 05 | session | vm: `/etc/sddm.conf.d/zz-profiler-autologin.conf` (`[Autologin] User=colby Session=plasma Relogin=true`; inspect `/etc/sddm.conf*` with sudo and patch whichever defines `[Autologin]`); KDE: `kwriteconfig6` to disable autolock/DPMS/suspend + user unit `profiler-inhibit.service` (`kde-inhibit --power --screenSaver sleep infinity`); install `profiler/bin/with-session-env` (reads `systemctl --user show-environment`, exports DISPLAY/WAYLAND_DISPLAY/XAUTHORITY/DBUS…, exit 3 if no DISPLAY; keeps Wine on winex11 via Xwayland `:0`). |
| 06 | audio | `~/.config/pipewire/pipewire.conf.d/90-profiler-null-sink.conf` (`support.null-audio-sink` node `profiler-null`, Audio/Sink, 48 kHz, linger) and `91-profiler-clock.conf` (`default.clock.rate=48000 allowed-rates=[48000] quantum=256 min-quantum=32 max-quantum=2048`); restart pipewire/wireplumber/pipewire-pulse; `pw-metadata -n settings 0 clock.force-quantum 0`. After phase 10: append `output_device = profiler-null` / `input_device = profiler-null` to `~/.config/pipeasio/config.ini` (PipeASIO selects by `node.name`; `fixed_buffer_size` stays true; `realtime` stays off). |
| 07 | repo | clone (or accept the bundle clone), `core.autocrlf=false`, branch `profiler` from `aceb236`; `git archive 'aceb236^' bench \| tar -x`; add `bench/` to `.git/info/exclude`; `sha256sum -c bench/SHA256SUMS`. |
| 08 | media | verify `~/Proprietary/ableton/`: exe sha256 starts `a2652ee454fcf788`, three `.bin` > 1 GiB beside it, `strings` matches `Ableton Live 12`, `grep -a 'Inno Setup'`. Prints the Windows `scp` line if missing. |
| 09 | build | pre-checks (no Live/wineserver, `/tmp` free, JOBS = min(nproc, (MemAvailable−2 GiB)/1.2 GiB)); `JOBS=$JOBS PIPEASIO_TSAN_MODE=skip ./build.sh 2>&1 \| tee ~/.local/state/profiler/build-<ts>.log` (pipefail; **no repo edits while it runs**); re-run `scripts/build-audit.sh dist/*.tar.zst`. Expect ~50–60 min cold on 8 vCPU, 15–20 min warm. |
| 10 | install | `ABLETON_LIVE_INSTALL_TIMEOUT=7200 profiler/bin/with-session-env ./scripts/installer.sh install --live-installer "$EXE" --live-major 12 --link=off --yes --audio-buffer=128 --audio-threads=auto --rt=auto --power=off --dpi=100 --shortcuts=preserve` (flags verified at `scripts/installer.sh:25-32`; baremetal: `--power=performance --audio-buffer=64`). Check: `…/drive_c/ProgramData/Ableton/Live 12 Trial/Program/Ableton Live 12 Trial.exe`, `grep -c pipeasio ~/.wine-ableton/system.reg`, launcher `--help`. Optional sub-phase: `make check && make test`. |
| 11 | plugins | `profiler/setup/plugins.lock` (Dexed from github asb2m10/dexed release, K1v from nilsschneider.de; URL + sha256 pinned on first verified run); unzip and copy `Dexed.vst3` (bundle dir) and `K1v_x64.vst3` into `~/.wine-ableton/drive_c/Program Files/Common Files/VST3/`. |
| 12 | osc | `profiler/control/install.sh --prefix ~/.wine-ableton` → copies the vendored AbletonOSC + overlay into `<User Library>/Remote Scripts/AbletonOSC` (User Library = `drive_c/users/colby/Documents/Ableton/User Library`, resolve the `Documents` symlink with `readlink -f`; record the real path in setup.conf). |
| 13 | human | launches Live (`with-session-env ~/.local/bin/ableton-live`) and prints the checklist (§12), waits for Enter (skipped by `--yes`); then verifies Log.txt shows `PipeASIO` + `Open: finished`, no crash-recovery files, no wineserver left. |
| 14 | golden | `profiler/bin/state snapshot --name post-install` (before 13) and `--name golden` (after 13). `state` = `snapshot|restore|diff|list|clean-crash`; set: `~/.wine-ableton`, `~/.config/ableton-wine`, `~/.config/pipeasio`, `~/.config/pipewire/pipewire.conf.d`, `~/.local/share/ableton-wine`, `~/.local/opt/wine-d2d1-nspa-11.13`, `~/.local/bin/ableton-live`, User Library if outside the prefix, `pw-metadata` text, MANIFEST.json. Mechanism: `cp -a --reflink=always` on btrfs (instant), rsync otherwise. Restore refuses while prefix processes exist, runs `wineserver -k`, clears `CrashDetection.cfg`/`CrashRecoveryInfo.cfg`/`Preferences/BaseFiles/*`, resets `clock.force-quantum`. |
| 15 | tracecheck | `profiler/bin/trace-prereqs`: BTF, bpftool feature probe, uprobe pmu, `bpftrace -l usdt:$RT/lib/wine/x86_64-unix/ntdll.so:*` (0 = "pending" until patch 0108 is built), `readelf -n … \| grep -c stapsdt`, perf/clang(bpf target)/pahole, `/dev/ntsync` + `strings wineserver \| grep -c ntsync`, sysctls, helper `version`, `ulimit -l`; also runs `scripts/check-ntsync.sh` (Live closed). |
| 16 | claude | `curl -fsSL https://claude.ai/install.sh \| bash`; PATH snippets for bash and fish (`~/.config/fish/conf.d/profiler.fish`); print login instructions (`claude` → `/login` → open URL on Windows → paste code; or `CLAUDE_CODE_OAUTH_TOKEN` from `claude setup-token` in `~/.config/profiler/env`, 0600). |
| 17 | dashboard | `cd profiler/dashboard && npm ci`; user unit `profiler-dashboard.service` (`npm run dev -- --host 0.0.0.0 --port 5173`), enabled; prints the URL `http://abletonlinux:5173`. |
| 18 | summary | table, warnings, actions, "Next" commands (`verify.sh`, `trace-prereqs`, `profiler/bin/bench --dry-run --tag smoke`, `claude`). |

**Root helper** `/usr/local/sbin/profiler-root-helper` (bash, root-owned, refuses if its lib dir is writable; every mutation logged to `/var/log/profiler-root-helper.log`): `version` · `snapshot` (baseline of THP, allowlisted sysctls, governor/EPP, ananicy state, IRQ affinities, `sched_rt_runtime_us` → `/var/lib/profiler/baseline.env`) · `reset` · `knob get|set KEY VALUE` (`thp`, `governor`, `epp`, `ananicy`, `sysctl.<allowlisted keys>`, `irq-affinity.N`, `irq-prio.N`, `rt-prio.<pid>` only for pids whose exe is under `~/.local/opt/wine-*`) · `trace start --tool NAME --run-dir DIR [--pid N]… [-- ARGS]` / `trace stop ID` / `status` / `logs ID` (tool from root-owned `/usr/local/lib/profiler/tracer/` or, when `/etc/profiler/allow-user-tools` exists (vm), from the repo; DIR must be under `~/.local/share/profiler/runs`; chown to `SUDO_UID` on exit) · `install-tracer SRC_DIR`. Arguments validated by anchored regexes. On the VM it is a guard-rail and portable interface, not a security boundary.

**`profiler/setup/verify.sh`**: runs every phase's check + helper, podman driver, groups, kernel/headers match, display probe, PipeWire nodes/quantum, repo clean + SHA256SUMS, dist artifacts + build-audit, runtime/prefix/Live exe, check-ntsync, VST3s, AbletonOSC dir, `state diff --name golden`, trace-prereqs, `claude --version`, `npm run build`. Exit 0 only when all hard checks pass; same coloured table.

**Windows-side bootstrap (`setup/bootstrap.md`)**: `git bundle create C:\src\AbletonLinux\profiler-bootstrap.bundle profiler` → `scp` bundle + `scp -r AbletonInstaller\* abletonlinux:Proprietary/ableton/` (6.1 GB) → `git clone -b profiler ~/profiler-bootstrap.bundle ~/Projects/ableton-linux` on the VM, set `origin` to upstream. Optional: power off VM, set `memsize = "16384"` in `C:\vms\vmware\AbletonLinux\AbletonLinux.vmx`, `vmrun -T ws snapshot … pre-build` before the first Wine build.

## 5. Workstream B — developer build loop `profiler/dev/wine-dev.sh`

Goal: 20–60 s Wine iterations in the **same** Ubuntu 22.04 image, same paths (`/work/wine-src`, `/work/build`, `/work/stage`), same compilers and `git am --3way` series application as `scripts/container-build.sh:140-180` (so ccache keys match the official build and a dev-verified patch file reproduces officially).

- `init`: `podman image exists ableton-wine-build:22.04 || podman build …`; `podman create --name wine-dev --userns=keep-id --init -w /work -v ~/wine-dev/work:/work -v $REPO:/src:ro -v $REPO/.ccache:/ccache -e CCACHE_DIR=/ccache -e CCACHE_MAXSIZE=5G … sleep infinity`; `container/init.sh` replays: unpack `vendor/wine-base-5c23dd1c.tar.zst`, `git init` + commit "base 5c23dd1c", apply `patches/[0-9]*.patch` then `patches/performance/*.patch` with the same synthetic `From: dist <build@localhost>` header rule, `git tag series-aceb236`, configure `CPPFLAGS=-I/opt/ntsync-uapi … --prefix=/opt/wine-d2d1-nspa-11.13 --enable-archs=i386,x86_64 --disable-tests`, `make -j`, `make install DESTDIR=/work/stage`. ~25–40 min once.
- `apply PATCH…` (`git am --3way`), `edit` (host path `~/wine-dev/work/wine-src`; uid matches via keep-id), `build [--dir dlls/ntdll]` (incremental make + install into stage, or `sync --artifacts` copying `ntdll.so`/`ntdll.dll` directly if per-dir install is not supported — VERIFY), `pipeasio-init` / `pipeasio-build` (replay `container-build.sh:250-262,363-373,438-444,562-563`; stage keeps `winebuild`/`winegcc`), `sync [--strip]` (first run `cp -a --reflink=auto ~/.local/opt/wine-d2d1-nspa-11.13 ~/.local/opt/wine-d2d1-nspa-11.13-dev`, then rsync changed files from stage, keep BUILD-INFO files, write `PROFILER-DEV-INFO.txt` with HEAD/dirty; default unstripped for symbols; refuses while any process runs from either runtime), `format-patch --number 0108 --name slug` (prints the audit checklist), `shell`, `status`, `logs`, `reset`.
- Launch against the dev runtime: `ABLETON_WINE_ROOT=~/.local/opt/wine-d2d1-nspa-11.13-dev WINE_X=1 profiler/bin/with-session-env scripts/ableton-live <set.als>` (launcher validates only `bin/wine`, `bin/wineserver`, `system.reg`; `scripts/ableton-live:341-348`).
- **A/B rule:** compare `WINE_X=0` vs `WINE_X=1` on ONE runtime (compare hashes runtime identity; dev vs official differ in stripping/link order). "Keep" requires `profiler/dev/build-official.sh` (flock + `build.sh` + `scripts/installer.sh runtime install --yes`) and a re-run of the A/B on the official runtime.
- PE probes build with `ABLETON_WINE_SOURCE=~/wine-dev/work/wine-src ABLETON_WINE_BUILD=~/wine-dev/work/build tools/build_*.sh` (pattern of `tools/build_apcprobe.sh`).

## 6. Workstream C — trace points

### 6.1 `patches/0108-ntdll-add-static-trace-points.patch` (Wine, verified against the 11.13 base)

Files: `dlls/ntdll/unix/sdt.h` (vendored systemtap `sys/sdt.h`, CC0, with the x86_64 nop changed to the 5-byte `0f 1f 44 00 00` so the kernel's optimized-uprobe path applies) + `sdt-config.h` (`_SDT_ASM_SECTION_AUTOGROUP_SUPPORT 1`, `RETAIN 1`), `dlls/ntdll/unix/signal_x86_64.c`, `dlls/ntdll/unix/server.c`. `sync.c` untouched so `performance/0001` keeps applying.

Probes (provider `wine`; argument displacements in **decimal** because libbpf's USDT parser only accepts `%d @ %ld(%reg)`):

| Probe | Site (11.13 line) | Args |
|---|---|---|
| `syscall_entry(id, frame, user_rsp, user_rip)` | between `ldmxcsr 0x33c(%r13)` (3094) and `movl 0xb0(%rcx),%eax` (3095) | `-4@176(%rcx) 8@%rcx 8@136(%rcx) 8@112(%rcx)`; `%rcx`=frame at all three Linux sub-paths; `*(user_rsp)` = return address into the NtXxx caller |
| `syscall_exit(status, frame, id, restore_flags)` | at `__wine_syscall_dispatcher_return` label (3128) after CFI, before `leaq 0x70(%rcx),%rsp` | `-4@%eax 8@%rcx -4@176(%rcx) -4@180(%rcx)` |
| `unixcall_entry(handle, code, frame, caller_rip)` | before `callq *(%r10,%rdx,8)` (3385) | `8@%r10 -4@%edx 8@%rsp 8@112(%rsp)` (unix-call return address is the PE caller itself; `__wine_unix_call` is inline) |
| `unixcall_exit(status, frame)` | after the call, `movq %rsp,%rcx` | `-4@%eax 8@%rcx` |
| `server_req_start(req_type)` / `server_req_end(req_type, status)` | `server_call_unlocked` (`server.c:285`), capture `req->u.req.request_header.req` **before** `send_request` (the union is overwritten by the reply) | C `STAP_PROBE1/2` |
| `server_wait_start(flags)` / `server_wait_end(ret)` | around `wait_select_reply` in `server_select` (~777) | where non-NTSync/APC waits block |

`STAP_PROBE_ASM(wine, name, template)` expands to adjacent string literals usable inside `__ASM_GLOBAL_FUNC`; templates must contain no commas; basic asm → single `%`. All sites sit on Wine's kernel stack or in non-leaf C (trampoline-safe). Fingerprint literal `WINE_USDT_V1` in `ntdll.so`. No i386 unix side exists (WoW64 reaches the same dispatcher). Audit: `REQUIRED_WINE_TAIL='0108-…'` (`scripts/build-audit.sh:13`), FINGERPRINTS `0108|ascii|lib/wine/x86_64-unix/ntdll.so|WINE_USDT_V1`, new structural check `must_usdt lib/wine/x86_64-unix/ntdll.so wine 8` (`readelf -n` provider count; proves notes survived `strip --strip-unneeded`), `scripts/build-audit.sh --freeze`, BASE.txt/CHANGELOG notes.

### 6.2 `patches/pipeasio/0017-usdt-block-markers.patch`

Files: `include/sdt.h` + `sdt-config.h`, `include/pipeasio_probe.h` (`PIPEASIO_PROBE(...)` = `STAP_PROBEV` on ELF, no-op for the WoW64 PE half), `include/pipeasio_block_clock.h` (`period_ns = nframes*1e9/rate`, `deadline = next_nsec > nsec ? next_nsec : nsec + period`, `slack = deadline − end`), `src/audio.c`, `src/asio.c`, `include/pipeasio_telemetry.h`, `tests/unit/test_block_clock.c` (+ CMake registration), README.

Probes (provider `pipeasio`, unconditional, nop when unattached): `cycle_start(clock_nsec, next_nsec, duration, position, flags)` / `cycle_end(missed, delivered)` in `audio_on_process` (`audio.c:1546`); `block_start(seq, nframes, rate, clock_nsec, deadline_ns, flags)` after `pipeasio_host_call_begin` (`asio.c:2554`); `block_before_live(seq)` / `block_after_live(seq)` where telemetry's before/after hooks sit; `block_end(seq, flags, missed)` after the output publish loop. `uint64_t block_seq` in the driver (callback thread only, starts at 1); `audio_client_t` stores `last_next_nsec/duration/rate`; telemetry samples gain `seq` + `slack_ns` and the per-second `cycles=` line gains `block_range=A-B late=N`. Also `SetThreadDescription` `pipeasio-rt` / `pipeasio-worker` for the data-loop and lifecycle threads. Fingerprint `block_range=` in `pipeasio64.dll.so`; `REQUIRED_PIPEASIO_TAIL`, `must_usdt … pipeasio 7`, freeze. "Late" = callback end after `next_nsec` (the data loop's next wakeup); cross-checked with `missed` (clock.position gaps).

## 7. Workstream D — tracer, symbolizer, roles, whole-app mode

**Prototype** `profiler/tracer/wine-trace.bt` (bpftrace 0.27): per-event lines (`E/X/S/B` records with `nsecs`, `tid`, ids, `seq`) + `profiler/tracer/reduce.py` offline join. Purpose: validate probe arguments and the block join before the C tracer exists.

**Production** `profiler/tracer/wine-trace.bpf.c` + `wine-trace.c` (libbpf CO-RE, `bpftool gen skeleton`, built on the CachyOS host with clang 23 / libbpf 1.7; `Makefile`):
- Attach USDT **per traced pid** (`bpf_program__attach_usdt(prog, pid, "$RT/lib/wine/x86_64-unix/ntdll.so", "wine", …)` and `pipeasio64.dll.so`) so other Wine processes keep the plain nop. PIDs from `scripts/lib/lifecycle.sh` (`ableton_prefix_pids`: prefix env + runtime exe, includes wineserver) narrowed by `--run-id` (`ABLETON_BENCH_RUN_ID`), plus `--pid`; follow forks via `tp_btf/sched_process_fork` (Max.exe, msedgewebview2.exe, plugin hosts).
- NTSync kernel-side: `fentry/fexit` on `ntsync_char_ioctl` (WAIT_ANY/WAIT_ALL; read `struct ntsync_wait_args`) and `fentry/ntsync_obj_ioctl` (EVENT_SET/PULSE, SEM_RELEASE, MUTEX_UNLOCK → waker identity); fallbacks `--ntsync kprobe|tracepoint|off`. Needs module BTF (`/sys/kernel/btf/ntsync`).
- Scheduler: `tp_btf/sched_switch` (on/off-CPU, run-queue delay), `sched_waking` (`woken_by`), `task_rename` (live comm), `sched_process_exit`.
- Maps: `agg[4]` hash keyed `{seq|window, tid, kind, id}` → `{count,total_ns,max_ns,oncpu_ns}` written at event completion into epoch ring `agg[(seq>>6)&3]`; user space drains `agg[(epoch-2)&3]` with `lookup_and_delete_batch` (≈170 ms slack at 750 blocks/s) — no per-event user-space work in summary mode. `inflight` per-tid stack (depth 4) pairs entry/exit by frame pointer; `gl` holds `cur_seq, block_start_ts, deadline_ns, callback_tid`; 16 MiB ring buffer; per-CPU scratch for stack copies.
- **Block association rule:** callback thread's events between `block_start`/`block_end` → that `seq`; its between-block events → window bucket flagged `between_blocks`; every other thread's event → the block in progress at its entry time (`cur_seq`, 0 → 100 ms window bucket). Non-audio threads are aggregated per 100 ms window (`threads.jsonl`), wineserver as role `wineserver`.
- Stack capture only on `syscall_entry`/`unixcall_entry` and only when sampled (`--sample 1/N`, default 1/64 summary, 1/4 drilldown), when the current block is already past the slack threshold, in `--mode drilldown`, or on `--trigger-ids`: record = header + `seq, frame, rsp, rip, id, kind` + the 20 nonvolatile registers from `syscall_frame` + `--stack-bytes` (default 1536) copied with `bpf_probe_read_user`. `server_req`/`ntsync_wait` inherit the enclosing entry's stack sample.
- Controls: `--mode summary|drilldown|sample`, `--sample 1/N`, `--stack-bytes`, `--roles audio|all`, `--no-exit`, `--slack-threshold 15`, `--ntsync …`, `--sched on|off`, `--ringbuf-mb`, `--duration`, `--out DIR`, `--calibrate`.
- CLI contract (shared with the root helper): `profiler/bin/wine-trace start --out DIR --pid… --mode M` (daemonises, pidfile in DIR, writes `tracer.json` with `started_monotonic_ns`, version, mode, sample, attach list) / `stop --out DIR` (SIGINT, flush, reduce + symbolize, writes `stopped_monotonic_ns`, `lost_events`, probe hit counts, `overhead_estimate_ns_per_block`) / `run --duration S`. Output files readable by the invoking user.

**Symbolizer** `profiler/tracer/symbolize.py` (stdlib): `/proc/PID/maps` snapshots (start, exec, every 5 s, on miss); PE image = mapping at file offset 0 whose file starts `MZ`, extent `[base, base+SizeOfImage)` from the header (MSVC sections are `pread()` into anonymous memory — never use per-page backing); minimal PE32+ parser (sections, EXPORT → nearest preceding export for Wine DLLs, IMPORT → `imports.json` static map of Live, EXCEPTION `.pdata` + `UNWIND_INFO`); x64 unwinder applying codes in reverse with the prolog-offset rule (PUSH_NONVOL, ALLOC_SMALL/LARGE, SET_FPREG, SAVE_NONVOL[_FAR], chained info; stop at PUSH_MACHFRAME, non-PE address, `wow64.dll`, window exhaustion, 12 frames); output `ntdll.dll!NtXxx+0x14 ← kernelbase.dll!WaitForMultipleObjectsEx+0xe3 ← Ableton Live 12 Trial.exe+0x1a2b3c4` (Live/plugins `module+offset` only); caches persisted to `symcache.json`.

**Roles** (`profiler/tracer/roles.toml`, from `comm` since Wine 11.13 propagates thread names): `pipeasio_callback` (tid firing `block_start`), `audio_worker` (`AudioCalc`), `main` (tid == pid of an `.exe`), `wineserver`, `pipeasio_rt`/`pipeasio_worker` (after 0017), `live:<comm>`, `plugin:<module>` (start address of `NtCreateThreadEx`'s 5th argument symbolized), `webview`/`max`/`push2` by exe, `unknown:<comm>`.

**Whole-app mode** `profiler/bin/profile-app --backend bpf|perf`: bpf = `perf_event` cpu-clock 999 Hz per traced pid emitting stack records → same unwinder; exact per-thread CPU/off-CPU from sched accounting; outputs `samples.jsonl`, `stacks.folded`, `profile.json` (per-role CPU share, top PE modules/sites, top unix leaves from the unstripped dev tree's `.symtab` via `--symbols-root`, off-CPU reasons on audio threads), SVG flame graph from `profiler/tracer/flamegraph.py` (own ~150-line renderer). perf = `perf record --call-graph dwarf -p <pids>` + `symbolize.py --perf` replacing `[unknown]` PE addresses (unix-side hot functions; dev runtime only).

**Tables** `profiler/tracer/tables/wine-<ver>.json` generated by `gen_tables.py --wine-src` from `dlls/ntdll/ntsyscalls.h` (0x0000–0x0fff), `dlls/win32u/win32syscalls.h` (0x1000+), `include/wine/server_protocol.h` `enum request` (patched tree; 0078 bumps the protocol), and each `dlls/*/unixlib.h` enum (unix-call codes); keyed by runtime VERSION with mismatch warning.

**Output files** in `raw/interface/`: `tracer.json`, `blocks.jsonl` (per block: `seq, t_start, t_before_live, t_after_live, t_end, clock_nsec, deadline_ns, period_ns, nframes, rate, callback_tid, wake_latency_ns, pre_ns, live_ns, post_ns, slack_ns, late, near_late, missed_cycles, flags, crossings[{tid, role, kind, id, n, total_ns, max_ns, woken_by?}], offcpu[], stacks[]`), `threads.jsonl` (100 ms × tid: role, oncpu/offcpu, wakeups, run_delay, crossings by kind, top ids), `summary.json` (the `interface` rollup in the measurement schema of §8), drill-down `events.jsonl`/`stacks.jsonl`, `symcache.json`, `imports.json`, `maps.json`. All times are `offset_seconds` from `monotonic_start_ns` (CLOCK_MONOTONIC = suite window base = PipeWire `clock.nsec` base). `kind ∈ syscall|unixcall|server_req|server_wait|ntsync_wait|ntsync_wake|offcpu`.

**Validation**: `tools/traceprobe.c` + `tools/build_traceprobe.sh` (same toolchain as `build_apcprobe.sh`; PASS/FAIL/SKIP, exit = FAIL count; prints `EXPECT kind id op n` lines) with phases: NtYieldExecution ×100; QPC ×200 (syscall 0x31); CreateEvent/CloseHandle ×50 (→ `create_event`/`close_handle` server requests); WaitForSingleObject 10 ms ×20 (ntsync WAIT_ANY → −ETIMEDOUT); helper-thread SetEvent ×20 (ntsync_wake + `woken_by`); SCardEstablishContext ×10 + DirectWrite ×20 (unix calls → `winscard.so`, `dwrite.so`); SleepEx alertable ×10 (`server_wait` vs `ntsync_wait count=0` under `WINE_APC_FASTPATH=1`). `profiler/tracer/validate.py` compares counts; block-join check vs telemetry (`cycles=` == `block_start`/s, `block_range` match, `live_callback` percentiles within 2 µs, `late=` equal). Unit tests: `test_symbolize.py` (synthetic PE32+ image + stack window), `test_reduce.py` (association rule, epoch drain), PipeASIO `test_block_clock`.

**Overhead**: plan with ≈0.5 µs/hit (optimized 5-byte-nop uprobes, VERIFY kernel support with `--calibrate`) to ≈2 µs (classic int3); 64 frames = 1,333 µs per block; dispatcher-level only, in-kernel aggregation, explicit-pid attach, `--no-exit`, `--roles audio`, sampled stacks. Bare-metal proof: three suite runs (untraced / summary / drilldown) compared on Live CPU, voluntary switches, xruns, telemetry p99 with `PIPEASIO_TELEMETRY=on`; accept summary mode at < 1 % process CPU and < 2 % on callback p99; drill-down is never used for timing claims.

## 8. Workstream E — control layer, scenarios

**Vendoring**: `profiler/control/vendor.sh` pins AbletonOSC `0ca68214bd62c9b5cb641ca34006cfd70ba94430` (MIT; keeps `LICENSE.md`, `__init__.py`, `manager.py`, `abletonosc/`, `pythonosc/`), `VENDOR.txt` records URL/commit/sha256. Overlay: `manager.py` (+2 lines registering `BenchHandler`) and `abletonosc/bench.py`.

**Ports**: the bench protocol runs on AbletonOSC's own server (**11000 in, 11001 out**; replies go to the sender host on 11001, which `scripts/bench-osc.py` already binds on 127.0.0.1). The canonical Sets still embed the M4L device on 19001/19002, so a second socket there would collide; leave the scripts' defaults alone and have `profiler/bin/bench` export `ABL_BENCH_OSC_SEND=11000 ABL_BENCH_OSC_RECV=11001` (plus session env, output dir under `~/.local/share/profiler/runs/`, runtime root). Rule: never run `liveosc.py` queries during a measurement window (one owner of 11001).

**`bench.py` handler** (`class BenchHandler(AbletonOSCHandler)`): exact protocol of the deleted device — `/abl/bench/ping→pong`, `play`, `stop`, `rewind`, `poll`, `cpu-period MS` (re-armed via `manager.schedule_message`, 100 ms ticks, main thread), `/abl/bench/ready 0|1` at init, `/abl/bench/playing 0|1` via `add_is_playing_listener`, `/abl/bench/cpu AVG PEAK` from `Live.Application.get_application().average_process_usage/peak_process_usage` (`-1 -1` while unavailable; `CPU_SCALE` settled by the smoke test) — plus `/abl/bench/scenario-marker NAME` (echo with song time), `/abl/bench/info`, `/abl/bench/views`, `/abl/bench/show-view NAME`, `/abl/bench/load-device KIND NAME [TRACK]` (DFS over `browser.instruments/audio_effects/plugins/max_for_live`, `browser.load_item`), `/abl/bench/subscribe PORT`. Only int/float/str args; every handler wrapped so a LOM error goes to `/live/error` and never kills the tick loop; `clear_api` removes listeners. Extend `bench-osc.py decode()` for `T F N I b d h` tags (python-osc emits `T/F` for bools) with a unit test.

**Client** `profiler/control/liveosc.py` (stdlib; reuses `bench-osc.py` encoder via `importlib`): `ping, wait_ready, play, stop, rewind, set_tempo, fire_clip, fire_scene, set_param, create_midi_track, create_audio_track, delete_track, load_device, show_view, marker, query, listen` + CLI. `install.sh --prefix DIR` (refuses if Live running; writes `INSTALLED.txt`; never touches `ProgramData/Ableton/*/Resources/MIDI Remote Scripts`). `smoke-test.sh`: probe → info → views → rewind/play (expects `playing 1` and ≥2 `cpu` lines) → stop; on no pong explains the Control-Surface step and checks `logs/abletonosc.log` mtime vs Live start.

**Scenarios** `profiler/scenarios/*.json` (schema `ableton-linux-scenario/v1`: `name, kind benchmark|diagnostic, base_set, requires, setup[], timeline{period_s, steps[{at_s, op, …}], repeat, marker_every_s}, teardown[]`), executed by `profiler/control/scenario-run.py setup|run|--validate` (fire-and-forget during the window; logs `offset\tmarker\tname` to stdout → `raw/scenario.tsv`; honours `--duration`/SIGTERM). Set: `idle-playing` (benchmark, every canonical Set), `clip-launch-storm`, `param-sweep`, `tempo-ramp` (benchmark, Benchmark_Inbuilts), `track-churn`, `view-flip`, `load-devices` (diagnostic). Benchmark-grade = fixed schedule, no browser/track creation. New saved Sets (`profiler/sets/` + SHA256SUMS via `profiler/bin/sets freeze`) only if the Trial allows saving (VERIFY); otherwise scenarios build state live from `Benchmark_Empty` each run.

## 9. Workstream F — benchmark suite and report integration (minimal diffs, house style)

**`scripts/bench-suite.sh`**: `--trace off|interface|drilldown` (env `ABLETON_BENCH_TRACE`), `--scenario NAME`, `--sets A,B,C`; overrides `ABLETON_BENCH_TRACER`, `ABLETON_BENCH_ROOT_HELPER`, `ABLETON_BENCH_SUDO`, `ABLETON_BENCH_SCENARIO_TOOL`; `structure=benchmark` only for the canonical five without scenario, else `diagnostic` (→ `init-run --structure --trace-mode --scenario`); preflight: tracer executable, privilege route (helper on PATH or `sudo -n true`), `check-udp --port 11000`, scenario validates; dry-run prints `trace= privilege= structure= scenario=`; per set: `trace_start` after `/abl/bench/play` (line 362) before the settle sleep (Zero: after `wait_log_quiet`), `trace_stop` after `bench-run.sh` (380) before `/abl/bench/stop`, then `bench-report.py interface --set-dir`; `finish()` calls `trace_stop` first. `bench-run.sh` accepts `scenario` mode and passes `--scenario/--scenario-tool/--set-sha256`.

**`scripts/bench-report.py`**: `capture` gains `--scenario --scenario-tool --set-sha256 --trace-mode`, a `TimedCommand("scenario", …)` beside `osc` (1804-1807), records `measurement["scenario"]`, `["set_file"]`, `["trace"]`; collector names unified into one tuple used at 1888/2820/2915 (edge rules at 2752 unchanged); skip `playback_state_confounder` in scenario mode (1885); tracer is shell-started (root), not a TimedCommand. New subcommand `interface --set-dir DIR [--near-late-fraction 0.15] [--top 20]` reads `raw/interface/*` and writes `measurement["interface"]` (schema `ableton-linux-interface/v1`: `tracer{version, mode, sample_rate, attach, lost_events, overhead, started/stopped_offset_seconds, coverage_complete}`, `evidence{}`, `window{}`, `thresholds{near_late_fraction, deadline_ns_mode, near_late_slack_ns}`, `blocks{count, late, near_late, late_per_minute, slack_ns{min,p01,p50,p99}, elapsed_ns{p50,p99,max}, deadline_ns{min,max}}`, `lost_slack{definition, total_ns, attributed_ns, unattributed_ns}`, `call_sites[{rank, key, kind, name, caller, late_blocks, near_late_blocks, n_in_late_blocks, per_late_block, total_ns_in_late_blocks, max_ns, share_of_lost_slack, n_all_blocks, total_ns_all_blocks, woken_by[]}]`, `kinds{}`, `roles{}`, `hotspots_non_audio[]`, `confounders[]`); confounders `interface-tracer-coverage-incomplete`, `interface-lost-events`, `interface-tracer-output-missing`. `render`: `## Interface crossings` section per set after the Results table (2442) — the 17-column main table is unchanged (test asserts 18 pipes); header bullets `Trace/Structure/Scenario`. `profile`: `systemd-detect-virt` → `system.virtualization{value, dmi_product, timing_claims_allowed}`; `IDENTITY_SPECS` gains `virtualization` and `trace`; `markdown_report`/`comparison_markdown` print a `> NO TIMING CLAIMS` banner when not `none`. `compare`: **hard** `ValueError("trace mode mismatch …")` beside the duration refusal (2931-2936); `--structure diagnostic` accepts identical non-canonical set orders + identical scenario; per-set `interface` metric deltas and `call_sites` joined on `key` (+ appeared/disappeared); `set-identity:set-file`. New `interface-drilldown --run-dir --set --top N`. Harness hash changes once (expected; all A/B pairs use one harness).

## 10. Workstream G — agent loop

**`CLAUDE.md`** (repo root): what the repo is; project map; exact commands (`profiler/bin/state restore`; `profiler/bin/bench --tag T [--trace interface] [--scenario S] [--sets …]`; `profiler/dev/wine-dev.sh …`; `profiler/dev/build-official.sh`; `bench-report.py compare/interface-drilldown`; `profiler/bin/history-add`; `make test`, `make test-profiler`; `set -o pipefail; … 2>&1 | tee ~/.local/state/profiler/logs/<ts>-<what>.log`); guardrails (never modify Live's install/Preferences/Options.txt/Sets by hand; restore golden before every trial; one hypothesis per trial; every change = opt-in env switch default-off + PE probe in `tools/` + note in `notes/`; never make a fix default; root only via helper verbs or `sudo -n` for the tracer; never `git add -A` after builds; no non-ignored writes during `build.sh`; new Wine patch = next number + `REQUIRED_WINE_TAIL` + FINGERPRINTS/STAMP_ONLY + `--freeze` + `make test` green; one branch `trial/T<id>-<slug>` and one commit per trial including the ledger line and `history/` files; no timing claims under virtualisation; no `liveosc.py` queries inside a window); acceptance rule (A/A pair for spread → interleaved ABAB untraced, n ≥ 3; accept iff median primary-metric improvement > 2× A/A spread and no Set regresses beyond the spread; xruns/PipeWire ERR = reject; then one traced run per arm confirming the call-site share dropped); stop criteria (`--budget-hours`, K = 3 consecutive revert/inconclusive, 2 consecutive build failures, any guardrail violation).

**`profiler/AGENT-PROMPT.md`** + `.claude/commands/profiler-loop.md` (`Follow @profiler/AGENT-PROMPT.md exactly. Arguments: $ARGUMENTS`): objective priorities (0 xruns/ERR → fewer late/near-late blocks → lower CPU; whole-app: also report `hotspots_non_audio` and UI-scenario findings); phase gate from `profile.json.system.virtualization` (VM ⇒ verdicts limited to `tooling|mechanism-confirmed`; bare metal ⇒ A/B verdicts); the loop (restore → baseline traced run → pick top call site not in ledger → hypothesis → change + switch + probe + note → `make test` + probe PASS → A/A → ABAB×3 → traced confirmation → ledger + history-add → commit → next); ledger discipline; report format.

**Ledger** `profiler/ledger.jsonl` (`ableton-linux-profiler-ledger/v1`): `trial, date, host, branch, hypothesis, evidence[{run, set, call_site, share_of_lost_slack}], change{kind, patch, switch, probe, note}, probe_result{pass,fail,skip,log}, runs{aa, abab[{a,b}], traced{a,b}}, metrics{primary, per_set{…a_median,b_median,aa_spread,delta,ratio_to_spread}, xruns, cpu_live_pct}, traced_confirmation{before, after}, verdict keep|revert|inconclusive|tooling|mechanism-confirmed, rationale, commit, minutes`. `profiler/bin/ledger-report` renders Markdown (counts by verdict, trial table, open hotspots, virtualisation banner).

## 11. Workstream H — gains dashboard `profiler/dashboard/` (Vite + npm)

**Stack**: Vite + React 18 + TypeScript, Recharts for charts, Vitest for tests; no backend, no router (tabs). **Load the `dataviz` skill before writing any chart code** (palette, light/dark tokens, mark rules).

**Data contract (committed, compact; the site reads it directly):**
- `profiler/history/runs/<run-id>.json` (`ableton-linux-profiler-history/v1`), written by `profiler/bin/history-add RUN_DIR [--trial T --arm A|B|AA] [--baseline]` (Python, stdlib) from `report.json`/`profile.json`: `run_id, tag, started_at, machine_id, hostname, virtualization, structure, scenario, trace_mode, duration_s, runtime{dist_version, source_tree_sha, dev_info}, switches{env from benchmark_gates}, harness_sha, commit, trial, arm, source_dir, sets{<Set>: {mode, host_cpu_pct, live_cpu_pct_per_core, wine_cpu_pct_per_core, pipewire_cpu_pct, irq_per_s, softirq_per_s, pipewire_errors, xruns, dsp_avg, dsp_peak, audio_workers, voluntary_switches_per_s, late_blocks, near_late_blocks, slack_p01_ns, slack_p50_ns, lost_slack_total_ns, call_sites_top[{key, share, total_ns_in_late_blocks}], hotspots_non_audio_top[]}}`.
- `profiler/history/baselines.json`: `{machine_id: {"<structure>/<scenario>": run_id}}`.
- `profiler/ledger.jsonl` (trials, verdicts).
- Loaded with `import.meta.glob('../../history/runs/*.json', {eager: true})` and `import ledger from '../../ledger.jsonl?raw'` (`vite.config.ts`: `server.fs.allow` includes `..`; `base: './'`) — a new run appears after `history-add` with HMR, no exporter.

**Model (`src/data/`):** `metrics.ts` registry (key, label, unit, direction lower/higher-is-better, source outcome|interface|scenario, decimals); `gains.ts`: baseline resolution per (machine, structure/scenario, set), delta % and absolute, A/A spread from runs with `arm=AA` of the same identity, significance = |delta| > 2× spread; `trials.ts`: join ledger ↔ runs. Tests: `src/data/*.test.ts` (Vitest).

**Views:** Overview (KPI tiles per Set: baseline → latest/best for late blocks/min, PipeWire errors + xruns, Live CPU/core, slack p01; cumulative gain vs baseline; kept-trial count; environment badge with a "no timing claims" ribbon for virtualised runs) · Trends (line charts per metric per Set over run time; baseline reference line; shaded A/A noise band; vertical markers for kept/reverted trials; filters: machine, environment, structure, scenario, trace mode, switch) · Trials (ledger table with verdict chips, hypothesis, switch, probe result, per-set deltas as ratio-to-spread; detail: ABAB pairs as paired dots, traced confirmation as before/after bars) · Call sites (top call sites by lost-slack share and their trend across traced runs; which trial targeted them) · Scenarios (diagnostic scenario metrics and `hotspots_non_audio` over time) · Runs (table of all runs with identity fields; pick two → inline deltas).

**Serving:** VM user unit `profiler-dashboard.service` (`npm run dev -- --host 0.0.0.0 --port 5173`) → `http://abletonlinux:5173` from Windows; `npm run build` → `dist/` (gitignored) for static hosting; on Windows, `git fetch vm` + `npm run dev` works too (Node present). Agent rule: `history-add` after every suite run; ledger line after every trial.

## 12. Human steps (printed by phase 13; one time per machine)

1. Live starts on the VM desktop: accept the licence; authorise the Trial via ableton.com (browser inside the VM) or continue unauthorised (demo mode: no save/export — scenarios then build state live).
2. Settings → Audio: Driver Type **ASIO**, Device **PipeASIO**, 48 kHz (buffer is PipeASIO's).
3. Settings → Link/Tempo/MIDI: Control Surface **AbletonOSC**, Input/Output None.
4. Settings → Licenses/Maintenance: auto-update and usage data off; Library: Cloud off. Leave the GPU renderer at Live's default.
5. **File → Quit (Ctrl+Q)** — never SIGTERM (leaves crash-recovery state).
Then `state snapshot --name golden` runs automatically.

## 13. Execution order and milestones

| M | Deliverable | Exit criterion | Env |
|---|---|---|---|
| 0 | Windows bootstrap: `profiler` branch + `profiler/` skeleton + setup script committed; bundle + installer copied to VM; VM RAM → 16 GiB (needs confirmation; VM power-off) and a `pre-build` VMware snapshot | VM clone on branch `profiler`, `bench/SHA256SUMS` verifies | host+VM |
| 1 | Setup script phases 00–12 run; Wine built and installed; human phase; golden snapshot; `verify.sh` green; first untraced suite run via `profiler/bin/bench` (control layer may still be the restored M4L device at this point) | `report.md` produced; `history-add` works; dashboard shows the run | VM |
| 2 | Control layer: AbletonOSC fork + `bench.py` + `liveosc.py` + smoke test; scenarios v1; `--scenario`/`--sets` in the suite; tests | smoke test PASS; a scenario run produces `raw/scenario.tsv` + markers in `osc.tsv` | VM |
| 3 | Trace points: patches 0108 + 0017; `wine-dev.sh init/build/sync`; `readelf -n` shows 8 + 7 probes; bpftrace prototype; `traceprobe.exe` counts match; block join validated vs telemetry | `validate.py` PASS; build-audit `--freeze` + `make test` green | VM |
| 4 | Production tracer + symbolizer + roles + outputs; suite `--trace`; `interface` section, render/compare/drilldown; `profile-app`; tests | end-to-end traced suite run in the VM yields `blocks.jsonl`, Interface tables, compare deltas; `make test-profiler` green | VM |
| 5 | Dashboard views + history/ledger tooling; `CLAUDE.md`, `AGENT-PROMPT.md`, `/profiler-loop`; `ledger-report` | dashboard renders trends/trials/call sites from ≥ 3 runs | VM |
| 6 | Agent-loop dry run in the VM with `WINE_APC_FASTPATH` as the "hello world" trial (verdict limited to `mechanism-confirmed`); official build via `build-official.sh` | ledger entry + dashboard trial card; no guardrail violations | VM |
| 7 | Bare metal: `setup-machine.sh --profile baremetal`; tracer overhead proof; A/A noise floor; traced campaign on all Sets + scenarios; optimisation loop under `/profiler-loop` | ranked call sites per Set; kept changes each with probe PASS, untraced A/B win, traced confirmation | HW |
| 8 | Upstream decision: notes in `notes/`, per-fix PRs, tool PR | maintainer review | — |

Implementation order inside each milestone follows the workstreams (A → B → C → D → E/F → G/H). Each milestone ends with a commit on `profiler` and `history-add` for any runs.

## 14. Verification (end to end)

1. `profiler/setup/verify.sh` exits 0; `profiler/bin/trace-prereqs` shows USDT probes present after M3.
2. New SSH session: `id -nG | grep -x realtime`, `chrt -r 10 true`, `with-session-env xdotool getdisplaygeometry`.
3. `scripts/build-audit.sh dist/*.tar.zst` OK; `scripts/check-ntsync.sh` OK; `with-session-env scripts/check-live-audio.sh` reports `Used SampleRate: 48000`.
4. `profiler/control/smoke-test.sh` PASS; `profiler/bin/bench --dry-run --tag smoke` then `--tag baseline`; `state diff --name golden` drift only in Log.txt/Preferences; `state restore` returns to empty.
5. `tools/run_in_prefix.sh traceprobe.exe` under `wine-trace` → `validate.py` PASS; `bpftrace -l usdt:…` lists 8 `wine:` and 7 `pipeasio:` probes.
6. `profiler/bin/bench --tag traced --trace interface` → `sets/*/raw/interface/blocks.jsonl`, `report.md` Interface tables; `bench-report.py compare` refuses traced-vs-untraced with exit 2; `interface-drilldown` lists late blocks.
7. `make test` (22 scripts) and `make test-profiler` green; `cd profiler/dashboard && npm test && npm run build`.
8. Dashboard at `http://abletonlinux:5173` shows the baseline, trend lines, and the hello-world trial with its ABAB pairs.
9. VM runs carry the `NO TIMING CLAIMS` banner; bare-metal runs do not.

## 15. Risks and VERIFY items

| Risk / VERIFY | Mitigation / how to verify |
|---|---|
| 8 GiB VM RAM for the container build (`/tmp` tmpfs is RAM too) | JOBS clamp; raise to 16 GiB; swap present |
| `apt.llvm.org` pin 21.1.8 ages out → image build fails | bump `LLVM_PKG_VERSION` in `Containerfile` on our branch (PE hashes change; fine for the fork) |
| Rootless podman falls back to `vfs` on btrfs | subuids + `podman system migrate`; check `GraphDriverName=overlay`; fuse-overlayfs fallback |
| Inno installer / Live without a display over SSH | everything GUI goes through `with-session-env` (exit 3 without DISPLAY); SDDM autologin; VERIFY sddm.conf precedence and Plasma 6 `kwriteconfig6` keys |
| `.note.stapsdt` vs `strip --strip-unneeded`; `STAP_PROBE_ASM` inside `__ASM_GLOBAL_FUNC`; `.altmacro` side effects; gas `"aGR"` section flags | `must_usdt` audit check; `objdump -d ntdll.so | grep -c 'nopl 0x0(%rax,%rax,1)'` = 4; set RETAIN 0 if gas rejects |
| libbpf USDT arg parsing (decimal offsets only), bpftrace 0.27 USDT by path, module BTF for `ntsync` | `bpftrace -l`, `ls /sys/kernel/btf/ntsync`; fallbacks `--ntsync kprobe|tracepoint` |
| Kernel optimized-uprobe support (5-byte nop) on 7.2.9 | `wine-trace --calibrate` reports ns/hit; budget assumes 0.5–2 µs |
| Uprobe rate on a loaded Set exceeds budget | `--no-exit`, `--roles audio`, sampled stacks; decisions only from untraced runs |
| `Live.Application.average_process_usage` unit (percent vs 0–1); `schedule_message` semantics; `/live/api/reload` covering `bench.py`; User Library path/symlink; Python version in Live 12's script runtime | smoke test sets `CPU_SCALE`; fall back to `Live.Base.Timer`; restart Live during handler dev; `readlink -f`; avoid 3.12+ syntax |
| Trial authorisation needs a browser in the VM; Max for Live availability for Benchmark_Max4Live; saving Sets in demo mode | optional `firefox`; unauthorised demo mode acceptable; scenarios build state live |
| Dexed/K1v asset names and licences | pin URL + sha256 on first verified download (`plugins.lock`) |
| `performance/` series locked to 0001; new patches must patch generated `configure` if configure.ac changes | all new Wine work in the main series (0108+); 0108 needs no configure change (vendored sdt.h) |
| Build digest guard aborts on repo writes; `dist/` records change after builds | `build-official.sh` flock + agent rules; `bench/` in `info/exclude`; never `git add -A` |
| SIGTERM-closed Live reopens the recovered Set | `state clean-crash` before every launch; `liveinject.exe ctrlq` for graceful close |
| VM timing is not trustworthy | banner in every report; verdicts gated by `virtualization`; Phase B on bare metal |
| Dashboard reads JSON outside the Vite root | `server.fs.allow`; fall back to a small exporter if glob-outside-root misbehaves |

## 16. Files to create/modify (summary)

- New: everything under `profiler/` (§3), `CLAUDE.md`, `.claude/commands/profiler-loop.md`, `patches/0108-ntdll-add-static-trace-points.patch`, `patches/pipeasio/0017-usdt-block-markers.patch`, `tools/traceprobe.c`, `tools/build_traceprobe.sh`, `.gitattributes` additions.
- Modified: `scripts/bench-suite.sh` (lines 12, 133-175, 179-188, 332-396), `scripts/bench-run.sh` (mode check line 64), `scripts/bench-report.py` (capture 1761-2013; render 2356-2553; profile 2115-2301; compare 2566-3003; parser 3410-3479), `scripts/bench-osc.py` (decode 69-79), `scripts/build-audit.sh` (lines 13, 15, 352-481, structural checks), `scripts/test-bench-report.py`, `scripts/test-bench-suite.sh`, `Makefile` (`test-profiler`), `.gitignore`, `CHANGELOG.md`/`patches/BASE.txt` notes.
- Reused as-is: `scripts/lib/lifecycle.sh` (pid matching), `scripts/lib/config.sh` (paths), `scripts/setup-realtime.sh`, `scripts/check-ntsync.sh`, `scripts/check-live-audio.sh`, `tools/build_apcprobe.sh` (toolchain pattern), `tools/liveinject.c`, `tools/run_in_prefix.sh`, `scripts/container-build.sh` (mirrored by the dev loop).
