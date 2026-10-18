# Design A — machine setup script + developer build loop (`profiler/`)

Companion to `wine-interface-profiler-plan.md`. Repo facts verified against the aceb236 tree. Items marked **VERIFY:** could not be verified from the repo.

Two findings that shape everything:

1. **The build's source freeze copies every untracked, non-ignored file in the repo into a `/tmp` tmpfs snapshot and aborts if the tree digest changes during the build** (`build.sh:67-108`, `scripts/source-tree-digest.sh` uses `git ls-files --cached --others --exclude-standard`). So: (a) restored `bench/` assets and any profiler run output must be git-ignored or excluded via `.git/info/exclude`; (b) nothing under `profiler/` may be written at runtime; all state goes to `~/.local/{state,share}/profiler/`.
2. **The Windows mirror had CRLF files in the working tree, but the blobs are LF.** Move code to the VM as git objects (`git bundle`), never as worktree files via scp. (The mirror has since been switched to `core.autocrlf=false` and re-checked-out.)

---

## 1. Repository layout

```
profiler/
├── README.md                      overview, bootstrap, phase map, how the agent uses it
├── .gitignore                     *.log, runs/, scratch/, __pycache__/
├── setup/
│   ├── setup-machine.sh           the machine setup script (§2)
│   ├── verify.sh                  re-checks everything, exit≠0 on failure (§2.6)
│   ├── bootstrap.md               the Windows-side steps (bundle, scp of media, VM RAM)
│   ├── lib/log.sh                 colour/log/summary library (§2.2)
│   ├── lib/phase.sh               phase registry, markers, dry-run, --only/--skip (§2.3)
│   ├── phases/NN-<name>.sh        one file per phase, sourced in order (§2.4)
│   ├── templates/                 files written to the host (verbatim, with @@VARS@@)
│   │   ├── sudoers-passwordless    → /etc/sudoers.d/90-profiler-colby
│   │   ├── sudoers-helper          → /etc/sudoers.d/91-profiler-helper
│   │   ├── limits-profiler.conf    → /etc/security/limits.d/90-profiler.conf
│   │   ├── sysctl-profiler.conf    → /etc/sysctl.d/90-profiler.conf
│   │   ├── sddm-autologin.conf     → /etc/sddm.conf.d/zz-profiler-autologin.conf
│   │   ├── profiler-inhibit.service→ ~/.config/systemd/user/
│   │   ├── profiler-dashboard.service → ~/.config/systemd/user/
│   │   ├── pw-90-profiler-null-sink.conf → ~/.config/pipewire/pipewire.conf.d/
│   │   ├── pw-91-profiler-clock.conf     → ~/.config/pipewire/pipewire.conf.d/
│   │   └── profiler.fish, profiler.bashrc (PATH snippets)
│   ├── root-helper/profiler-root-helper   → /usr/local/sbin/ (§2.5)
│   └── plugins.lock               URL + sha256 for Dexed / K1v (placeholders until first run)
├── bin/
│   ├── with-session-env           export DISPLAY/WAYLAND_DISPLAY/XAUTHORITY/DBUS from the Plasma session, exec
│   ├── state                      snapshot | restore | diff | list | clean-crash (§2.4.n)
│   ├── trace-prereqs              tracer prerequisites report (§2.4.o)
│   └── bench                      suite wrapper: session env + OSC ports + output dir + runtime root
├── dev/
│   ├── wine-dev.sh                persistent-container dev loop (§3)
│   ├── container/init.sh          runs inside the container: mirrors container-build.sh steps 1-3
│   ├── container/pipeasio-init.sh mirrors container-build.sh step 4 (configure only)
│   └── build-official.sh          flock-wrapped `build.sh` + `installer.sh runtime install` (the "keep" gate)
└── (tracer/, control/, scenarios/, dashboard/ — other designs)
```

