#!/usr/bin/env python3
"""Send commands to Ableton Live through AbletonOSC and read its replies.

Usage:
  liveosc.py ping [--timeout SECONDS]
  liveosc.py wait-ready [--timeout SECONDS]
  liveosc.py play | stop | rewind
  liveosc.py set-tempo BPM
  liveosc.py set-quantization VALUE
  liveosc.py fire-clip TRACK CLIP
  liveosc.py fire-scene SCENE
  liveosc.py set-param TRACK DEVICE PARAMETER VALUE
  liveosc.py create-midi-track INDEX | create-audio-track INDEX | delete-track INDEX
  liveosc.py create-clip TRACK CLIP LENGTH
  liveosc.py add-notes TRACK CLIP PITCH START DURATION VELOCITY MUTE [...]
  liveosc.py load-device KIND NAME [TRACK]
  liveosc.py show-view NAME
  liveosc.py marker NAME
  liveosc.py query ADDRESS [ARG ...] [--reply ADDRESS] [--timeout SECONDS]
  liveosc.py listen [--duration SECONDS]

Commands go to UDP 11000 and replies arrive on UDP 11001, the AbletonOSC
ports. ABL_BENCH_OSC_SEND and ABL_BENCH_OSC_RECV select other ports, as for
scripts/bench-osc.py. The reply port is bound only while a call waits for a
reply. Never wait for replies during a measurement window: bench-osc.py dump
owns the reply port then.
"""

from __future__ import annotations

import argparse
import importlib.util
import os
from pathlib import Path
import select
import socket
import struct
import sys
import time
from typing import Callable, Iterable, Iterator, NamedTuple


HERE = Path(__file__).resolve().parent
HOST = "127.0.0.1"
SEND_PORT = int(os.environ.get("ABL_BENCH_OSC_SEND", 11000))
RECV_PORT = int(os.environ.get("ABL_BENCH_OSC_RECV", 11001))
PING_INTERVAL = 0.25
CONTROL_SURFACE_HINT = (
    "AbletonOSC did not answer. Select it as a Control Surface in Live "
    "(Preferences > Link, Tempo & MIDI > Control Surface: AbletonOSC, Input and "
    "Output: None), close Preferences, and restart Live when it was started "
    "before profiler/control/install.sh ran"
)


def load(name: str, path: Path):
    # The suite scripts have hyphenated names, so they are loaded by path
    # (the same trick as scripts/test-bench-report.py).
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


osc = load("bench_osc", HERE.parents[1] / "scripts" / "bench-osc.py")


class LiveTimeout(TimeoutError):
    """No reply arrived in time."""


class LiveError(RuntimeError):
    """Live relayed an error on /live/error, or the reply port is taken."""


class Message(NamedTuple):
    address: str
    arguments: list

    def __str__(self) -> str:
        return " ".join([self.address, *self.arguments])


def wire_arguments(values: Iterable[object]) -> list[str]:
    """Format values so that bench-osc.py encode() keeps their OSC types.

    bool and int become int32, float stays float32 (repr keeps the decimal
    point or exponent), everything else is sent as a string. A string that
    looks like a number is sent as that number, so names must not look numeric.
    """
    result = []
    for value in values:
        if isinstance(value, bool):
            result.append(str(int(value)))
        elif isinstance(value, float):
            result.append(repr(value))
        else:
            result.append(str(value))
    return result


def send(address: str, *values: object) -> Message:
    """Send one command without waiting for a reply."""
    message = Message(address, wire_arguments(values))
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as client:
        client.sendto(osc.encode(address, message.arguments), (HOST, SEND_PORT))
    return message


