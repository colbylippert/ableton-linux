#!/usr/bin/env python3
"""A fake Live for tests: the modules the vendored AbletonOSC imports when it
loads, the Live objects BenchHandler touches, and a loader that assembles
vendor/AbletonOSC/ plus overlay/ the way install.sh does and imports it.

    python3 fake_live.py serve [--duration S] [--listen-port N] [--response-port N]

runs the overlay Manager on the real OSCServer with a 100 ms tick loop, so
scripts/bench-osc.py, liveosc.py and smoke-test.sh can be exercised without
Live. Nothing here needs Live; python stdlib only.
"""

import argparse
import atexit
import contextlib
import functools
import importlib
import os
import shutil
import signal
import sys
import tempfile
import time
import types

HERE = os.path.dirname(os.path.abspath(__file__))
CONTROL = os.path.dirname(HERE)
VENDOR = os.path.join(CONTROL, "vendor", "AbletonOSC")
OVERLAY = os.path.join(CONTROL, "overlay")
MAIN_VIEWS = ("Browser", "Arranger", "Session", "Detail", "Detail/Clip", "Detail/DeviceChain")

# What Live.Application.get_application() returns; install() replaces it.
state = types.SimpleNamespace(application=None)


#--------------------------------------------------------------------------------
# Live objects
#--------------------------------------------------------------------------------
class FakeTrack(object):
    def __init__(self, name, group=None, foldable=False, sends=()):
        self.name = name
        self.devices = []
        self.clip_slots = []
        self.group_track = group
        self.is_grouped = group is not None
        self.is_foldable = foldable
        self.mixer_device = FakeMixer(sends)


class FakeParameter(object):
    def __init__(self, value, minimum=0.0, maximum=1.0):
        self.value = value
        self.min = minimum
        self.max = maximum
        self.automation_state = 0   # Live.DeviceParameter.AutomationState: 0 none, 1 playing, 2 overridden


class FakeMixer(object):
    def __init__(self, sends=()):
        self.volume = FakeParameter(0.85)
        self.sends = [FakeParameter(value) for value in sends]


class FakeMasterTrack(object):
    def __init__(self):
        self.mixer_device = FakeMixer()


class FakeSongView(object):
    def __init__(self, song):
        self.selected_track = song.tracks[0] if song.tracks else None
        self.selected_scene = None
        self.selected_device = None


class FakeSong(object):
    """Playback state with the is_playing listener BenchHandler uses; every
    other attribute exists so the vendored handlers construct."""

    def __init__(self):
        self.is_playing = False
        self.current_song_time = 0.0
        self.tempo = 120.0
        self.tracks = [FakeTrack("1-MIDI"), FakeTrack("2-Audio")]
        self.master_track = FakeMasterTrack()
        self.scenes = []
        self.cue_points = []
        self.view = FakeSongView(self)
        self.calls = []
        self.listeners = {}

    def add_is_playing_listener(self, callback):
        self.listeners.setdefault("is_playing", []).append(callback)

    def remove_is_playing_listener(self, callback):
        try:
            self.listeners["is_playing"].remove(callback)
        except (KeyError, ValueError):
            raise RuntimeError("listener is not connected")

    def start_playing(self):
        self.calls.append("start_playing")
        self.set_playing(True)

    def stop_playing(self):
        self.calls.append("stop_playing")
        self.set_playing(False)

    def duplicate_track(self, index):
        """As Live: the copy goes right after the track, and a group is copied with its children, after the last."""
        track = self.tracks[index]
        block = [track]
        if track.is_foldable:
            for other in self.tracks[index + 1:]:
                if other.group_track is not track:
                    break
                block.append(other)
        def sends(t):
            return [send.value for send in t.mixer_device.sends]
        group = FakeTrack(track.name, track.group_track, track.is_foldable, sends(track))
        copies = [group] + [FakeTrack(child.name, group, child.is_foldable, sends(child)) for child in block[1:]]
        self.tracks[index + len(block):index + len(block)] = copies
        self.calls.append("duplicate_track %d" % index)

    def set_playing(self, value):
        if self.is_playing == value:
            return
        self.is_playing = value
        for callback in list(self.listeners.get("is_playing", [])):
            callback()


