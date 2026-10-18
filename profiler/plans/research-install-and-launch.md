# Research — install, launch and runtime environment (aceb236, runtime 2026.08.28.1)

## What blocks an unattended run

1. **The installer takes the `.exe` directly**: `sh install-ableton-latest.run install --live-installer "<dir>/Ableton Live 12 Trial Installer.exe"` or, from source, `./scripts/installer.sh install --live-installer … --live-major 12 --link=off --yes`. Accepts `ableton_live*.zip`, `*ableton*.exe`, `*live*.exe` (`scripts/installer.sh:422`). Runs Wine from the installer's own folder (`cd "$(dirname "$installer")"`, `installer.sh:1309-1317`), so the three `-N.bin` parts must sit next to the `.exe`. Engine detected by signature: "Inno Setup" → `/SILENT /SUPPRESSMSGBOXES /NORESTART '/MERGETASKS=!audiodriver'` (`installer.sh:1263-1306`). Our `.exe` contains "Inno Setup" 3 times, `.wixburn` 0 times.
2. **Nothing selects PipeASIO inside Live.** Settings > Audio > Driver Type ASIO > Audio Device PipeASIO is manual (`README.md:141-145`, `scripts/lib/ui.sh:395`). `Preferences.cfg` is binary; only read (theme) by `scripts/detect-theme.sh:161-175`, `scripts/ableton-live:1272-1376`.
3. **Licence agreement and authorisation wait for the first launch** (`BUILDING.md:148`, `ui.sh:382`). Authorisation is tied to the prefix's MachineGuid (`ui.sh:394`, `notes/ABLETON-WINE-ONLINE-AUTH.md:16-17`).
4. **`bench/` was deleted in HEAD** (aceb236); `scripts/bench-suite.sh:144-149` still expects it.
5. **The launcher passes no command-line switches to Live**: `wine "<EXE>"` or `wine "<EXE>" "<winpath of .als>"`. The only Live option it manages is `-MaxAudioThreads=N` in `Options.txt` (`scripts/lib/live-options.sh:829-874`).

## README install flow

- Requirements (`README.md:57-80`): x86-64, glibc ≥ 2.35, PipeWire ≥ 1.4.2, Linux ≥ 6.14 with NTSync, GStreamer base+good, coreutils/tar/zstd/flock. CachyOS and Arch named as meeting them (`:71-72`).
- Prefix default `~/.wine-ableton`; override `ABLETON_WINEPREFIX` or `--prefix` (plain `WINEPREFIX` is not read). Resolution: environment → `~/.config/ableton-wine/config` → default (`scripts/lib/config.sh:549-557`).
- Runtime default `~/.local/opt/wine-d2d1-nspa-11.13`; override `ABLETON_WINE_ROOT` or `--runtime-root` (`config.sh:540-548`).
- Winetricks during prefix creation: `corefonts vcrun2022 mfc42` (`scripts/setup-prefix.sh:872-876`), vendored `vendor/winetricks -q -f` with `WINE`/`WINE64` set (`:914-915`), cache `vendor/winetricks-cache` (`:891-910`). New-style WoW64, single `wine` binary (`:911-913`).
- Fonts: Bitstream Vera copied/registered (`setup-prefix.sh:936-1044`); launcher links Live's fonts each launch (`ableton-live:1546-1606`).
- DPI: launcher recalibrates `LogPixels` and `dpiAwareness` on cold start (`ableton-live:862-1133`); `ABLETON_DPI_MODE=100|fractional|dpi<N>|fractional<N>|preserve`; fresh prefixes fall back to 100% (`setup-prefix.sh:739-741`).
- GPU renderer: prefix setup removes `-_ForceGdiBackend` (`setup-prefix.sh:1419-1424`); Live's GPU renderer toggle is manual (`TROUBLESHOOTING.md:570-590`), default off.
- Plug-ins (`README.md:241-281`): installers via `env WINEPREFIX="$HOME/.wine-ableton" "$HOME/.local/opt/wine-d2d1-nspa-11.13/bin/wine" installer.exe`; VST3 bundles into `~/.wine-ableton/drive_c/Program Files/Common Files/VST3/`; the bench suite looks in `.../Common Files/VST3/` or `.../Program Files/VSTPlugins/` (`bench-suite.sh:122-131`).
- Link (`README.md:339-396`): `ableton-linkd` session mode by default (`--link=session|always|off`); firewall prompts only when ufw/firewalld active (`scripts/setup-link.sh:763-792`).

