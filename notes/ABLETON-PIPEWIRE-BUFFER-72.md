# A 72-frame buffer for USB interfaces that move audio in 0.5 ms transfers

On the profiling laptop's Focusrite Scarlett 2i4, a 64-frame buffer makes PipeWire's audio cycles uneven: 1.0, 1.5,
1.5 ms, repeating. Every third cycle gives Live 1.0 ms instead of 1.333 ms, and the rare PipeWire errors fell there.
A 72-frame buffer makes every cycle 1.5 ms. Kept by the user's decision on 2026-10-20 ("We will keep the 72 frame fix")
on the evidence of diagnostics D0016, D0017 and D0018 (`profiler/plans/kernel-plan.md`).

## Switch

PipeASIO's buffer size: `buffer_size = 72` in `~/.config/pipeasio/config.ini` (with `fixed_buffer_size = true`, as
setup writes it, PipeASIO offers Live only that size). `PIPEASIO_PREFERRED_BUFFERSIZE` overrides it for one launch.

| Where | Setting |
|---|---|
| Everyday Live on the laptop | `~/.config/pipeasio/config.ini`: `buffer_size = 72` |
| Trials, ramps and cross-OS runs | the `golden` snapshot (`profiler/bin/state`), re-baselined with the same file; every run restores it |
| The previous kept configuration (64 frames) | snapshot `golden.20261020T205208Z` |
| The upstream baseline (D0006) | snapshot `golden.20261019T153253Z`, 64 frames, unchanged |
| One run at another size | `linux-run.sh TAG kept-wN-bF`, `BUFFER=F first-buffer.sh`, or `PIPEASIO_PREFERRED_BUFFERSIZE=F` |

## Why

- **The transfers:** the Scarlett 2i4 streams over high-speed USB in 125 µs packets, and snd-usb-audio completes them in
  transfers of four packets, 0.5 ms (24 frames at 48 kHz). The driver can report a finished period only at the end of a
  transfer.
- **The scheduling:** PipeWire's pro-audio profile drives the card from that report (interrupt scheduling,
  `api.alsa.disable-tsched = true`). Each graph cycle therefore starts on a 0.5 ms boundary.
- **64 frames:** a 64-frame period (1.333 ms) is not a multiple of 0.5 ms, so its cycles alternate 1.0, 1.5, 1.5 ms.
  PipeASIO calls Live's `bufferSwitch` inside each cycle, so Live's deadline alternates the same way.
  - A block of 1.0 to 1.33 ms, which Live's own meter shows as 75 to 100 % and fine, misses PipeWire's deadline when it
    falls in a short cycle.
  - PipeWire then counts an error on Live's node, with no missed deadline in Live's meter.
- **72 frames** is three transfers. Every cycle starts on a transfer boundary exactly 1.5 ms after the last.

The right size depends on the interface: choose a multiple of its transfer size in frames. Here that is 24 frames at
48 kHz, so 48, 72, 96 or 120. `profiler/trials/first-buffer.sh` measures the cycle spacing of any interface.

## Design

- **Interrupt scheduling stays.** Timer scheduling (D0017) also evens the cycles, but PipeWire then keeps a full period
  of headroom queued, and the output latency Live reports rose from 2.67 to 6.00 ms.
- **Live's latency:** at 72 frames Live reports 3.00 ms in and 3.50 ms out, against 2.67 and 2.67 ms at 64.
- **Windows:** the Focusrite Windows driver reports 6.79 ms overall at 64 samples.

## Verification

`BUFFER=72 profiler/trials/first-buffer.sh d0018 2 Inbuilts 30` (D0018 step 1) records PipeASIO's USDT probes from
Live's first buffer. It gave:
- cycles spaced 1,471.7 / 1,500.0 / 1,528.3 µs at p1 / p50 / p99, against 988.8 / 1,499.9 / 1,511.2 at 64 frames;
- one 72-frame block per cycle;
- no muting or missed frames;
- one error on the Focusrite's driver node, against 19 at 64 frames.

## Effect in Live

Full passes, three runs from fresh boots, 2 workers, 18 minutes of playback each:

| | 64 frames (D0014) | 72 frames (D0018) |
|---|---|---|
| PipeWire errors | 3 | 0 |
| Missed deadlines | 0 | 0 |
| DSP average % (Inbuilts / Max4Live / VSTs) | 6.43 / 6.78 / 5.81 | 7.74 / 7.97 / 6.98 |
| Audio-thread CPU % | 12.4 / 13.4 / 9.4 | 15.4 / 16.4 / 12.3 |
| Latency Live reports, in / out | 2.67 / 2.67 ms | 3.00 / 3.50 ms |

- **Errors:** all three errors across the three configurations (D0017's timer scheduling had none either) fell in the
  one with uneven cycles. At equal rates that happens 1 time in 27.
- **The cost is CPU:** Live's audio threads use 24 to 31 % more for the same audio. A buffer that is not a power of two
  plausibly costs an extra partial chunk per block (72 = 64 + 8).
- DSP averages from before 2026-10-20 16:52 are at 64 frames, and are not comparable one to one with later ones.
