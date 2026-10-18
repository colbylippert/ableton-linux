# Present skipping (patch 0110)

Patch `0110` lets the screen update less often than Live draws. With
`WINED3D_PRESENT_SKIP=N`, wined3d shows only every Nth present of each swap
chain and returns at once for the others. Without the switch nothing changes.

## Switch

Set `WINED3D_PRESENT_SKIP` in Live's environment. The launcher passes it
through like any other Wine switch, and the bench suite records it.

| Value | Effect |
|---|---|
| `2` to `60` | Show every Nth present per swap chain: at 60 Hz, `6` shows 10 frames per second. |
| unset, or anything else | Every present is shown. |

wined3d writes one line on the `winediag` channel when the switch is active.

## Why

Live draws its UI at the display rate, 60 frames per second, and then the
present path and the compositor (KWin and Xwayland) handle every frame. On the
profiling laptop (NVIDIA-only external display, Wine's Vulkan back end, Live's
GPU renderer on) the display work came to about 14.5 % of one core: Live's UI
thread 8.9, Wine's command-stream thread 1.7, the compositor 3.9.

Slowing Live down does not work. A present cap that made Live's UI thread wait,
and a lower refresh rate reported to Live, both cut the display work, but below
30 frames per second the PipeWire errors rose from 0–5 to 18–20 per 3-minute
run. Live's audio engine depends on the UI loop running at the display rate.
Telling Live its window is occluded does not make it skip drawing either.

Present skipping keeps Live's loop at full rate and skips only the presentation.
At `N = 6`, the compositor's share fell from 3.9 to 1.6 % and the command
stream's from 1.7 to 1.2 %, about 2.4 points of a core in all. The audio was
unchanged: 0 errors, the same DSP average and peak. Live's own drawing on its UI
thread is not affected; Wine cannot skip that. The screen and mouse feedback
update at 1/N of the display rate.

## Design

- **Where:** `wined3d_swapchain_present()` (`dlls/wined3d/swapchain.c`). A
  skipped present returns `WINED3D_OK` before the wined3d lock is taken, so
  other threads are never held up. Each swap chain counts its own presents.
- **Complete frames:** wined3d rotates the swap chain's buffers only on a real
  present. The frames drawn in between land in the same back buffer, so the
  frame that is finally shown holds everything drawn since the last one.
  Applications that redraw only damaged regions stay correct.
- **Frame latency:** without a waitable object, the present path waits on the
  frame-latency semaphore after queueing a present, and the worker thread
  releases it after presenting; a skipped present does neither. With
  `DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT`, the application waits on
  that semaphore itself before each frame, so a skipped present releases it once,
  as the worker thread would have done.
- **Fingerprint:** the literal `WINED3D_PRESENT_SKIP` in `wined3d.dll`.

## Probe

`tools/presentskipprobe.c` renders and presents 240 frames through a Direct3D 11
flip-model swap chain, once plainly and once paced by the frame-latency
waitable object. It fails on a present that does not return `S_OK`, a frame that
takes a second or more, or a frame-latency wait that does not complete. Run it
with and without the switch: with `WINED3D_PRESENT_SKIP=6` the loops finish about
six times faster, because only every sixth present waits for the display.

    tools/build_presentskipprobe.sh
    WINED3D_PRESENT_SKIP=6 tools/run_in_prefix.sh presentskipprobe.exe