Why one top-level dir and not `scripts/`, `tools/` or `beta/`: `scripts/` is policed by `make test` (`test-installer-ui.sh` asserts every sentence comes from `scripts/lib/ui.sh`'s dictionary; `test-release-policy.sh`, `test-config-boundary.sh` audit that tree). `tools/` is PE probes; `beta/` is the tester kit with its own SHA256SUMS. Upstream never touches `profiler/`, so rebases are conflict-free; `build.sh` snapshots it harmlessly (small, read-only). Wine/PipeASIO patches still go where the audit expects them (`patches/0108-…`, `patches/pipeasio/0017-…`).

Branch and remotes: VM clone is canonical (`~/Projects/ableton-linux`, branch `profiler`, `origin` = upstream). The Windows mirror adds `git remote add vm ssh://abletonlinux/home/colby/Projects/ableton-linux` and only ever `git fetch vm`. `.gitattributes` on our branch: `profiler/** text eol=lf`, `*.sh text eol=lf`.

---

## 2. `profiler/setup/setup-machine.sh`

### 2.1 Invocation

```
profiler/setup/setup-machine.sh --profile vm|baremetal [options]

  --live-installer PATH    default ~/Proprietary/ableton/Ableton Live 12 Trial Installer.exe
  --media-dir DIR          default ~/Proprietary/ableton
  --repo-dir DIR           default ~/Projects/ableton-linux
  --jobs N                 build parallelism (default: computed, §2.4.j)
  --audio-buffer N         64|128|256|512|1024 (vm default 128, baremetal 64)
  --passwordless-sudo      write NOPASSWD ALL sudoers (vm profile default: on; baremetal: off)
  --autologin              SDDM autologin into Plasma Wayland (vm default: on)
  --vm-ram-check           warn + print .vmx instructions when MemTotal < 12 GiB
  --yes                    non-interactive: skip the human checklist wait, accept defaults
  --dry-run                print every command, write nothing (sudo never invoked)
  --only P[,P]  --skip P[,P]  --from P   phase selection (names below)
  --force                  ignore done-markers
  --list-phases  --no-color  -h
```

Run as `colby`, `#!/usr/bin/env bash`, `set -euo pipefail`, `LC_ALL=C.UTF-8`. Over SSH: `ssh -t abletonlinux 'bash -lc "~/Projects/ableton-linux/profiler/setup/setup-machine.sh --profile vm"'` (`-t` for the sudo prompt; fish is the login shell so everything goes through `bash -lc`). Options persist to `~/.config/profiler/setup.conf` (`key=value`) so re-runs need no flags. Exit codes: 0 ok, 1 phase failed, 2 usage, 3 reboot/re-login required.

Phase order (dependency-driven):

| # | name | needs |
|---|---|---|
| 00 | `preflight` | – |
| 01 | `sudo` | – (first, so every later sudo is non-interactive) |
| 02 | `packages` | sudo |
| 03 | `podman` | packages |
| 04 | `limits` | packages |
| 05 | `session` | packages |
| 06 | `audio` | packages (pipewire restart) |
| 07 | `repo` | packages (git) |
| 08 | `media` | – |
| 09 | `build` | podman, repo, media |
| 10 | `install` | build, session, audio |
| 11 | `plugins` | install |
| 12 | `osc` | install |
| 13 | `human` | install, osc, session |
| 14 | `golden` | human |
| 15 | `tracecheck` | packages, install |
| 16 | `claude` | – |
| 17 | `dashboard` | packages (node) |
| 18 | `summary` | all |

### 2.2 Log/colour library `profiler/setup/lib/log.sh`

- Colour only when stdout is a tty, `NO_COLOR` unset, `TERM` not `dumb`, and `--no-color` absent. Glyphs UTF-8 when `LANG`/`LC_ALL` is UTF-8, ASCII otherwise.
- `log_init LOGFILE`: `mkdir -p ~/.local/state/profiler`, `LOGFILE=~/.local/state/profiler/setup-$(date -u +%Y%m%dT%H%M%SZ).log`, `exec 3>&1` keeps the terminal; every message goes coloured to fd 3 and plain (ANSI-free) to the file. Command output is captured by `run` through `tee -a "$LOGFILE"`, prefixed `    │ `. Symlink `~/.local/state/profiler/setup-latest.log`.
- API: `section N TOTAL name` (bold cyan rule `══ [03/18] packages ══`), `step msg` (`→`), `ok msg` (green `✓`), `warn msg` (yellow `⚠`, counted), `fail msg` (red `✗`, counted; phase aborts), `skip msg` (dim `↷`), `info msg` (blue `i`), `kv key value` (aligned detail line). Every line carries `[HH:MM:SS]`.
- `run [--quiet] [--sudo] [--timeout S] -- cmd…`: prints the command (dim), honours `DRY_RUN` (prints `[dry-run]` and returns 0), runs under `timeout` when asked, streams output into the log, and on non-zero exit calls `fail` with the exit code and the last 20 lines. `--sudo` prefixes `sudo -n` (never prompts; phase `sudo` guarantees it works).
- `summary_table`: one row per phase: name | status (`ok|skipped|warn|failed|not-run`) | wall time | note; followed by `WARNINGS`, `ACTIONS REQUIRED` (re-login, reboot, human steps), the log path.

### 2.3 Phase framework `profiler/setup/lib/phase.sh`

- Each phase file defines `phase_<name>_check` (returns 0 when the desired state is already present; read-only) and `phase_<name>_apply`. The runner: if `--force` not given and `check` passes → `skip`; else `apply`, then `check` again (must pass, else `fail`), then write the marker `~/.local/state/profiler/phases/NN-<name>.done` (`ts=… stamp=sha256(templates+inputs)`). Markers are advisory: a later run always re-evaluates `check`, so the script is idempotent and resumable after a crash or a reboot.
- `--dry-run` exports `DRY_RUN=1`; `run` prints; `check` functions still run (read-only).
- `sudo` keepalive: after phase `sudo`, `( while true; do sudo -n -v; sleep 50; done ) &` with the pid killed in the EXIT trap (only when NOPASSWD is not in force).
- `need_relogin=1` / `need_reboot=1` flags set by phases; summary prints them and the exit code becomes 3.

### 2.4 Phases

#### 00 `preflight`

Read-only. Fails on hard requirements, warns otherwise:

- `/etc/os-release` ID in `cachyos|arch`; `uname -m` = x86_64; `/lib/ld-linux-x86-64.so.2 --help | grep 'x86-64-v3 (supported)'`.
- Kernel ≥ 6.14, `[ -c /dev/ntsync ]`, `/sys/module/ntsync`, `[ -r /sys/kernel/btf/vmlinux ]`, `[ -d /sys/bus/event_source/devices/uprobe ]`, `mountpoint -q /sys/kernel/tracing`, `/proc/sys/net/core/bpf_jit_enable` = 1, `zgrep` of `/proc/config.gz` for `CONFIG_UPROBE_EVENTS=y CONFIG_BPF_EVENTS=y CONFIG_KPROBES=y CONFIG_USER_STACKTRACE_SUPPORT=y CONFIG_DEBUG_INFO_BTF=y CONFIG_HZ_1000=y`.
- Kernel package vs running kernel: `pkgbase=$(cat /usr/lib/modules/$(uname -r)/pkgbase)` (→ `linux-cachyos`); `pacman -Q "$pkgbase"` version must match `uname -r`, else `need_reboot=1`.
- RAM: `MemTotal` < 12 GiB → warn "container build needs ~1.2 GiB per job; JOBS will be clamped" and, with `--vm-ram-check`, print: power the VM off, set `memsize = "16384"` in the `.vmx`.
- Disk: `df -BG --output=avail ~` ≥ 60 GiB; `/tmp` is tmpfs → warn that `build.sh` hard-codes `/tmp` (no `TMPDIR`), needs ≥ 2 GiB free there.
- Swap present; `sched_rt_runtime_us` recorded; `clocksource` = tsc; THP setting recorded.
- Network: `curl -fsI https://github.com`, `https://snapshot.ubuntu.com`, `https://apt.llvm.org`, `https://registry-1.docker.io/v2/` (401 is fine), pacman mirror reachable (`pacman -Sy` is NOT run here).
- Session: `systemctl --user show-environment | grep -E '^(DISPLAY|WAYLAND_DISPLAY|XAUTHORITY|DBUS_SESSION_BUS_ADDRESS)='` all present → "Plasma session detected"; else warn that phases `install`/`human` need it.
- Shell: login shell fish → info "all remote invocations must use `bash -lc`".
- Time: `timedatectl show -p NTPSynchronized`, `vmware-toolbox-cmd timesync status` (VM).
- Tools the script itself needs now: `sudo curl git tar zstd sha256sum timeout flock`.

#### 01 `sudo`

- `sudo -v` once (interactive, tty).
- `--passwordless-sudo` (vm default): write `/etc/sudoers.d/90-profiler-colby` from the template (`colby ALL=(root) NOPASSWD: ALL`) via `visudo -cf FILE` on a temp copy first, then `install -m 0440 -o root -g root`. Check: `sudo -n true`.
- Both profiles: install the root helper (§2.5): `install -m 0755 -o root -g root profiler/setup/root-helper/profiler-root-helper /usr/local/sbin/`, `install -d -m 0755 /var/lib/profiler /run/profiler`, sudoers `/etc/sudoers.d/91-profiler-helper`: `colby ALL=(root) NOPASSWD: /usr/local/sbin/profiler-root-helper`. Check: `sudo -n /usr/local/sbin/profiler-root-helper version`.
- Baseline snapshot of host knobs right away: `sudo profiler-root-helper snapshot`.

#### 02 `packages`

Arch rules: no partial upgrades, so one `pacman -Syu` first (may bump the kernel → `need_reboot`), then `--needed` installs. Non-interactive with `--noconfirm`.

```bash
sudo pacman -Syu --noconfirm
kpkg="$(cat /usr/lib/modules/$(uname -r)/pkgbase)"          # linux-cachyos
sudo pacman -S --needed --noconfirm \
  base-devel git binutils zstd cabextract unzip rsync ccache jq python \
  podman passt crun netavark aardvark-dns fuse-overlayfs \
  bpftrace bcc bcc-tools python-bcc perf strace ltrace sysstat \
  libbpf bpf clang llvm lld pahole elfutils "${kpkg}-headers" \
  mingw-w64-gcc xorg-server-xvfb xdotool xorg-xprop xdg-utils desktop-file-utils shared-mime-info \
  alsa-utils inotify-tools tmux socat lsof psmisc wl-clipboard nodejs npm shellcheck
# optional (vm profile prompts unless --yes; baremetal off by default):
sudo pacman -S --needed --noconfirm qt6-base qt6-wayland firefox
```

Verified in repos today: bpftrace 0.27.0 (depends on bcc), bcc 0.37, perf 7.2.10, cmake 4.4, ninja, mingw-w64-gcc 16.2, sysstat, xdotool, xorg-server-xvfb, winetricks, cabextract, rsync, ccache, lld, nodejs 26.11, npm 12.2, shellcheck 0.11. `ananicy-cpp`: disable through `profiler-root-helper knob set ananicy off` so `reset` can restore it. `cachyos-settings` sysctls stay; the helper's `snapshot` records `sysctl -a`.

#### 03 `podman`

```bash
getsubids colby >/dev/null 2>&1 || sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 colby
podman system migrate
podman info --format '{{.Host.Security.Rootless}} {{.Store.GraphDriverName}} {{.Store.GraphStatus}} {{.Host.NetworkBackend}}'
podman run --rm docker.io/library/alpine:3.20 true
```
Check: rootless `true`, driver `overlay` with `Native Overlay Diff: "true"`, network `netavark`. Storage lands in `~/.local/share/containers/storage`. Also `loginctl enable-linger colby`.

#### 04 `limits`

- `sudo usermod -aG realtime,audio colby`. `need_relogin=1` when `id -nG` lacks `realtime`.
- Call the repo's own profile, non-interactively: `"$REPO/scripts/setup-realtime.sh"` → writes `/etc/security/limits.d/90-ableton-rt.conf` (@audio rtprio 95 / memlock unlimited / nice -19) and `/etc/sysctl.d/90-ableton-rt.conf` (vm.swappiness=10), applies `sysctl --system`. PAM takes the last matching line alphabetically; `chrt -r 10 true` must succeed (the launcher's probe, `scripts/ableton-live:1715`).
- `/etc/security/limits.d/90-profiler.conf`: `colby - nofile 524288`.
- `/etc/sysctl.d/90-profiler.conf` (vm profile only): `kernel.perf_event_paranoid = -1`, `kernel.kptr_restrict = 0`. Baremetal: nothing here; the helper handles it per run and resets.
- Check: group membership (via `getent group realtime`), both files present, `sysctl -n vm.swappiness` = 10.