class Replies:
    """Owns the reply port for one call or one setup phase.

    AbletonOSC answers to port RECV_PORT of the sender host, not to the
    sending socket. Never hold the port during a measurement window:
    bench-osc.py dump owns it then and the bind fails.
    """

    def __init__(self) -> None:
        self.socket: socket.socket | None = None
        self.errors: list[str] = []

    def __enter__(self) -> Replies:
        listener = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            listener.bind((HOST, RECV_PORT))
        except OSError as error:
            listener.close()
            raise LiveError(
                f"cannot bind UDP {HOST}:{RECV_PORT} for replies ({error}): another client "
                "owns the reply port (bench-osc.py dump during a measurement window?)"
            ) from error
        self.socket = listener
        return self

    def __exit__(self, *exc_info: object) -> None:
        assert self.socket is not None
        self.socket.close()
        self.socket = None

    def receive(self, timeout: float) -> tuple[str, list[object]] | None:
        """Return the next decodable message within timeout seconds, or None."""
        assert self.socket is not None
        deadline = time.monotonic() + timeout
        while True:
            remaining = max(0.0, deadline - time.monotonic())
            readable, _, _ = select.select([self.socket], [], [], remaining)
            if not readable:
                return None
            packet, _ = self.socket.recvfrom(65536)
            try:
                address, arguments = osc.decode(packet)
            except (UnicodeDecodeError, ValueError, struct.error, IndexError):
                continue
            if address == "/live/error":
                self.errors.append(" ".join(str(value) for value in arguments))
            return address, arguments

    def wait(
        self,
        accept: Callable[[str, list[object]], bool],
        what: str,
        timeout: float,
        resend: Callable[[], object] | None = None,
        fail_on_error: bool = True,
    ) -> list[object]:
        """Wait for a message that accept(address, arguments) approves.

        resend() runs first and then every PING_INTERVAL seconds, for commands
        whose datagram is lost while the handler does not exist yet. A
        /live/error received meanwhile raises LiveError when fail_on_error is
        set. The timeout error names the Control Surface step.
        """
        deadline = time.monotonic() + timeout
        next_send = 0.0
        while True:
            now = time.monotonic()
            if resend is not None and now >= next_send:
                resend()
                next_send = now + PING_INTERVAL
            if now >= deadline:
                raise LiveTimeout(
                    f"no {what} within {timeout:g}s on UDP {HOST}:{RECV_PORT}: {CONTROL_SURFACE_HINT}"
                )
            remaining = deadline - now
            if resend is not None:
                remaining = min(remaining, next_send - now)
            message = self.receive(remaining)
            if message is None:
                continue
            address, arguments = message
            if address == "/live/error" and fail_on_error:
                raise LiveError(f"Live reported an error while waiting for {what}: {self.errors[-1]}")
            if accept(address, arguments):
                return arguments

    def sync(self, timeout: float) -> None:
        """Ping until the matching pong arrives: every earlier command was processed."""
        nonce = osc.probe_nonce()
        self.wait(
            lambda address, arguments: address == "/abl/bench/pong" and arguments == [nonce],
            f"/abl/bench/pong {nonce}",
            timeout,
            resend=lambda: send("/abl/bench/ping", nonce),
            fail_on_error=False,
        )


def ping(timeout: float = 5.0) -> float:
    """Send one ping; return the round-trip time in seconds."""
    nonce = osc.probe_nonce()
    started = time.monotonic()
    with Replies() as replies:
        send("/abl/bench/ping", nonce)
        replies.wait(
            lambda address, arguments: address == "/abl/bench/pong" and arguments == [nonce],
            f"/abl/bench/pong {nonce}",
            timeout,
            fail_on_error=False,
        )
    return time.monotonic() - started


def wait_ready(timeout: float = 120.0) -> float:
    """Ping every PING_INTERVAL seconds until the bench handler answers.

    Returns the seconds waited. The ready report is sent once at Live start
    and is easily missed, so the pong is the readiness signal.
    """
    started = time.monotonic()
    with Replies() as replies:
        replies.sync(timeout)
    return time.monotonic() - started