## INSTALLER.md, dist/, non-interactive use

- The `.run` contains the runtime tarball + sha256, scripts, winetricks + cache, static `cabextract`, `ableton-linkd`, `pipewire-version-probe`, `ntsyncprobe.exe` (`scripts/make-installer.sh:2-3, 206-252`). Source builds: `./build.sh` then `./scripts/installer.sh install --live-installer ... --live-major 12 --link=session` (`BUILDING.md:35-39`). `make install` already creates the prefix; `make setup` afterwards fails ("prefix already exists", `installer.sh:647-649`).
- Non-interactive: giving a command (`install`) skips the menu (`setup-run-header.sh:590-639`); `--yes` skips the overwrite prompt (`scripts/lib/manifest.sh:1209-1212`); other prompts time out after `ABLETON_UI_PROMPT_TIMEOUT` (30 s, `ui.sh:916-921`) taking defaults. Pre-flight flags: `--audio-buffer`, `--shortcuts`, `--dpi`, `--audio-threads`, `--rt`, `--power` (`INSTALLER.md:43-52`; grammar at `installer.sh:25-32`; `--rt=auto|off`). `plan install ...` / `--dry-run` preview.
- Blockers: needs `x86_64`, `timeout`, `tar`, `zstd` (`installer.sh:616-636`); running PipeWire (probe, `:662-689`); a display (Inno "need[s] a window connection… a headless run installs nothing", `setup-prefix.sh:1553-1556`); sudo via `/dev/tty` unless `sudo -n` works (`config.sh:958-973`) → `--link=off`; refuses when runtime Wine processes run and no TTY (`scripts/lib/lifecycle.sh:101-109`); `strings` (binutils) to read the Live version (`installer.sh:573-581`).
- `ABLETON_LIVE_INSTALL_TIMEOUT` default 3600 s (`installer.sh:1308`). Success check: `drive_c/ProgramData/Ableton/Live 12*/Program/Ableton Live 12*.exe` (`:1171-1186`). Trial lands at `C:\ProgramData\Ableton\Live 12 Trial\Program\Ableton Live 12 Trial.exe` (`scripts/ableton-profile.sh:29-31`). Precedent: `beta/tester-kit/run-session:209-210` runs `bash <installer> install --link=off` unattended.

## Launcher `scripts/ableton-live` (installed to `~/.local/bin/ableton-live`)

