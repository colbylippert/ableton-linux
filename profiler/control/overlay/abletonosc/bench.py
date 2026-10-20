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
import math
import os
import re
import sys
import time
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
# The load ramp (/abl/bench/duplicate-all) keeps every summing bus at the Set's own level. The copies play the same
# audio in sync, so with N copies playing the return tracks and the master receive N times the amplitude
# (+20 log10 N dB) and their effects would run hot. The first pass finds a trim for every return track and for the
# master: the Utility already first in its chain when its gain is not automated (the Set's returns start with one),
# else a new Utility put first; each pass sets the trim to the Set's own gain minus 20 log10 N dB. Sends, faders and
# automation stay as the Set has them: setting an automated parameter would override its automation for the rest of
# the session. The trims cost the same in every configuration a ramp compares.
RAMP_TRIM_DEVICE = "Utility"
# Utility's gain parameter: "Output" in Live 12.4 (12.4.6: Device On, Left Inv, Right Inv, Channel Mode, Stereo Width,
# Mono, Bass Mono, Bass Freq, Balance, Output, Mute, DC Filter), "Gain" in earlier versions.
RAMP_TRIM_PARAMETERS = ("Output", "Gain")
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
        self.ramp_originals = None
        self.ramp_pass = 0
        self.ramp_trims = []

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
        self._add("duplicate-all", self._duplicate_all)
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

    def _duplicate_all(self, params):
        """One load-ramp pass: duplicate every top-level track the Set had at the first pass (a group with its
        children), so each pass adds the Set's own load once; the copies play the same clips and automation in sync.
        The first pass also puts a Utility first on every return track and on the master, and every pass sets their
        gain to -20 log10 N dB with N copies playing. Reports /abl/bench/duplicate-all (pass, tracks now, ms, trims,
        trim gain in dB, the largest distance in dB between a trim's display and its target)."""
        song = self.song
        start = time.monotonic()
        if self.ramp_originals is None:
            self.ramp_originals = [track for track in song.tracks if not track.is_grouped]
            for bus in list(song.return_tracks) + [song.master_track]:
                try:
                    trim = self._bus_trim(bus)
                    self.ramp_trims.append((trim, self._db_of(trim, trim.value)))
                except Exception as e:
                    self.logger.error("bench: no load-ramp trim on %s: %s %r (insert_device %s; first device %s)" % (
                        getattr(bus, "name", "?"), type(e).__name__, e, hasattr(bus, "insert_device"),
                        getattr(bus.devices[0], "class_name", "?") if list(bus.devices) else "none"))
        tracks = list(song.tracks)
        # from the last original to the first, so the indices still to come stay valid
        for index in sorted((self._index_of(tracks, track) for track in self.ramp_originals), reverse=True):
            song.duplicate_track(index)
        self.ramp_pass += 1
        gain_db = -20.0 * math.log10(self.ramp_pass + 1)
        miss_db = 0.0
        for trim, own_db in self.ramp_trims:
            target = own_db + gain_db
            self._set_db(trim, target)
            if target > float("-inf"):   # a bus the Set keeps silent stays silent
                miss_db = max(miss_db, abs(self._db_of(trim, trim.value) - target))
        self._report("/abl/bench/duplicate-all", (self.ramp_pass, len(song.tracks), int((time.monotonic() - start) * 1000),
                                                  len(self.ramp_trims), round(gain_db, 2), round(miss_db, 2)))

    def _bus_trim(self, track):
        """The gain that trims TRACK: the Utility already first in its chain when its gain is not automated, else a new
        Utility put first."""
        devices = list(track.devices)
        if devices and getattr(devices[0], "class_name", "") == "StereoGain":
            gain = self._gain_parameter(devices[0])
            if getattr(gain, "automation_state", 0) == 0:
                return gain
        return self._insert_trim(track)

    @staticmethod
    def _gain_parameter(device):
        """Utility's gain: its parameter with the first name in RAMP_TRIM_PARAMETERS."""
        parameters = list(device.parameters)
        for name in RAMP_TRIM_PARAMETERS:
            for parameter in parameters:
                if parameter.name == name:
                    return parameter
        raise ValueError("no gain parameter (%s) on %s; it has %s" % (
            "/".join(RAMP_TRIM_PARAMETERS), getattr(device, "class_name", "?"),
            ", ".join(repr(p.name) for p in parameters)))

    def _insert_trim(self, track):
        """A Utility first in TRACK's chain; its gain parameter. Live 12.1+ inserts a native device at an index; else
        the browser loads it on the selected track and Song.move_device puts it first."""
        if hasattr(track, "insert_device"):
            track.insert_device(RAMP_TRIM_DEVICE, 0)
            device = track.devices[0]
        else:
            item = self._browser_item("audio_effects", RAMP_TRIM_DEVICE)
            if item is None:
                raise ValueError("%s is not in the browser" % RAMP_TRIM_DEVICE)
            before = list(track.devices)
            self.song.view.selected_track = track
            Live.Application.get_application().browser.load_item(item)
            device = next(d for d in track.devices if not any(d == b for b in before))
            self.song.move_device(device, track, 0)
        return self._gain_parameter(device)

    @staticmethod
    def _db_of(parameter, value):
        """VALUE of PARAMETER in dB as its own display reads it ("-6.0 dB"; "-inf dB" at the bottom)."""
        text = parameter.str_for_value(value)
        match = re.search(r"(-?inf|[-+]?\d+(?:\.\d+)?)", text)
        if not match:
            raise ValueError("unreadable %s display: %r" % (parameter.name, text))
        return float("-inf") if "inf" in match.group(1) else float(match.group(1))

    @classmethod
    def _set_db(cls, parameter, db):
        """Set PARAMETER to DB as its display reads it: a bisection over str_for_value, which rises with the value."""
        low, high = parameter.min, parameter.max
        for _ in range(40):
            middle = (low + high) / 2.0
            if cls._db_of(parameter, middle) < db:
                low = middle
            else:
                high = middle
        parameter.value = high

    @staticmethod
    def _index_of(tracks, track):
        for index, other in enumerate(tracks):
            if other == track:
                return index
        raise ValueError("an original track of the load ramp is gone: %s" % getattr(track, "name", "?"))

    def _unsubscribe(self, params):
        self.subscribers.discard(("127.0.0.1", int(params[0])))
