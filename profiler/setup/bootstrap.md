# Bootstrap: from the Windows host to a set-up laptop

These are the steps that happen on the Windows side before `setup-machine.sh` can run on
the target, plus the one command that starts it. The target is the native CachyOS laptop
(MSI Katana 15, `ssh ableton-laptop`, user `colby`, login shell fish). Everything after
step 4 is done by `profiler/setup/setup-machine.sh` on the laptop itself.

Two rules shape these steps:

- **Code moves as git objects, never as copied working-tree files.** The Windows checkout
  is the source of truth for edits, but a `scp` of the files can carry CRLF line endings
  or lose executable bits. A `git bundle` carries exactly the committed blobs.
- **The login shell on the laptop is fish.** Run every remote command through bash:
  `ssh ableton-laptop "bash -lc '…'"`, or `ssh ableton-laptop bash -s <<'EOF' … EOF` for
  several lines.

## 1. SSH alias (once)

`C:\Users\colby\.ssh\config` pins the laptop by IP. Its hostname is `abletonlinux`, the
same as the retired VM's, so name resolution must not decide which machine you reach:

```
Host ableton-laptop abletonlinux
    HostName 10.0.0.86
    User colby
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
    ServerAliveInterval 30
```

Check it with `ssh -o BatchMode=yes ableton-laptop true`. The key must already be in
`~colby/.ssh/authorized_keys` on the laptop.

If the laptop does not answer, it may be asleep: closing the lid suspends it until phase
`session` sets `HandleLidSwitchExternalPower=ignore`. Open the lid or press a key.

A new file under `C:\Users\colby\.ssh` inherits an ACL that Windows OpenSSH rejects. Fix
it with:

```
icacls <file> /inheritance:r /grant:r "LIVE\colby:(F)" "NT AUTHORITY\SYSTEM:(F)" "BUILTIN\Administrators:(F)"
```

## 2. The repository (git bundle → laptop)

On Windows (PowerShell), commit first and then bundle the `profiler` branch:

```powershell
cd C:\src\AbletonLinux\ableton-linux
git status --short            # must be empty: only committed work travels
git bundle create C:\src\AbletonLinux\profiler-bootstrap.bundle profiler
git bundle verify C:\src\AbletonLinux\profiler-bootstrap.bundle
scp C:\src\AbletonLinux\profiler-bootstrap.bundle ableton-laptop:profiler-bootstrap.bundle
```

On the laptop, use the first command if the clone does not exist yet. Use the second to
update the existing clone at `~/Projects/ableton-linux` (fast-forward only, never a merge):

```powershell
# fresh clone
ssh ableton-laptop "bash -lc 'git clone -b profiler ~/profiler-bootstrap.bundle ~/Projects/ableton-linux && cd ~/Projects/ableton-linux && git remote set-url origin https://github.com/shibco/ableton-linux && git config core.autocrlf false && git merge-base --is-ancestor aceb236 HEAD && git log --oneline -1'"

# existing clone (branch profiler checked out, clean tree)
ssh ableton-laptop "bash -lc 'cd ~/Projects/ableton-linux && git diff --quiet HEAD && git fetch ~/profiler-bootstrap.bundle profiler && git merge --ff-only FETCH_HEAD && git log --oneline -1'"
```

Later updates use the same bundle-and-fetch steps. Work committed on the laptop (for
example by the agent loop) comes back the other way. Add the laptop as a remote once with
`git remote add laptop ssh://ableton-laptop/home/colby/Projects/ableton-linux`. After that,
`git fetch laptop` is all you need. Never push into the laptop's checked-out branch.

`bench/` (the benchmark Sets) is not on the `profiler` branch. Phase `repo` restores it
from `aceb236^` and lists it in `.git/info/exclude`, so it never enters a commit or the
build snapshot.

## 3. The Live installer media (once, about 6.1 GB)

The Inno Setup installer needs its three `-N.bin` slices in the same directory as the `.exe`:

```powershell
ssh ableton-laptop "bash -lc 'mkdir -p ~/Proprietary/ableton'"
scp (Get-ChildItem C:\src\AbletonLinux\AbletonInstaller\*).FullName ableton-laptop:Proprietary/ableton/
ssh ableton-laptop "bash -lc 'ls -l ~/Proprietary/ableton && sha256sum ~/Proprietary/ableton/*.exe'"
```

Expected: Live 12.4.6's `Ableton Live 12 Trial Installer.exe` (about 6.6 MB, sha256
starting `e4e334774046d861`) and `…-1.bin` … `…-4.bin` (the first three over 1 GiB,
the last about 182 MB). Live 12.4.3 or newer is required: the canonical bench Sets
were saved by 12.4.3 and older Live refuses them. Phase `media`
checks this and refuses incomplete media. Never commit or redistribute these files.

## 4. Run the setup

From Windows, with `-t` so the one sudo prompt can reach your terminal:

```powershell
ssh -t ableton-laptop 'bash -lc "~/Projects/ableton-linux/profiler/setup/setup-machine.sh --profile baremetal --passwordless-sudo --autologin"'
```

What to expect:

- **One sudo password prompt, once.** It appears at the first phase that needs root
  (phase `sudo`), which then installs `/etc/sudoers.d/90-profiler-colby` (NOPASSWD) and the
  root helper's own rule. No later step asks again, and later runs never prompt.
- **The options are saved** in `~/.config/profiler/setup.conf`. Every later run only
  needs `setup-machine.sh`, with no flags. `--audio-device` defaults to `builtin` on this
  profile. That is the SOF speaker sink, which gives a real hardware clock and stays
  muted during benchmark runs.
- **Exit code 3** means "log out and back in, or reboot, then run the same command
  again". This happens after the `realtime` group is added (phase `limits`) or after a
  kernel update (phase `packages`). Every phase is idempotent, so the re-run continues
  where it stopped. Use `sudo reboot` over SSH: the laptop logs back in on its own once
  phase `session` has set up Plasma Login Manager autologin.
- **The Wine build** (phase `build`) takes about 1 hour cold. Do not edit, commit or
  create anything in `~/Projects/ableton-linux` while it runs: `build.sh` snapshots the
  tree and aborts if it changes.
- **The human step** (phase `human`, about 3 minutes, at the laptop's screen): Live opens
  on the desktop. Accept the licence and continue unauthorised (demo). Set Audio to
  ASIO / PipeASIO at 48 kHz, set Control Surface to AbletonOSC, turn off updates and
  usage data, then **File > Quit (Ctrl+Q)**. The phase notices that Live has quit,
  verifies `Log.txt` and continues with the golden snapshot. With `--yes`, the step is
  deferred. Finish it later with `setup-machine.sh --only human`, then `--only golden`.

Preview without changing anything (no sudo, no log, nothing saved):

```powershell
ssh ableton-laptop 'bash -lc "~/Projects/ableton-linux/profiler/setup/setup-machine.sh --profile baremetal --passwordless-sudo --autologin --dry-run"'
```

## 5. Check the result

```powershell
ssh -t ableton-laptop 'bash -lc "~/Projects/ableton-linux/profiler/setup/verify.sh"'
```

`verify.sh` is read-only. It exits 0 only when every hard check passes. The laptop checks
are: on AC power, the lid drop-in, Wi-Fi power save off, autologin configured, the
speaker sink recorded as `audio_node=` and muted, and PipeASIO pointed at it. The
dashboard runs at `http://10.0.0.86:5173/`. `abletonlinux` resolves only if you add it to
`C:\Windows\System32\drivers\etc\hosts`.
