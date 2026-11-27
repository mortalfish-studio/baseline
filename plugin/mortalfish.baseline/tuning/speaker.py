"""Control an on-demand, speaker-only PipeWire filter and a local mic check."""

from array import array
from contextlib import contextmanager
from dataclasses import dataclass
import fcntl
import json
import math
import os
from pathlib import Path
import re
import signal
import subprocess
from tempfile import TemporaryDirectory
from time import monotonic, sleep
import sys
import wave

UNIT = "omarchy-surface-speaker-tuning.service"
FILTER = "mortalfish.surface-speaker-eq"
FILTER_PLAYBACK = FILTER + ".playback"
RECORDING = "mortalfish.speaker-check.capture"
TEST_PLAYBACK = "mortalfish.speaker-check.playback"
HERE = Path(__file__).resolve().parent
RATE = 48000
FREQUENCIES = (250, 500, 1000, 3150, 6300)


class Unavailable(Exception):
    """A short error identifier for the widget."""


def command(*argv, timeout=4):
    return subprocess.run(argv, capture_output=True, text=True, check=True, timeout=timeout).stdout


@dataclass
class AudioGraph:
    nodes: dict
    links: set
    default_sink: str = ""

    def linked(self, output, input_node):
        return (output, input_node) in self.links


def audio_graph():
    try:
        objects = json.loads(command("pw-dump"))
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        raise Unavailable("pipewire") from error

    node_ids = {}
    nodes = {}
    links = set()
    default_sink = ""
    for obj in objects:
        if obj.get("type") == "PipeWire:Interface:Node":
            props = obj.get("info", {}).get("props", {})
            name = props.get("node.name")
            if name:
                node_ids[obj["id"]] = name
                nodes[name] = {**props, "id": obj["id"]}
        elif obj.get("type") == "PipeWire:Interface:Metadata":
            for entry in obj.get("metadata", []):
                if entry.get("subject") == 0 and entry.get("key") == "default.audio.sink":
                    value = entry.get("value")
                    if isinstance(value, str):
                        try:
                            value = json.loads(value)
                        except ValueError:
                            continue
                    if isinstance(value, dict):
                        default_sink = value.get("name", "")

    for obj in objects:
        if obj.get("type") == "PipeWire:Interface:Link":
            info = obj.get("info", {})
            output = node_ids.get(info.get("output-node-id"))
            input_node = node_ids.get(info.get("input-node-id"))
            if output and input_node and info.get("state") in {"active", "paused"}:
                links.add((output, input_node))
    return AudioGraph(nodes, links, default_sink)


def device(graph, role, media_class, pcm):
    matches = [
        node["node.name"]
        for node in graph.nodes.values()
        if node.get("media.class") == media_class
        and re.fullmatch(
            rf"alsa_(?:input|output)\.platform-sound\.HiFi__{role}__(?:sink|source)",
            node.get("node.name", ""),
        )
        and str(node.get("api.alsa.pcm.device", pcm)) == str(pcm)
    ]
    return matches[0] if len(matches) == 1 else None


def speaker_node(graph):
    return device(graph, "Speakers?", "Audio/Sink", 1)


def mic_node(graph):
    return device(graph, "Mic", "Audio/Source", 3)


def tuned(graph):
    return FILTER in graph.nodes


def result(graph):
    speaker = speaker_node(graph)
    route = ""
    if tuned(graph) and speaker:
        routed = graph.linked(FILTER_PLAYBACK, speaker) and any(
            input_node == FILTER for _, input_node in graph.links
        )
        direct = any(
            input_node == speaker and output != FILTER_PLAYBACK
            and graph.nodes[output].get("media.class") == "Stream/Output/Audio"
            for output, input_node in graph.links
        )
        if direct:
            route = "mixed" if routed else "direct"
        elif routed:
            route = "through"
        elif graph.default_sink and graph.default_sink != speaker:
            route = "external"
        else:
            route = "idle"
    return {"available": bool(speaker), "tuned": tuned(graph), "route": route}


def filter_config(speaker):
    template = (HERE / "speaker.conf.in").read_text()
    selector = json.dumps({"node.name": speaker})
    return template.replace("@TARGET@", selector).replace("@SPEAKER@", json.dumps(speaker))


def run_filter():
    speaker = speaker_node(audio_graph())
    if not speaker:
        raise Unavailable("speaker")

    config = Path(os.environ["RUNTIME_DIRECTORY"]) / "speaker.conf"
    config.write_text(filter_config(speaker))
    os.execvp("pipewire", ["pipewire", "-c", str(config)])


def set_tuned(enabled, current):
    if enabled == tuned(current):
        return current

    if enabled:
        if not speaker_node(current):
            raise Unavailable("speaker")
        command(
            "systemd-run", "--user", "--quiet", "--collect",
            f"--unit={UNIT}", "--property=Type=exec",
            "--property=RuntimeDirectory=omarchy-surface-speaker-tuning",
            "--", sys.executable, str(HERE / "speaker.py"), "serve",
        )
    else:
        command("systemctl", "--user", "stop", UNIT)

    deadline = monotonic() + 2.5
    while monotonic() < deadline:
        current = audio_graph()
        if tuned(current) == enabled:
            if not enabled:
                return current
            try:
                # A filters-metadata change makes WirePlumber revisit existing
                # streams as well as new ones. It only changes our filter.
                command(
                    "pw-metadata", "-n", "filters", str(current.nodes[FILTER]["id"]),
                    "filter.smart.disabled", "false", "Spa:String:JSON",
                )
            except (OSError, subprocess.SubprocessError):
                command("systemctl", "--user", "stop", UNIT)
                raise
            sleep(0.25)
            return audio_graph()
        sleep(0.12)

    if enabled:
        command("systemctl", "--user", "stop", UNIT)
    raise Unavailable("filter")


