# B5 T-proto: why the bpftrace prototype crashes (std::bad_alloc), and the libbpf oops

Written by the duplicate T-proto instance (resumed by mistake) for the workflow's T-proto instance
and the libbpf owner. Everything marked VERIFIED was observed on the laptop (kernel 7.2.9-cachyos
PREEMPT(full)/lazy, bpftrace 0.27.0, bpftool 7.2); the rest is inference.

## 1. Root cause: preemptible uprobe programs + per-CPU memory (two layers)

USDT probes are `BPF_PROG_TYPE_KPROBE` programs on `uprobe_multi` links. They run under
`migrate_disable()` only: **preemptible, with no recursion guard** (`uprobe_prog_run` →
`uprobe_multi_link_handler`, from the oops call trace). If a second thread hits **the same probe on
the same CPU** while the first run is preempted halfway, the two runs share any per-CPU memory the
program writes before `bpf_ringbuf_output`.

### Layer 1: bpftrace's own per-CPU scratch (fixed by `on_stack_limit = 256`)
- printf arguments larger than `on_stack_limit` (default 32 bytes) go into a global per-CPU array.
  JIT prologue of a test program without the config (VERIFIED): it reads cpu_number via `%gs`, then
  `imulq $72, %rdi` and `movabsq $<array>, %rbx; addq %rdi, %rbx` to get the scratch slot.
- gdb backtrace of the B4 crash (VERIFIED): `__cxa_throw` ← `OpaqueValue::check` ←
  `OpaqueValue::slice` ← `async_action::prepare_args` ← `event_printer` ← `ringbuf_printer` ←
  `poll_output`. A record shorter than its printf id's argument struct throws std::bad_alloc.
- Bisect (VERIFIED, Live playing Benchmark_Inbuilts at 64 frames): every single-printf script
  survived 15 s at 100–200k lines/s. Entry+exit printf pairs with different struct sizes died within
  1–3 s, and so did syscall_entry with T+E printfs. The same E+X script with `config =
  { on_stack_limit = 256 }` ran 30 s with 6.0M lines (3.02M E, 3.01M X) and exited cleanly.

### Layer 2: the kernel's per-CPU BPF private stack (NOT fixed; the t60 crash)
- Since 6.14 the verifier gives KPROBE/TRACEPOINT/PERF_EVENT/RAW_TP programs whose stack depth is
  **>= 64 bytes (BPF_PRIV_STACK_MIN_SIZE)** a per-CPU private stack. This assumes they cannot
  re-enter on one CPU, which is false for preemptible uprobe programs.
- JIT evidence (VERIFIED, uprobe on libc `getppid`, `on_stack_limit = 256`, an 8-argument printf):
  ```
  15: movabsq $108704948853264, %r9
  1f: addq    %gs:-1816375256, %r9      ; this_cpu_off -> per-CPU private stack in %r9
  2a: movq    %rdi, -72(%r9)            ; printf_args live on the per-CPU stack
  ```
  It has no `subq $N, %rsp`. A small program (`@n = count()`) gets the normal `subq $40, %rsp`.
- The t60 run (60 s requested, the template with on_stack_limit=256, 19 probes) still aborted with
  std::bad_alloc after **32.9 s** (10.3M lines). It also printed a second `hdr` line carrying an
  ordinary event timestamp, i.e. a record whose printf-id slot had been overwritten/zeroed: the
  same memory-sharing failure on the private stack.
- `CONFIG_BPF_JIT_ALWAYS_ON=y`, so there is no interpreter fallback and no known knob to disable
  private stacks.

### Which programs of the t60 script use the private stack (VERIFIED, frames.sh classifier)
PRIVATE: syscall_entry, syscall_exit, unixcall_entry, server_req_start, server_req_end,
server_wait_end, pipeasio block_start, block_end, cycle_start, fentry ntsync_char_ioctl,
fentry ntsync_obj_ioctl, tracepoint sched_process_exec.
Normal stack: unixcall_exit (48), server_wait_start (16), block_before_live (40),
block_after_live (40), cycle_end (40), fexit ntsync_char_ioctl (40), task_rename (48),
BEGIN/END (raw_tp).

Notes:
- fentry/fexit (TRACING) programs get a private stack only together with the kernel's recursion
  guard (`prog->active`): a re-entry is **skipped**, so events are missed (no corruption).
- Classic tracepoints run non-preemptible, so a private stack is harmless there.
- The pipeasio probes fire only on the single PipeASIO callback thread, so they cannot re-enter.