#### 05 `session`

- `--autologin` (vm): `/etc/sddm.conf.d/zz-profiler-autologin.conf`:
  ```
  [Autologin]
  User=colby
  Session=plasma
  Relogin=true
  ```
  (`plasma` = `/usr/share/wayland-sessions/plasma.desktop`. VERIFY: `ls /usr/share/wayland-sessions`.) Precedence: the script runs `sudo grep -n -A3 '^\[Autologin\]' /etc/sddm.conf /etc/sddm.conf.d/*.conf` and, if any other file sets `User=`, patches that file in place (backup `*.profiler-bak`). Takes effect at next boot.
- Screen lock / DPMS / sleep in KDE (user-level):
  ```bash
  kwriteconfig6 --file kscreenlockerrc --group Daemon --key Autolock false
  kwriteconfig6 --file kscreenlockerrc --group Daemon --key LockOnResume false
  kwriteconfig6 --file powerdevilrc --group AC --group Display --key DimDisplayWhenIdle false
  kwriteconfig6 --file powerdevilrc --group AC --group Display --key TurnOffDisplayWhenIdle false
  kwriteconfig6 --file powerdevilrc --group AC --group SuspendAndShutdown --key AutoSuspendAction 0
  systemctl --user try-restart plasma-powerdevil.service
  ```
  (VERIFY: Plasma 6 key names and unit name.) Belt and braces: user unit `profiler-inhibit.service` = `kde-inhibit --power --screenSaver --notifications sleep infinity`, `WantedBy=graphical-session.target`.
