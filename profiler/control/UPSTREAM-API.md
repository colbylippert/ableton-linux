# AbletonOSC upstream API — facts for the overlay, client and scenario authors

Scope: the vendored tree `profiler/control/vendor/AbletonOSC/` at upstream commit
`0ca68214bd62c9b5cb641ca34006cfd70ba94430` (2025-11-19, MIT, see `VENDOR.txt`).
Every `file:line` below is relative to that directory and was read from the vendored
code. Behaviour that lives in Live's own Python framework (`Live`, `ableton.v2`,
`_Framework`) is not in the tree; those statements are marked **VERIFY**.

## 1. Tree, entry point, import graph

- Vendored: `LICENSE.md README.md __init__.py manager.py abletonosc/ pythonosc/`. Not
  vendored: `tests/` (pytest + the `client/` package), `client/` (needs
  `pythonosc.udp_client`, not stdlib-only), `.github/`, `run-console.py`,
  `CONTRIBUTING.md`.
- Live imports the folder as a package and calls `create_instance(c_instance)` →
  `Manager(c_instance)` (`__init__.py:8-9`). `from .manager import Manager` is wrapped in
  `try/except ImportError: pass` (`__init__.py:1-6`), so an `ImportError`/
  `ModuleNotFoundError` raised while importing `manager.py` (for example a misspelled
  `from .abletonosc import bench`) is swallowed and the surface fails later with
  `NameError: Manager` inside `create_instance`. A `SyntaxError` is not an
  `ImportError` and propagates. Either way Live only records the failure in its own
  `Log.txt`; nothing reaches `logs/abletonosc.log` (logging starts in `Manager.__init__`).
- `manager.py` imports `ControlSurface` from `ableton.v2.control_surface`,
  `EncoderElement` from `_Framework` (unused), `Live`, and the `abletonosc` package
  (`manager.py:1-5`). The package `abletonosc/__init__.py:6-16` imports every handler
  module plus `OSC_LISTEN_PORT`/`OSC_RESPONSE_PORT`; `introspection.py` is imported by
  nobody. Only `abletonosc/osc_server.py:3-5` uses `pythonosc` (`osc_message`,
  `osc_bundle`, `osc_message_builder`; transitively `parsing/osc_types.py`,
  `parsing/ntp.py`). `pythonosc/{osc_server,dispatcher,udp_client,osc_packet,
  osc_bundle_builder}.py` are vendored because they ship in the package but are never
  imported by the Remote Script (`dispatcher.py:153` carries an invalid `'\w'` escape that
  Python 3.12+ reports as a `SyntaxWarning` at compile time; harmless, and only if
  something imports it).
- All upstream handlers are built from `AbletonOSCHandler` (`abletonosc/handler.py:6`) and
  registered in one list in `Manager.init_api()` (`manager.py:93-103`).

## 2. `OSCServer` (`abletonosc/osc_server.py`)

Constructor and ports:

- `OSCServer(local_addr=('0.0.0.0', OSC_LISTEN_PORT), remote_addr=('127.0.0.1', OSC_RESPONSE_PORT))`
  (`osc_server.py:14-16`); `OSC_LISTEN_PORT = 11000`, `OSC_RESPONSE_PORT = 11001`
  (`abletonosc/constants.py:5-6`). `Manager` constructs it with no arguments
  (`manager.py:24`), so it listens on every IPv4 interface, port 11000.
- The UDP socket is created, set non-blocking and bound in the constructor
  (`osc_server.py:36-38`). A busy port raises `OSError` out of the constructor; `Manager`
  catches only that (`manager.py:32-34`), shows "Couldn't bind to port 11000", and skips
  `schedule_message`, `start_logging` and `init_api` (`manager.py:25-28`): no tick loop,
  no handlers, no log file, and `self.osc_server` is never assigned (so a later
  `disconnect()` at `manager.py:146` raises `AttributeError`). Preflight must prove 11000
  is free before Live starts.
