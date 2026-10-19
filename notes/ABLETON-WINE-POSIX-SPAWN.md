# Starting processes with posix_spawn (patch 0112)

Patch `0112` lets Wine start new processes with `posix_spawn()` instead of `fork()`.
With `WINE_POSIX_SPAWN=1`, starting a process no longer write-protects the parent's
memory. Without the switch nothing changes.

## Switch

Set `WINE_POSIX_SPAWN` in Live's environment. The launcher passes it through like
any other Wine switch, and the bench suite records it.

| Value | Effect |
|---|---|
| `1` | `spawn_process()` starts the new process's loader with `posix_spawn()`. |
| unset, or anything else | `fork()`, then `fork()` again and exec, as upstream. |

Wine writes one line on the `winediag` channel the first time a process starts
another with the switch set.

## Why

Diagnostic D0003 asked why Live's late audio blocks run long. They fall at the same
song positions in every run: the first time certain clips play. In each one an audio
thread takes about 1,500 page faults inside a single 1.33 ms block. All of them are
writes to present, write-protected pages of Live's own heap, one fault per 4 KiB page.

`spawn_process()` in `dlls/ntdll/unix/process.c` starts every new process with
`fork()`. Live starts four helper processes while a Set loads. Each `fork()` marks every
private writable page of Live copy-on-write. The intermediate child exits at once, so
the pages are Live's alone again, but the first write to each one still takes a fault.
When Live later writes a few megabytes for the first time, for example when a clip first
plays, those faults pile up inside one audio block. Windows has no `fork()`, so this cost
exists only under Wine.

`posix_spawn()` runs the child in the parent's address space until it execs
(`CLONE_VM | CLONE_VFORK`). No page table is copied and none of the parent's pages is
write-protected.

## Design

- **Where:** `spawn_process()` calls `spawn_process_posix()` when the switch is set.
  It expresses the child's set-up as spawn attributes and file actions, so the child
  only makes system calls before it execs:
  - a new session (`POSIX_SPAWN_SETSID`) in the same cases as the fork path;
  - stdin and stdout from the parent, or `/dev/null`;
  - the working directory (`posix_spawn_file_actions_addfchdir_np`);
  - `SIGPIPE` back to its default.
- **Loader:** `spawn_wineloader()` in `loader.c` is the twin of `exec_wineloader()`. It
  builds the child's environment (ours, with `WINEDEBUG`, `WINESERVERSOCKET`,
  `WINEPRELOADRESERVE` and `WINELOADERNOEXEC` set as `exec_wineloader()` would) without
  touching our own. It then tries the same loaders, the preloader first, in the same
  order.
- **Children:** the fork path detaches the new process through an intermediate child.
  With `posix_spawn()` the process is our own child, so `spawn_process_posix()` reaps
  children that have exited each time it starts another, without waiting.
- **Scope:** only `spawn_process()`, which starts Windows processes. `__wine_unix_spawnvp()`
  and `fork_and_exec()`, which start Unix programs, still fork.
- **Fingerprint:** the literal `WINE_POSIX_SPAWN` in `ntdll.so`.

## Probe

`tools/spawncowprobe.c` commits 128 MiB as 1 MiB pieces, which huge pages cannot back,
as with Live's heap. It writes every page once and times a second write pass. It then
starts a child process, waits for it, and times a third pass. It fails if the pass
after the child costs more than 0.1 µs per page above the warm pass.

On the profiling laptop:

| | Pass after the child | Per page |
|---|---|---|
| Without the switch | 17.6 ms | 0.53 µs (one fault per page) |
| With the switch | 0.6 ms | 0.018 µs (same as warm) |

The child also started faster with the switch (5–9 ms against 12 ms).

    tools/build_spawncowprobe.sh
    WINE_POSIX_SPAWN=1 tools/run_in_prefix.sh spawncowprobe.exe

## Effect in Live

A dev-runtime A/B on the three heavy Sets (60 s windows, the loop's whole first pass):

| | Without the switch | With the switch |
|---|---|---|
| Late blocks | 12 | 0 |
| Longest block | about 1.9 ms | about 0.9 ms |
| Live's page faults per window | about 12,700 | about 300 |
