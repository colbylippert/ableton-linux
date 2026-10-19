# profiler/kernel: kernel-level work for the kernel plan

The items of `profiler/plans/kernel-plan.md` that live in the kernel or need root. Every one is opt-in, and the stock kernel, boot entry and ntsync module stay the default after a reboot.

| Directory | Item | Contents |
|---|---|---|
| `census/` | K0 (D0004) | `census-capture` (a bench-tracer stand-in: ntsync sets, resets and waits, sleeps, wake sources, IRQ time), `d0004.sh` (the census run in the kept configuration), `analyze.py` (the gates for K3, K4/K7, K5 and K6) |

Later items add `grub/` (boot variants, K2/K6), `ntsync-live/` (the custom ntsync module, K3/K5), `prewake/` (K7) and `scx/` (K9).