- Install `profiler/bin/with-session-env` (symlinked to `~/.local/bin/with-session-env`): reads `systemctl --user show-environment`, exports an allowlist (`DISPLAY WAYLAND_DISPLAY XAUTHORITY DBUS_SESSION_BUS_ADDRESS XDG_CURRENT_DESKTOP XDG_SESSION_TYPE XDG_SESSION_DESKTOP DESKTOP_SESSION KDE_FULL_SESSION KDE_SESSION_VERSION`), sets `XDG_RUNTIME_DIR=/run/user/$(id -u)` if unset, fails with exit 3 and a clear message when `DISPLAY` is absent, then `exec "$@"`. Re-reads every time because `XAUTHORITY` has a random suffix per login. Wine stays on winex11 via Xwayland `:0`.
- Check: `with-session-env xdotool getdisplaygeometry` prints a geometry; autologin file present; inhibit unit active.

#### 06 `audio`

`~/.config/pipewire/pipewire.conf.d/90-profiler-null-sink.conf`
```
context.objects = [
  { factory = adapter
    args = { factory.name = support.null-audio-sink  node.name = "profiler-null"
             node.description = "Profiler null sink"  media.class = Audio/Sink
             object.linger = true  audio.position = [ FL FR ]  audio.rate = 48000
             monitor.channel-volumes = true } }
]
```
`~/.config/pipewire/pipewire.conf.d/91-profiler-clock.conf`
```
context.properties = {
  default.clock.rate = 48000  default.clock.allowed-rates = [ 48000 ]
  default.clock.quantum = 256  default.clock.min-quantum = 32  default.clock.max-quantum = 2048
}
```
`systemctl --user restart pipewire.socket pipewire.service wireplumber.service pipewire-pulse.service`; check `pw-cli ls Node | grep -q profiler-null`, `pw-metadata -n settings | grep clock.min-quantum` = 32, `pw-metadata -n settings 0 clock.force-quantum 0`.

PipeASIO selects nodes by `node.name` via `output_device`/`input_device` (env `PIPEASIO_OUTPUT_DEVICE`/`PIPEASIO_INPUT_DEVICE`), locks the graph quantum to its buffer unless `follow_device_clock`, and `fixed_buffer_size` takes the size away from Live. PipeWire's `min-quantum` must be ≤ the smallest buffer we will ever request (32; the current 1024 would silently pin everything to 1024). Buffer default: vm **128**, baremetal **64**; per-run override `PIPEASIO_PREFERRED_BUFFERSIZE`. After phase 10 seeds `~/.config/pipeasio/config.ini`, append `output_device = profiler-null` and `input_device = profiler-null`. `realtime` stays `0`.

#### 07 `repo`

Bootstrap (Windows side, documented in `bootstrap.md`):
```powershell
cd C:\src\AbletonLinux\ableton-linux
git bundle create C:\src\AbletonLinux\profiler-bootstrap.bundle profiler
scp C:\src\AbletonLinux\profiler-bootstrap.bundle abletonlinux:~/
ssh abletonlinux 'bash -lc "git clone -b profiler ~/profiler-bootstrap.bundle ~/Projects/ableton-linux && cd ~/Projects/ableton-linux && git remote set-url origin https://github.com/shibco/ableton-linux && git fetch origin && git merge-base --is-ancestor aceb236 HEAD && echo OK"'
```
Phase (handles a fresh clone too):
```bash
[ -d "$REPO/.git" ] || git clone https://github.com/shibco/ableton-linux "$REPO"
git -C "$REPO" config core.autocrlf false; git -C "$REPO" config core.eol lf
git -C "$REPO" rev-parse -q --verify profiler >/dev/null || git -C "$REPO" checkout -b profiler aceb236
git -C "$REPO" checkout profiler
git -C "$REPO" archive 'aceb236^' bench | tar -x -C "$REPO"          # restores bench/.gitignore too
grep -qx 'bench/' "$REPO/.git/info/exclude" || echo 'bench/' >> "$REPO/.git/info/exclude"
( cd "$REPO" && sha256sum -c bench/SHA256SUMS )                       # 12 assets
```
`bench/` goes in `.git/info/exclude` (not `.gitignore`) so it never enters a commit or the build snapshot. Profiler-driven bench runs always pass `--output ~/.local/share/profiler/runs/<id>/bench`. Check: branch `profiler`, `aceb236` ancestor, `bench/SHA256SUMS` verifies, clean status.

#### 08 `media`

Expected in `~/Proprietary/ableton/`: `Ableton Live 12 Trial Installer.exe` + `-1.bin`, `-2.bin`, `-3.bin` (Inno Setup slices must sit beside the exe: `installer.sh:1311-1316` does `cd "$(dirname "$installer")"`). Windows copy: `scp -r "C:\src\AbletonLinux\AbletonInstaller\*" abletonlinux:Proprietary/ableton/` (6.1 GB). Checks: exe ≈ 6.5 MB, sha256 starts `a2652ee454fcf788`, exactly three `*.bin` > 1 GiB, `strings` matches `Ableton[ _-]*Live[ _-]*12` (what `installer.sh:552-591` does), `grep -qa 'Inno Setup'` on the first 4 MiB.

#### 09 `build`

Pre-checks: Live/wineserver not running; `/tmp` ≥ 2 GiB free; JOBS = `min(nproc, max(2, (MemAvailable_GiB − 2) / 1.2))` unless `--jobs`; `podman image exists ableton-wine-build:22.04` reported.

```bash
cd "$REPO"
JOBS="$JOBS" PIPEASIO_TSAN_MODE=skip ./build.sh 2>&1 | tee "$HOME/.local/state/profiler/build-$(date -u +%Y%m%dT%H%M%SZ).log"
```
Expected on 8 vCPU: ~50–60 min cold, ~15–20 min with warm `.ccache`. Hard rule printed before starting: **do not edit anything in the repo while it runs**. `profiler/dev/build-official.sh` wraps this with `flock ~/.local/state/profiler/build.lock`. Check: `dist/wine-d2d1-nspa-11.13-2026.08.28.1.tar.zst` + `.sha256` + `BUILD-INFO-2026.08.28.1.txt` + `pipewire-version-probe`; `./scripts/build-audit.sh dist/*.tar.zst` passes.

#### 10 `install`