- Options: `-h`, `-c/--config` (env help), `-V`, one positional set or URL (`:197-247`). Env help at `:4-175`.
- Wine: `$ABLETON_WINE_ROOT/bin/wine`; fails if `wine`, `wineserver` or `system.reg` missing (`:341-348`) — the only runtime validation.
- Live exe: `$WINEPREFIX/drive_c/ProgramData/Ableton/*/Program/Ableton Live*.exe`, newest version (`:398-454`); `ABLETON_LIVE_EXE`, `ABLETON_LIVE_VERSION=11|12`.
- Exports: `WINEPREFIX=$ABLETON_WINEPREFIX` (`:342`); unsets `WINELOADER WINEDLLPATH WINEDLLOVERRIDES WINEARCH` (`:503`); `WINEDEBUG=-all,+winediag` (`:508`), `WINE_D3D_CONFIG=csmt=0x1` (`:509`), `WINED3D_DCOMP_FORCE_FULL_REDRAW=1` (`:510`); `WINE_X11_FORCE_OFFSCREEN_CLASS`/`WINE_WIN32_FULLSCREEN_CLASS`/`WINE_WIN32_RESIZABLE_CLASS` = `Ableton Live Window Class` (`:514-522`); `WINE_DISABLE_UNIX_MOUNT_REPARSE=1`, `WINESERVER` (`:525-526`); `WINEDLLOVERRIDES` += `mscoree,mshtml=` (+ `dcomp=` if `ABLETON_DCOMP=off`) (`:558-564`); `WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS` SwiftShader `--no-sandbox` (`:568`); `ABLETON_RT`, `ABLETON_POWER` (`:1714`, `:1738`).
- Passed through, never set: `WINE_APC_FASTPATH`, all `PIPEASIO_*` (`:1695-1697`), `WINE_D3D_FORCE_GPU_RENDERING`. No `WINENTSYNC` (automatic when `/dev/ntsync` exists; warns otherwise, `:528-553`). DXVK not used.
- Command: `[powerprofilesctl launch -p performance -r "Ableton Live session" -i ableton-live --] [chrt -r 10] $WINE_ROOT/bin/wine "C:\ProgramData\...\Ableton Live 12 Trial.exe" [doc]` under `setsid` (`:1706-1742`, `:1841-1846`). `chrt -r 10` applies whenever `chrt -r 10 true` succeeds (CachyOS grants it, `:1707-1709`); `ABLETON_RT=off` disables.
- Opening a set: `ableton-live "/path/Set.als"` (`winepath -w`, `:1892-1900`). `ABLETON_VDESK=WxH` (`:1882-1884`). No headless mode.
- Lifecycle: bring-up lock (`:687-718`); waits `ABLETON_LAUNCH_TIMEOUT` (90 s, 5-600) for Live (`:1782-1876`); stays alive until Live exits (`:1875`); kills leftover agents (`AbletonPushCpl.exe tusbaudiocplapp.exe AbletonAudioCpl.exe MicrosoftEdgeUpdate.exe`, `lifecycle.sh:203, 331-394`); hands arguments to a running instance.
- Side processes: `ableton-linkctl start` unless Link off (`:1750-1755`), theme watcher, `learnheal.exe` (`:1757-1780`).
- Logs: `~/.local/state/ableton-wine/logs/live.log` (rotated `.1` on cold start, `:481-497`); Live's `drive_c/users/<user>/AppData/Roaming/Ableton/Live <ver>/Preferences/Log.txt`.
- Options.txt: `-MaxAudioThreads=N` written before a cold start (`ABLETON_MAX_AUDIO_THREADS=auto|off|1-63`, `:352-385, 742-764`); marker `.ableton-linux-max-audio-threads-v1`; prefix setup removes `-DontCombineAPCs` and `-_ForceGdiBackend` (`setup-prefix.sh:1415-1424`).
- Settings files: `~/.config/ableton-wine/config` (`config.sh:664-674`); `~/.config/ableton-wine/preferences` (`scripts/lib/preferences.sh:54-80`).
- Session token: `bench-suite.sh` sets `ABLETON_BENCH_RUN_ID=<run>:<set>`; Live inherits it; matched in `/proc/PID/environ` (`bench-suite.sh:343-347`, `207-217`; `lifecycle.sh:12-17`). Live PIDs = `WINEPREFIX=` env match + exe under the runtime root + cmdline `Ableton Live*.exe` (`lifecycle.sh:49-59, 141-150`).
- Other launchers: `bin/ableton-live-beta`, `bin/ableton-live-portal`, `bin/ableton-wine-portal`, `bin/set-file-portal-policy`, `tools/run_in_prefix.sh` (hardcodes `$HOME/.local/opt/wine-d2d1-nspa-11.13`, `WINEPREFIX=$HOME/.wine-ableton`, `WINEDEBUG=-all`).

## Host scripts

- `scripts/setup-realtime.sh`: normal user, sudo per command (120 s timeout, `:100-107`); no options; creates `audio` group if missing (`ABLETON_RT_GROUP`), `usermod -aG`, writes `/etc/security/limits.d/90-ableton-rt.conf` (rtprio 95, memlock unlimited, nice -19), `/etc/sysctl.d/90-ableton-rt.conf` (`vm.swappiness=10`), `sysctl --system`, removes old cpufreq service, enables `rtirq.service` if installed (`:128-215`). No governor/bootloader changes. `DESTDIR=path` dry run (`:29-31, 120-130`). No reset.
- `scripts/audio-report.sh`: read-only snapshot (kernel, PipeWire, runtime, CPU topology, `/dev/ntsync` + wineserver fd, `ulimit -r`, PipeWire settings, forced quantums, `pw-top` 3 s, RT threads, PipeASIO config + env, `-MaxAudioThreads`, `live.log` tail, journal xruns) (`:29-259`).
- `scripts/check-ntsync.sh`: Live closed; `strings` on wineserver (falsely FAILs without binutils, `:70-76`); runs `ntsyncprobe.exe`; exit 0/1/2/3.
- `scripts/check-live-audio.sh`: `setsid nohup` launch, tails `Log.txt` for `Open: finished`/`FatalError`, `wineserver -k` (`:17-61`).

## Arch/CachyOS

