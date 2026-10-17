"""The benchmark suite's /abl/bench/* control protocol as an AbletonOSC handler.

The canonical Sets embedded a Max for Live device that spoke this protocol on
UDP 19001/19002. This handler speaks the same protocol on AbletonOSC's own
server (11000 in, 11001 out) without a Max runtime, plus the scenario-driver
additions (markers, views, device loading, subscribers). Every report carries
only int, float and str arguments so scripts/bench-osc.py decode() keeps
working; bools go out as 0/1.

Every callback runs on Live's main thread inside Manager.tick(). A failing
Live API call is logged as "bench: ..." which the manager relays to
/live/error; it never stops the tick loop or the periodic CPU report.
"""
import collections
import os
import sys
import traceback

import Live
from .handler import AbletonOSCHandler

# Multiplier for Application.average_process_usage and peak_process_usage so
# the wire carries percent. Both attributes already are percent of the audio
# buffer period (Live 12.4.6, B5 on the laptop: AbletonOSC's unscaled
# /live/application/get/average_process_usage returned exactly the value this
# handler reported, 22.159615 and 48.926708; Live's CPU meter showed 26% on
# Benchmark_Empty, whose B4 average was 27%). peak_process_usage is Live's recent worst buffer,
# 1.7-2x the average and not reset by reading; it exceeds 100% when a buffer
# misses its deadline (B4's 571-797% peaks match PipeWire xruns), so a large
# peak is not a unit error. Keep 1.0.
CPU_SCALE = 1.0
# Live runs schedule_message() callbacks on 100 ms ticks (Manager.tick).
TICK_MS = 100
# The Max device reported CPU every 500 ms without being asked; the suite's
# osc collector relies on that.
DEFAULT_CPU_PERIOD_MS = 500
# Browser roots that /abl/bench/load-device searches by item name.
BROWSER_ROOTS = ("instruments", "audio_effects", "midi_effects", "plugins", "max_for_live")
SCRIPT_PATH = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))