- `_response_port = remote_addr[1]` = 11001 is fixed for the lifetime of the server
  (`osc_server.py:34`).

How the reply address is chosen:

- Every received datagram first rewrites the default reply address to
  `(sender_ip, OSC_RESPONSE_PORT)` (`osc_server.py:158-165`, uses the constant, not the
  constructor value), then the datagram is parsed and dispatched (`osc_server.py:166`).
- A handler return value is sent back to `(sender_ip, self._response_port)` with the
  **request's own address** (`osc_server.py:92-98`; wildcard matches use the matched
  callback address, `osc_server.py:117-123`).
- `send(address, params=(), remote_addr=None)` with `remote_addr=None` goes to the default
  reply address (`osc_server.py:81-83`): before any client has spoken that is
  `('127.0.0.1', 11001)` (`osc_server.py:16`), afterwards the most recent sender's IP at
  11001. Replies never go to the sender's source port; the client must bind 11001
  (`bench-osc.py` binds `127.0.0.1:RECV`, so `ABL_BENCH_OSC_RECV=11001` works unchanged).
- Consequence for `/abl/bench/ping`: a handler that *returns* a tuple answers on
  `/abl/bench/ping`, not `/abl/bench/pong`. Echo explicitly with
  `self.osc_server.send("/abl/bench/pong", tuple(params))` and return `None`.

`add_handler(address, fn)` (`osc_server.py:45-54`):

- Exact-match dict assignment, last registration wins (`osc_server.py:54`); a bench handler
  registered after the upstream handlers can therefore override an upstream address.
  `clear_handlers()` empties the dict (`osc_server.py:56-60`).
- `fn` is called with one positional argument, `message.params`, which is a **list**
  (`osc_server.py:90`; `OscMessage.params` returns `list(self)`,
  `pythonosc/osc_message.py:106-109`). The type hints say `Tuple`, the object is a list;
  slices are lists, `len(params) == 0` for a message without arguments
  (`osc_message.py:28-30`). Upstream keys listeners with `tuple(params)`
  (`handler.py:72`).
- Return `None` → nothing is sent. Return a `tuple` → sent as the reply described above.
  Returning anything else (list, bare value) trips `assert isinstance(rv, tuple)`
  (`osc_server.py:93`, `118`), which lands in `/live/error` like any other handler
  exception.
- Wildcards: an unregistered address containing `*` becomes the regex
  `address.replace("*", "[^/]+")` and is tested with `re.match` against every registered
  address (`osc_server.py:99-102`). `re.match` only anchors the start, so `/abl/bench/*`
  invokes **every** `/abl/bench/...` handler and `/live/song/get/*` also hits
  `/live/song/get/track_names`. In wildcard mode `ValueError` and `AttributeError` from
  callbacks are swallowed (`osc_server.py:103-116`); in exact mode nothing is caught.
- Unknown address without `*` → `logger.error("AbletonOSC: Unknown OSC address: …")`
  (`osc_server.py:124-125`) → relayed to `/live/error` (section 7).

`send(address, params=(), remote_addr=None)` (`osc_server.py:62-85`):

- Each element of `params` goes through `OscMessageBuilder.add_arg(param)` (`osc_server.py:75-77`)
  with type inference (`pythonosc/osc_message_builder.py:98-129`): `str`→`s`, `bytes`→`b`,
  `True`→`T`, `False`→`F` (checked before `int`, so Python bools never become `i`),
  `int`→`i` or `h` when `bit_length() > 32`, `float`→`f` (32-bit, `osc_types.py:224-233`),
  a 4-tuple→`m` (MIDI packet), `list`→array `[…]`, `None`→`N`, anything else →
  `ValueError('Infered arg_value type is not supported')`.