class FakeBrowserItem(object):
    def __init__(self, name, children=(), is_loadable=False, is_device=False, uri=""):
        self.name = name
        self.children = list(children)
        self.is_loadable = is_loadable
        self.is_device = is_device
        self.uri = uri or "query:%s" % name

    def iter_children(self):
        return iter(self.children)


def default_browser_roots():
    return {
        "instruments": FakeBrowserItem("Instruments", [
            FakeBrowserItem("Drums", [FakeBrowserItem("Drum Rack", is_loadable=True, is_device=True)]),
            FakeBrowserItem("Operator", is_loadable=True, is_device=True),
            FakeBrowserItem("Wavetable", is_loadable=True, is_device=True),
        ]),
        "audio_effects": FakeBrowserItem("Audio Effects", [
            FakeBrowserItem("Reverb", is_loadable=True, is_device=True),
        ]),
        "midi_effects": FakeBrowserItem("MIDI Effects", [
            FakeBrowserItem("Arpeggiator", is_loadable=True, is_device=True),
        ]),
        "plugins": FakeBrowserItem("Plug-Ins", [
            FakeBrowserItem("VST3", [FakeBrowserItem("Dexed", is_loadable=True, is_device=True)]),
        ]),
        "max_for_live": FakeBrowserItem("Max for Live", []),
    }


class FakeBrowser(object):
    def __init__(self):
        for name, root in default_browser_roots().items():
            setattr(self, name, root)
        self.loaded = []
        self.load_error = None

    def load_item(self, item):
        if self.load_error is not None:
            raise self.load_error
        self.loaded.append(item)


class FakeApplicationView(object):
    def __init__(self):
        self.visible = {"Session", "Browser", "Detail"}
        self.shown = []
        self.focused = []

    def available_main_views(self):
        return list(MAIN_VIEWS)

    def show_view(self, name):
        self.shown.append(name)
        self.visible.add(name)

    def focus_view(self, name):
        self.focused.append(name)
        self.visible.add(name)

    def is_view_visible(self, name):
        return name in self.visible


class FakeApplication(object):
    """average_process_usage/peak_process_usage read a value or raise
    usage_error, so a test can make the attribute unavailable."""

    def __init__(self, average=0.25, peak=0.5, version=(12, 4, 3)):
        self._average = average
        self._peak = peak
        self.usage_error = None
        self.version = version
        self.view = FakeApplicationView()
        self.browser = FakeBrowser()

    def _usage(self, value):
        if self.usage_error is not None:
            raise self.usage_error
        return value

    @property
    def average_process_usage(self):
        return self._usage(self._average)

    @average_process_usage.setter
    def average_process_usage(self, value):
        self._average = value

    @property
    def peak_process_usage(self):
        return self._usage(self._peak)

    @peak_process_usage.setter
    def peak_process_usage(self, value):
        self._peak = value

    def get_major_version(self):
        return self.version[0]

    def get_minor_version(self):
        return self.version[1]

    def get_bugfix_version(self):
        return self.version[2]


#--------------------------------------------------------------------------------
# Live's control surface framework: what manager.py and handler.py use
#--------------------------------------------------------------------------------
class Component(object):
    """ableton.v2.control_surface.component.Component: only .song is used.
    Live parents a Component to the control surface whose component_guard()
    is active; here the guard records which ControlSurface supplies the song."""

    song_provider = None

    def __init__(self, *args, **kwargs):
        provider = Component.song_provider
        self._song = provider.song() if provider is not None else None
        self.disconnected = False

    def disconnect(self):
        self.disconnected = True

    @property
    def song(self):
        if self._song is None:
            raise RuntimeError("Component was created outside component_guard()")
        return self._song


class FakeCInstance(object):
    def __init__(self, song):
        self._song = song

    def song(self):
        return self._song