class BenchHandler(AbletonOSCHandler):
    def __init__(self, manager):
        super().__init__(manager)
        self.class_identifier = "bench"

    def init_api(self):
        # AbletonOSCHandler.__init__ calls init_api() before it assigns its own
        # attributes, so everything a callback needs is created here first.
        self.subscribers = set()
        self.period_ticks = 0
        self.generation = 0
        self.playing_listener = None
        self.browser_index = {}
        self.browser_pending = {}
        self.cpu_attribute_ok = False

        self._add("ping", self._ping)
        self._add("play", self._play)
        self._add("stop", self._stop)
        self._add("rewind", self._rewind)
        self._add("poll", self._poll)
        self._add("cpu-period", self._cpu_period)
        self._add("scenario-marker", self._scenario_marker)
        self._add("info", self._info)
        self._add("views", self._views)
        self._add("show-view", self._show_view)
        self._add("focus-view", self._focus_view)
        self._add("load-device", self._load_device)
        self._add("subscribe", self._subscribe)
        self._add("unsubscribe", self._unsubscribe)
        self._startup()

    def clear_api(self):
        # Manager.clear_api() calls this on /live/api/reload: a CPU tick this
        # instance still has queued must die, and the listener must go.
        self.generation += 1
        self.period_ticks = 0
        if self.playing_listener is not None:
            try:
                self.song.remove_is_playing_listener(self.playing_listener)
            except Exception as e:
                self.logger.info("bench: is_playing listener already removed: %s" % e)
            self.playing_listener = None
        super().clear_api()

    def disconnect(self):
        # Manager.disconnect() (Set closed, surface deselected, Live quitting)
        # shuts the OSC socket and never calls clear_api(): drop the listener
        # and the CPU chain here so nothing reports through the closed socket.
        self.clear_api()
        super().disconnect()

    #--------------------------------------------------------------------------------
    # Registration, reports, errors
    #--------------------------------------------------------------------------------
    def _add(self, name, callback):
        def guarded(params):
            try:
                callback(params)
            except Exception as e:
                # "bench: " supplies the ": " the error relay strips (manager.py).
                self.logger.error("bench: %s failed: %s" % (name, e))
                self.logger.warning("bench: %s" % traceback.format_exc())
        self.osc_server.add_handler("/abl/bench/" + name, guarded)

    def _report(self, address, params):
        params = tuple(params)
        self.osc_server.send(address, params)
        for subscriber in list(self.subscribers):
            try:
                self.osc_server.send(address, params, remote_addr=subscriber)
            except OSError as e:
                self.logger.warning("bench: subscriber %s:%d missed %s: %s"
                                    % (subscriber[0], subscriber[1], address, e))

    def _startup(self):
        ready = 1
        try:
            float(Live.Application.get_application().average_process_usage)
            self.cpu_attribute_ok = True
        except Exception as e:
            ready = 0
            self.logger.error("bench: average_process_usage is unavailable: %s" % e)
        try:
            self._listen_playing()
        except Exception as e:
            ready = 0
            self.logger.error("bench: is_playing listener failed: %s" % e)
        try:
            self._set_period(DEFAULT_CPU_PERIOD_MS)
        except Exception as e:
            ready = 0
            self.logger.error("bench: cpu period failed: %s" % e)
        self._report("/abl/bench/ready", (ready,))

    def _listen_playing(self):
        song = self.song

        def playing_changed():
            try:
                self._report("/abl/bench/playing", (int(song.is_playing),))
            except Exception as e:
                self.logger.error("bench: playing report failed: %s" % e)
        song.add_is_playing_listener(playing_changed)
        self.playing_listener = playing_changed

    #--------------------------------------------------------------------------------
    # Periodic CPU report: schedule_message() is one-shot with no cancel, so a
    # generation counter kills the chain instead.
    #--------------------------------------------------------------------------------
    def _set_period(self, ms):
        self.generation += 1
        self.period_ticks = max(1, int(round(ms / float(TICK_MS)))) if ms > 0 else 0
        if self.period_ticks:
            self._arm(self.generation)

    def _arm(self, generation):
        def cpu_tick(*_):
            if generation != self.generation:
                return
            try:
                self._send_cpu()
            except Exception as e:
                self.logger.error("bench: cpu report failed: %s" % e)
            if generation == self.generation:
                self._arm(generation)
        self.manager.schedule_message(self.period_ticks, cpu_tick)

    def _cpu_values(self):
        try:
            application = Live.Application.get_application()
        except Exception:
            application = None
        values = []
        for attribute in ("average_process_usage", "peak_process_usage"):
            try:
                values.append(float(getattr(application, attribute)) * CPU_SCALE)
            except Exception:
                values.append(-1.0)
        return tuple(values)

    def _send_cpu(self):
        self._report("/abl/bench/cpu", self._cpu_values())

    #--------------------------------------------------------------------------------
    # Callbacks; params is the list of OSC arguments
    #--------------------------------------------------------------------------------
    def _ping(self, params):
        self._report("/abl/bench/pong", params)

    def _play(self, params):
        self.song.start_playing()

    def _stop(self, params):
        self.song.stop_playing()

    def _rewind(self, params):
        self.song.current_song_time = 0.0

    def _poll(self, params):
        self._send_cpu()

    def _cpu_period(self, params):
        self._set_period(float(params[0]) if params else DEFAULT_CPU_PERIOD_MS)

    def _scenario_marker(self, params):
        song = self.song
        name = str(params[0]) if params else ""
        self._report("/abl/bench/scenario-marker",
                     (name, float(song.current_song_time), int(song.is_playing)))

    def _info(self, params):
        self._report("/abl/bench/info",
                     (self._live_version(), "%d.%d.%d" % sys.version_info[:3],
                      int(self.cpu_attribute_ok), SCRIPT_PATH))

    def _live_version(self):
        application = Live.Application.get_application()
        parts = []
        for name in ("get_major_version", "get_minor_version", "get_bugfix_version"):
            try:
                parts.append(str(int(getattr(application, name)())))
            except Exception:
                break
        return ".".join(parts) or "unknown"

    def _views(self, params):
        view = Live.Application.get_application().view
        self._report("/abl/bench/views", tuple(str(name) for name in view.available_main_views()))

    def _show_view(self, params):
        self._view_call("show_view", params)

    def _focus_view(self, params):
        self._view_call("focus_view", params)

    def _view_call(self, method, params):
        name = str(params[0])
        view = Live.Application.get_application().view
        getattr(view, method)(name)
        self._report("/abl/bench/view", (name, int(view.is_view_visible(name))))

    def _load_device(self, params):
        kind, name = str(params[0]), str(params[1])
        if len(params) > 2:
            self.song.view.selected_track = self.song.tracks[int(params[2])]
        item = self._browser_item(kind, name)
        if item is None:
            self._report("/abl/bench/load-device", (name, "missing"))
            return
        try:
            Live.Application.get_application().browser.load_item(item)
        except Exception:
            # A cached item can be stale after a browser rescan: forget the index.
            self.browser_index.pop(kind, None)
            self.browser_pending.pop(kind, None)
            raise
        self._report("/abl/bench/load-device", (name, "ok"))

    def _browser_item(self, kind, name):
        if kind not in BROWSER_ROOTS:
            raise ValueError("unknown browser root %r; expected one of %s" % (kind, ", ".join(BROWSER_ROOTS)))
        index = self.browser_index.get(kind)
        if index is None:
            index = self.browser_index[kind] = {}
            self.browser_pending[kind] = collections.deque(
                [getattr(Live.Application.get_application().browser, kind)])
        if name in index:
            return index[name]
        # Breadth-first, in browser order, and only until the name turns up:
        # this runs on Live's main thread, and the preset trees below the
        # devices are large. The shallowest loadable item with a name wins, so
        # a top-level device is never shadowed by a same-named preset. The
        # walk resumes where it stopped for the next name.
        pending = self.browser_pending[kind]
        while pending:
            item = pending.popleft()
            pending.extend(item.children)
            if item.is_loadable and item.name not in index:
                index[item.name] = item
                if item.name == name:
                    return item
        return None

    def _subscribe(self, params):
        self.subscribers.add(("127.0.0.1", int(params[0])))

    def _unsubscribe(self, params):
        self.subscribers.discard(("127.0.0.1", int(params[0])))