- That `ValueError` is raised at `osc_server.py:77`, outside the `try` at `79-85` which only
  catches `BuildError` (logged at ERROR → `/live/error`). A Live object, dict or nested
  tuple in `params` therefore raises out of `send()` into the caller. `socket.sendto`
  errors (`OSError`) are not caught in `send()` either.
- No arguments → type tag `,` (`osc_message_builder.py:147-149`); strings are UTF-8
  (`osc_types.py:37-49`); ints must fit `>i` or `BuildError` (`osc_types.py:96-105`).
- Rule that follows for the bench protocol: send only `int` (32-bit), `float`, `str`; cast
  bools with `int(x)`; `scripts/bench-osc.py decode()` currently understands only
  `i/f/s`, and `T/F/N/h/d/b` tags come from the `/live/*` replies of upstream handlers
  (`is_playing` is a bool → `T`/`F`; `_get_property` turns a `RuntimeError` into `None` →
  `N`, `handler.py:36-45`).

Parsing (`pythonosc/osc_message.py:25-84`): tags `i h f d s b r m t T F N [ ]`; an unknown
tag logs a warning on the root logger and is skipped without consuming bytes
(`osc_message.py:75-77`). Bundles (`#bundle`) are unpacked recursively and executed
immediately, time tags ignored (`osc_server.py:127-146`, `pythonosc/osc_bundle.py:21-66`).

`process()` (`osc_server.py:148-188`): drains the socket with `recvfrom(65536)` until
`EAGAIN`/`EWOULDBLOCK` (`158`, `174-179`); `ECONNRESET` is a warning (`169-173`), other
socket errors are logged at ERROR (`180-184`). Any other exception from parsing or a
handler is caught by the blanket `except Exception` (`186-188`): logged at ERROR
(`"AbletonOSC: Error handling OSC message: %s" % e`) plus the traceback at WARNING, and
**the drain stops for this tick**; datagrams still queued wait for the next tick. The tick
loop itself survives (section 4). `shutdown()` closes the socket (`190-194`).

## 3. `Manager(ControlSurface)` (`manager.py`)

- `__init__(self, c_instance)` (`manager.py:15-34`): `ControlSurface.__init__` (`16`),
  `log_level = "info"` (`18`), `handlers = []`, `midi_mappings = {}` (`20-21`); then inside
  `try`: `OSCServer()` (`24`), `schedule_message(0, self.tick)` (`25`), `start_logging()`
  (`27`), `init_api()` (`28`), status-bar message (`30`), log line (`31`). The tick is
  queued for Live's scheduler rather than run synchronously (**VERIFY** for delay 0), so
  `init_api()` completes before the first `tick()`.
- `init_api()` (`manager.py:70-103`) registers `/live/test` (sends `("ok",)` to the default
  address, `71-73`), `/live/api/reload` (`74-75`), `/live/api/get/log_level` (returns a
  tuple → reply, `76-77`), `/live/api/set/log_level` (asserts one of
  `debug|info|warning|error|critical`, changes only the file handler level, `78-82`),
  `/live/api/show_message` (`83-84`), then builds `self.handlers = [SongHandler(self),
  ApplicationHandler(self), ClipHandler, ClipSlotHandler, TrackHandler, DeviceHandler,
  ViewHandler, SceneHandler, MidiMapHandler]` inside `with self.component_guard():`
  (`92-103`). The overlay appends `BenchHandler(self)` to this list literal, inside the
  guard: `AbletonOSCHandler` is a `Component` (`handler.py:1,6`) and `self.song` in every
  upstream handler (`view.py:12`, `song.py:47`, `scene.py:16`) depends on the Component
  being parented by the control surface — **VERIFY** whether `component_guard()` is what
  parents it (it is `ControlSurface` code, not vendored). `self.manager.song()` and
  `Live.Application.get_application()` (`application.py:11`) do not need it.
- `clear_api()` (`manager.py:105-108`): `osc_server.clear_handlers()` then
  `handler.clear_api()` for every handler in the current list. Old `Component`s are never
  disconnected (harmless leak on reload).