Mentioned: `README.md:71-72`; `ableton-live:1707-1709` (realtime rights); `TROUBLESHOOTING.md:310-314` (`sudo pacman -S qt6-base qt6-wayland` for the PipeASIO panel); `setup-prefix.sh:982` (`ttf-bitstream-vera` fallback). No multilib/lib32 needed (Wine `--enable-archs=i386,x86_64`). Host tools: `chrt`, `setsid`, `flock`, `strings`, `xdg-mime`, `update-desktop-database`, `fc-scan`, optional `powerprofilesctl`, `inotifywait`; suite: python3, `pw-top`, `pw-metadata`, `pw-dump`, `wpctl`. The launcher suggests `sudo modprobe ntsync` when missing (`ableton-live:543`).

## PipeASIO at runtime

- Registration: `wine regsvr32 /s pipeasio64.dll` → `HKLM\Software\ASIO\PipeASIO`, CLSID `{2D3CA9E2-1193-4C5D-B5FD-38798F3DC074}` (`scripts/lib/pipeasio.sh:7-10, 581-612`; `setup-prefix.sh:1258`).
- Config `${XDG_CONFIG_HOME:-~/.config}/pipeasio/config.ini`, created if absent (`setup-prefix.sh:1260-1331`): `[pipeasio] inputs = 2 / outputs = 2 / buffer_size = <seed> / fixed_buffer_size = true / auto_connect = true`; seed 128 under `.run` (`installer.sh:510-514`, `--audio-buffer=64..1024`), 256 under standalone setup-prefix. Re-read while running (~1 s). Keys: `inputs outputs auto_connect input_device output_device sample_rate fixed_buffer_size follow_device_clock buffer_size(32-8192) node_name realtime` (`TROUBLESHOOTING.md:361-375`).
- Env overrides: `PIPEASIO_PREFERRED_BUFFERSIZE`, `PIPEASIO_SAMPLE_RATE`, `PIPEASIO_NUMBER_INPUTS/OUTPUTS`, `PIPEASIO_CONNECT_TO_HARDWARE`, `PIPEASIO_INPUT_DEVICE/OUTPUT_DEVICE` (PipeWire node name), `PIPEASIO_FIXED_BUFFERSIZE`, `PIPEASIO_FOLLOW_DEVICE_CLOCK`, `PIPEASIO_CLIENT_NAME`, `PIPEASIO_REALTIME` (default off; `PIPEASIO_RT_PRIORITY` legacy), `PIPEASIO_TELEMETRY=on`, `PIPEASIO_ALLOW_QUANTUM_MISMATCH`, `PIPEASIO_DEBUG`.
- `sample_rate=0` → Live's rate pins the graph; `fixed_buffer_size=true` → PipeASIO/PipeWire own the buffer; foreign quantum → silence then re-request (`PIPEASIO-15.md:20-31`); reset `pw-metadata -n settings 0 clock.force-quantum 0`.

## VMs/headless

Not covered anywhere in the repo. Facts: a desktop session is required (`bench-suite.sh:168`, `check-live-audio.sh:15`); Xvfb only in `scripts/test-d2d-resize.sh:69-84`; llvmpipe → Wine falls back to table GPU description (patch 0061); `auto_null` default flagged by the tester kit (`beta/tester-kit/lib/run-probes.sh:73-76`).

## Bench harness notes

Order Zero, Empty, Inbuilts, Max4Live, VSTs; 30 s each (min 10); 180 s launch timeout; 5 s settle. SIGTERM close leaves `CrashDetection.cfg`, `CrashRecoveryInfo.cfg`, `Preferences/BaseFiles` → next launch opens the recovered set silently (`notes/FINDINGS-M4L-LAUNCH-2026-08-04.md:440-447`); graceful: `tools/liveinject.c` `ctrlq`/`close` (prebuilt `beta/tester-kit/probes/advanced/windows/liveinject.exe`). OSC commands UDP 19001 (`ABL_BENCH_OSC_SEND`), reports 19002 (`ABL_BENCH_OSC_RECV`) (`scripts/bench-osc.py:27-28`). Max for Live: four sets use the control device, Benchmark_Max4Live adds more; Trial-M4L availability unverified.

## Doc/code contradictions

PipeASIO buffer default 128 (`.run`) vs 256 (standalone/docs); prompt timeout 5 s (CHANGELOG) vs 30 s (code); launcher log path in the GPU note is stale (code: `~/.local/state/ableton-wine/logs/live.log`).