def query(
    address: str, values: Iterable[object] = (), timeout: float = 5.0, reply: str | None = None
) -> list[object]:
    """Send a command and return the arguments of its reply.

    AbletonOSC answers /live/... getters on the request address; the bench
    handler answers on its own addresses (reply=). The reply port is bound
    only for this call.
    """
    expected = reply or address
    with Replies() as replies:
        send(address, *values)
        return replies.wait(
            lambda reply_address, arguments: reply_address == expected,
            f"reply {expected} to {address}",
            timeout,
        )


def listen(duration: float | None = None) -> Iterator[tuple[float, str, list[object]]]:
    """Yield (offset_seconds, address, arguments) for every report until duration elapses."""
    started = time.monotonic()
    with Replies() as replies:
        while True:
            elapsed = time.monotonic() - started
            if duration is not None and elapsed >= duration:
                return
            message = replies.receive(1.0 if duration is None else min(1.0, duration - elapsed))
            if message is not None:
                yield (time.monotonic() - started, message[0], message[1])


def play() -> Message:
    return send("/abl/bench/play")


def stop() -> Message:
    return send("/abl/bench/stop")


def rewind() -> Message:
    return send("/abl/bench/rewind")


def set_tempo(bpm: float) -> Message:
    return send("/live/song/set/tempo", float(bpm))


def set_quantization(value: int) -> Message:
    # Live.Song.Quantization: 0 none, 4 one bar, 7 one quarter note.
    return send("/live/song/set/clip_trigger_quantization", int(value))


def fire_clip(track: int, clip: int) -> Message:
    return send("/live/clip/fire", int(track), int(clip))


def fire_scene(scene: int) -> Message:
    return send("/live/scene/fire", int(scene))


def set_param(track: int, device: int, param: int, value: float) -> Message:
    return send("/live/device/set/parameter/value", int(track), int(device), int(param), float(value))


def create_midi_track(index: int = -1) -> Message:
    return send("/live/song/create_midi_track", int(index))


def create_audio_track(index: int = -1) -> Message:
    return send("/live/song/create_audio_track", int(index))


def delete_track(index: int) -> Message:
    return send("/live/song/delete_track", int(index))


def create_clip(track: int, clip: int, length: float) -> Message:
    return send("/live/clip_slot/create_clip", int(track), int(clip), float(length))


def add_notes(track: int, clip: int, notes: Iterable[Iterable[object]]) -> Message:
    values: list[object] = []
    for pitch, start, duration, velocity, mute in notes:
        values += [int(pitch), float(start), float(duration), float(velocity), int(bool(mute))]
    return send("/live/clip/add/notes", int(track), int(clip), *values)


def load_device(kind: str, name: str, track: int | None = None) -> Message:
    values: list[object] = [str(kind), str(name)]
    if track is not None:
        values.append(int(track))
    return send("/abl/bench/load-device", *values)


def duplicate_all() -> Message:
    return send("/abl/bench/duplicate-all")


def show_view(name: str) -> Message:
    return send("/abl/bench/show-view", str(name))


def marker(name: str) -> Message:
    return send("/abl/bench/scenario-marker", str(name))


def command_ping(args: argparse.Namespace) -> int:
    print("pong after %.3fs" % ping(args.timeout))
    return 0


def command_wait_ready(args: argparse.Namespace) -> int:
    print("ready after %.3fs" % wait_ready(args.timeout))
    return 0


def command_query(args: argparse.Namespace) -> int:
    reply = query(args.address, args.arguments, args.timeout, args.reply)
    print(" ".join(str(value) for value in reply))
    return 0


def command_listen(args: argparse.Namespace) -> int:
    for _, address, arguments in listen(args.duration):
        osc.output(address, arguments)
    return 0


def command_add_notes(args: argparse.Namespace) -> int:
    if len(args.values) % 5:
        print("liveosc: add-notes takes groups of PITCH START DURATION VELOCITY MUTE", file=sys.stderr)
        return 2
    notes = [args.values[offset:offset + 5] for offset in range(0, len(args.values), 5)]
    add_notes(args.track, args.clip, notes)
    return 0