- `tick()` (`manager.py:110-119`): `osc_server.process()` then `schedule_message(1, self.tick)`.
  The docstring states the cadence: "Called once per 100ms tick … does not appear to
  support threading, and beachballs when a thread is started" (`111-116`). Upstream's own
  tests also assume a 100 ms tick and wait 125 ms per tick (`tests/__init__.py:13-14`,
  not vendored). All OSC work runs on Live's main thread inside this callback.
- `schedule_message(delay_in_ticks, callback)` is inherited from `ControlSurface`; the
  vendored code shows the signature by use only: `schedule_message(0, self.tick)` at init
  (`manager.py:25`) and `schedule_message(1, self.tick)` per tick (`119`). It is one-shot;
  `tick()` re-arms itself. **VERIFY** the exact signature (`parameter=None` third argument
  in `ableton.v2`), that 1 tick is 100 ms, and that there is no API to cancel a scheduled
  callback (none is used upstream).
- `reload_imports()` (`manager.py:121-140`): see section 8. `disconnect()`
  (`142-147`) stops logging, closes the socket, then `super().disconnect()`.
  `build_midi_map()` (`149-158`) serves `/live/midimap/map_cc` (`midimap.py:11-23`).
- `show_message(text)` puts text in Live's status bar (`manager.py:30`, `72`, `84`) and is
  available to handlers as `self.manager.show_message(...)`.

## 4. `AbletonOSCHandler(Component)` (`abletonosc/handler.py`)

- Constructor `__init__(self, manager)` (`handler.py:7-16`): `super().__init__()` (`8`),
  `self.logger = logging.getLogger("abletonosc")` (`10`), `self.manager = manager` (`11`),
  `self.osc_server = manager.osc_server` (`12`), **then `self.init_api()` (`13`)**, and only
  afterwards `self.listener_functions = {}`, `self.listener_objects = {}` (`14-15`) and
  `self.class_identifier = None` (`16`).
  Consequences for a subclass:
  - `_start_listen` reads `self.listener_functions` (`handler.py:73`), so it cannot be
    called from `init_api()`; call it from a handler callback or create the dicts yourself
    before registering.
  - `class_identifier` must be assigned on the instance **after** `super().__init__(manager)`
    (upstream pattern `view.py:6-8`, `track.py:6-8`, `scene.py:6-8`); a class attribute is
    shadowed by the `None` assignment at `handler.py:16`. `class_identifier` is used in
    log lines (`28`, `32`, `44`) and in listener reply addresses
    `/live/<class_identifier>/get/<prop>` (`69`).
  - Any state that callbacks need must be created inside `init_api()` before
    `add_handler` (upstream does this: `song.py:269`, `clip.py:31` is set after
    `super().__init__`).
- `init_api()` is a no-op hook (`handler.py:18-19`); `clear_api()` calls
  `_clear_listeners()` (`21-22`) and is invoked by `Manager.clear_api()` on every
  `/live/api/reload` (`manager.py:107-108`). Overrides call `super().clear_api()`
  (`song.py:295-300`).
- Helpers (all synchronous, main thread): `_call_method(target, method, params=())` →
  `getattr(target, method)(*params)` (`handler.py:27-29`); `_set_property(target, prop,
  params)` → `setattr(target, prop, params[0])` (`31-33`); `_get_property(target, prop,
  params=())` → `(value, *params)`, `RuntimeError` → `None` (`35-45`);
  `_start_listen(target, prop, params=(), getter=None)` → `target.add_<prop>_listener(cb)`,
  key `(prop, tuple(params))`, re-registers if already present, sends
  `/live/<class_identifier>/get/<prop>` with `(*params, *value)` on every change **and
  once immediately** (`47-85`); `_stop_listen` (`87-107`) tolerates a dead observer;
  `_clear_listeners` (`109-116`).
