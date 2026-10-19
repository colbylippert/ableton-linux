# profiler/kernel: kernel-level work for the kernel plan

The items of `profiler/plans/kernel-plan.md` that live in the kernel or need root. Every one is opt-in, and the stock kernel, boot entry and ntsync module stay the default after a reboot.

| Directory | Item | Contents |
|---|---|---|
| `census/` | K0 (D0004) | `census-capture` (a bench-tracer stand-in: ntsync sets, resets and waits, sleeps, wake sources, IRQ time), `d0004.sh` (the census run in the kept configuration), `analyze.py` (the gates for K3, K4/K7, K5 and K6) |
| `grub/` | K2, K6 (I0) | `variants` (NAME\|extra kernel arguments), `45_profiler-variants` (the grub.d script: one entry per variant, after the normal entries, cloned from the normal entry without `savedefault`), `install.sh` (`sudo profiler/kernel/grub/install.sh [--remove]`); `profiler/bin/boot-kernel VARIANT` boots one once and verifies it |
| `ntsync-live/` | K3, K5 | `upstream/` (pristine v7.2.11 driver, uapi and selftests; `SOURCE.txt`, `SHA256SUMS`), `SERIES` and `patches/` (stage 1: 0001 identity, parameters, stats; 0002 the features ioctl; 0003 the optimistic spin), `include/ntsync_live.h` (the uapi additions), `bin/ntsync-live` (`build [--pristine]`, `e0`, `status`; builds into `~/.local/opt/ntsync-live/<series8>/`) |

Later items add `prewake/` (K7) and `scx/` (K9).