### Frame-size measurements (VERIFIED, variants on the real ntdll.so/pipeasio probes, Live not needed)
The frame size is driven by the printf record plus **8 bytes per USDT argument read** (one result
slot each). `@emitted` count() hardly matters. A body fits under 64 only with ≤ 2 USDT args and a
≤ ~40-byte record:

| body | frame |
|---|---|
| `E ts tid syscall ID fr=FR seq=S` (no rsp/rip), with @emitted, @pids filter | stack 48 |
| `X ts tid syscall fr=FR st=ST` (no id, no rf) | stack 48 |
| X with rf (3 args), or with id | PRIVATE |
| `E ts tid unixcall H:C seq=S` (no fr/rip) | stack 48 |
| `R ts tid fr=FR rip=RIP` (second program on unixcall_entry) | stack 48 |
| unixcall E with fr (3+ args) | PRIVATE |
| `S req TYPE dur=u32 seq=u32` (no status) | stack 40 |
| S req with status | PRIVATE |
| `S wait FLAGS dur=u32 st=ST seq=u32` | stack 48 |
| block_start/block_end/cycle_start, any variant | PRIVATE (single thread: tolerable) |
| tracepoint task_newtask T line | PRIVATE (tracepoint: non-preemptible, harmless) |

### Proposed fix (partly applied, see section 4)
1. Exactly ONE printf per USDT/fentry program: remove the first-sight T lines. T comes from
   `tracepoint:task:task_newtask` plus a /proc snapshot (`tasks-start.txt`/`tasks-stop.txt`) read
   by reduce.py; `@tids` is seeded from the snapshot for the sched filter. With one printf per
   program a mixed record can never carry the wrong id/size, so the consumer cannot crash.
2. Keep the multi-thread probes (syscall/unixcall entry+exit, server req/wait end) under 64 bytes
   (the table above), so they cannot mix records at all.
3. After start, have the wrapper classify every loaded program by its JIT prologue
   (`bpftool prog dump jited`: `%gs:..%r9` → private) and record/warn in tracer.json.

## 2. The libbpf tracer's kernel oops (uptime 24441 s, before the reboot)
- `BUG: unable to handle page fault for address 00000d32a9f8c924` (supervisor read, kernel mode)
  in `bpf_prog_73315ea51a874990_wine_syscall_exit+0x8d5` on `pipeasio-rt[623623]`.
  Call trace: `uprobe_prog_run` ← `uprobe_multi_link_handler` ← `handler_chain` ←
  `uprobe_notify_resume` ← `exc_int3`. "note: pipeasio-rt[623623] exited with irqs disabled".
- Inference: the same Layer-2 hazard. If wine_syscall_exit's frame is >= 64 bytes it runs on a
  per-CPU private stack. A preempted run had a stack slot holding a pointer overwritten by a
  re-entering run, and the program then dereferenced a garbage pointer (verifier-trusted stack
  value) → oops. The libbpf owner should check the JIT prologue of every uprobe program
  (`bpftool prog dump jited id N | sed -n 4,16p`; `%gs:..%r9` = private) and keep uprobe programs
  under 64 bytes, e.g. by building records directly in the ring buffer with `bpf_ringbuf_reserve`
  rather than in a large stack struct, plus per-tid map state.
- Aftermath (VERIFIED): the dying task kept the uprobe SRCU read side. Every later uprobe detach
  hung in `synchronize_srcu` (`bpf_uprobe_multi_link_release` / `perf_event_detach_bpf_prog`):
  libbpf `build/wine-trace` pid 623899 and my bpftrace `--dry-run` pid 633144 sat in D state, and
  54 uprobe_multi links stayed on ntdll.so/pipeasio64.dll.so (int3 on every Wine syscall, traced
  or not) until the laptop was rebooted (~01:10).

## 3. Other verified facts
- Clock: bpftrace 0.27 `nsecs` = CLOCK_BOOTTIME; `nsecs(monotonic)` = python
  `time.monotonic_ns()` (BEGIN test: 12483787767248 vs python 12484018443691; boot 22411…).
  After the reboot the wrapper's check passed: hdr 221064224574 within python monotonic
  219765304408..240296935993.
- Loss reporting: bpftrace reports ring-buffer drops as `Lost N events` (+ `WARNING: Total lost
  event count`) on **stderr**. A SIGSTOP-stall test gave Lost 797266, while emitted − received was
  1236294: records still queued at exit are lost silently. **`--no-warnings` suppresses the
  "Lost" line too**, so the daemon must not use it. The bpftrace count() increment is a
  non-atomic per-CPU load/add/store and can undercount under preemption, so @emitted is a lower
  bound. Correct formula: lost = max(Lost lines, emitted − received) + fentry recursion misses.
  The current reduce.py still ADDS reported + shortfall (double count) and must be changed.
  bpftool 7.2's `prog show --json` has no `recursion_misses` key on this system (absent when 0?).