- Listener callbacks are invoked by Live synchronously on the main thread when the
  property changes; upstream sends OSC from inside them (`handler.py:70`,
  `song.py:286-293`, `device.py:99-106`), so `song.add_is_playing_listener(cb)` with a
  `send()` inside `cb` follows established practice (**VERIFY** that the main-thread
  guarantee holds for `is_playing`).

## 5. `application.py` and `average_process_usage`

- `/live/application/get/version` → `(major, minor)` from
  `Live.Application.get_application().get_major_version()/get_minor_version()`
  (`application.py:10-13`).
- `/live/startup` is sent with no arguments during `init_api()` (`application.py:14`) — to
  `127.0.0.1:11001`, before any client exists.
- `/live/application/get/average_process_usage` → `(application.average_process_usage,)`
  (`application.py:16-19`); the attribute is read directly, no scaling, no try/except. At
  init an **empty** `/live/application/get/average_process_usage` message is also sent
  (`application.py:20`, no params). `peak_process_usage` is not referenced anywhere
  upstream. The unit (percent vs 0–1) cannot be read from the code → **VERIFY** with the
  smoke test against Live's CPU meter (`CPU_SCALE`).

## 6. Wire conventions of the upstream addresses the scenarios use

Index arguments are cast with `int()` by the wrappers (`clip.py:53`, `clip_slot.py:12`,
`device.py:12`, `scene.py:15`, `track.py:18`), so `i` or `f` both work there;
`song.py:105` and `song.py:234` unpack without casting. Replies carry the request address
and prepend the object indices.

| Address and arguments | Code | Effect / reply |
|---|---|---|
| `/live/song/start_playing`, `stop_playing`, `continue_playing`, `create_midi_track IDX`, `create_audio_track IDX`, `delete_track IDX`, `create_scene IDX`, `stop_all_clips`, `undo`, … | `song.py:20-48` via `_call_method(self.song, name)`; args passed positionally | no reply |
| `/live/song/set/tempo BPM`, `/live/song/set/current_song_time T`, `/live/song/set/loop 0|1` | `song.py:53-76`, `93-94` → `setattr(song, prop, params[0])` | no reply; send floats as `f` |
| `/live/song/get/is_playing`, `get/tempo`, `get/current_song_time` | `song.py:81-94` | `(value,)`; `is_playing` arrives as `T`/`F` |
| `/live/song/get/num_tracks` | `song.py:99` | `(n,)` |
| `/live/view/set/selected_track T` | `view.py:26-27`, `43` | `song.view.selected_track = song.tracks[T]`, no reply |
| `/live/clip/fire T C` | `clip.py:34-64`, `66-71`, `117-119` | `track.clip_slots[C].clip.fire()`; empty slot → `AttributeError` → `/live/error` |
| `/live/clip_slot/fire T C`, `/live/clip_slot/create_clip T C LENGTH` | `clip_slot.py:10-32`, `46-48` | slot methods; `create_clip(length)` |
| `/live/clip/add/notes T C [PITCH START DUR VEL MUTE]…` | `clip.py:145-155`, `167` | groups of five → `Live.Clip.MidiNoteSpecification`, `clip.add_new_notes` |
| `/live/scene/fire S` | `scene.py:13-30`, `46-47` | `song.scenes[S].fire()`, no reply |
| `/live/device/set/parameter/value T D P V` | `device.py:10-22`, `128-131`, `139` | `device.parameters[P].value = V`; `V` as received |
| `/live/track/get/num_devices T` | `track.py:11-30`, `139-140`, `159` | `(T, n)` |
| `/live/track/get/devices/name T` | `track.py:142-143`, `160` | `(T, name, …)` |
| `/live/track/get/output_meter_level T` | `track.py:46`, `66-68` | `(T, level)` |
| `/live/track/delete_device T D` | `track.py:32-35`, `62-64` | `track.delete_device(D)` |
| `/live/track/... "*"` | `track.py:15-18` | `params[0] == "*"` loops over all tracks but returns after the first reply (`27-28`) |
| `/live/test` | `manager.py:71-73` | `/live/test ("ok",)` + status-bar message |