class ControlSurface(object):
    """ableton.v2.control_surface.ControlSurface: schedule_message() queues
    one-shot callbacks that advance() fires on 100 ms ticks, like Live."""

    def __init__(self, c_instance=None, *args, **kwargs):
        self._c_instance = c_instance
        self.scheduled = []
        self.messages = []

    def song(self):
        return self._c_instance.song()

    def schedule_message(self, delay_in_ticks, callback, parameter=None):
        assert delay_in_ticks >= 0
        assert callable(callback)
        self.scheduled.append([delay_in_ticks, callback, parameter])

    def advance(self, ticks=1):
        """Run ticks: a callback scheduled with delay N fires on the Nth tick
        after scheduling (N = 0 on the next one). Callbacks that re-arm
        themselves while firing wait for a later tick."""
        for _ in range(ticks):
            pending, self.scheduled = self.scheduled, []
            for entry in pending:
                entry[0] -= 1
                if entry[0] > 0:
                    self.scheduled.append(entry)
                    continue
                _, callback, parameter = entry
                if parameter is None:
                    callback()
                else:
                    callback(parameter)

    @contextlib.contextmanager
    def component_guard(self):
        previous = Component.song_provider
        Component.song_provider = self
        try:
            yield
        finally:
            Component.song_provider = previous

    def show_message(self, text):
        self.messages.append(text)

    def request_rebuild_midi_map(self):
        pass

    def disconnect(self):
        pass


class EncoderElement(object):
    pass


class FakeOSCServer(object):
    """Records what OSCServer.send() would put on the wire; dispatch() calls a
    registered handler the way process_message() does."""

    def __init__(self, *args, **kwargs):
        self._local_addr = ("0.0.0.0", 11000)
        self._remote_addr = ("127.0.0.1", 11001)
        self._response_port = 11001
        self.handlers = {}
        self.sent = []

    def add_handler(self, address, handler):
        self.handlers[address] = handler

    def clear_handlers(self):
        self.handlers = {}

    def send(self, address, params=(), remote_addr=None):
        self.sent.append((address, tuple(params), remote_addr))

    def dispatch(self, address, *params):
        rv = self.handlers[address](list(params))
        if rv is not None:
            assert isinstance(rv, tuple)
            self.send(address, rv, ("127.0.0.1", self._response_port))
        return rv

    def messages(self, address):
        return [(params, remote_addr) for sent, params, remote_addr in self.sent if sent == address]

    def process(self):
        pass

    def shutdown(self):
        pass


class FakeManager(ControlSurface):
    """The attributes of Manager that AbletonOSCHandler and BenchHandler use,
    with a recording server instead of a socket."""

    def __init__(self, song=None, osc_server=None):
        ControlSurface.__init__(self, FakeCInstance(song or FakeSong()))
        self.osc_server = osc_server or FakeOSCServer()
        self.handlers = []
        self.midi_mappings = {}
        self.log_level = "info"


#--------------------------------------------------------------------------------
# Module installation and the vendor + overlay loader
#--------------------------------------------------------------------------------
def _module(name, **attributes):
    module = types.ModuleType(name)
    module.__path__ = []
    module.__fake_live__ = True
    for key, value in attributes.items():
        setattr(module, key, value)
    sys.modules[name] = module
    return module


def install(application=None):
    """Put the fake Live, ableton and _Framework modules into sys.modules
    (idempotent) and select the application get_application() returns."""
    state.application = application or FakeApplication()
    if getattr(sys.modules.get("Live"), "__fake_live__", False):
        return state.application
    live = _module("Live")
    live.Application = _module("Live.Application", get_application=lambda: state.application)
    live.Clip = _module("Live.Clip")
    live.MidiMap = _module("Live.MidiMap")
    live.Base = _module("Live.Base")
    ableton = _module("ableton")
    ableton.v2 = _module("ableton.v2")
    ableton.v2.control_surface = _module("ableton.v2.control_surface", ControlSurface=ControlSurface)
    ableton.v2.control_surface.component = _module("ableton.v2.control_surface.component", Component=Component)
    framework = _module("_Framework")
    framework.EncoderElement = _module("_Framework.EncoderElement", EncoderElement=EncoderElement)
    return state.application