```bash
ABLETON_LIVE_INSTALL_TIMEOUT=7200 \
profiler/bin/with-session-env ./scripts/installer.sh install \
  --live-installer "$HOME/Proprietary/ableton/Ableton Live 12 Trial Installer.exe" \
  --live-major 12 --link=off --yes \
  --audio-buffer=128 --audio-threads=auto --rt=auto --power=off --dpi=100 --shortcuts=preserve
```
Flag spellings verified against `installer.sh:25-32` (`--rt=auto|off`; the launcher maps `ABLETON_RT=on` to `auto`). `--power=off` for vm; baremetal `--power=performance --audio-buffer=64`. Requirements the installer enforces (`installer.sh:616-689`): x86_64, `timeout tar zstd`, running PipeWire ≥ 1.4.2, `cabextract`, `strings`, a window connection. Non-interactive: `--yes`; remaining prompts time out after `ABLETON_UI_PROMPT_TIMEOUT=30`. Output locations (`scripts/lib/config.sh:511-516,547,556`): runtime `~/.local/opt/wine-d2d1-nspa-11.13`, prefix `~/.wine-ableton`, data `~/.local/share/ableton-wine`, config `~/.config/ableton-wine/{config,preferences}`, launcher `~/.local/bin/ableton-live`, PipeASIO `~/.config/pipeasio/config.ini` (seeded `inputs=2 outputs=2 buffer_size=128 fixed_buffer_size=true auto_connect=true`, `setup-prefix.sh:1283-1290`). Check: `~/.wine-ableton/drive_c/ProgramData/Ableton/Live 12 Trial/Program/Ableton Live 12 Trial.exe`, `wine --version`, `grep -c pipeasio ~/.wine-ableton/system.reg` > 0, `ableton-live --help`. Optional sub-phase: `make check && make test`.

#### 11 `plugins`

`profiler/setup/plugins.lock`:
```
dexed  url=https://github.com/asb2m10/dexed/releases/download/v1.0.1/<asset>.zip  sha256=<fill>  member=Dexed.vst3
k1v    url=https://www.nilsschneider.de/<path>/K1v_x64.vst3.zip                   sha256=<fill>  member=K1v_x64.vst3
```
(VERIFY asset names at implementation; placeholders filled by `--pin-plugins`.) Download to `~/.cache/profiler/downloads/<name>/`, verify sha256 when pinned, unzip into scratch, copy the member (`Dexed.vst3` is a bundle *folder*; `K1v_x64.vst3` a single file) into `~/.wine-ableton/drive_c/Program Files/Common Files/VST3/`. Check: the suite's `find_vst` paths (`bench-suite.sh:122-131`).

#### 12 `osc`

User Library: `drive_c/users/colby/Documents/Ableton/User Library` (the beta profiler probes `Documents` and legacy `My Documents`, `beta/scripts/ableton-linux-profiler.sh:184-199`). Wine may make `Documents` a symlink into `$HOME` (VERIFY with `readlink`). `ul="$(readlink -f ~/.wine-ableton/drive_c/users/colby/Documents)/Ableton/User Library/Remote Scripts"`, `profiler/control/install.sh --prefix ~/.wine-ableton`. Record `user_library=` in setup.conf so `state` includes it.

#### 13 `human`

Prints the checklist, launches Live (`with-session-env ~/.local/bin/ableton-live`), waits on `read -r` unless `--yes`:

1. Accept the licence; authorise the trial or continue unauthorised.
2. Settings > Audio: Driver Type **ASIO**, Audio Device **PipeASIO**, 48000.
3. Settings > Link, Tempo & MIDI: Control Surface **AbletonOSC** (Input/Output none).
4. Settings > Licenses/Maintenance: updates/usage data off; Library: Cloud off. Leave the GPU renderer at Live's default.
5. **File > Quit** (Ctrl+Q). Never SIGTERM.

Then verify: newest `…/Live 12*/Preferences/Log.txt` contains `PipeASIO` and `Open: finished`, `grep -a AbletonOSC Log.txt` (VERIFY exact line), no crash-recovery files, no `wineserver` for the prefix.

#### 14 `golden` — `profiler/bin/state`

```
state snapshot [--name golden]     state restore [--name golden] [--keep-logs]
state diff [--name golden]         state list      state clean-crash
```
Snapshot set (`~/.local/share/profiler/golden/<name>/`): `~/.wine-ableton` → `prefix/`, `~/.config/ableton-wine`, `~/.config/pipeasio/config.ini`, `~/.config/pipewire/pipewire.conf.d`, `~/.local/share/ableton-wine` → `data/`, `~/.local/opt/wine-d2d1-nspa-11.13` → `runtime/`, `~/.local/bin/ableton-live`, `~/Documents/Ableton` when the User Library lives there, `pw-metadata -n settings` text, `wpctl status`, `MANIFEST.json`. Mechanism: `cp -a --reflink=always SRC DST` when `stat -f -c %T` says btrfs, else `rsync -aHAX --delete`. Restore: refuse while prefix processes exist (`grep -lzF "WINEPREFIX=$HOME/.wine-ableton" /proc/[0-9]*/environ`), else `wineserver -k` + `-w`, `rm -rf` target, reflink copy back, then `pw-metadata -n settings 0 clock.force-quantum 0`, delete `CrashDetection.cfg CrashRecoveryInfo.cfg` and `Preferences/BaseFiles/*` (`clean-crash` does only this last part). `diff`: `rsync -rni --delete` dry-run listing + registry sha256 comparison. Two snapshots: `post-install` (before the human phase) and `golden` (after it).

#### 15 `tracecheck` — `profiler/bin/trace-prereqs`

Table, exit≠0 on hard failures: BTF file; `bpftool btf dump file /sys/kernel/btf/vmlinux format c | head -1`; `bpftool feature probe kernel | grep -E 'bpf_probe_read_user|HAVE_BPF_JIT'`; `/sys/bus/event_source/devices/uprobe/type`; `bpftrace --version`, `bpftrace -l "usdt:$RT/lib/wine/x86_64-unix/ntdll.so:*"` + `readelf -n … | grep -c stapsdt` (0 until the USDT patch is built: "pending"), `perf version`, `clang --version` + `-target bpf` smoke compile, `pahole --version`, `/dev/ntsync` mode 0666 + `strings $RT/bin/wineserver | grep -c ntsync`, sysctls, `sudo -n profiler-root-helper version`, `ulimit -l`, THP. Also runs `scripts/check-ntsync.sh` (Live closed).