`view.py` exposes only `selected_scene/track/clip/device` get/set/listen
(`view.py:38-50`); nothing in the tree calls `Application.View.show_view`,
`focus_view`, `available_main_views` or the browser, so those `/abl/bench/*` features
are new LOM usage (**VERIFY** on Live 12 as the design already lists).

## 7. Error relay to `/live/error`

- `start_logging()` (`manager.py:37-64`) attaches two handlers to the module logger
  `logging.getLogger("abletonosc")` (`manager.py:12`; the same logger object is used by
  `handler.py:10` and `osc_server.py:41`): a `FileHandler` (section 10) and
  `LiveOSCErrorLogHandler` (`manager.py:53-64`), level ERROR (`63`).
- `emit()` takes the record text, strips everything up to and including the first
  `": "` (`message[message.index(":") + 2:]`, `manager.py:56`) and sends
  `/live/error (text,)` to the default reply address (`57-58`); `OSError` from the send is
  ignored (`59-61`). A record whose message contains **no colon** makes
  `str.index` raise `ValueError` inside `emit()`; `logging.Handler.handle()` does not
  guard `emit()`, so the exception propagates out of the `logger.error(...)` call into
  the code that logged (inside an OSC handler it becomes a second error,
  `"Error handling OSC message: substring not found"`, relayed by `process()`; inside a
  scheduled callback it escapes into Live's scheduler). Always log errors as
  `"bench: <text>"` from `bench.py`; the client receives `<text>`.
- Sources that reach `/live/error` this way: handler exceptions caught in `process()`
  (`osc_server.py:186-188` → `"Error handling OSC message: <e>"`), unknown addresses
  (`125`), OSC build/parse/socket errors (`85`, `140`, `146`, `184`), `song.py:161`, and any
  `self.logger.error(...)` in a handler. Not relayed: `logging.warning(exc)` in
  `reload_imports()` (`manager.py:134-136`) goes to the root logger, so a failed reload is
  invisible both on OSC and in `abletonosc.log`.
- The logger's level is never set (only the file handler's, `manager.py:48`, `82`); INFO
  records are visible only if Live's root logger level allows them (**VERIFY**; the upstream
  log file does show `[INFO]` lines in practice).

## 8. `/live/api/reload` and new modules

- `reload_imports()` (`manager.py:121-140`) calls `importlib.reload` on a **fixed list**:
  `abletonosc.application, clip, clip_slot, device, handler, osc_server, scene, song,
  track, view`, then the package `abletonosc` (`manager.py:123-133`). Not reloaded:
  `manager.py` itself, `abletonosc/constants.py`, `midimap.py`, `introspection.py`,
  anything under `pythonosc/`, and any **new module such as `abletonosc/bench.py`**.
  Reloading the package re-executes `abletonosc/__init__.py`, which re-imports already
  loaded submodules without re-executing them (`abletonosc/__init__.py:6-16`).
- After the reloads it unconditionally runs `clear_api()` then `init_api()`
  (`manager.py:138-139`); handlers are re-instantiated from whatever class objects
  `init_api()` references at call time. Upstream references `abletonosc.SongHandler` etc.
  through the package attributes (`manager.py:94-102`), which the package re-execution
  rebinds to the reloaded classes. Note the upstream ordering quirk: handler modules are
  reloaded before `abletonosc.handler` (`123-127`), so the reloaded subclasses still
  derive from the previous `AbletonOSCHandler` class object.