def assemble(target):
    """Copy vendor/AbletonOSC/ then overlay/ into target, as install.sh does."""
    shutil.copytree(VENDOR, target, ignore=shutil.ignore_patterns("__pycache__", "*.pyc", "logs"))
    for dirpath, _, filenames in os.walk(OVERLAY):
        for filename in filenames:
            if filename.endswith(".pyc"):
                continue
            source = os.path.join(dirpath, filename)
            destination = os.path.join(target, os.path.relpath(source, OVERLAY))
            os.makedirs(os.path.dirname(destination), exist_ok=True)
            shutil.copy2(source, destination)


_package = None


def load_overlay():
    """Import vendor + overlay as the package AbletonOSC from a temporary
    directory; returns the package (its manager and abletonosc.bench loaded)."""
    global _package
    if _package is not None:
        return _package
    install()
    root = tempfile.mkdtemp(prefix="fake-live-")
    atexit.register(shutil.rmtree, root, True)
    assemble(os.path.join(root, "AbletonOSC"))
    sys.path.insert(0, root)
    _package = importlib.import_module("AbletonOSC")
    # AbletonOSC/__init__.py swallows ImportError; import the pieces explicitly.
    importlib.import_module("AbletonOSC.manager")
    importlib.import_module("AbletonOSC.abletonosc.bench")
    return _package


#--------------------------------------------------------------------------------
# serve: the overlay Manager on the real OSCServer, ticked every 100 ms
#--------------------------------------------------------------------------------
def serve(args):
    package = load_overlay()
    song = FakeSong()
    application = state.application
    application.average_process_usage = args.cpu_average
    application.peak_process_usage = args.cpu_peak
    osc = package.abletonosc
    if args.listen_port != 11000 or args.response_port != 11001:
        # Manager calls OSCServer() without arguments and process() takes the
        # reply port from the module constant.
        osc.OSCServer = functools.partial(osc.osc_server.OSCServer,
                                          local_addr=("0.0.0.0", args.listen_port),
                                          remote_addr=("127.0.0.1", args.response_port))
        osc.osc_server.OSC_RESPONSE_PORT = args.response_port
    manager = package.manager.Manager(FakeCInstance(song))
    if not hasattr(manager, "osc_server"):
        print("fake Live: could not bind UDP %d" % args.listen_port, file=sys.stderr)
        return 1
    print("fake Live: AbletonOSC on UDP %d, replies to %d, log %s"
          % (args.listen_port, args.response_port,
             os.path.join(os.path.dirname(package.manager.__file__), "logs", "abletonosc.log")),
          flush=True)
    stop = []
    for signum in (signal.SIGINT, signal.SIGTERM):
        signal.signal(signum, lambda *_: stop.append(signum))
    deadline = time.monotonic() + args.duration if args.duration else None
    while not stop and (deadline is None or time.monotonic() < deadline):
        manager.advance()
        if song.is_playing:
            song.current_song_time += 0.1 * song.tempo / 60.0
        time.sleep(0.1)
    manager.disconnect()
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    serve_parser = commands.add_parser("serve", help="run the overlay Manager on the real OSC server")
    serve_parser.add_argument("--duration", type=float, default=0.0, help="seconds to run (default: until SIGTERM)")
    serve_parser.add_argument("--listen-port", type=int, default=11000)
    serve_parser.add_argument("--response-port", type=int, default=11001)
    serve_parser.add_argument("--cpu-average", type=float, default=12.5, help="fake average_process_usage")
    serve_parser.add_argument("--cpu-peak", type=float, default=30.0, help="fake peak_process_usage")
    args = parser.parse_args(argv)
    return serve(args)


if __name__ == "__main__":
    raise SystemExit(main())