#### 16 `claude`

```bash
curl -fsSL https://claude.ai/install.sh | bash          # native binary → ~/.local/bin/claude
install -m 0644 templates/profiler.fish ~/.config/fish/conf.d/profiler.fish    # fish_add_path -g ~/.local/bin
grep -q 'profiler PATH' ~/.bashrc || cat templates/profiler.bashrc >> ~/.bashrc
grep -q bashrc ~/.bash_profile 2>/dev/null || printf '[[ -f ~/.bashrc ]] && . ~/.bashrc\n' >> ~/.bash_profile
```
Login instructions printed: interactive `claude` → `/login` → open URL on the Windows host → paste code; or `claude setup-token` elsewhere → `CLAUDE_CODE_OAUTH_TOKEN=…` in `~/.config/profiler/env` (0600). Check: `claude --version`; `fish -c 'command -v claude'`; `bash -lc 'command -v claude'`.

#### 17 `dashboard`

`cd $REPO/profiler/dashboard && npm ci`; user unit `profiler-dashboard.service` (`npm run dev -- --host 0.0.0.0 --port 5173`, `WorkingDirectory=`, `Restart=on-failure`), enabled + started; prints `http://abletonlinux:5173`. Skipped with a warning if `profiler/dashboard/package.json` does not exist yet.

#### 18 `summary`

Summary table, warnings, actions (re-login/reboot/human steps outstanding), then "Next": `ssh -t abletonlinux 'bash -lc "cd ~/Projects/ableton-linux && claude"'`, `profiler/setup/verify.sh`, `profiler/bin/trace-prereqs`, `profiler/bin/bench --dry-run --tag smoke`.

### 2.5 Root helper `/usr/local/sbin/profiler-root-helper`

Bash, root-owned 0755, refuses to run if its own file or `/usr/local/lib/profiler` is group/world-writable (pattern from `scripts/setup-realtime.sh:34-47`). Invoked as `sudo -n profiler-root-helper VERB …`. With NOPASSWD ALL on the VM it is a guard-rail and portable interface, not a security boundary.

```
version
snapshot [--force]                      # /var/lib/profiler/baseline.env: thp, sysctl allowlist, governor/epp per cpu,
                                        #   ananicy-cpp state, irq affinities, sched_rt_runtime_us; first call only
reset                                   # restore everything in baseline.env; idempotent
knob get KEY | set KEY VALUE            # KEY ∈ thp(always|madvise|never) | governor | epp | ananicy(on|off) |
                                        #   sysctl.<kernel.perf_event_paranoid|kernel.kptr_restrict|kernel.sched_rt_runtime_us|
                                        #   kernel.sched_autogroup_enabled|kernel.timer_migration|vm.swappiness|vm.max_map_count> |
                                        #   irq-affinity.<N>(hexmask) | irq-prio.<N>(1..98) | rt-prio.<pid>(fifo:N|rr:N|other)
                                        #   (rt-prio only for pids whose /proc/pid/exe is under ~/.local/opt/wine-*/bin)
trace start --tool NAME --run-dir DIR [--pid N] [--duration S] [-- ARGS…]
                                        # NAME resolves to /usr/local/lib/profiler/tracer/NAME (root-owned) or,
                                        #   when /etc/profiler/allow-user-tools exists (vm profile), to $REPO/profiler/tracer/NAME;
                                        #   DIR must be under the invoking user's ~/.local/share/profiler/runs; runs via setsid,
                                        #   stdout/err → DIR/trace/<tool>.{out,err}, pidfile /run/profiler/<id>.pid, chown -R $SUDO_UID on exit
trace stop ID [--signal INT] | status | logs ID
install-tracer SRC_DIR                  # copy repo tracer dir to /usr/local/lib/profiler/tracer (sha256 manifest recorded)
```
All arguments validated by anchored regexes; keys outside the allowlist refused with exit 2; every mutation appended to `/var/log/profiler-root-helper.log`.

### 2.6 `profiler/setup/verify.sh`

Runs every phase's `check` function plus: `sudo -n true` / helper `version`; `podman info` driver; `id -nG` vs `getent group realtime`; `pacman -Q $kpkg` vs `uname -r`; display probe; `pw-cli ls Node | grep profiler-null`; `pw-metadata -n settings` quantum values; `git -C $REPO status --porcelain` empty and `bench/SHA256SUMS` ok; `dist/` artifacts + `scripts/build-audit.sh`; runtime/prefix/launcher/Live exe; `scripts/check-ntsync.sh`; VST3s; AbletonOSC dir; `state diff --name golden`; `trace-prereqs`; `claude --version`; dashboard build. Exit 0 only when all hard checks pass; same coloured table.

---

## 3. Developer build loop `profiler/dev/wine-dev.sh`

Goal: 20–60 s Wine iterations in the *same* Ubuntu 22.04 image, same paths, same compilers, same ccache, same patch application and configure flags as `scripts/container-build.sh`, so a dev-verified patch file drops into `patches/` and the official build reproduces it.

