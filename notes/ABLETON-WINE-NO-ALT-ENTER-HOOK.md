# Skipping wined3d's Alt+Enter message hook (patch 0111)

Patch `0111` lets wined3d skip the message hook it installs for Alt+Enter. With
`WINED3D_NO_ALT_ENTER_HOOK=1`, threads that own Direct3D swap chain windows keep
their messages free of that hook. Without the switch nothing changes.

## Switch

Set `WINED3D_NO_ALT_ENTER_HOOK` in Live's environment. The launcher passes it
through like any other Wine switch, and the bench suite records it.

| Value | Effect |
|---|---|
| `1` | wined3d does not install its `WH_GETMESSAGE` hook; Alt+Enter no longer toggles DXGI's exclusive fullscreen. |
| unset, or anything else | The hook is installed, as upstream. |

wined3d writes one line on the `winediag` channel when the switch is active.

## Why

Diagnostic D0002 asked what wakes wineserver about 2,300 times per second while
Live plays. All of it is client requests, about 1,735 per second from Live's UI
thread: Live's own threads post its UI thread a message about 246 times per
second, and every message the thread retrieves runs a `WH_GETMESSAGE` hook chain.
The hook is wined3d's (`wined3d_hook_proc` in `dlls/wined3d/wined3d_main.c`). wined3d
installs it on every thread that owns a swap chain window, only to catch Alt+Enter
for DXGI's exclusive-fullscreen toggle. Each hooked message costs about three
wineserver round trips (`start_hook_chain`, `get_hook_info` for `CallNextHookEx`,
`finish_hook_chain`), about a third of all wineserver requests during playback.

Live never uses that toggle; its own full-screen mode is a window mode. Applications
that let DXGI toggle exclusive fullscreen with Alt+Enter should leave the switch
unset.

## Design

- **Where:** `wined3d_swapchain_state_register()` keeps its per-thread hook entry and
  reference count, but stores no hook when the switch is set. The unregister path
  and the cleanup at DLL unload unhook only a hook that exists.
- **Scope:** only the Alt+Enter hook. Window subclassing, focus and fullscreen
  handling through the API are unchanged.
- **Fingerprint:** the literal `WINED3D_NO_ALT_ENTER_HOOK` in `wined3d.dll`.

## Probe

`tools/msghookprobe.c` posts 20,000 messages to its own window and drains them,
once before it creates a Direct3D 11 swap chain on the window and once after. It
fails if a message is lost, arrives out of order, or a batch takes ten seconds or
more, and it reports the time per message before and after. On the profiling
laptop, each message cost 8.6 µs more after the swap chain with the hook (11.1 →
19.7 µs), and nothing more with the switch (12.7 → 9.4 µs).

    tools/build_msghookprobe.sh
    WINED3D_NO_ALT_ENTER_HOOK=1 tools/run_in_prefix.sh msghookprobe.exe