- For the overlay this means: (1) `from .abletonosc import bench` in `manager.py` (a
  module binding stays valid across `importlib.reload`, which re-executes in place),
  (2) construct `bench.BenchHandler(self)` in the `init_api()` list, and (3) add
  `importlib.reload(bench)` to `reload_imports()` after the `abletonosc.handler` line
  (`manager.py:127`) and before `importlib.reload(abletonosc)` (`133`). Without (3),
  `/live/api/reload` re-instantiates the old `BenchHandler` and edits to `bench.py` need a
  Live restart. `manager.py` changes always need a restart. The design's "+2 lines"
  becomes +3 with the reload entry.
- `clear_api()` is the only hook on reload: remove listeners and mark periodic callbacks
  dead there. A `schedule_message` callback already queued by the old instance still fires
  once after reload (no cancel API is used upstream, **VERIFY**); guard the re-arm with a
  flag or generation counter so the old instance stops re-arming.
- The README calls `/live/api/reload` "Used in development only" (`README.md:43`).

## 9. Constraints on a periodic timer (`/abl/bench/cpu-period`)

- There is no thread and no `Live.Base.Timer` in the tree; the only periodic mechanism
  upstream is the self-re-arming `schedule_message(1, self.tick)` (`manager.py:118-119`).
  A bench period of `MS` milliseconds is `schedule_message(max(1, round(MS / 100)),
  self._cpu_tick)` re-armed at the end of `_cpu_tick`; resolution and minimum period are
  one tick (nominally 100 ms); the real period includes scheduler jitter and the time the
  OSC drain and handlers take within the same tick — measure it from the `dump` timestamps
  in the smoke test.
- A scheduled callback runs outside `OSCServer.process()`, so its exceptions are **not**
  caught by `osc_server.py:186-188`; they propagate into Live's scheduler and, if raised
  before the re-arm line, the timer silently stops. Wrap the body in `try/except
  Exception`, log with `self.logger.error("bench: …")`, and re-arm in `finally`.
- Everything (socket drain, handlers, listeners, timer callbacks) shares Live's main
  thread: a slow handler (browser walk, device load) delays the tick, the UI and every
  queued message. A client sending at 20 Hz sees its messages processed in bursts of two
  per tick (`tick()` drains the whole socket, `osc_server.py:154-166`).
- Report values with `int`/`float`/`str` only (section 2); `float` is 32-bit on the wire,
  so Live song time keeps about 7 significant digits.

## 10. Logging path and cost

- `start_logging()` resolves `os.path.dirname(os.path.realpath(__file__))` of `manager.py`
  and creates `logs/` (mode `0o755`) beside it, file `logs/abletonosc.log`
  (`manager.py:42-46`); `realpath` follows symlinks, so a symlinked install would log into
  the symlink target — the repo's `profiler/.gitignore` ignores
  `control/vendor/AbletonOSC/logs/` for that case; `install.sh` copies instead. Under
  Wine the installed copy lives in the User Library, so the host path is
  `<prefix>/drive_c/users/<user>/Documents/Ableton/User Library/Remote Scripts/AbletonOSC/logs/abletonosc.log`
  (README install paths `README.md:17-25`; `Documents` may be a symlink, **VERIFY** with
  `readlink -f`). The directory must be writable by Live; never install under
  `ProgramData/Ableton/*/Resources/MIDI Remote Scripts`.
- `FileHandler` opens in append mode and is never rotated. Format
  `(%(asctime)s) [%(levelname)s] %(message)s` (`manager.py:49`). Default level `info`
  (`manager.py:18`, `48`); `/live/api/set/log_level LEVEL` changes it at runtime
  (`manager.py:78-82`, no reply; query with `/live/api/get/log_level`).
- Every upstream `get/set/call` logs one INFO line (`handler.py:28`, `32`, `44`), listener
  updates another (`68`), and at `debug` the tick logs `"Tick..."` ten times a second
  (`manager.py:117`). For measurement windows set `error` (or at most `warning`) before
  the window; the smoke test can leave `info`.