- bpftrace 0.27 prints compile warnings (clang's vmlinux.h note + the script source) on stdout,
  i.e. into events.txt. The reducer ignores those lines (no line starts with an event-kind token).
- Validation after the reboot (VERIFIED, b5-tproto-v1): all 15 traceprobe EXPECT lines PASS. The
  only FAIL was pairing-enclosure with 1 of 188, the terminate_process request inside
  NtTerminateProcess that never exits (the other actor's open-enclosure INFO covers it).
  tracer_exit=clean, lost_events=0, abandoned_entries=0. winscard.dll is not loadable in the
  prefix (phase6 SKIP).

## 4. Edits this duplicate made at 01:37–01:38 (Windows checkout; NOT tested, NOT on the laptop)
1. `profiler/tracer/wine-trace.bt` (01:37:19): fix items 1–2 above.
   - Header comment explains the two layers.
   - `hdr ... format=3`.
   - All T blocks removed from the USDT and fentry programs.
   - Line format changes:
     - `E syscall` drops rsp/rip;
     - `X syscall` drops id and rf;
     - unixcall_entry is split into `E ts tid unixcall H:C seq=S` plus a second program
       `R ts tid fr=FR rip=RIP` (@emitted[82]);
     - `S req` drops st and uses u32 dur/seq;
     - `S wait` uses u32 dur/seq.
   - New `tracepoint:task:task_newtask /@FILTER@/` emits the T line (@emitted[84]) and sets
     `@tids`.
   - The other actor's 16 KB `#` padding in BEGIN is kept.
2. `profiler/bin/wine-trace` (01:38:00):
   - `snapshot_tasks start|stop` writes T lines to `tasks-<x>.txt`; the generator seeds
     `@tids[...]` from tasks-start.txt.
   - `task_newtask` added to list_probes.
   - The daemon runs **without** `--no-warnings`.
   - `check_frames` (bpftool JIT prologue → `private_stack_programs` in tracer.json, warning for
     non-pipeasio kprobe programs).
   - `recursion_misses_of` at stop.
   - `reduce.py` is now called with **`--recursion-misses N`**.
3. `profiler/tracer/reduce.py` (01:38:59), INCOMPLETE:
   - Parser accepts `R` lines, X syscall without id, E unixcall without fr (frame None); `R` added
     to EVENT_KINDS.
   - `load_events(..., extra_paths=)` reads tasks-*.txt and counts received lines only from
     events.txt.
   - process() joins R to the newest frameless unix-call entry on the tid (R_JOIN_WINDOW_NS =
     1 ms, pending_r), with counters unixcall_entries_without_r / unixcall_r_lines_unmatched /
     unixcall_r_lines_too_late.
   - loss_accounting reads `opt.recursion_misses` but does not use it yet.
   - **Missing:** (a) the `--recursion-misses` argparse option (the patched wrapper passes it, so
     `wine-trace stop` will fail with "unrecognized arguments" until it is added); (b) run() does
     not pass `extra_paths=[in_dir/tasks-start.txt, in_dir/tasks-stop.txt]` yet; (c) the loss
     formula change max(...)+misses; (d) tests (test_reduce/test_bt_template still expect format
     2 shapes and T printfs: the "every printf counted" test passes, but test_generated_script
     needs task_newtask in `available`).

   **Recommendation:** the owning instance either reverts these three files to its own versions or
   completes items (a)–(d), then re-measures with frames.sh (every non-pipeasio kprobe must show
   "stack N") and reruns the 60 s Benchmark_Inbuilts trace.

## 5. Tools left on the laptop (/tmp, recreated after the reboot)
- `/tmp/profiler-b5/tproto-tools/frames.sh SCRIPT.bt`: loads a script and prints PRIVATE /
  `stack N` per program.
- `privstack.sh`, `stall.sh`/`stall2.sh`: the JIT and drop-report experiments.
- `e2e.sh NAME SECS` and `validate-run.sh NAME`: lock-holding drivers.
- `live-up.sh`/`live-down.sh`.
- Variant scripts in `/tmp/profiler-b5/tproto-frames/`.

Laptop left clean: no Live, no bpftrace/tracer, no flock holder, 0 uprobe links, no D-state tasks.
