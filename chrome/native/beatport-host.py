#!/usr/bin/env python3
"""Native messaging host for the "Baseline for Beatport" extension.

Chrome starts this when the extension connects. It:
  - writes the playlists the page reports to ~/.local/state/afterlight/beatport.json
  - listens on $XDG_RUNTIME_DIR/afterlight-beatport.sock for one-line JSON
    requests from `afterlight beatport ...` (open, check, page; optional
    "timeout" in seconds), passes them to the extension, and answers with the
    extension's reply.
"""
import json, os, socket, struct, sys, threading, time, uuid
from pathlib import Path

STATE = Path(os.environ.get("XDG_STATE_HOME") or Path.home() / ".local/state") / "afterlight/beatport.json"
SOCK = Path(os.environ.get("XDG_RUNTIME_DIR") or "/tmp") / "afterlight-beatport.sock"
out_lock = threading.Lock()
pending = {}          # request id -> (event, holder) waiting for the extension's reply
pending_lock = threading.Lock()
KINDS = {"open", "check", "page", "tabs", "fetch", "scratch", "scratch-close", "media", "applemusic", "version", "reload", "deck", "deck-close", "mixing"}


def send(message):
    data = json.dumps(message).encode()
    with out_lock:
        sys.stdout.buffer.write(struct.pack("=I", len(data)) + data)
        sys.stdout.buffer.flush()


def save_playlists(items):
    clean = []
    for i in items[:30]:
        if not isinstance(i, dict):
            continue
        name, url = str(i.get("name", ""))[:60], str(i.get("url", ""))
        if name and not name.lower().startswith("skip to") and url.startswith("https://www.beatport.com/"):
            clean.append({"name": name, "url": url})
    STATE.parent.mkdir(parents=True, exist_ok=True)
    tmp = STATE.with_suffix(".tmp")
    tmp.write_text(json.dumps({"playlists": clean, "updated": int(time.time())}, indent=2) + "\n")
    tmp.replace(STATE)


def read_chrome():
    while True:
        head = sys.stdin.buffer.read(4)
        if len(head) < 4:
            os._exit(0)
        size = struct.unpack("=I", head)[0]
        try:
            message = json.loads(sys.stdin.buffer.read(size))
        except ValueError:
            continue
        if not isinstance(message, dict):
            continue
        if message.get("type") == "playlists" and isinstance(message.get("items"), list):
            save_playlists(message["items"])
        elif message.get("type") == "source" and message.get("site") in {"beatport", "ytmusic", "applemusic", "youtube"}:
            # Which app the music is coming from, for Baseline's Player tab.
            path = STATE.parent / "source.json"
            tmp = path.with_suffix(".tmp")
            tmp.write_text(json.dumps({"site": message["site"], "at": int(time.time())}) + "\n")
            tmp.replace(path)
        elif message.get("type") == "log":
            # What the add-on was doing, for working out what went wrong (kept short).
            path = STATE.parent / "addon.log"
            try:
                lines = path.read_text().splitlines()[-199:] if path.exists() else []
            except OSError:
                lines = []
            lines.append(time.strftime("%H:%M:%S ") + str(message.get("text", ""))[:300].replace("\n", " "))
            path.write_text("\n".join(lines) + "\n")
        elif message.get("type") == "reply":
            with pending_lock:
                waiter = pending.pop(message.get("id"), None)
            if waiter:
                waiter[1].append(message)
                waiter[0].set()


def serve_one(conn):
    with conn:
        conn.settimeout(5)
        try:
            request = json.loads(conn.makefile().readline())
        except (OSError, ValueError):
            return
        if not isinstance(request, dict):
            return
        if request.get("type") == "ping":
            conn.sendall(b'{"ok": true}\n')
            return
        if request.get("type") not in KINDS:
            return
        wait = max(1, min(float(request.pop("timeout", 5) or 5), 60))
        conn.settimeout(wait + 2)
        request["id"] = uuid.uuid4().hex
        event, holder = threading.Event(), []
        with pending_lock:
            pending[request["id"]] = (event, holder)
        send(request)
        event.wait(wait)
        with pending_lock:
            pending.pop(request["id"], None)
        reply = holder[0] if holder else {"ok": False, "error": "no reply from Beatport"}
        try:
            conn.sendall((json.dumps(reply) + "\n").encode())
        except OSError:
            pass


def main():
    try:
        SOCK.unlink()
    except FileNotFoundError:
        pass
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(str(SOCK))
    os.chmod(SOCK, 0o600)
    server.listen(4)
    threading.Thread(target=read_chrome, daemon=True).start()
    while True:
        conn, _ = server.accept()
        threading.Thread(target=serve_one, args=(conn,), daemon=True).start()


if __name__ == "__main__":
    main()