- The log file's mtime moves on the first `logger.info` of a session (`manager.py:31`),
  which is what `smoke-test.sh` compares against the Live process start time.

## 11. Python version and syntax assumptions

- README: "AbletonOSC requires Ableton Live 11 or above" (`README.md:13`).
- The vendored code uses only `typing.Tuple/Optional/Any/Callable` generics
  (`handler.py:2`, `track.py:1`), `super().__init__()`, `%`-formatting, star-unpacking
  in tuple displays (`handler.py:45`), `socket.setblocking(0)`; no f-strings, walrus,
  `match`, `X | Y` unions or `list[...]` generics anywhere in `manager.py`,
  `abletonosc/` or `pythonosc/` — it runs on any 3.5+ interpreter, so it adds no
  constraint beyond Live's own. `__pycache__` directories are written by Live next to the
  sources at load time (upstream `.gitignore` lists `__pycache__`); `vendor.sh` strips
  them and `--check` ignores them.
- Live 12's embedded interpreter is expected to be 3.11 (plan assumption); keep
  `bench.py` and the overlay 3.11-compatible (no PEP 695 `type` aliases, no nested
  same-quote f-strings). **VERIFY** on the VM once Live is installed: the first two bytes
  of any shipped Remote Script bytecode give the magic number —
  `od -An -tu2 -N2 "<Program>/Resources/MIDI Remote Scripts/ableton/v2/control_surface/control_surface.pyc"`
  → `3495` is 3.11 (`3439` 3.10, `3531` 3.12); also `ls "<Program>" | grep -i python`
  for the bundled `python3xx.dll`. At the time of writing the VM has no Live install
  (`~/.wine-ableton` absent), so this is unmeasured.
- `/abl/bench/info` should report `sys.version` from inside Live to settle it at runtime.

## 12. Checklist for `overlay/abletonosc/bench.py` (derived from the above)

1. `class BenchHandler(AbletonOSCHandler)`; `__init__`: `super().__init__(manager)` then
   `self.class_identifier = "bench"`; create any dict/state inside `init_api()` before
   registering.
2. Register with `self.osc_server.add_handler("/abl/bench/<x>", fn)`; `fn(params)` gets a
   list; return `None` and send replies explicitly with `self.osc_server.send(addr,
   (ints, floats, strs))`, plus `send(addr, params, remote_addr=(host, port))` per
   subscriber.
3. Wrap every callback and the timer body in `try/except Exception`, report with
   `self.logger.error("bench: %s" % exc)` (the colon is required: without one the relay
   handler itself raises, section 7), never let an exception reach the re-arm line.
4. `clear_api()`: remove the `is_playing` listener, set the period to 0 / bump the
   generation counter, then `super().clear_api()`.
5. Never answer `ping` by returning a tuple (that replies on `/abl/bench/ping`).
6. Expect `/live/error` and `/live/startup` traffic on the same 11001 socket as
   `/abl/bench/*` reports; `bench-osc.py dump` sees them all.
7. Instance construction happens inside `component_guard()` in `Manager.init_api()`; if
   `self.song` is avoided, use `self.manager.song()` or `Live.Application.get_application()`.

## VERIFY (Live framework facts not readable from the vendored tree)

1. `ControlSurface.schedule_message(delay_in_ticks, callback, parameter=None)`: exact
   signature, 100 ms tick on Live 12, one-shot, no cancel.
2. `component_guard()` parents `Component`s so that `self.song` works; behaviour of a
   handler created outside it.
3. Unit of `Application.average_process_usage` and existence of `peak_process_usage`.
4. Listener callbacks (`add_is_playing_listener`) run on the main thread.
5. Python version of Live 12's Remote Script interpreter (pyc magic check above).
6. User Library path and the `Documents` symlink inside the prefix.
7. `Application.View.show_view/focus_view/available_main_views` and the browser API —
   no upstream usage to copy from.