SENDS: dict[str, Callable[[argparse.Namespace], Message]] = {
    "play": lambda args: play(),
    "stop": lambda args: stop(),
    "rewind": lambda args: rewind(),
    "set-tempo": lambda args: set_tempo(args.bpm),
    "set-quantization": lambda args: set_quantization(args.value),
    "fire-clip": lambda args: fire_clip(args.track, args.clip),
    "fire-scene": lambda args: fire_scene(args.scene),
    "set-param": lambda args: set_param(args.track, args.device, args.parameter, args.value),
    "create-midi-track": lambda args: create_midi_track(args.index),
    "create-audio-track": lambda args: create_audio_track(args.index),
    "delete-track": lambda args: delete_track(args.index),
    "create-clip": lambda args: create_clip(args.track, args.clip, args.length),
    "load-device": lambda args: load_device(args.kind, args.name, args.track),
    "show-view": lambda args: show_view(args.name),
    "marker": lambda args: marker(args.name),
}
COMMANDS: dict[str, Callable[[argparse.Namespace], int]] = {
    "ping": command_ping,
    "wait-ready": command_wait_ready,
    "query": command_query,
    "listen": command_listen,
    "add-notes": command_add_notes,
}


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    commands = root.add_subparsers(dest="command", required=True)

    def command(name: str, help: str, *arguments: tuple) -> None:
        sub = commands.add_parser(name, help=help)
        for flags, options in arguments:
            sub.add_argument(*flags, **options)

    def timeout(default: float) -> tuple:
        return (("--timeout",), {"type": osc.positive, "default": default, "help": "maximum wait in seconds"})

    index = {"type": int}
    number = {"type": float}
    command("ping", "send one ping and print the round-trip time", timeout(5.0))
    command("wait-ready", "ping until the bench handler answers", timeout(120.0))
    command("play", "start playback")
    command("stop", "stop playback")
    command("rewind", "move the song position to the start")
    command("set-tempo", "set the song tempo", (("bpm",), number))
    command("set-quantization", "set the clip trigger quantization (0 none, 4 bar, 7 quarter)",
            (("value",), index))
    command("fire-clip", "fire a session clip", (("track",), index), (("clip",), index))
    command("fire-scene", "fire a scene", (("scene",), index))
    command("set-param", "set a device parameter value",
            (("track",), index), (("device",), index), (("parameter",), index), (("value",), number))
    command("create-midi-track", "insert a MIDI track (-1 appends)", (("index",), index))
    command("create-audio-track", "insert an audio track (-1 appends)", (("index",), index))
    command("delete-track", "delete a track", (("index",), index))
    command("create-clip", "create an empty MIDI clip of LENGTH beats",
            (("track",), index), (("clip",), index), (("length",), number))
    command("add-notes", "add notes to a MIDI clip",
            (("track",), index), (("clip",), index),
            (("values",), {"nargs": "+", "type": float, "help": "PITCH START DURATION VELOCITY MUTE groups"}))
    command("load-device", "load a browser item onto a track",
            (("kind",), {"choices": ("instruments", "audio_effects", "plugins", "max_for_live")}),
            (("name",), {}), (("track",), {"type": int, "nargs": "?"}))
    command("show-view", "show a main view (Session, Arranger, Detail/DeviceChain, ...)", (("name",), {}))
    command("marker", "timestamp a scenario step Live-side", (("name",), {}))
    command("query", "send a command and print its reply",
            (("address",), {}), (("arguments",), {"nargs": "*"}),
            (("--reply",), {"help": "reply address when it differs from ADDRESS"}), timeout(5.0))
    command("listen", "print every report",
            (("--duration",), {"type": osc.positive, "help": "time to read reports in seconds"}))
    return root


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    try:
        if args.command in SENDS:
            SENDS[args.command](args)
            return 0
        return COMMANDS[args.command](args)
    except (LiveTimeout, LiveError) as error:
        print(f"liveosc: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