Environment (defaults): `WINE_DEV_NAME=wine-dev`, `IMAGE=ableton-wine-build:22.04`, `WINE_DEV_WORK=~/wine-dev/work` (bind-mounted at `/work`; a plain directory on `@home`, so the agent edits `~/wine-dev/work/wine-src/…` directly from the host), `REPO=~/Projects/ableton-linux` (`/src`, ro), `CCACHE=$REPO/.ccache` (`/ccache`, shared with `build.sh`; the Containerfile's `/usr/lib/ccache-shims` + `CCACHE_DIR=/ccache` apply automatically; identical paths mean the official build hits the dev cache), `DEV_ROOT=~/.local/opt/wine-d2d1-nspa-11.13-dev`, `JOBS` as computed by setup, `INSTALL_PREFIX=/opt/wine-d2d1-nspa-11.13`.

Subcommands:

- `init`
  ```bash
  podman image exists "$IMAGE" || podman build -t "$IMAGE" -f "$REPO/Containerfile" "$REPO"
  mkdir -p "$WINE_DEV_WORK"
  podman create --name wine-dev --userns=keep-id --init -w /work \
    -v "$WINE_DEV_WORK:/work" -v "$REPO:/src:ro" -v "$CCACHE:/ccache" \
    -e CCACHE_DIR=/ccache -e CCACHE_MAXSIZE=5G -e JOBS="$JOBS" -e INSTALL_PREFIX="$INSTALL_PREFIX" \
    "$IMAGE" sleep infinity
  podman start wine-dev
  podman exec -i wine-dev bash -s < "$REPO/profiler/dev/container/init.sh"
  ```
  `container/init.sh` replays `container-build.sh:140-180`: `zstd -dc --long=27 /src/vendor/wine-base-5c23dd1c.tar.zst | tar -x -C /work/wine-src`; `git config --global --add safe.directory /work/wine-src`; `git init -q`; `git -c user.email=build@localhost -c user.name=dist add -A && commit -m "base 5c23dd1c"`; for each `patches/[0-9][0-9][0-9][0-9]-*.patch` then `patches/performance/*.patch`: `git am --3way`, prepending `From: dist <build@localhost>\nDate: Thu, 01 Jan 2026 00:00:00 +0000\n` when the first 8 lines lack `^From: `; `git tag series-aceb236`; `mkdir /work/build && cd /work/build && CPPFLAGS="-I/opt/ntsync-uapi" ../wine-src/configure --prefix=/opt/wine-d2d1-nspa-11.13 --enable-archs=i386,x86_64 --disable-tests`; `make -j$JOBS`; `make install DESTDIR=/work/stage`; `grep -q '^#define HAVE_LINUX_NTSYNC_H 1' include/config.h`. ~25–40 min once.
- `apply PATCHFILE…` — `git am --3way` into `/work/wine-src` with the same synthetic header rule; `apply --abort`; `log` shows commits since `series-aceb236`.
- `edit` — prints `~/wine-dev/work/wine-src`; commits made on the host with `git -C ~/wine-dev/work/wine-src commit`.
- `build [--dir dlls/ntdll]` — `podman exec wine-dev bash -lc 'cd /work/build && make -j$JOBS ${dir:+$dir} && make install DESTDIR=/work/stage'`. Incremental. VERIFY whether Wine's Makefile supports `make dlls/ntdll/install`; if not, `sync --artifacts` copies `dlls/ntdll/x86_64-unix/ntdll.so` → `lib/wine/x86_64-unix/`, `dlls/ntdll/x86_64-windows/ntdll.dll` → `lib/wine/x86_64-windows/` (and i386 pairs) directly.
- `pipeasio-init` / `pipeasio-build` — replay `container-build.sh:250-262,363-373,438-444,562-563`: untar `vendor/pipeasio-1.5.0.tar.gz --strip-components=1` into `/work/pipeasio`, `patch -p1 --no-backup-if-mismatch -i` each `patches/pipeasio/*.patch`, `PATH=/work/stage/opt/wine-d2d1-nspa-11.13/bin:$PATH PKG_CONFIG_PATH=/opt/pipewire-sdk/usr/lib/x86_64-linux-gnu/pkgconfig PKG_CONFIG_SYSROOT_DIR=/opt/pipewire-sdk CC=gcc CXX=g++ cmake -S . -B build -G Ninja -DWINEBUILD=…/bin/winebuild -DWINEGCC=…/bin/winegcc -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/opt/wine-d2d1-nspa-11.13 -DCMAKE_EXE_LINKER_FLAGS=-Wl,--allow-shlib-undefined -DBUILD_SETTINGS_PANEL=ON -DBUILD_TESTS=ON`; build = `cmake --build build -j$JOBS && DESTDIR=/work/stage cmake --install build && rm -f /work/stage/opt/…/bin/pipeasio-register`. The stage keeps `winebuild/winegcc` (the official pipeline deletes them only at strip time, `container-build.sh:613-616`).
- `sync [--strip]` — first run: `cp -a --reflink=auto ~/.local/opt/wine-d2d1-nspa-11.13 "$DEV_ROOT"` (keeps `.ableton-linux-runtime`, `ABLETON-WINE-BUILD-INFO.txt`, `share/ableton-wine/VERSION` that the launcher reads at `ableton-live:184`). Every run: refuse while any process has `/proc/*/exe` under either runtime; `rsync -a --itemize-changes --exclude 'ABLETON-WINE-*.txt' --exclude .ableton-linux-runtime ~/wine-dev/work/stage/opt/wine-d2d1-nspa-11.13/ "$DEV_ROOT/"`; print the changed-file list; write `$DEV_ROOT/PROFILER-DEV-INFO.txt` (HEAD, dirty flag, applied commits since `series-aceb236`, timestamp, stripped yes/no). Default **unstripped**; `--strip` replays `container-build.sh:607-610`.
- `format-patch [--number 0108] [--name slug]` — `git -C wine-src format-patch -1 --no-numbered --no-signature --stat=80`, renamed to `patches/0108-<slug>.patch` (or `patches/pipeasio/0017-…` from a `/work/pipeasio` diff against a pristine copy), then prints the audit checklist: bump `REQUIRED_WINE_TAIL` (`scripts/build-audit.sh:13`) / `REQUIRED_PIPEASIO_TAIL` (`:15`), add a `FINGERPRINTS` line (`:352-413`) or a `STAMP_ONLY` reason (`:424-481`), run `./scripts/build-audit.sh --freeze`; performance series stays exactly `0001` (`test-release-policy.sh:436`), so new work goes in the main series; configure.ac changes must also patch `configure`; protocol changes must include regenerated `server_protocol.h` etc.
- `shell`, `status` (container state, HEAD/dirty, last build/sync times, `DEV_ROOT` vs stage diff count), `logs`, `reset [--keep-work]`.

Launching Live against the dev runtime:
```bash
ABLETON_WINE_ROOT="$HOME/.local/opt/wine-d2d1-nspa-11.13-dev" WINE_MY_SWITCH=1 \
  profiler/bin/with-session-env scripts/ableton-live "bench/BenchmarkSets Project/Benchmark_Inbuilts.als"
```
`ABLETON_WINE_ROOT` from the environment outranks the saved config (`config.sh:540-547`); the launcher validates only `bin/wine`, `bin/wineserver`, `system.reg`; `lifecycle.sh:19-24,49-59` identify prefix processes by runtime root. Before switching runtimes: `state clean-crash` and make sure no wineserver from the other root serves the prefix.

Why acceptance A/B must use ONE runtime with the switch flipped: `bench-report.py profile`/`compare` hash the runtime identity (BUILD-INFO + wine + both PipeASIO halves) and flag any change; dev vs official also differ in stripping and ccache/link order. The dev loop compares `WINE_X=0` vs `WINE_X=1` on the same `$DEV_ROOT`, repeated pairs. A "keep" decision requires `profiler/dev/build-official.sh` = `flock` + `JOBS=… PIPEASIO_TSAN_MODE=skip ./build.sh` + `./scripts/installer.sh runtime install --yes` + the same A/B on the official runtime. The script refuses to run while the dev container is building and while any Live runs.

---

## 4. Verification and failure modes

After the script (expected results in brackets):

1. New SSH session → `id -nG | tr ' ' '\n' | grep -x realtime` (present) · `ulimit -r; ulimit -l` (≥95; unlimited) · `chrt -r 10 true && echo rt-ok`.
2. `profiler/setup/verify.sh` (all green).
3. `podman info --format '{{.Store.GraphDriverName}}'` (overlay) · `podman ps -a` (`wine-dev` after `init`).
4. `pw-cli ls Node | grep -A3 profiler-null` · `pw-metadata -n settings` (`clock.min-quantum 32`, `clock.force-quantum 0`).
5. `profiler/bin/with-session-env xdotool getdisplaygeometry` (e.g. `1920 1080`) from SSH.
6. `ls dist/` · `./scripts/build-audit.sh dist/wine-d2d1-nspa-11.13-2026.08.28.1.tar.zst` (`OK`).
7. `./scripts/check-ntsync.sh` (`OK: NTSync active …`) · `profiler/bin/trace-prereqs`.
8. `profiler/bin/with-session-env ./scripts/check-live-audio.sh` (`OK: Live opened the audio driver cleanly (Used SampleRate: 48000)`).
9. `profiler/bin/bench --dry-run --tag smoke` then a real `--tag baseline`.
10. `profiler/bin/state diff --name golden` after a run (drift only in Log.txt/Preferences; `state restore` returns it to empty).
11. `profiler/dev/wine-dev.sh init && … status && … build && … sync` then step 8 with `ABLETON_WINE_ROOT=…-dev`.
12. `claude --version`; `cd ~/Projects/ableton-linux && claude` (login once).

| Risk | Mitigation |
|---|---|
| 8 GiB RAM: `make -j8` of Wine OOMs or swaps | JOBS clamp from `MemAvailable`; `--vm-ram-check` prints the `.vmx` `memsize=16384` change; swap present |
| `/tmp` is a 3.9 GB tmpfs and `build.sh` hard-codes `/tmp` | preflight requires ≥2 GiB free; never store anything else in `/tmp` |
| Rootless podman on btrfs falls back to `vfs` or lacks subuids | `usermod --add-subuids` + `podman system migrate`; check `GraphDriverName=overlay`; `fuse-overlayfs` fallback |
| `apt.llvm.org` pin has aged out → image build fails at step [2/7] | bump `LLVM_PKG_VERSION` in `Containerfile` on our branch |
| Installer/Live started over SSH without a display | every GUI step goes through `with-session-env` (exit 3); SDDM autologin |
| `XAUTHORITY` path changes per login | `with-session-env` re-reads each call; `DISPLAY=:0` keeps Wine on x11 |
| fish login shell | all remote commands use `bash -lc`; PATH snippets for both shells |
| Group changes need a new login | documented; verify.sh detects; Live is launched from SSH sessions |
| SDDM `/etc/sddm.conf` may override `conf.d` | script inspects all files with sudo and patches whichever defines `[Autologin]` |
| `pacman -Syu` upgrades the kernel → running kernel ≠ headers/bcc | preflight/verify compare; summary demands a reboot |
| Build aborts: "source changed while its immutable snapshot was being made" | `build-official.sh` flock; all logs/state outside the repo; `bench/` excluded |
| SIGTERM-closed Live opens the recovered set next time | `state clean-crash` before every launch; `tools/liveinject.c` `ctrlq`/`close` |
| M4L device vs AbletonOSC bench handler ports | AbletonOSC's 11000/11001 via `ABL_BENCH_OSC_SEND/RECV`; Sets untouched |
| Live 12 Trial authorisation needs a browser inside the VM | `firefox` optional package; unauthorised demo mode acceptable |
| PipeWire min-quantum 1024 silently pins PipeASIO to 1024 | `91-profiler-clock.conf`; verify.sh checks `pw-metadata` |
| VM timing is noisy | stated everywhere as "function only"; buffer 128 default |
| Dev tree diverges from the official artifact | `PROFILER-DEV-INFO.txt` records HEAD/dirty; "keep" gate = official build + runtime install + A/B rerun |
| Replacing runtime files under a running wineserver | `sync`, `state restore`, `build-official.sh` refuse while prefix processes exist |
| Golden snapshot misses the User Library when `Documents` is a Wine symlink | phase `osc` resolves and records the real path; `state` includes it |
| `ananicy-cpp`/`cachyos-settings` tweaks skew measurements | helper `snapshot` baseline at phase 01; `knob set ananicy off`; `reset` restores |

Critical repo files to mirror/read: `scripts/container-build.sh` (lines 140-180, 250-262, 363-373, 438-444, 562-563, 607-616), `scripts/installer.sh` (flag grammar 25-32, payload checks 552-612, host preflight 616-689, Live install 1188-1344), `scripts/ableton-live` (env help 1-135, validation 341-348, RT/power 1706-1742, launch 1782-1909), `scripts/lib/config.sh` (paths 511-557), `scripts/lib/lifecycle.sh` (pid matching), `scripts/setup-realtime.sh`.