def write_tones(path):
    samples = array("h")
    length = int(0.30 * RATE)
    ramp = int(0.025 * RATE)
    for freq in FREQUENCIES:
        for idx in range(length):
            envelope = min(1, idx / ramp, (length - 1 - idx) / ramp)
            samples.append(round(14000 * envelope * math.sin(math.tau * freq * idx / RATE)))
        samples.extend([0] * int(0.09 * RATE))
    with wave.open(str(path), "wb") as stream:
        stream.setparams((1, 2, RATE, 0, "NONE", "not compressed"))
        stream.writeframes(samples.tobytes())


def tone_levels(samples):
    if not samples or max(abs(value) for value in samples) < 48:
        raise Unavailable("quiet")

    def band_energy(freq):
        coefficient = 2 * math.cos(math.tau * freq / RATE)
        previous = older = 0.0
        for value in samples:
            current = value + coefficient * previous - older
            older, previous = previous, current
        return max(1, older**2 + previous**2 - coefficient * older * previous)

    energies = [band_energy(freq) for freq in FREQUENCIES]
    reference = energies[2]
    if reference < 16 * max(band_energy(950), band_energy(1050)):
        raise Unavailable("quiet")
    return [round(10 * math.log10(energy / reference), 1) for energy in energies]


def stream_properties(name):
    return json.dumps({
        "node.name": name,
        "node.dont-fallback": True,
        "node.dont-move": True,
        "stream.restore-target": False,
    })


@contextmanager
def audio_process(argv, error):
    process = subprocess.Popen(argv, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        yield process
    except subprocess.TimeoutExpired as cause:
        raise Unavailable(error) from cause
    finally:
        if process.poll() is None:
            process.send_signal(signal.SIGINT)
            try:
                process.wait(timeout=1)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


def wait_for_link(process, output, input_node, error, through=None):
    deadline = monotonic() + 2
    while monotonic() < deadline and process.poll() is None:
        graph = audio_graph()
        if graph.linked(output, input_node) and (
            not through or graph.linked(*through)
        ):
            return
        sleep(0.08)
    raise Unavailable(error)


def measure(current):
    speaker, mic = speaker_node(current), mic_node(current)
    if not speaker or not mic:
        raise Unavailable("mic")

    use_filter = tuned(current)
    target = FILTER if use_filter else speaker
    through = (FILTER_PLAYBACK, speaker) if use_filter else None
    with TemporaryDirectory(prefix="surface-speaker-check-") as folder:
        tones, recording = Path(folder) / "tones.wav", Path(folder) / "check.pcm"
        write_tones(tones)
        record = [
            "pw-record", "--target", mic, "--rate", str(RATE), "--channels", "1",
            "--format", "s16", "--raw", "--properties", stream_properties(RECORDING),
            str(recording),
        ]
        play = [
            "pw-play", "--target", target, "--volume", "0.35",
            "--properties", stream_properties(TEST_PLAYBACK), str(tones),
        ]
        with audio_process(record, "capture") as recorder:
            wait_for_link(recorder, mic, RECORDING, "capture")
            sleep(0.15)
            with audio_process(play, "playback") as player:
                wait_for_link(player, TEST_PLAYBACK, target, "playback", through)
                if player.wait(timeout=4):
                    raise Unavailable("playback")
            sleep(0.15)

        with recording.open("rb") as stream:
            sample_bytes = stream.read(RATE * 2 * 8)
        if len(sample_bytes) < RATE * 4:
            raise Unavailable("capture")
        return tone_levels(array("h", sample_bytes[:len(sample_bytes) // 2 * 2]))


@contextmanager
def action_lock():
    lockfile = Path(os.environ["XDG_RUNTIME_DIR"]) / "omarchy-surface-speaker-tuning.lock"
    with lockfile.open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise Unavailable("busy") from error
        yield


def action(name):
    if name == "status":
        return result(audio_graph())
    if name == "serve":
        run_filter()

    with action_lock():
        current = audio_graph()
        if name == "measure":
            return {**result(current), "bands": measure(current)}
        enabled = name == "tuned" or (name == "compare" and not tuned(current))
        return result(set_tuned(enabled, current))


if __name__ == "__main__":
    names = {"status", "original", "tuned", "compare", "measure", "serve"}
    if len(sys.argv) != 2 or sys.argv[1] not in names:
        sys.exit("Expected a speaker tuning action")
    try:
        print(json.dumps(action(sys.argv[1]), allow_nan=False))
    except Unavailable as error:
        print(json.dumps({"error": str(error)}))
        sys.exit(1)
    except (OSError, KeyError, subprocess.SubprocessError, wave.Error):
        error = "measurement" if sys.argv[1] == "measure" else "filter"
        print(json.dumps({"error": error}))
        sys.exit(1)
