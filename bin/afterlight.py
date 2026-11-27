#!/usr/bin/env python3
"""Baseline control: looks, modes, wallpapers, tweaks, and the system's health.

The Baseline bar panel drives this; it works on its own from a terminal too.

  afterlight state                       everything the panel shows, as JSON
  afterlight mode [day|night|saver|toggle|auto|status]
  afterlight wallpaper [next|set <id>|toggle <id> day|night]
  afterlight wallpaper add <file|https url>... | paste | remove <id>
  afterlight set <key.path> <json>       change a setting, e.g. tweaks.night.dim 0.5
  afterlight bar [glassy|opaque|none]    the bar's background
  afterlight agents [open <id>]          T3 Code threads: what's working, waiting, done
  afterlight sync                        rebuild night/saver wallpapers, tweaks, timer
  afterlight library                     every picture, and which looks use it
  afterlight assign <id> <look> day|night on|off
  afterlight look [list|set <id>|next|previous|build <id>]   the colour scheme and its wallpapers
  afterlight mouse [status|light|bind|daemon]  the Razer mouse's lighting and extra buttons
  afterlight prompt                      the starship prompt in the current look's colours
  afterlight check [--json]              is every part of Baseline in place?
  afterlight catalog [list|add <id>|update <id>|remove <id>]   looks shared by others
  afterlight share <look> --preview | --author=<name> --include=<picture ids>   share a look (pull request)
  afterlight looks backup                run your backup command (settings backup.command)
  afterlight apps [set coding|chat <id>|custom …]   which apps own workspaces 3 and 4
  afterlight sonos [state|use <room>|off|volume <n|+n|-n>|toggle|next|…]   Sonos rooms on your network
  afterlight pictures [<look>]           download the built-in looks' pictures from their links
  afterlight updates [--fetch] | update  is Baseline behind GitHub? / pull, repair, restart
  afterlight repair [--quiet|--keep-bar|--system]  put back what an update knocked out
  afterlight snapshot                    record how things are before installing (install.sh does this)
  afterlight uninstall [--dry-run] [--packages] [--yes]   take Baseline off, put back the snapshot

Settings live in ~/.config/omarchy/afterlight/settings.json. Night wallpapers
are darkened copies made from the day originals. Night and Saver each have
their own colour temperature (Day is neutral); Saver ends by putting the
screen brightness, power profile and bar back as they were.
"""

import colorsys
import contextlib
import copy
import datetime
import time
import fcntl
import hashlib
import json
import os
import random
import re
import select
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HOME = Path.home()
CONFIG = Path(os.environ.get("XDG_CONFIG_HOME") or HOME / ".config")
STATE_HOME = Path(os.environ.get("XDG_STATE_HOME") or HOME / ".local/state")
CACHE = Path(os.environ.get("XDG_CACHE_HOME") or HOME / ".cache")

THEMES = CONFIG / "omarchy/themes"
REPO = Path(__file__).resolve().parent.parent
USER_BG = CONFIG / "omarchy/backgrounds"
# Where pictures come from: each look's own folder (filled in by use_look),
# and the folder of ones you add, shared by every look.
SOURCES = {"extra": USER_BG / "afterlight-2049"}
NIGHT_DIR = USER_BG / "afterlight-2049-night"
SAVER_DIR = USER_BG / "afterlight-2049-saver"
BLACK_DIR = USER_BG / "afterlight-black"
SETTINGS = CONFIG / "omarchy/afterlight/settings.json"
TWEAKS = CONFIG / "omarchy/afterlight/tweaks.lua"
STATE = STATE_HOME / "afterlight/state.json"
THUMBS = CACHE / "afterlight/thumbs"
TIMER = CONFIG / "systemd/user/afterlight-mode.timer"

SLUGS = {"day": "afterlight-2049", "night": "afterlight-2049-night", "saver": "afterlight-2049-saver"}
LOOK_DIR = REPO
LOOKS_DIR = REPO / "looks"                                   # built in: part of Baseline
MINE_DIR = HOME / ".local/share/baseline/mine"               # yours, made in the Studio
MODE_FOLDERS = {"day": "", "night": "night", "saver": "saver"}
IMAGES = {".jpg", ".jpeg", ".png", ".webp", ".bmp", ".gif"}
VIDEOS = {".mp4", ".m4v", ".mov", ".webm", ".mkv"}

DEFAULTS = {
    "ui": {"tab": "system"},
    # Which look (colour scheme and wallpapers) Day, Night and Saver are drawn in.
    "look": "afterlight",
    # Which apps own workspace 3 (code) and 4 (chat); see `afterlight apps`.
    "apps": {"coding": "t3code", "chat": "grok", "custom": {}},
    # Run after you save or delete a look of your own, e.g. a dotfiles sync.
    "backup": {"command": ""},
    # Sonos: the room the Player tab controls, and whether it has the volume keys.
    "sonos": {"on": False, "room": ""},
    # Where "play <something>" looks when it isn't a Beatport chart or playlist
    # and no service is named: "ytmusic" or "applemusic".
    "music": {"service": "ytmusic"},
    "deck": {"home": True, "crate": True},   # the Deck kept open on workspace 7; its crate unfolded
    "battery": {"limit": False, "limitPercent": 80},
    # Beatport links pinned in the Player tab: [{"name": ..., "url": ...}]
    "beatport": {"pins": []},
    # Lines the morning check adds between two dates (inclusive), YYYY-MM-DD:
    # [{"from": "2026-12-19", "until": "2026-12-26", "text": "..."}]
    "reminders": [],
    "agents": {"notify": True},
    # The Razer mouse: theme-coloured lighting and what its extra buttons do
    # (ids from MOUSE_ACTIONS; "default" leaves a button doing its own thing).
    "mouse": {"lighting": True, "sniper": "dictate", "front": "voice", "rear": "next",
              "tiltLeft": "workspacePrev", "tiltRight": "workspaceNext",
              # Each light's colour (a name from MOUSE_COLOURS), how far its
              # theme colour is pushed towards full colour, and how bright per mode.
              "logo": "orange", "wheel": "blue", "strip": "orange", "strength": 0.8,
              "brightnessDay": 100, "brightnessNight": 80, "brightnessSaver": 60},
    "schedule": {"auto": True, "day": "07:00", "night": "20:00", "saverOnBattery": False},
    "wallpapers": {
        "day": ["afterlight/1-vegas-haze.jpg", "afterlight/4-vegas-towers.jpg", "extra/lone-walk.jpg",
                "extra/wallace-office.jpg", "extra/snowfall.jpg"],
        "night": ["afterlight/2-spinner-rain.jpg", "afterlight/3-los-angeles.jpg", "extra/la-night.jpg",
                  "extra/pyramid-approach.jpg", "extra/amber-transit.mp4"],
        "cycleMinutes": 0,
        "black": False,
    },
    "tweaks": {
        "day": {"dim": 0.3, "blur": True, "blurBrightness": 0.8, "terminalOpacity": 0.9, "webDim": 0.0, "animations": True},
        "night": {"dim": 0.55, "blur": True, "blurBrightness": 0.6, "terminalOpacity": 0.9, "webDim": 0.25, "animations": True,
                  "wallpaperBrightness": 35, "warmth": 5000},
        "saver": {"dim": 0.6, "blur": False, "terminalOpacity": 1.0, "webDim": 0.35, "animations": False,
                  "backlight": 60, "warmth": 4500, "powerSaver": True, "opaqueBar": True,
                  "wallpaper": "black"},
    },
}

# Bounds on what the panel (or a typo) can write.
LIMITS = {
    "dim": (0.0, 0.9), "blurBrightness": (0.2, 1.0), "terminalOpacity": (0.6, 1.0), "webDim": (0.0, 0.6),
    "wallpaperBrightness": (10, 100), "backlight": (5, 100), "warmth": (2500, 6500),
    "cycleMinutes": (0, 240),
    "strength": (0.0, 1.0), "brightnessDay": (5, 100), "brightnessNight": (5, 100), "brightnessSaver": (5, 100),
}


# ---------------------------------------------------------------- utilities

def run(*cmd, quiet=True):
    try:
        return subprocess.run(cmd, capture_output=quiet, text=True, timeout=120)
    except (OSError, subprocess.TimeoutExpired):
        return None


def out(*cmd):
    result = run(*cmd)
    return result.stdout.strip() if result and result.returncode == 0 else ""


def write_atomic(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", dir=path.parent, delete=False) as handle:
        handle.write(text)
    Path(handle.name).replace(path)


def read_json(path, fallback):
    try:
        value = json.loads(path.read_text())
        return value if isinstance(value, dict) else fallback
    except (OSError, ValueError):
        return fallback


def read_list(path):
    try:
        value = json.loads(path.read_text())
        return value if isinstance(value, list) else []
    except (OSError, ValueError):
        return []


def merge(base, override):
    result = copy.deepcopy(base)
    for key, value in override.items():
        if isinstance(value, dict) and isinstance(result.get(key), dict):
            result[key] = merge(result[key], value)
        else:
            result[key] = value
    return result


def load():
    settings = merge(DEFAULTS, read_json(SETTINGS, {}))
    # Pictures were once "theme/<file>" for whichever look was on; now each
    # id names its look, so one picture can be picked by several looks.
    changed = False
    def fix(ids, look_id):
        nonlocal changed
        fixed = [f"{look_id}/{i[6:]}" if i.startswith("theme/") else i for i in ids]
        changed = changed or fixed != ids
        return fixed
    for period in ("day", "night"):
        settings["wallpapers"][period] = fix(settings["wallpapers"][period], settings["look"])
    for look_id, picks in settings.get("lookWallpapers", {}).items():
        for period in ("day", "night"):
            picks[period] = fix(picks.get(period, []), look_id)
    if changed:
        save(settings)
    return settings


def save(settings):
    write_atomic(SETTINGS, json.dumps(settings, indent=2) + "\n")


def load_state():
    return read_json(STATE, {})


def save_state(state):
    write_atomic(STATE, json.dumps(state, indent=2) + "\n")


def current_slug():
    try:
        return (STATE_HOME / "omarchy/current/theme.name").read_text().strip()
    except OSError:
        return ""


def current_mode():
    slug = current_slug()
    for look_id in look_ids():
        for mode, name in look_info(look_id)["slugs"].items():
            if slug == name:
                return mode
    return "other"


def notify(title, body=""):
    run("omarchy-notification-send", "--app-name", "T3 Code", "-u", "low", title, body)


# ---------------------------------------------------------------- wallpapers

def library():
    items = []
    for prefix, folder in SOURCES.items():
        if not folder.is_dir():
            continue
        for path in sorted(folder.iterdir()):
            suffix = path.suffix.lower()
            if path.is_file() and (suffix in IMAGES or suffix in VIDEOS):
                items.append({"id": f"{prefix}/{path.name}", "name": path.stem, "path": str(path),
                              "video": suffix in VIDEOS})
    return items


def by_id():
    return {item["id"]: item for item in library()}


def thumbnail(item):
    source = Path(item["path"])
    key = hashlib.sha1(f"{source}:{source.stat().st_mtime_ns}".encode()).hexdigest()[:16]
    target = THUMBS / f"{key}.jpg"
    if not target.exists():
        THUMBS.mkdir(parents=True, exist_ok=True)
        if item["video"]:
            run("ffmpeg", "-v", "error", "-y", "-ss", "2", "-i", str(source), "-frames:v", "1",
                "-vf", "scale=360:-2", str(target))
        else:
            run("vipsthumbnail", str(source), "--size", "360x", "-o", f"{target}[Q=85]")
    return str(target) if target.exists() else ""


def darken(source, target, percent):
    """Scale the encoded values, so 35% looks like 35% to the eye."""
    factor = max(0.05, min(1.0, percent / 100))
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = target.with_name(f".tmp-{target.name}")
    if source.suffix.lower() in VIDEOS:
        chroma = "128+(val-128)*0.85"
        result = run("ffmpeg", "-v", "error", "-y", "-i", str(source), "-an",
                     "-vf", f"lutyuv=y=val*{factor}:u={chroma}:v={chroma}",
                     "-c:v", "libx264", "-crf", "22", "-preset", "medium", "-pix_fmt", "yuv420p",
                     "-f", "mp4", str(temporary))
    else:
        result = run("magick", str(source), "-evaluate", "multiply", str(factor),
                     "-modulate", "100,85", "-quality", "92", str(temporary))
    if result and result.returncode == 0 and temporary.exists():
        temporary.replace(target)
        return True
    temporary.unlink(missing_ok=True)
    return False


def sync_folder(folder, wanted):
    """Make folder hold exactly `wanted` {name: (source, percent)}, rebuilding stale copies."""
    folder.mkdir(parents=True, exist_ok=True)
    manifest_path = folder / ".afterlight.json"
    manifest = read_json(manifest_path, {})
    fresh = {}
    for name, (source, percent) in wanted.items():
        if source == "black":
            stamp = f"black:{monitor_size()}"
        else:
            stamp = f"{source}:{Path(source).stat().st_mtime_ns}:{percent}"
        target = folder / name
        if manifest.get(name) != stamp or not target.exists():
            if source == "black":
                size = monitor_size()
                ok = run("magick", "-size", size, "xc:black", str(target))
                ok = ok and ok.returncode == 0
            else:
                ok = darken(Path(source), target, percent)
            if not ok:
                continue
        fresh[name] = stamp
    for path in folder.iterdir():
        if path.name != ".afterlight.json" and path.name not in fresh:
            path.unlink(missing_ok=True)
    write_atomic(manifest_path, json.dumps(fresh, indent=2) + "\n")


def monitor_size():
    try:
        monitors = json.loads(out("hyprctl", "monitors", "-j") or "[]")
        biggest = max(monitors, key=lambda m: m["width"] * m["height"])
        return f"{biggest['width']}x{biggest['height']}"
    except (ValueError, KeyError):
        return "2560x1600"


def night_name(item_id):
    return item_id.replace("/", "-")


def sync_wallpapers(settings):
    items = by_id()
    percent = settings["tweaks"]["night"]["wallpaperBrightness"]
    night = {night_name(i): (items[i]["path"], percent) for i in settings["wallpapers"]["night"] if i in items}
    # The night theme no longer ships copies of its own; its backgrounds are these.
    sync_folder(NIGHT_DIR, night)
    if settings["tweaks"]["saver"]["wallpaper"] == "black":
        saver = {"black.png": ("black", 0)}
    else:
        # Stills only: a playing video costs more power than anything else on screen.
        saver = {night_name(i): (items[i]["path"], max(10, percent - 15))
                 for i in settings["wallpapers"]["night"] if i in items and not items[i]["video"]}
        saver = saver or {"black.png": ("black", 0)}
    sync_folder(SAVER_DIR, saver)


def black_wallpaper():
    sync_folder(BLACK_DIR, {"black.png": ("black", 0)})
    return str(BLACK_DIR / "black.png")


def pool(settings, mode):
    # "No wallpaper": plain black in every mode, until a picture is chosen.
    if settings["wallpapers"].get("black"):
        return [black_wallpaper()]
    if mode == "night":
        folder = NIGHT_DIR
    elif mode == "saver":
        folder = SAVER_DIR
    else:
        items = by_id()
        return [items[i]["path"] for i in settings["wallpapers"]["day"] if i in items]
    if not folder.is_dir():
        return []
    return sorted(str(p) for p in folder.iterdir() if p.is_file() and not p.name.startswith("."))


def current_background():
    try:
        return str((STATE_HOME / "omarchy/current/background").resolve())
    except OSError:
        return ""


def show(path):
    run("omarchy-theme-bg-set", path)


def wallpaper_next(settings, shuffle=False):
    mode = current_mode()
    if mode == "other":
        return
    choices = pool(settings, mode)
    if not choices:
        return
    now = current_background()
    if shuffle:
        others = [c for c in choices if c != now] or choices
        show(random.choice(others))
    else:
        index = choices.index(now) if now in choices else -1
        show(choices[(index + 1) % len(choices)])


def wallpaper_black(settings, want):
    on = (not settings["wallpapers"].get("black")) if want == "toggle" else want == "on"
    settings["wallpapers"]["black"] = on
    save(settings)
    if on:
        show(black_wallpaper())
    else:
        wallpaper_next(settings, shuffle=True)


def wallpaper_set(settings, item_id):
    items = by_id()
    if item_id not in items:
        sys.exit(f"Unknown wallpaper: {item_id}")
    if settings["wallpapers"].get("black"):
        settings["wallpapers"]["black"] = False
        save(settings)
    mode = current_mode()
    if mode == "night" and item_id in settings["wallpapers"]["night"]:
        candidate = NIGHT_DIR / night_name(item_id)
        show(str(candidate) if candidate.exists() else items[item_id]["path"])
    else:
        show(items[item_id]["path"])


# ---------------------------------------------------------------- adding wallpapers

MAX_BYTES = 200 * 1024 * 1024
RECENT_DIRS = [HOME / "Downloads", HOME / "Pictures"]


def media_kind(path):
    mime = out("file", "--brief", "--mime-type", str(path))
    if mime.startswith("image/") and mime not in {"image/svg+xml"}:
        return "image"
    if mime.startswith("video/"):
        return "video"
    return ""


def safe_name(name, kind, mime_ext=""):
    stem, suffix = os.path.splitext(os.path.basename(name))
    stem = "".join(c if c.isalnum() or c in "-_" else "-" for c in stem.lower()).strip("-")[:60] or "wallpaper"
    suffix = suffix.lower()
    if suffix not in IMAGES | VIDEOS:
        suffix = mime_ext or (".mp4" if kind == "video" else ".jpg")
    target = SOURCES["extra"] / f"{stem}{suffix}"
    n = 2
    while target.exists():
        target = SOURCES["extra"] / f"{stem}-{n}{suffix}"
        n += 1
    return target


def adopt(temporary, original_name, settings, looks=None):
    """Move a checked file into the library and turn it on for Day, in this
    look or the looks named."""
    kind = media_kind(temporary)
    if not kind:
        temporary.unlink(missing_ok=True)
        sys.exit("That isn't an image or a video.")
    ext = {"image": "", "video": ""}[kind]
    if kind == "image":
        ext = {"image/png": ".png", "image/jpeg": ".jpg", "image/webp": ".webp", "image/gif": ".gif"}.get(
            out("file", "--brief", "--mime-type", str(temporary)), ".jpg")
    SOURCES["extra"].mkdir(parents=True, exist_ok=True)
    target = safe_name(original_name, kind, ext)
    shutil.move(str(temporary), target)
    item_id = f"extra/{target.name}"
    for look_id in looks or [settings["look"]]:
        picks = get_picks(settings, look_id)
        if item_id not in picks["day"]:
            picks["day"].append(item_id)
        set_picks(settings, look_id, picks)
    save(settings)
    print(item_id)
    return item_id


def add_wallpaper(settings, source, looks=None):
    staging = Path(tempfile.mkdtemp(prefix="afterlight-"))
    try:
        if source.startswith("file://"):
            from urllib.parse import unquote, urlparse
            source = unquote(urlparse(source).path)
        if source.startswith("https://") or source.startswith("http://"):
            if not source.startswith("https://"):
                sys.exit("Only https links can be downloaded.")
            from urllib.parse import unquote, urlparse
            # A Wallhaven page link fetches its picture, and remembers the page.
            origin = wallhaven_resolve(source) or {"page": source, "image": source, "credit": "", "source": ""}
            source = origin["image"] or source
            name = unquote(os.path.basename(urlparse(source).path)) or "download"
            temporary = staging / "download"
            result = run("curl", "--fail", "--location", "--silent", "--show-error", "--proto", "=https",
                         "--max-time", "90", "--max-filesize", str(MAX_BYTES), "-o", str(temporary), source)
            if not result or result.returncode != 0 or not temporary.exists():
                sys.exit("The download didn't work: " + ((result.stderr or "").strip()[:200] if result else "curl failed"))
            item_id = adopt(temporary, name, settings, looks)
            record_source(item_id, origin)
            return item_id
        path = Path(source).expanduser()
        if not path.is_file():
            sys.exit(f"No such file: {source}")
        if path.stat().st_size > MAX_BYTES:
            sys.exit("That file is over 200 MB.")
        temporary = staging / "copy"
        shutil.copyfile(path, temporary)
        return adopt(temporary, path.name, settings, looks)
    finally:
        shutil.rmtree(staging, ignore_errors=True)


def paste_wallpaper(settings, looks=None):
    types = out("wl-paste", "--list-types").splitlines()
    for mime in ("image/png", "image/jpeg", "image/webp"):
        if mime in types:
            staging = Path(tempfile.mkdtemp(prefix="afterlight-"))
            temporary = staging / "pasted"
            with temporary.open("wb") as handle:
                subprocess.run(["wl-paste", "--type", mime], stdout=handle, timeout=30)
            try:
                return adopt(temporary, "pasted", settings, looks)
            finally:
                shutil.rmtree(staging, ignore_errors=True)
    if "text/uri-list" in types:
        uris = [u.strip() for u in out("wl-paste", "--type", "text/uri-list").splitlines() if u.strip() and not u.startswith("#")]
        if uris:
            return add_wallpaper(settings, uris[0], looks)
    text = out("wl-paste", "--no-newline").strip()
    if text.startswith(("https://", "http://", "file://", "/", "~/")) and "\n" not in text:
        return add_wallpaper(settings, text, looks)
    sys.exit("Copy an image, an image link, or a file first.")


def remove_wallpaper(settings, item_id):
    if not item_id.startswith("extra/"):
        sys.exit("Only wallpapers you added can be removed; switch the theme's own off instead.")
    item = by_id().get(item_id)
    if not item:
        sys.exit(f"Unknown wallpaper: {item_id}")
    if run("gio", "trash", item["path"]) is None:
        sys.exit("Couldn't move it to the trash.")
    for look_id in look_ids():
        picks = get_picks(settings, look_id)
        for period in ("day", "night"):
            if item_id in picks[period]:
                picks[period].remove(item_id)
        set_picks(settings, look_id, picks)
    save(settings)
    sync_wallpapers(settings)


def recent_files(limit=8):
    """Newest pictures and videos in Downloads and Pictures that aren't in the library yet."""
    known = {(Path(i["path"]).name, Path(i["path"]).stat().st_size) for i in library()}
    found = []
    for folder in RECENT_DIRS:
        if not folder.is_dir():
            continue
        for path in folder.iterdir():
            suffix = path.suffix.lower()
            if path.is_file() and (suffix in IMAGES or suffix in VIDEOS):
                try:
                    stat = path.stat()
                except OSError:
                    continue
                if ((path.name, stat.st_size) not in known and stat.st_size > 50_000
                        and not path.name.lower().startswith("screenshot")):
                    found.append((stat.st_mtime, path))
    found.sort(reverse=True)
    items = []
    for _, path in found[:limit]:
        item = {"path": str(path), "name": path.stem, "video": path.suffix.lower() in VIDEOS}
        item["thumb"] = thumbnail(item)
        items.append(item)
    return items


# ---------------------------------------------------------------- agents (T3 Code)

T3_HOME = Path(os.environ.get("T3CODE_HOME") or HOME / ".t3")
T3_DB = T3_HOME / "userdata/statev2.sqlite"
AGENTS_STATE = STATE_HOME / "afterlight/agents.json"
WORKING = {"preparing", "queued", "starting", "running"}
FAILED = {"failed", "interrupted", "rolled_back"}


CHAT_PROJECT = "Chat"   # OmaRelay's T3 project for questions and chats


def group_for(status, pending):
    # "waiting" without an open request means waiting on its own subagents or
    # background work, not on you.
    if pending:
        return "waiting"
    if status == "waiting":
        return "working"
    if status in WORKING:
        return "working"
    if status in FAILED:
        return "failed"
    if status == "completed":
        return "done"
    return "idle"


def agents_from_db():
    """Read T3's own database, read-only: cheap enough to poll every few seconds.
    It's T3's internal format, so any surprise falls back to the t3 command."""
    import sqlite3
    db = sqlite3.connect(f"file:{T3_DB}?mode=ro", uri=True, timeout=1)
    try:
        projects = {pid: title for pid, title in db.execute(
            "select project_id, title from projection_projects where deleted_at is null")}
        latest = {}
        for thread_id, status, requested, completed in db.execute(
                "select thread_id, status, requested_at, completed_at from orchestration_v2_projection_runs "
                "order by thread_id, ordinal"):
            latest[thread_id] = (status, requested, completed)
        pending = {}
        for thread_id, kind in db.execute(
                "select thread_id, kind from orchestration_v2_projection_runtime_requests where resolved_at is null"):
            pending[thread_id] = kind or "input"
        threads = []
        for thread_id, project_id, title, archived, deleted, updated, payload in db.execute(
                "select thread_id, project_id, title, archived_at, deleted_at, updated_at, payload_json "
                "from orchestration_v2_projection_threads"):
            if archived or deleted:
                continue
            info = json.loads(payload or "{}")
            status, started, completed = latest.get(thread_id, ("idle", None, None))
            lineage = info.get("lineage") or {}
            prs = info.get("pullRequests") or []
            model = (info.get("modelSelection") or {}).get("model") or ""
            threads.append({
                "id": thread_id, "title": title or "Untitled", "project": projects.get(project_id, ""),
                "status": status, "pending": pending.get(thread_id, ""),
                "startedAt": started, "completedAt": completed, "updatedAt": updated,
                "lastVisitedAt": info.get("lastVisitedAt"),
                "settled": bool(info.get("settledAt")), "snoozed": bool(info.get("snoozedUntil")),
                "parent": lineage.get("parentThreadId"), "relationship": lineage.get("relationshipToParent"),
                "model": model, "branch": info.get("branch") or "",
                "pullRequests": len(prs),
            })
        return threads
    finally:
        db.close()


def agents_from_cli():
    """The supported but slower path: one `t3 thread list` per project we know of."""
    import sqlite3
    try:
        db = sqlite3.connect(f"file:{T3_DB}?mode=ro", uri=True, timeout=1)
        project_ids = [r[0] for r in db.execute("select project_id from projection_projects where deleted_at is null")]
        db.close()
    except Exception:
        project_ids = []
    threads = []
    for project_id in project_ids or [None]:
        command = ["t3", "thread", "list", "--json"] + (["--project", project_id] if project_id else [])
        result = run(*command)
        if not result or result.returncode != 0:
            continue
        try:
            listing = json.loads(result.stdout)
        except ValueError:
            continue
        for t in listing if isinstance(listing, list) else []:
            threads.append({
                "id": t.get("threadId"), "title": t.get("title") or "Untitled", "project": "",
                "status": t.get("status") or "idle", "pending": "",
                "startedAt": None, "completedAt": None, "updatedAt": t.get("updatedAt"),
                "lastVisitedAt": None, "settled": bool(t.get("settled")), "snoozed": bool(t.get("snoozed")),
                "parent": t.get("parentThreadId"), "relationship": t.get("relationshipToParent"),
                "model": t.get("model") or "", "branch": "",
                "pullRequests": int(t.get("openPullRequestCount") or 0),
            })
    return threads


def agents_report(settings, notify=True):
    from datetime import datetime, timezone
    source = "db"
    try:
        threads = agents_from_db() if T3_DB.exists() else None
    except Exception:
        threads = None
    if threads is None:
        source = "cli"
        threads = agents_from_cli() if shutil.which("t3") else []
        if not threads:
            source = "none"

    now = datetime.now(timezone.utc)

    def age_hours(stamp):
        try:
            return (now - datetime.fromisoformat(stamp.replace("Z", "+00:00"))).total_seconds() / 3600
        except (AttributeError, ValueError):
            return 1e9

    for t in threads:
        t["group"] = group_for(t["status"], t["pending"])
        finished = t["completedAt"] or t["updatedAt"]
        t["unseen"] = (t["group"] in {"done", "failed"} and not t["settled"]
                       and (not t["lastVisitedAt"] or (finished or "") > t["lastVisitedAt"]))

    # Chat threads (OmaRelay's questions) live in the Relay tab, not here.
    chats = [t for t in threads if t["project"] == CHAT_PROJECT]
    work = [t for t in threads if t["project"] != CHAT_PROJECT]
    by_id = {t["id"]: t for t in work}
    for t in work:
        # A fork is its own conversation; only subagents nest under a parent.
        if t["relationship"] != "subagent" or t["parent"] not in by_id:
            t["parent"] = None
    kids = {}
    for t in work:
        if t["parent"]:
            kids.setdefault(t["parent"], []).append(t)
    top = [t for t in work if not t["parent"]]
    for t in top:
        mine = kids.get(t["id"], [])
        live = [k for k in mine if k["group"] in {"working", "waiting", "failed"}]
        t["children"] = len(live)
        t["finishedChildren"] = sum(1 for k in mine if k["group"] in {"done", "idle"}
                                    and age_hours(k["updatedAt"]) < 24)
        t["_live"] = live
        # A parent waiting on its subagents is busy, not waiting on you.
        if live and t["group"] == "waiting" and not t["pending"]:
            t["group"] = "working"

    order = {"waiting": 0, "failed": 1, "working": 2, "done": 3, "idle": 4}

    def recent_first(t):
        return t["updatedAt"] or ""

    shown_top = [t for t in top if t["group"] in {"working", "waiting"} or t["unseen"]
                 or t["children"] or (not t["settled"] and age_hours(t["updatedAt"]) < 24)]
    shown_top.sort(key=recent_first, reverse=True)
    shown_top.sort(key=lambda t: (order[t["group"]], not t["unseen"]))
    shown = []
    for t in shown_top[:12]:
        shown.append(t)
        shown.extend(sorted(t.pop("_live"), key=lambda k: order[k["group"]]))
    for t in top:
        t.pop("_live", None)

    counts = {g: sum(1 for t in top if t["group"] == g) for g in ("working", "waiting")}
    counts["working"] += sum(t["children"] for t in top)
    counts["unseen"] = sum(1 for t in top if t["unseen"] and t["group"] == "done")
    counts["failed"] = sum(1 for t in top if t["group"] == "failed" and t["unseen"])

    recent_chats = sorted([t for t in chats if not t["settled"] and age_hours(t["updatedAt"]) < 72],
                          key=recent_first, reverse=True)[:5]

    if notify and source != "none":
        notify_changes(settings, top)

    return {"source": source, "counts": counts, "threads": shown,
            "chats": recent_chats, "notify": settings["agents"]["notify"], "now": now.isoformat()}


def notify_changes(settings, threads):
    previous = read_json(AGENTS_STATE, {})
    known = previous.get("groups", {})
    first_run = not known
    lines = []
    for t in threads:
        was = known.get(t["id"])
        now = t["group"]
        # Nothing on the first look, nothing unchanged, and a thread first seen
        # mid-flight only counts once it needs you.
        if first_run or was == now or (was is None and now != "waiting"):
            continue
        if now == "done" and was in {"working", "waiting"}:
            lines.append(("󰄬 Finished", t))
        elif now == "failed" and was in {"working", "waiting"}:
            lines.append(("󰅙 Stopped: " + t["status"].replace("_", " "), t))
        elif now == "waiting":
            lines.append(("󰋗 Waiting for you", t))
    write_atomic(AGENTS_STATE, json.dumps({"groups": {t["id"]: t["group"] for t in threads}}) + "\n")
    if not settings["agents"]["notify"]:
        return
    for headline, t in lines[:4]:
        urgency = "normal" if t["group"] in {"waiting", "failed"} else "low"
        body = t["title"] + (f"\n{t['project']}" if t["project"] else "")
        # Named "T3 Code" so the notification filter lets it through.
        run("omarchy-notification-send", "--app-name", "T3 Code", "-u", urgency, headline, body)


def open_thread(thread_id):
    if not all(c.isalnum() or c == "-" for c in thread_id):
        sys.exit("Bad thread id")
    run("xdg-open", f"t3code://app/threads/{thread_id}")
    run("hyprctl", "dispatch", 'hl.dsp.focus({ window = "class:com.t3tools.T3Code" })')


# ---------------------------------------------------------------- tweaks and timer

def lua_value(value):
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return repr(float(value)) if isinstance(value, float) else str(value)
    return json.dumps(str(value))


def write_tweaks(settings):
    keys = ("dim", "blur", "blurBrightness", "terminalOpacity", "webDim", "animations")
    lines = ["-- Written by `afterlight` from settings.json; edit there or in the Baseline panel.", "return {"]
    for mode in ("day", "night", "saver"):
        values = settings["tweaks"][mode]
        fields = ", ".join(f"{k} = {lua_value(values[k])}" for k in keys if k in values)
        lines.append(f"  {mode} = {{ {fields} }},")
    lines.append("}")
    text = "\n".join(lines) + "\n"
    try:
        if TWEAKS.read_text() == text:
            return False
    except OSError:
        pass
    write_atomic(TWEAKS, text)
    return True


def reload_hyprland():
    if current_mode() != "other":
        run("hyprctl", "reload")


def write_timer(settings):
    schedule = settings["schedule"]
    text = (
        "[Unit]\nDescription=Baseline day/night switch (written by afterlight)\n\n"
        f"[Timer]\nOnCalendar=*-*-* {schedule['day']}:00\nOnCalendar=*-*-* {schedule['night']}:00\n"
        "# Catch a switch missed while the laptop was off or asleep.\nPersistent=true\n\n"
        "[Install]\nWantedBy=timers.target\n"
    )
    try:
        if TIMER.read_text() == text:
            return
    except OSError:
        pass
    write_atomic(TIMER, text)
    run("systemctl", "--user", "daemon-reload")
    if schedule["auto"]:
        run("systemctl", "--user", "restart", "afterlight-mode.timer")


def minutes(hhmm):
    hours, mins = hhmm.split(":")
    return int(hours) * 60 + int(mins)


def period_now(settings):
    from datetime import datetime
    now = datetime.now()
    current = now.hour * 60 + now.minute
    day, night = minutes(settings["schedule"]["day"]), minutes(settings["schedule"]["night"])
    if day < night:
        return "day" if day <= current < night else "night"
    return "night" if night <= current < day else "day"


def on_battery():
    """Draining counts as on battery, so a charger too weak to keep up does too."""
    for supply in Path("/sys/class/power_supply").glob("*"):
        try:
            if (supply / "type").read_text().strip() == "Battery":
                return (supply / "status").read_text().strip() == "Discharging"
        except OSError:
            continue
    return False


# ---------------------------------------------------------------- saver

def enter_saver(settings):
    saver = settings["tweaks"]["saver"]
    state = load_state()
    if not state.get("saverRestore"):
        restore = {}
        level = out("brightnessctl", "-m")
        if level:
            restore["backlight"] = level.split(",")[2]
        restore["profile"] = out("powerprofilesctl", "get") or None
        restore["bar"] = out("omarchy-bar", "background") or None
        state["saverRestore"] = restore
        save_state(state)
    run("brightnessctl", "-q", "set", f"{int(saver['backlight'])}%")
    run("hyprctl", "hyprsunset", "temperature", str(int(saver["warmth"])))
    if saver["powerSaver"]:
        run("powerprofilesctl", "set", "power-saver")
    if saver["opaqueBar"]:
        run("omarchy-bar", "background", "opaque")


def apply_warmth(settings, mode):
    """Each mode's colour temperature: Night and Saver their own, Day neutral."""
    kelvin = int(settings["tweaks"].get(mode, {}).get("warmth", 6500)) if mode in {"night", "saver"} else 6500
    run("hyprctl", "hyprsunset", "temperature", str(kelvin))
    if kelvin >= 6500:
        run("hyprctl", "hyprsunset", "identity")


def leave_saver():
    state = load_state()
    restore = state.pop("saverRestore", None)
    if not restore:
        return
    if restore.get("backlight"):
        run("brightnessctl", "-q", "set", restore["backlight"])
    # The colour temperature isn't put back here: set_mode sets the next mode's.
    if restore.get("profile"):
        run("powerprofilesctl", "set", restore["profile"])
    if restore.get("bar") in {"opaque", "glassy", "none"}:
        run("omarchy-bar", "background", restore["bar"])
    save_state(state)


# ---------------------------------------------------------------- modes

def set_mode(settings, want, manual=True):
    mode = current_mode()
    state = load_state()
    if manual:
        # A Saver picked by hand stays until it's left by hand; the clock
        # and the charger only steer day and night.
        state["saverManual"] = want == "saver"
        save_state(state)
    if want == mode:
        return
    if mode == "saver":
        leave_saver()
    if want == "saver":
        sync_wallpapers(settings)
        enter_saver(settings)
    elif want == "night":
        sync_wallpapers(settings)
    run("omarchy-theme-set", SLUGS[want])
    apply_warmth(settings, want)
    mouse_light(settings, want)
    wallpaper_next(settings, shuffle=True)


def auto_mode(settings):
    mode = current_mode()
    if mode == "other":
        return
    state = load_state()
    if mode == "saver" and state.get("saverManual"):
        return
    if settings["schedule"]["saverOnBattery"] and on_battery():
        want = "saver"
    elif settings["schedule"]["auto"] or mode == "saver":
        want = period_now(settings)
    else:
        return
    set_mode(settings, want, manual=False)


# ---------------------------------------------------------------- looks

# A look is a whole colour scheme with its own wallpapers, each in Day, Night
# and Saver. The original amber one lives at the top of the repo; the others
# in looks/<id>/ (colors.toml, night/, saver/, backgrounds/, look.json).
def look_ids():
    found = ["afterlight"]
    if LOOKS_DIR.is_dir():
        others = [d for d in LOOKS_DIR.iterdir() if (d / "look.json").is_file()]
        found += [d.name for d in sorted(others, key=lambda d: (read_json(d / "look.json", {}).get("order", 99), d.name))]
    if MINE_DIR.is_dir():
        mine = [d for d in MINE_DIR.iterdir() if (d / "look.json").is_file() and d.name not in found]
        found += [d.name for d in sorted(mine, key=lambda d: (read_json(d / "look.json", {}).get("order", 500), d.name))]
    shared = HOME / ".local/share/baseline/looks"
    if shared.is_dir():
        added = [d for d in shared.iterdir() if (d / "look.json").is_file() and (d / "colors.toml").is_file()]
        found += ["c-" + d.name for d in sorted(added, key=lambda d: (read_json(d / "look.json", {}).get("order", 9999), d.name))]
    return found


def look_info(look_id):
    if look_id == "afterlight":
        return {"id": "afterlight", "name": "Afterlight", "tagline": "Sodium amber and teal through the smog",
                "shared": False, "author": "", "builtin": True, "dir": REPO, "slugs": {"day": "afterlight-2049", "night": "afterlight-2049-night",
                                       "saver": "afterlight-2049-saver"}}
    shared = look_id.startswith("c-")
    if shared:
        folder = HOME / ".local/share/baseline/looks" / look_id[2:]
    elif (LOOKS_DIR / look_id / "look.json").is_file():
        folder = LOOKS_DIR / look_id
    else:
        folder = MINE_DIR / look_id
    meta = read_json(folder / "look.json", {})
    base = f"afterlight-{look_id}"
    return {"id": look_id, "name": meta.get("name", look_id.title()), "tagline": meta.get("tagline", ""),
            "shared": shared, "author": meta.get("author", "") if shared else "",
            "builtin": look_id == "afterlight" or folder.parent == LOOKS_DIR,
            "dir": folder, "slugs": {"day": base, "night": f"{base}-night", "saver": f"{base}-saver"}}


def use_look(look_id):
    """Point the module at a look: its theme names, folders and wallpapers."""
    global SLUGS, LOOK_DIR, NIGHT_DIR, SAVER_DIR
    info = look_info(look_id if look_id in look_ids() else "afterlight")
    SLUGS, LOOK_DIR = info["slugs"], info["dir"]
    for other in look_ids():
        SOURCES[other] = look_info(other)["dir"] / "backgrounds"
    NIGHT_DIR = USER_BG / SLUGS["night"]
    SAVER_DIR = USER_BG / SLUGS["saver"]
    return info


def install_looks():
    """Each look's three themes linked into Omarchy's themes folder, each
    with Chrome's seed colour: the accent, not Omarchy's default of the
    background, so Chrome's frame, tabs and highlights take the look's hue
    (light or dark still follows the system)."""
    for look_id in look_ids():
        info = look_info(look_id)
        for mode, slug in info["slugs"].items():
            target = info["dir"] / MODE_FOLDERS[mode] if MODE_FOLDERS[mode] else info["dir"]
            try:
                accent = read_colors(target / "colors.toml")["accent"]
                seed = ",".join(str(int(accent[i:i + 2], 16)) for i in (1, 3, 5))
                chrome = target / "chromium.theme"
                if not chrome.exists() or chrome.read_text().strip() != seed:
                    write_atomic(chrome, seed + "\n")
                    chrome.chmod(0o644)
            except (OSError, KeyError, ValueError):
                pass
            link = THEMES / slug
            if link.is_symlink() and link.resolve() == target.resolve():
                continue
            if link.exists() and not link.is_symlink():
                continue    # someone's own folder of that name: leave it alone
            link.unlink(missing_ok=True)
            link.symlink_to(target)


def look_pools(look_id):
    """A look's starting wallpapers: all its own pictures, day and night."""
    folder = look_info(look_id)["dir"] / "backgrounds"
    names = sorted(p.name for p in folder.iterdir() if p.suffix.lower() in IMAGES | VIDEOS) if folder.is_dir() else []
    ids = [f"{look_id}/{n}" for n in names]
    return {"day": ids, "night": list(ids)}


def set_look(settings, look_id):
    if look_id not in look_ids():
        sys.exit(f"Unknown look: {look_id} (have: {', '.join(look_ids())})")
    old = settings["look"]
    mode = current_mode()
    if old != look_id or mode == "other":
        # Each look remembers its own wallpaper picks.
        stash = settings.setdefault("lookWallpapers", {})
        stash[old] = {"day": settings["wallpapers"]["day"], "night": settings["wallpapers"]["night"]}
        picks = stash.get(look_id) or look_pools(look_id)
        settings["wallpapers"]["day"], settings["wallpapers"]["night"] = list(picks["day"]), list(picks["night"])
        settings["look"] = look_id
        save(settings)
    use_look(look_id)
    install_looks()
    if mode == "other":
        mode = period_now(settings)
    sync_wallpapers(settings)
    run("omarchy-theme-set", SLUGS[mode])
    apply_warmth(settings, mode)
    mouse_light(settings, mode)
    wallpaper_next(settings, shuffle=True)


def read_colors(path):
    colours = {}
    for line in path.read_text().splitlines():
        key, _, value = line.partition("=")
        value = value.strip()
        if value.startswith('"'):
            value = value[1:].split('"', 1)[0]     # a quoted value, then maybe a comment
        else:
            value = value.split("#", 1)[0].strip()
        if key.strip() and not key.strip().startswith("#") and value:
            colours[key.strip()] = value
    return colours


def scale_colour(hexa, value=1.0, saturation=1.0):
    r, g, b = (int(hexa[i:i + 2], 16) / 255 for i in (1, 3, 5))
    h, sat, val = colorsys.rgb_to_hsv(r, g, b)
    r, g, b = colorsys.hsv_to_rgb(h, min(1, sat * saturation), min(1, val * value))
    return "#" + "".join(f"{round(c * 255):02x}" for c in (r, g, b))


LOOK_KEYS = ("accent", "selection", "muted", "background", "dark_background", "darker_background",
             "lighter_background", "foreground", "dark_foreground", "light_foreground", "bright_foreground",
             "red", "yellow", "orange", "green", "cyan", "blue", "magenta", "brown",
             "bright_red", "bright_yellow", "bright_green", "bright_cyan", "bright_blue", "bright_magenta")


def build_look(look_id):
    """From a look's Day colors.toml, write its Night and Saver palettes (true
    black, the colours pulled back to embers, as Afterlight's own are) and
    each mode's hyprland.lua (borders, plus the shared atmosphere)."""
    info = look_info(look_id)
    if look_id == "afterlight":
        sys.exit("Afterlight's own palettes are hand-made; build is for looks/<id>")
    meta = read_json(info["dir"] / "look.json", {})
    day = read_colors(info["dir"] / "colors.toml")
    missing = [k for k in LOOK_KEYS if k not in day]
    if missing:
        sys.exit(f"{look_id}/colors.toml is missing: {', '.join(missing)}")
    # How far each mode pulls the day colours back (value, saturation).
    pulls = {"night": {"text": (0.79, 0.95), "colour": (0.76, 0.92), "accent": (0.76, 0.92),
                       "lighter": 0.47, "selection": 0.6, "border": "cc"},
             "saver": {"text": (0.70, 0.9), "colour": (0.72, 0.9), "accent": (0.66, 0.9),
                       "lighter": 0.47, "selection": 0.5, "border": "aa"}}
    for mode, pull in pulls.items():
        out = {}
        for key in LOOK_KEYS:
            value = day[key]
            if key in {"background", "dark_background", "darker_background"}:
                out[key] = "#000000"
            elif key == "lighter_background":
                out[key] = scale_colour(value, pull["lighter"])
            elif key == "selection":
                out[key] = scale_colour(value, pull["selection"])
            elif key == "accent":
                out[key] = scale_colour(value, *pull["accent"])
            elif key.endswith("foreground") or key == "muted":
                out[key] = scale_colour(value, *pull["text"])
            else:
                out[key] = scale_colour(value, *pull["colour"])
        a, c = out["accent"][1:], out["cyan"][1:]
        inactive = scale_colour(day["lighter_background"], 0.55)[1:]
        lines = ['mode = "dark"', "",
                 f"# {meta.get('name', look_id)} {mode.title()}: written by `afterlight look build {look_id}`",
                 "# from the Day palette; edit that and build again.", ""]
        lines += [f'{k} = "{out[k]}"' for k in LOOK_KEYS]
        lines += ["", f'hyprland_active_border = "rgba({a}{pull["border"]}) rgba({c}{pull["border"]}) 45deg"',
                  f'hyprland_inactive_border = "rgba({inactive}aa)"', ""]
        write_atomic(info["dir"] / mode / "colors.toml", "\n".join(lines))
    for mode in ("day", "night", "saver"):
        folder = info["dir"] / MODE_FOLDERS[mode] if MODE_FOLDERS[mode] else info["dir"]
        colours = read_colors(folder / "colors.toml")
        alpha = {"day": "ee", "night": "cc", "saver": "aa"}[mode]
        inactive = colours.get("hyprland_inactive_border") or f"rgba({day['lighter_background'][1:]}aa)"
        text = (f"-- {meta.get('name', look_id)} {mode.title()} window atmosphere, written by `afterlight look build`.\n"
                "-- A theme-shipped hyprland.lua replaces the one Omarchy generates, so the borders\n"
                "-- are set here too; the rest lives in Afterlight's shared atmosphere.lua.\n\n"
                f'local active_border_color = {{ colors = {{ "rgba({colours["accent"][1:]}{alpha})", '
                f'"rgba({colours["cyan"][1:]}{alpha})" }}, angle = 45 }}\n'
                f'local inactive_border_color = "{inactive}"\n\n'
                'local ok, atmosphere = pcall(dofile, os.getenv("HOME") .. "/.config/omarchy/themes/afterlight-2049/atmosphere.lua")\n'
                "if ok then\n"
                f'  atmosphere("{mode}", active_border_color, inactive_border_color)\n'
                "else\n"
                "  hl.config({ general = { col = { active_border = active_border_color, inactive_border = inactive_border_color } } })\n"
                "end\n")
        write_atomic(folder / "hyprland.lua", text)


def get_picks(settings, look_id):
    """A look's Day and Night pictures: the live lists for the look that's
    on, its stash for the others (or all its own pictures, if never set)."""
    if look_id == settings["look"]:
        return {"day": list(settings["wallpapers"]["day"]), "night": list(settings["wallpapers"]["night"])}
    stash = settings.get("lookWallpapers", {}).get(look_id)
    return {"day": list(stash["day"]), "night": list(stash["night"])} if stash else look_pools(look_id)


def set_picks(settings, look_id, picks):
    if look_id == settings["look"]:
        settings["wallpapers"]["day"], settings["wallpapers"]["night"] = picks["day"], picks["night"]
    else:
        settings.setdefault("lookWallpapers", {})[look_id] = picks


def assign(settings, item_id, look_id, period, on):
    if look_id not in look_ids():
        sys.exit(f"Unknown look: {look_id}")
    if period not in {"day", "night"}:
        sys.exit("assign takes day or night")
    if item_id not in by_id():
        sys.exit(f"Unknown wallpaper: {item_id}")
    picks = get_picks(settings, look_id)
    if on and item_id not in picks[period]:
        picks[period].append(item_id)
    elif not on and item_id in picks[period]:
        picks[period].remove(item_id)
    set_picks(settings, look_id, picks)
    save(settings)
    if look_id == settings["look"] and period == "night":
        sync_wallpapers(settings)


def library_state(settings):
    """Every picture, and which looks use it by day and by night."""
    picks = {look_id: get_picks(settings, look_id) for look_id in look_ids()}
    items = library()
    for item in items:
        item["thumb"] = thumbnail(item)
        item["owner"] = item["id"].split("/", 1)[0]
        item["looks"] = {look_id: {"day": item["id"] in p["day"], "night": item["id"] in p["night"]}
                         for look_id, p in picks.items()}
    return {"look": settings["look"], "items": items, "looks": looks_state(),
            "extraFolder": str(SOURCES["extra"])}


def looks_state():
    result = []
    for look_id in look_ids():
        info = look_info(look_id)
        folder = info["dir"] / "backgrounds"
        pictures = sorted(p for p in folder.iterdir() if p.suffix.lower() in IMAGES) if folder.is_dir() else []
        result.append({"id": look_id, "name": info["name"], "tagline": info["tagline"],
                       "palette": palette("day", look_id), "nightPalette": palette("night", look_id),
                       "thumbs": [thumbnail({"path": str(p), "video": False}) for p in pictures[:4]]})
    return result


# ---------------------------------------------------------------- making looks

def hex_to_rgb(hexa):
    return tuple(int(hexa[i:i + 2], 16) / 255 for i in (1, 3, 5))


def rgb_to_hex(rgb):
    return "#" + "".join(f"{round(max(0, min(1, c)) * 255):02x}" for c in rgb)


def hsv_hex(h, sat, val):
    return rgb_to_hex(colorsys.hsv_to_rgb(h % 1, max(0, min(1, sat)), max(0, min(1, val))))


def mix(a, b, t):
    ra, rb = hex_to_rgb(a), hex_to_rgb(b)
    return rgb_to_hex(tuple(x + (y - x) * t for x, y in zip(ra, rb)))


def luminance(hexa):
    def lin(c):
        return c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4
    r, g, b = (lin(c) for c in hex_to_rgb(hexa))
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def contrast(a, b):
    la, lb = sorted((luminance(a), luminance(b)), reverse=True)
    return (la + 0.05) / (lb + 0.05)


def image_palette(path):
    """Suggest a look from a picture: its strongest neon for the accent, a
    second neon well round the colour wheel from it, a near-black ground in
    the picture's own shadow hue, and pale text tinted by the accent."""
    result = run("magick", str(path) + "[0]", "-resize", "200x200", "-colors", "16", "-depth", "8",
                 "-format", "%c", "histogram:info:-")
    if not result or result.returncode != 0:
        sys.exit("Couldn't read that picture.")
    swatches = []
    for line in result.stdout.splitlines():
        m = re.search(r"(\d+):.*?(#[0-9A-Fa-f]{6})", line)
        if m:
            count, hexa = int(m.group(1)), m.group(2).lower()
            h, sat, val = colorsys.rgb_to_hsv(*hex_to_rgb(hexa))
            swatches.append({"hex": hexa, "count": count, "h": h, "s": sat, "v": val})
    if not swatches:
        sys.exit("Couldn't read that picture.")
    total = sum(w["count"] for w in swatches)

    def vivid(w):
        return w["s"] * w["v"] * (0.35 + (w["count"] / total) ** 0.35)
    ranked = sorted(swatches, key=vivid, reverse=True)
    first = ranked[0]
    second = next((w for w in ranked[1:] if min(abs(w["h"] - first["h"]), 1 - abs(w["h"] - first["h"])) > 0.12 and w["s"] > 0.25), None)
    accent = hsv_hex(first["h"], max(first["s"], 0.6), max(first["v"], 0.9))
    cyan = hsv_hex(second["h"], max(second["s"], 0.55), max(second["v"], 0.88)) if second \
        else hsv_hex(first["h"] + 0.5, 0.6, 0.9)
    dark = min(swatches, key=lambda w: w["v"] - (w["count"] / total) * 0.3)
    background = hsv_hex(dark["h"], min(dark["s"], 0.45), 0.085)
    foreground = hsv_hex(first["h"], 0.12, 0.93)
    return {"accent": accent, "cyan": cyan, "background": background, "foreground": foreground,
            "swatches": [w["hex"] for w in sorted(swatches, key=lambda w: w["count"], reverse=True)]}


def derive_palette(seed):
    """A whole Day palette from four key colours (accent, cyan as the second
    neon, background, foreground); any other key given in seed is kept."""
    accent, cyan, bg, fg = seed["accent"], seed["cyan"], seed["background"], seed["foreground"]
    ah, a_s, a_v = colorsys.rgb_to_hsv(*hex_to_rgb(accent))
    # Keep body text readable: lift it until it's 7:1 on the ground.
    while contrast(fg, bg) < 7 and luminance(fg) < 0.95:
        fg = mix(fg, "#ffffff", 0.12)
    sat = max(0.42, min(0.72, a_s * 0.85))
    val = max(0.82, min(0.95, a_v))
    bh, bs, bv = colorsys.rgb_to_hsv(*hex_to_rgb(bg))
    colours = {
        "accent": accent, "cyan": cyan, "background": bg, "foreground": fg,
        "selection": mix(bg, accent, 0.28),
        "muted": mix(fg, bg, 0.55),
        "dark_background": hsv_hex(bh, bs, bv * 0.72),
        "darker_background": hsv_hex(bh, bs, bv * 0.45),
        "lighter_background": hsv_hex(bh, min(1, bs * 1.1 + 0.05), min(1, bv + 0.075)),
        "dark_foreground": mix(fg, bg, 0.35),
        "light_foreground": mix(fg, "#ffffff", 0.35),
        "bright_foreground": mix(fg, "#ffffff", 0.7),
        "red": hsv_hex(0.985, sat, val), "yellow": hsv_hex(0.115, sat * 0.9, val),
        "orange": hsv_hex(0.06, sat, val), "green": hsv_hex(0.42, sat * 0.75, val * 0.92),
        "blue": hsv_hex(0.62, sat, val), "magenta": hsv_hex(0.82, sat, val),
        "brown": hsv_hex(0.07, sat * 0.55, val * 0.62),
    }
    for name in ("red", "yellow", "green", "cyan", "blue", "magenta"):
        h, s_, v = colorsys.rgb_to_hsv(*hex_to_rgb(colours[name]))
        colours["bright_" + name] = hsv_hex(h, s_ * 0.72, min(1, v + 0.1))
    for key, value in seed.items():
        # The foreground keeps its lift: a dim one given here would undo it.
        if key in LOOK_KEYS and key != "foreground" and isinstance(value, str) \
                and re.fullmatch(r"#[0-9a-fA-F]{6}", value):
            colours[key] = value.lower()
    return colours


def look_slug(name):
    slug = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")[:24] or "look"
    return "afterlight" + "-mine" if slug == "afterlight" else slug


def save_look(settings, data):
    """Create or update a look from the Studio: {id?, name, tagline,
    colours: {...}, derive: bool, inspiredBy: picture id?}."""
    name = str(data.get("name") or "").strip()[:40]
    if not name:
        sys.exit("A look needs a name.")
    look_id = data.get("id") or look_slug(name)
    if look_id.startswith("c-"):
        sys.exit("Looks from the catalog stay as their author made them: save a copy under a new name instead.")
    if look_id == "afterlight" or (LOOKS_DIR / look_id / "look.json").is_file():
        sys.exit("The built-in looks are part of Baseline: save a copy under a new name instead.")
    if not re.fullmatch(r"[a-z0-9-]{1,32}", look_id):
        sys.exit("Bad look id.")
    folder = MINE_DIR / look_id
    fresh = not folder.exists()
    if fresh and look_id in look_ids():
        sys.exit("That name is taken.")
    colours = data.get("colours") or {}
    if data.get("derive", True):
        colours = derive_palette(colours)
    missing = [k for k in LOOK_KEYS if k not in colours]
    if missing:
        sys.exit("Missing colours: " + ", ".join(missing))
    meta = read_json(folder / "look.json", {})
    meta.update({"name": name, "tagline": str(data.get("tagline") or "").strip()[:80]})
    if fresh:
        others = [read_json(look_info(i)["dir"] / "look.json", {}).get("order", 0) for i in look_ids()
                  if not look_info(i)["builtin"] and not i.startswith("c-")]
        meta["order"] = max(others, default=500) + 1
    if data.get("inspiredBy"):
        meta["inspiredBy"] = data["inspiredBy"]
    (folder / "backgrounds").mkdir(parents=True, exist_ok=True)
    write_atomic(folder / "look.json", json.dumps(meta, indent=2) + "\n")
    lines = ['mode = "dark"', "", f"# {name}: made in Baseline Studio.", ""]
    lines += [f'{k} = "{colours[k]}"' for k in LOOK_KEYS]
    lines += ["", f'hyprland_active_border = "rgba({colours["accent"][1:]}ee) rgba({colours["cyan"][1:]}ee) 45deg"',
              f'hyprland_inactive_border = "rgba({colours["lighter_background"][1:]}aa)"', ""]
    write_atomic(folder / "colors.toml", "\n".join(lines))
    build_look(look_id)
    install_looks()
    # A look inspired by a picture starts with that picture.
    if fresh and data.get("inspiredBy") in by_id():
        picks = {"day": [data["inspiredBy"]], "night": [data["inspiredBy"]]}
        set_picks(settings, look_id, picks)
        save(settings)
    # Saving the look that's on shows the change straight away.
    if look_id == settings["look"] and current_mode() != "other":
        run("omarchy-theme-set", SLUGS[current_mode()])
        mouse_light(settings)
    looks_backup(f"Look: {name}")
    print(look_id)
    return look_id


def delete_look(settings, look_id):
    if look_id.startswith("c-") and look_id in look_ids():
        return catalog_remove(settings, look_id[2:])
    if look_id not in look_ids() or look_info(look_id)["builtin"]:
        sys.exit("That look can't be deleted.")
    if look_id == settings["look"]:
        set_look(settings, "afterlight")
        settings = load()
    info = look_info(look_id)
    for slug in info["slugs"].values():
        link = THEMES / slug
        if link.is_symlink():
            link.unlink()
    if run("gio", "trash", str(info["dir"])) is None:
        sys.exit("Couldn't move it to the trash.")
    settings.get("lookWallpapers", {}).pop(look_id, None)
    save(settings)
    looks_backup(f"Look removed: {info['name']}")


def look_detail(look_id):
    """Everything the Studio edits for one look."""
    info = look_info(look_id)
    day = read_colors(info["dir"] / "colors.toml")
    meta = read_json(info["dir"] / "look.json", {}) if look_id != "afterlight" else {}
    return {"id": look_id, "name": info["name"], "tagline": info["tagline"],
            "builtin": info["builtin"] or info["shared"], "shared": info["shared"], "author": info["author"],
            "inspiredBy": meta.get("inspiredBy", ""),
            "colours": {k: day[k] for k in LOOK_KEYS if k in day},
            "night": palette("night", look_id), "saver": palette("saver", look_id)}


# ---------------------------------------------------------------- your looks, backed up

def looks_backup(message="Looks: update"):
    """Back up your own looks (in ~/.local/share/baseline/mine, outside the
    repo) by running the command in settings backup.command, if you set one,
    e.g. a dotfiles sync. It runs in the background; the message is passed on
    as BASELINE_BACKUP_REASON."""
    command = (load().get("backup") or {}).get("command", "").strip()
    if not command:
        return False
    subprocess.Popen(["bash", "-c", command], env={**os.environ, "BASELINE_BACKUP_REASON": message},
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    return True


# ---------------------------------------------------------------- where pictures came from

SOURCES_FILE = CONFIG / "omarchy/afterlight/sources.json"
# Sites a shared look's pictures may be downloaded from (direct image links).
PICTURE_HOSTS = {"w.wallhaven.cc", "images.unsplash.com", "upload.wikimedia.org"}
# Original sources that are paid stock: never shared, even as links.
STOCK_HOSTS = ("istockphoto.", "shutterstock.", "gettyimages.", "stock.adobe.", "alamy.", "dreamstime.", "123rf.",
               "depositphotos.")


def wallhaven_resolve(url):
    """A Wallhaven page (wallhaven.cc/w/<id>) to its picture's details."""
    found = re.fullmatch(r"https://(?:www\.)?wallhaven\.cc/w/([a-z0-9]{4,10})/?", url.strip())
    if not found:
        return None
    from urllib.request import Request, urlopen
    try:
        with urlopen(Request(f"https://wallhaven.cc/api/v1/w/{found.group(1)}",
                             headers={"User-Agent": "baseline-looks/1"}), timeout=20) as response:
            data = json.loads(response.read(200_000))["data"]
    except Exception:
        return None
    return {"page": f"https://wallhaven.cc/w/{found.group(1)}", "image": data.get("path", ""),
            "credit": "uploaded to Wallhaven by " + ((data.get("uploader") or {}).get("username") or "unknown"),
            "source": data.get("source") or ""}


def record_source(item_id, info):
    sources = read_json(SOURCES_FILE, {})
    sources[item_id] = {k: str(v)[:300] for k, v in info.items() if k in {"page", "image", "credit", "source"}}
    SOURCES_FILE.parent.mkdir(parents=True, exist_ok=True)
    write_atomic(SOURCES_FILE, json.dumps(sources, indent=2) + "\n")


def picture_sources(look_id):
    """{picture id: source info} for a look's own pictures and the added ones it uses."""
    info = look_info(look_id)
    found = {}
    for entry in read_list(info["dir"] / "pictures.json"):
        if isinstance(entry, dict) and entry.get("file"):
            found[f"{look_id}/{entry['file']}"] = entry
    sources = read_json(SOURCES_FILE, {})
    settings = load()
    picks = get_picks(settings, look_id)
    for item_id in picks["day"] + picks["night"]:
        if item_id in sources:
            found[item_id] = sources[item_id]
    return found


def shareable(entry):
    """(ok, reason) for sharing one picture as a link."""
    from urllib.parse import urlparse
    image, page, source = entry.get("image", ""), entry.get("page", ""), entry.get("source", "")
    if not image or not page:
        return False, "no recorded source"
    host = urlparse(image).hostname or ""
    if not image.startswith("https://") or host not in PICTURE_HOSTS:
        return False, f"{host or 'that site'} isn't a site shared looks download from"
    if any(stock in (urlparse(source).hostname or "") for stock in STOCK_HOSTS):
        return False, "its original is a paid stock photo"
    if not re.search(r"\.(jpe?g|png|webp)$", urlparse(image).path, flags=re.I):
        return False, "not a jpg, png or webp"
    return True, ""


# ---------------------------------------------------------------- shared looks: the public catalog

CATALOG_REPO = "mortalfish-studio/baseline-looks"
CATALOG_URL = f"https://github.com/{CATALOG_REPO}"
CATALOG_CACHE = HOME / ".cache/baseline/catalog"
COMMUNITY_DIR = HOME / ".local/share/baseline/looks"
CATALOG_FORMAT = 1
SHARED_PREFIX = "c-"     # a look added from the catalog is c-<its id>
MAX_PICTURES = 8
PICTURE_BYTES = 25 * 1024 * 1024


def clean_text(value, limit):
    """Plain, single-line text: no control characters, no markup brackets."""
    text = re.sub(r"[\x00-\x1f\x7f<>]", "", str(value or "")).strip()
    return text[:limit]


def parse_palette(text):
    """A shared colors.toml, strictly: only known colour keys with #rrggbb values."""
    colours, mode = {}, "dark"
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        found = re.fullmatch(r'([a-z_]+)\s*=\s*"([^"]*)"', line)
        if not found:
            raise ValueError(f"unexpected line in colors.toml: {line[:40]}")
        key, value = found.groups()
        if key == "mode":
            if value not in {"dark", "light"}:
                raise ValueError("mode must be dark or light")
            mode = value
        elif key in LOOK_KEYS:
            if not re.fullmatch(r"#[0-9a-fA-F]{6}", value):
                raise ValueError(f"{key} isn't a #rrggbb colour")
            colours[key] = value.lower()
        elif key.startswith("hyprland_"):
            continue    # generated locally from the palette instead
        else:
            raise ValueError(f"unknown key in colors.toml: {key}")
    missing = [k for k in LOOK_KEYS if k not in colours]
    if missing:
        raise ValueError("colors.toml is missing " + ", ".join(missing))
    return colours, mode


def validate_shared(folder):
    """A catalog look, checked as data: (meta, colours, pictures). Raises ValueError."""
    def small(path, limit=65536):
        if not path.is_file() or path.is_symlink() or path.stat().st_size > limit:
            raise ValueError(f"{path.name} missing or too large")
        return path.read_text(errors="strict")
    extra = sorted(p.name for p in folder.iterdir() if p.name not in {"look.json", "colors.toml", "pictures.json"})
    if extra:
        raise ValueError("unexpected files: " + ", ".join(extra[:5]))
    raw = json.loads(small(folder / "look.json"))
    if not isinstance(raw, dict) or raw.get("format") != CATALOG_FORMAT:
        raise ValueError("look.json isn't format 1")
    look_id = str(raw.get("id", ""))
    if look_id != folder.name or not re.fullmatch(r"[a-z0-9-]{1,32}", look_id):
        raise ValueError("look.json id doesn't match its folder")
    meta = {"format": CATALOG_FORMAT, "id": look_id, "name": clean_text(raw.get("name"), 40),
            "tagline": clean_text(raw.get("tagline"), 120), "author": clean_text(raw.get("author"), 40),
            "version": raw.get("version")}
    if not meta["name"] or not isinstance(meta["version"], int) or not 1 <= meta["version"] <= 9999:
        raise ValueError("look.json needs a name and a version number")
    colours, mode = parse_palette(small(folder / "colors.toml"))
    pictures = []
    if (folder / "pictures.json").exists():
        listed = json.loads(small(folder / "pictures.json"))
        if not isinstance(listed, list) or len(listed) > MAX_PICTURES:
            raise ValueError(f"pictures.json must list at most {MAX_PICTURES} pictures")
        for entry in listed:
            if not isinstance(entry, dict):
                raise ValueError("pictures.json entries must be objects")
            item = {"title": clean_text(entry.get("title"), 60), "page": clean_text(entry.get("page"), 300),
                    "image": clean_text(entry.get("image"), 300), "credit": clean_text(entry.get("credit"), 120),
                    "source": clean_text(entry.get("source"), 300)}
            ok, reason = shareable(item)
            if not ok:
                raise ValueError(f"picture {item['title'] or item['page']}: {reason}")
            if not item["page"].startswith("https://") or (item["source"] and not item["source"].startswith("https://")):
                raise ValueError("picture links must be https")
            pictures.append(item)
    return meta, colours, pictures, mode


def catalog_refresh(force=False):
    """A local copy of the public catalog (git, read as data only)."""
    marker = CATALOG_CACHE / ".git/FETCH_HEAD"
    fresh = marker.exists() and time.time() - marker.stat().st_mtime < 600
    if (CATALOG_CACHE / ".git").is_dir():
        if force or not fresh:
            run("git", "-C", str(CATALOG_CACHE), "pull", "-q", "--ff-only")
            marker.touch(exist_ok=True) if marker.parent.exists() else None
    else:
        CATALOG_CACHE.parent.mkdir(parents=True, exist_ok=True)
        result = run("git", "clone", "-q", "--depth", "1", CATALOG_URL + ".git", str(CATALOG_CACHE))
        if not result or result.returncode:
            return False
    return (CATALOG_CACHE / "looks").is_dir()


def catalog_installed(settings):
    return settings.setdefault("catalog", {}).setdefault("installed", {})


def catalog_list(settings, force=False):
    reachable = catalog_refresh(force)
    installed = catalog_installed(settings)
    looks = []
    for folder in sorted((CATALOG_CACHE / "looks").iterdir()) if reachable else []:
        if not folder.is_dir():
            continue
        try:
            meta, colours, pictures, mode = validate_shared(folder)
        except (ValueError, OSError, UnicodeDecodeError) as error:
            looks.append({"id": folder.name, "problem": str(error)[:160]})
            continue
        have = installed.get(meta["id"])
        looks.append({**meta, "colours": {k: colours[k] for k in ("background", "foreground", "accent", "cyan",
                                                                   "magenta", "blue", "lighter_background")},
                      "pictures": [{"title": p["title"], "credit": p["credit"], "page": p["page"]} for p in pictures],
                      "installed": bool(have), "installedVersion": have["version"] if have else None,
                      "update": bool(have) and have["version"] < meta["version"],
                      "lookId": SHARED_PREFIX + meta["id"]})
    return {"reachable": reachable, "url": CATALOG_URL, "looks": looks}


def fetch_picture(url, target):
    """Download one picture from an allowed site: https only, no redirects,
    size-capped, and kept only if it really is an image."""
    staging = Path(tempfile.mkdtemp(prefix="baseline-"))
    try:
        temporary = staging / "picture"
        result = run("curl", "--fail", "--silent", "--proto", "=https", "--max-time", "90",
                     "--max-filesize", str(PICTURE_BYTES), "-A", "baseline-looks/1", "-o", str(temporary), url)
        if not result or result.returncode or not temporary.is_file():
            return False
        if out("file", "--brief", "--mime-type", str(temporary)) not in {"image/jpeg", "image/png", "image/webp"}:
            return False
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(temporary), target)
        return True
    finally:
        shutil.rmtree(staging, ignore_errors=True)


def catalog_add(settings, catalog_id, with_pictures=True):
    """Add (or update) a look from the catalog. Its palette is re-written
    here and its window files generated here: nothing from the catalog runs."""
    if not catalog_refresh():
        sys.exit("The catalog can't be reached.")
    folder = CATALOG_CACHE / "looks" / catalog_id
    if not re.fullmatch(r"[a-z0-9-]{1,32}", catalog_id) or not folder.is_dir():
        sys.exit("No such look in the catalog.")
    try:
        meta, colours, pictures, mode = validate_shared(folder)
    except (ValueError, OSError, UnicodeDecodeError) as error:
        sys.exit(f"That look didn't pass the checks: {error}")
    look_id = SHARED_PREFIX + catalog_id
    dest = COMMUNITY_DIR / catalog_id
    had = look_id in look_ids()
    (dest / "backgrounds").mkdir(parents=True, exist_ok=True)
    order = 1000 + len([i for i in look_ids() if i.startswith(SHARED_PREFIX)])
    old = read_json(dest / "look.json", {})
    write_atomic(dest / "look.json", json.dumps({"name": meta["name"], "tagline": meta["tagline"],
                                                 "author": meta["author"], "order": old.get("order", order),
                                                 "catalog": {"id": catalog_id, "version": meta["version"]}},
                                                indent=2) + "\n")
    lines = [f'mode = "{mode}"', "", f"# {meta['name']}: from the Baseline looks catalog.", ""]
    lines += [f'{k} = "{colours[k]}"' for k in LOOK_KEYS]
    lines += ["", f'hyprland_active_border = "rgba({colours["accent"][1:]}ee) rgba({colours["cyan"][1:]}ee) 45deg"',
              f'hyprland_inactive_border = "rgba({colours["lighter_background"][1:]}aa)"', ""]
    write_atomic(dest / "colors.toml", "\n".join(lines))
    got = []
    if with_pictures:
        entries = []
        for n, picture in enumerate(pictures, 1):
            name = f"{n}-{look_slug(picture['title'] or 'picture')}{Path(picture['image']).suffix.lower()}"
            if (dest / "backgrounds" / name).is_file() or fetch_picture(picture["image"], dest / "backgrounds" / name):
                got.append(name)
                entries.append({"file": name, **picture})
        write_atomic(dest / "pictures.json", json.dumps(entries, indent=2) + "\n")
    build_look(look_id)
    install_looks()
    catalog_installed(settings)[catalog_id] = {"version": meta["version"], "pictures": bool(with_pictures)}
    if not had or not get_picks(settings, look_id)["day"]:
        ids = [f"{look_id}/{n}" for n in got]
        set_picks(settings, look_id, {"day": ids, "night": list(ids)})
    save(settings)
    print(json.dumps({"lookId": look_id, "pictures": len(got), "of": len(pictures) if with_pictures else 0}))
    return look_id


def catalog_remove(settings, catalog_id):
    look_id = SHARED_PREFIX + catalog_id
    if look_id == settings["look"]:
        set_look(settings, "afterlight")
        settings = load()
    info = look_info(look_id)
    for slug in info["slugs"].values():
        link = THEMES / slug
        if link.is_symlink():
            link.unlink()
    if info["dir"].is_dir() and info["dir"].is_relative_to(COMMUNITY_DIR):
        shutil.rmtree(info["dir"])
    catalog_installed(settings).pop(catalog_id, None)
    settings.get("lookWallpapers", {}).pop(look_id, None)
    save(settings)


def share_preview(settings, look_id, author=""):
    """Exactly what Share would publish for a look: nothing leaves the machine."""
    if look_id not in look_ids() or look_id.startswith(SHARED_PREFIX):
        sys.exit("Only your own looks (and the built-in ones) can be shared.")
    info = look_info(look_id)
    day = read_colors(info["dir"] / "colors.toml")
    catalog_id = "afterlight" if look_id == "afterlight" else look_slug(info["name"])
    published = None
    if catalog_refresh():
        try:
            published = validate_shared(CATALOG_CACHE / "looks" / catalog_id)[0]
        except (ValueError, OSError, UnicodeDecodeError):
            published = None
    pictures = []
    for item_id, entry in picture_sources(look_id).items():
        item = {"id": item_id, "title": clean_text(Path(item_id).stem.split("-", 1)[-1].replace("-", " "), 60),
                "page": entry.get("page", ""), "image": entry.get("image", ""), "credit": entry.get("credit", ""),
                "source": entry.get("source", "")}
        item["ok"], item["reason"] = shareable(item)
        pictures.append(item)
    unknown = [p for p in by_id() if p.startswith(f"{look_id}/") and p not in picture_sources(look_id)]
    return {"lookId": look_id, "id": catalog_id, "name": info["name"], "tagline": info["tagline"],
            "author": clean_text(author or settings.get("catalog", {}).get("author", ""), 40),
            "version": (published["version"] + 1) if published else 1, "update": bool(published),
            "colours": {k: day[k] for k in LOOK_KEYS if k in day},
            "pictures": pictures, "withoutSource": len(unknown), "catalog": CATALOG_URL}


def share_look(settings, look_id, author, include):
    """Open a pull request adding (or updating) the look in the catalog.
    Commits carry your GitHub no-reply address, never your own email."""
    preview = share_preview(settings, look_id, author)
    author = preview["author"]
    if not re.fullmatch(r"[A-Za-z0-9 _.-]{2,40}", author or ""):
        sys.exit("Pick an author name (letters, numbers, spaces, . _ -).")
    settings.setdefault("catalog", {})["author"] = author
    save(settings)
    login = out("gh", "api", "user", "-q", ".login").strip()
    user_id = out("gh", "api", "user", "-q", ".id").strip()
    if not login:
        sys.exit("Sign in to GitHub first: gh auth login")
    pictures = [{k: p[k] for k in ("title", "page", "image", "credit", "source")}
                for p in preview["pictures"] if p["ok"] and p["id"] in include][:MAX_PICTURES]
    package = {"look.json": json.dumps({"format": CATALOG_FORMAT, "id": preview["id"], "name": preview["name"],
                                        "tagline": preview["tagline"], "author": author,
                                        "version": preview["version"]}, indent=2) + "\n",
               "colors.toml": "\n".join(['mode = "dark"', ""] + [f'{k} = "{v}"' for k, v in preview["colours"].items()]) + "\n"}
    if pictures:
        package["pictures.json"] = json.dumps(pictures, indent=2) + "\n"
    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp) / "catalog"
        # Check the package passes the same checks everyone's install does.
        check = Path(tmp) / "check" / preview["id"]
        check.mkdir(parents=True)
        for name, text in package.items():
            (check / name).write_text(text)
        validate_shared(check)
        if run("gh", "repo", "clone", CATALOG_REPO, str(work), "--", "-q", "--depth", "1").returncode:
            sys.exit("Couldn't fetch the catalog.")
        can_push = out("gh", "api", f"repos/{CATALOG_REPO}", "-q", ".permissions.push").strip() == "true"
        remote = "origin"
        if not can_push:
            run("gh", "repo", "fork", CATALOG_REPO, "--clone=false")
            run("git", "-C", str(work), "remote", "add", "fork", f"https://github.com/{login}/{CATALOG_REPO.split('/')[1]}.git")
            remote = "fork"
        branch = f"look/{preview['id']}-v{preview['version']}"
        run("git", "-C", str(work), "checkout", "-q", "-b", branch)
        target = work / "looks" / preview["id"]
        if target.exists():
            shutil.rmtree(target)
        target.mkdir(parents=True)
        for name, text in package.items():
            (target / name).write_text(text)
        run("git", "-C", str(work), "add", "-A")
        email = f"{user_id}+{login}@users.noreply.github.com"
        verb = "Update" if preview["update"] else "Add"
        run("git", "-C", str(work), "-c", f"user.name={author}", "-c", f"user.email={email}",
            "commit", "-q", "-m", f"{verb} look: {preview['name']} (v{preview['version']})")
        pushed = run("git", "-C", str(work), "push", "-q", remote, branch)
        if not pushed or pushed.returncode:
            sys.exit("Couldn't push: " + ((pushed.stderr or "").strip()[:200] if pushed else ""))
        body = (f"**{preview['name']}**: {preview['tagline']}\n\nBy {author}. "
                f"{len(pictures)} picture link(s), palette only otherwise.\n\n"
                "- [x] Palette made by the author\n- [x] Pictures are links to their original pages, with credit\n"
                "- [x] No stock photos, no personal details\n\nOpened from Baseline Studio.")
        head = branch if can_push else f"{login}:{branch}"
        result = run("gh", "pr", "create", "--repo", CATALOG_REPO, "--head", head, "--base", "main",
                     "--title", f"{verb} look: {preview['name']}", "--body", body)
    url = (result.stdout or "").strip().splitlines()[-1] if result and result.returncode == 0 else ""
    if not url:
        sys.exit("The pull request didn't open: " + ((result.stderr or "").strip()[:200] if result else ""))
    print(json.dumps({"url": url}))
    return url


# ---------------------------------------------------------------- updates to Baseline itself

OMARELAY_POINTER = HOME / ".local/share/omarelay/source-checkout"


def omarelay_dir():
    try:
        path = Path(OMARELAY_POINTER.read_text().strip())
        return path if (path / "install.py").is_file() else None
    except OSError:
        return None


def updates_state(fetch=False):
    """How far each checkout is behind GitHub. Fetches at most every 6 hours."""
    repos = {"baseline": REPO, "omarelay": omarelay_dir()}
    found = {}
    for name, path in repos.items():
        if not path or not (path / ".git").exists():
            continue
        marker = path / ".git/FETCH_HEAD"
        if fetch and (not marker.exists() or time.time() - marker.stat().st_mtime > 6 * 3600):
            run("timeout", "20", "git", "-C", str(path), "fetch", "-q")
        behind = out("git", "-C", str(path), "rev-list", "--count", "HEAD..@{u}").strip()
        found[name] = int(behind) if behind.isdigit() else 0
    return {"behind": found, "total": sum(found.values())}


def update_all(settings):
    """Pull Baseline and OmaRelay, reinstall OmaRelay, repair, restart the shell."""
    lines = []
    for name, path in (("Baseline", REPO), ("OmaRelay", omarelay_dir())):
        if not path:
            continue
        result = run("git", "-C", str(path), "pull", "-q", "--ff-only")
        lines.append(f"{name}: " + ("up to date" if result and result.returncode == 0
                                    else "has its own changes, not updated"))
    if omarelay_dir():
        run("python3", str(omarelay_dir() / "install.py"))
    result = health_run(load(), fix=True)
    subprocess.Popen(["omarchy", "restart", "shell"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                     start_new_session=True)
    print("\n".join(lines + [f"{len(result['checks']) - result['failing']} of {len(result['checks'])} parts in place"]))


# ---------------------------------------------------------------- T3 Code

T3_MARK_START, T3_MARK_END = "/* afterlight neon */", "/* afterlight neon end */"


def t3_neon(theme):
    """After Omarchy writes T3 Code's "omarchy" theme from the palette, add a
    neon layer in an Afterlight look's colours (marked, so it's replaced, not
    stacked): an accent-to-cyan rule under the chat header, a glow round the
    composer while typing, accent edges on your messages and the selected
    thread. Other themes get the plain Omarchy theme back."""
    target = HOME / ".t3/userdata/themes/omarchy.json"
    if not target.is_file():
        return
    data = json.loads(target.read_text())
    css = re.sub(re.escape(T3_MARK_START) + r".*?" + re.escape(T3_MARK_END) + r"\n?", "", data.get("css", ""), flags=re.S)

    def rgba(hexa, alpha):
        r, g, b = (int(hexa[i:i + 2], 16) for i in (1, 3, 5))
        return f"rgba({r}, {g}, {b}, {alpha})"
    if theme.lower().startswith("afterlight"):
        colours = read_colors(STATE_HOME / "omarchy/current/theme/colors.toml")
        accent, cyan = colours.get("accent"), colours.get("cyan")
        if accent and cyan:
            css += f"""{T3_MARK_START}
[data-chat-header] {{ border-bottom: 1px solid transparent !important;
  border-image: linear-gradient(90deg, {rgba(accent, 0.75)}, {rgba(cyan, 0.15)}) 1 !important; }}
[data-slot="composer-host"] {{ border-color: {rgba(accent, 0.35)} !important;
  transition: box-shadow 180ms ease-out, border-color 180ms ease-out; }}
[data-slot="composer-host"]:focus-within {{ border-color: {rgba(accent, 0.8)} !important;
  box-shadow: 0 0 0 1px {rgba(accent, 0.35)}, 0 0 22px {rgba(accent, 0.18)}, 0 0 48px {rgba(cyan, 0.08)} !important; }}
[data-user-message-bubble] {{ box-shadow: inset 2px 0 0 {rgba(accent, 0.85)} !important; }}
[data-thread-item][data-active="true"], [data-thread-item][aria-current="page"] {{ box-shadow: inset 2px 0 0 {accent} !important; }}
[data-slot="scroll-area-thumb"], ::-webkit-scrollbar-thumb {{ background: {rgba(accent, 0.35)} !important; }}
{T3_MARK_END}
"""
    if css != data.get("css", ""):
        data["css"] = css
        write_atomic(target, json.dumps(data, indent=2) + "\n")


# ---------------------------------------------------------------- terminal prompt

PROMPT_MARK_START, PROMPT_MARK_END = "# baseline palette", "# baseline palette end"


def prompt_palette():
    """Point starship's prompt at the current theme: the folder and the prompt
    mark in its accent, git in its highlight, a failed command in its red.
    Starship reads its config at every prompt, so open terminals follow at once."""
    target = CONFIG / "starship.toml"
    path = STATE_HOME / "omarchy/current/theme/colors.toml"
    if not target.is_file() or not path.is_file():
        return
    colours = read_colors(path)
    text = re.sub(r"\n*" + re.escape(PROMPT_MARK_START) + r".*?" + re.escape(PROMPT_MARK_END) + r"\n?", "\n", target.read_text(), flags=re.S)
    if re.search(r'^palette\s*=', text, flags=re.M):
        text = re.sub(r'^palette\s*=.*$', 'palette = "baseline"', text, count=1, flags=re.M)
    else:
        text = 'palette = "baseline"\n' + text
    block = [PROMPT_MARK_START, "[palettes.baseline]"]
    for name, key in (("accent", "accent"), ("highlight", "cyan"), ("alert", "red"), ("dim", "muted")):
        block.append(f'{name} = "{colours.get(key, "#ffffff")}"')
    text = text.rstrip("\n") + "\n\n" + "\n".join(block) + "\n" + PROMPT_MARK_END + "\n"
    if text != target.read_text():
        write_atomic(target, text)


# ---------------------------------------------------------------- state for the panel

def palette(mode, look_id=None):
    """The colours a mode is drawn in, read from its colors.toml."""
    base = look_info(look_id)["dir"] if look_id else LOOK_DIR
    folder = base / MODE_FOLDERS[mode] if MODE_FOLDERS[mode] else base
    colours = {}
    try:
        for line in (folder / "colors.toml").read_text().splitlines():
            key, _, value = line.partition("=")
            value = value.strip().strip('"')
            if key.strip() in {"background", "foreground", "accent", "cyan", "red", "lighter_background", "muted",
                                  "magenta", "blue", "selection"} \
                    and value.startswith("#") and len(value) == 7:
                colours[key.strip()] = value
    except OSError:
        pass
    return colours


def panel_state(settings):
    # The panel shows this look's pictures: its own, ones you added, and
    # any it has picked from other looks.
    chosen = set(settings["wallpapers"]["day"]) | set(settings["wallpapers"]["night"])
    items = [i for i in library() if i["id"].split("/", 1)[0] in {settings["look"], "extra"} or i["id"] in chosen]
    for item in items:
        item["thumb"] = thumbnail(item)
        item["day"] = item["id"] in settings["wallpapers"]["day"]
        item["night"] = item["id"] in settings["wallpapers"]["night"]
    now = current_background()
    current_id = ""
    for item in items:
        if item["path"] == now or (item["night"] and str(NIGHT_DIR / night_name(item["id"])) == now):
            current_id = item["id"]
    return {
        "mode": current_mode(),
        "period": period_now(settings),
        "onBattery": on_battery(),
        "saverManual": bool(load_state().get("saverManual")),
        "settings": settings,
        "wallpapers": items,
        "currentWallpaper": current_id,
        "extraFolder": str(SOURCES["extra"]),
        "bar": out("omarchy-bar", "background") or "opaque",
        "recent": recent_files(),
        "palettes": {mode: palette(mode) for mode in SLUGS},
        "look": settings["look"],
        "looks": looks_state(),
        "beatportGenres": [{"name": g["name"], "path": g["path"]} for g in BEATPORT_GENRES],
    }


# ---------------------------------------------------------------- setting changes

def set_path(settings, dotted, value):
    keys = dotted.split(".")
    node = settings
    defaults = DEFAULTS
    for key in keys[:-1]:
        if key not in node or not isinstance(node[key], dict):
            sys.exit(f"Unknown setting: {dotted}")
        node, defaults = node[key], defaults.get(key, {})
    leaf = keys[-1]
    if leaf not in defaults:
        sys.exit(f"Unknown setting: {dotted}")
    expected = defaults[leaf]
    if isinstance(expected, bool):
        if not isinstance(value, bool):
            sys.exit(f"{dotted} takes true or false")
    elif isinstance(expected, (int, float)):
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            sys.exit(f"{dotted} takes a number")
        low, high = LIMITS.get(leaf, (value, value))
        value = max(low, min(high, value))
    elif isinstance(expected, str):
        if not isinstance(value, str):
            sys.exit(f"{dotted} takes text")
        if leaf in {"day", "night"} and keys[0] == "schedule":
            try:
                hours, mins = value.split(":")
                value = f"{int(hours) % 24:02d}:{int(mins) % 60:02d}"
            except ValueError:
                sys.exit(f"{dotted} takes a time like 07:00")
        if keys == ["music", "service"] and value not in {"ytmusic", "applemusic"}:
            sys.exit("music.service is ytmusic or applemusic")
        if keys == ["look"]:
            sys.exit("Change the look with: afterlight look set <id>")
        if keys[0] == "ui" and value not in {"system", "player", "status", "wallpapers", "theme", "setup"}:
            sys.exit("ui.tab takes system, player, status, wallpapers, theme or setup")
        if keys[0] == "mouse" and leaf in MOUSE_ZONES:
            if value not in MOUSE_COLOURS:
                sys.exit(f"{dotted} takes one of: {', '.join(MOUSE_COLOURS)}")
        elif keys[0] == "mouse":
            if value not in MOUSE_ACTIONS:
                sys.exit(f"{dotted} takes one of: {', '.join(MOUSE_ACTIONS)}")
            if leaf in TILTS and MOUSE_ACTIONS[value][1]:
                sys.exit(f"{dotted} is a tilt: it takes a tap action, not a hold")
        if leaf == "wallpaper" and value not in {"black", "night"}:
            sys.exit("tweaks.saver.wallpaper takes black or night")
    node[leaf] = value
    return keys


def apply_change(settings, keys):
    group = keys[0]
    if group == "tweaks":
        if write_tweaks(settings):
            reload_hyprland()
        leaf = keys[-1]
        mode = current_mode()
        if leaf in {"wallpaperBrightness", "wallpaper"}:
            sync_wallpapers(settings)
            if mode in {"night", "saver"}:
                wallpaper_next(settings, shuffle=True)
        elif mode == "saver" and keys[1] == "saver":
            enter_saver(settings)
        elif mode == "night" and keys[1] == "night" and leaf == "warmth":
            apply_warmth(settings, "night")
    elif group == "mouse":
        if keys[-1] == "lighting" or keys[-1] in MOUSE_ZONES or keys[-1] == "strength" \
                or keys[-1].startswith("brightness"):
            mouse_light(settings)
        elif write_mouse(settings):
            run("hyprctl", "reload")
    elif group == "schedule":
        write_timer(settings)
        run("systemctl", "--user", "enable" if settings["schedule"]["auto"] else "disable",
            "--now", "afterlight-mode.timer")


def toggle_wallpaper(settings, item_id, period):
    if period not in {"day", "night"}:
        sys.exit("toggle takes day or night")
    if item_id not in by_id():
        sys.exit(f"Unknown wallpaper: {item_id}")
    chosen = settings["wallpapers"][period]
    if item_id in chosen:
        chosen.remove(item_id)
    else:
        chosen.append(item_id)
    save(settings)
    if period == "night":
        sync_wallpapers(settings)


# ---------------------------------------------------------------- audio

def audio_outputs():
    """Every playback device, which one is default, and whether its jack or
    link reports something connected."""
    try:
        sinks = json.loads(subprocess.run(["pactl", "-f", "json", "list", "sinks"], capture_output=True,
                                          text=True, timeout=4, check=True).stdout)
        default = subprocess.run(["pactl", "get-default-sink"], capture_output=True, text=True,
                                 timeout=4).stdout.strip()
    except (OSError, ValueError, subprocess.SubprocessError):
        return {"outputs": [], "default": None}
    outputs = []
    for sink in sinks:
        props = sink.get("properties", {})
        if props.get("node.virtual") == "true" or sink["name"].endswith(".monitor"):
            continue
        ports = sink.get("ports", [])
        active = next((port for port in ports if port.get("name") == sink.get("active_port")), ports[0] if ports else {})
        text = " ".join([sink["name"], sink.get("description", ""), props.get("device.icon_name", ""),
                         active.get("type", ""), active.get("name", "")]).lower()
        bus = props.get("device.bus", "")
        kind = ("bluetooth" if bus == "bluetooth" else "headphones" if "headphone" in text or "headset" in text
                else "speaker" if "speaker" in text else "usb" if bus == "usb" else "hdmi" if "hdmi" in text
                else "other")
        label = re.sub(r"^Built-in Audio\s+", "", sink.get("description", sink["name"]))
        label = re.sub(r"\s+playback$", "", label, flags=re.I) or sink["name"]
        volume = None
        try:
            volume = round(int(next(iter(sink["volume"].values()))["value_percent"].rstrip("%")))
        except (KeyError, StopIteration, ValueError, AttributeError):
            pass
        outputs.append({
            "name": sink["name"], "label": label, "kind": kind,
            "connected": active.get("availability") != "not available",
            "default": sink["name"] == default, "volume": volume, "muted": bool(sink.get("mute")),
        })
    order = {"speaker": 0, "headphones": 1, "bluetooth": 2, "usb": 3, "hdmi": 4, "other": 5}
    outputs.sort(key=lambda o: order.get(o["kind"], 9))
    return {"outputs": outputs, "default": default}


def audio_use(name):
    known = {o["name"] for o in audio_outputs()["outputs"]}
    if name not in known:
        sys.exit("That output isn't there any more.")
    run("pactl", "set-default-sink", name)
    # Move whatever is already playing, so the switch is heard straight away.
    try:
        inputs = json.loads(subprocess.run(["pactl", "-f", "json", "list", "sink-inputs"], capture_output=True,
                                           text=True, timeout=4, check=True).stdout)
    except (OSError, ValueError, subprocess.SubprocessError):
        inputs = []
    for stream in inputs:
        subprocess.run(["pactl", "move-sink-input", str(stream["index"]), name], capture_output=True, timeout=4)
    where_toast()


def where_toast():
    """After switching where sound goes: "Playing on Headphones", with the
    laptop's song and cover, in the bar's music popup. Quiet when nothing plays."""
    track = laptop_track()
    if not track or not track["playing"]:
        return
    output = next((o for o in audio_outputs()["outputs"] if o["default"]), None)
    if output:
        toast(f"Playing on {output['label']}", f"{track['title']} · {track['artist']}", art=track["art"],
              glyph="󰓃")


# ---------------------------------------------------------------- Sonos, on the home network

# Sonos speakers answer on the local network (UPnP, port 1400): rooms, group
# volume, mute, play/pause/skip and what's playing, in a fraction of a second,
# with no account and no internet. Picking Sonos in the Player tab makes the
# volume slider, mute and the volume keys drive the chosen room; the laptop's
# own sound stays where it is. Needs "UPnP" left on in the Sonos app
# (Account > Privacy & Security). Playing something by name goes through the
# Grok agent instead (OmaRelay: "play ... on Sonos").
SONOS_CACHE = STATE.parent / "sonos.json"
SONOS_TARGET = STATE.parent / "sonos-target"      # present while Sonos has the volume keys
SONOS_ART = HOME / ".cache/afterlight/sonos-art"
SONOS_PORT = 1400
SONOS_STEP = 5
_UPNP = {
    "AVTransport": "/MediaRenderer/AVTransport/Control",
    "RenderingControl": "/MediaRenderer/RenderingControl/Control",
    "GroupRenderingControl": "/MediaRenderer/GroupRenderingControl/Control",
    "ZoneGroupTopology": "/ZoneGroupTopology/Control",
    "ContentDirectory": "/MediaServer/ContentDirectory/Control",
}
SONOS_SERVICE = "Apple Music"      # the service Grok's Sonos tools play laptop music from
SONOS_GROK_TIMEOUT = 150


def sonos_private(ip):
    """Only ever talk to addresses on the local network."""
    import ipaddress
    try:
        address = ipaddress.ip_address(ip)
    except ValueError:
        return False
    return address.is_private and not address.is_loopback


def sonos_call(ip, service, action, args=None, timeout=2.5):
    """One UPnP action on one speaker; the reply's fields as a dict, or None."""
    import urllib.request
    import xml.etree.ElementTree as ET
    from xml.sax.saxutils import escape
    if not sonos_private(ip):
        return None
    body = "".join(f"<{k}>{escape(str(v))}</{k}>" for k, v in (args or {}).items())
    urn = f"urn:schemas-upnp-org:service:{service}:1"
    envelope = ('<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
                's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>'
                f'<u:{action} xmlns:u="{urn}">{body}</u:{action}></s:Body></s:Envelope>')
    request = urllib.request.Request(f"http://{ip}:{SONOS_PORT}{_UPNP[service]}", data=envelope.encode(),
                                     headers={"Content-Type": 'text/xml; charset="utf-8"',
                                              "SOAPACTION": f'"{urn}#{action}"'})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as reply:
            root = ET.fromstring(reply.read(512 * 1024))
    except (OSError, ET.ParseError, ValueError):
        return None
    response = next((el for el in root.iter() if el.tag.endswith(f"{action}Response")), None)
    return {child.tag.split("}")[-1]: (child.text or "") for child in response} if response is not None else None


def sonos_discover(timeout=4):
    """Speakers' addresses, from the system's own discovery service (Avahi,
    mDNS), which a firewall leaves alone. Sonos announce _sonos._tcp."""
    out = quiet_out("avahi-browse", "-rtp", "_sonos._tcp", timeout=timeout)
    found = {line.split(";")[7] for line in out.splitlines()
             if line.startswith("=") and len(line.split(";")) > 8 and line.split(";")[2] == "IPv4"}
    return sorted(ip for ip in found if sonos_private(ip))


def sonos_room_name(name):
    """'Kitchen - Sonos' reads as 'Kitchen'; extra spaces go."""
    name = re.sub(r"\s+-\s+Sonos$", "", re.sub(r"\s+", " ", str(name or "")).strip())
    return clean_text(name, 40) or "Sonos"


def sonos_parse_groups(xml_text):
    """Rooms from a GetZoneGroupState reply: one per group, named by its
    visible members, led by its coordinator."""
    import html as htmlmod
    import xml.etree.ElementTree as ET
    try:
        root = ET.fromstring(htmlmod.unescape(xml_text) if xml_text.lstrip().startswith("&lt;") else xml_text)
    except ET.ParseError:
        return []
    rooms = []
    for group in root.iter("ZoneGroup"):
        members = [m for m in group.findall("ZoneGroupMember") if m.get("Invisible") != "1"]
        coordinator = next((m for m in group.findall("ZoneGroupMember") if m.get("UUID") == group.get("Coordinator")), None)
        if coordinator is None or not members:
            continue
        ip = re.sub(r"^https?://([^:/]+).*$", r"\1", coordinator.get("Location", ""))
        if not sonos_private(ip):
            continue
        names = list(dict.fromkeys(sonos_room_name(m.get("ZoneName")) for m in members))
        # Each speaker of the group on its own too (rooms join and leave groups).
        speakers = []
        for m in members:
            at = re.sub(r"^https?://([^:/]+).*$", r"\1", m.get("Location", ""))
            if sonos_private(at) and re.fullmatch(r"RINCON_[0-9A-Fa-f]{12}\d{5}", m.get("UUID", "")):
                speakers.append({"id": m.get("UUID"), "name": sonos_room_name(m.get("ZoneName")), "ip": at})
        rooms.append({"id": group.get("Coordinator"), "name": " + ".join(names), "ip": ip,
                      "members": names, "speakers": speakers})
    rooms.sort(key=lambda r: r["name"].lower())
    return rooms


def sonos_rooms(refresh=False):
    """The rooms right now, from any speaker we know (found again when none answer)."""
    cache = read_json(SONOS_CACHE, {})
    known = [ip for ip in cache.get("speakers", []) if sonos_private(ip)]
    tries = [lambda: known, sonos_discover] if known and not refresh else [sonos_discover]
    for find in tries:      # the search only runs if no known speaker answers
        ips = find()
        for ip in ips[:6]:
            reply = sonos_call(ip, "ZoneGroupTopology", "GetZoneGroupState")
            rooms = sonos_parse_groups(reply.get("ZoneGroupState", "")) if reply else []
            if rooms:
                # Remember the speakers, and the room names for OmaRelay to hand
                # Grok (kept up to date: rewritten when they change, or daily).
                speakers = sorted({r["ip"] for r in rooms} | set(ips))[:32]
                names = sorted({m for r in rooms for m in r["members"]})[:40]
                if speakers != known or names != cache.get("rooms") or time.time() - cache.get("updated", 0) > 86400:
                    write_atomic(SONOS_CACHE, json.dumps({"speakers": speakers, "rooms": names,
                                                          "updated": int(time.time())}) + "\n")
                return rooms
    return []


def sonos_parse_track(meta_xml, uri=""):
    """Title, artist, album and art from a track's DIDL metadata. TV and
    line-in say so."""
    import xml.etree.ElementTree as ET
    track = {"title": "", "artist": "", "album": "", "art": ""}
    if uri.startswith("x-sonos-htastream:"):
        track["title"] = "TV"
        return track
    if uri.startswith("x-rincon-stream:"):
        track["title"] = "Line-in"
        return track
    if not meta_xml or meta_xml == "NOT_IMPLEMENTED":
        return track
    try:
        root = ET.fromstring(meta_xml)
    except ET.ParseError:
        return track
    def find(name):
        el = next((e for e in root.iter() if e.tag.split("}")[-1] == name), None)
        return (el.text or "").strip() if el is not None else ""
    stream = find("streamContent")      # radio: "Artist - Title"
    track.update(title=clean_text(find("title"), 120), artist=clean_text(find("creator") or find("albumArtist"), 120),
                 album=clean_text(find("album"), 120), art=find("albumArtURI"))
    if stream and not track["artist"]:
        artist, _, title = stream.partition(" - ")
        track.update(artist=clean_text(artist, 120), title=clean_text(title or stream, 120))
    return track


def sonos_art(ip, art):
    """Cache a cover the speaker serves (/getaa?...) and return its path.
    Covers elsewhere on the internet aren't fetched."""
    import urllib.request
    if not art.startswith("/getaa?") or not sonos_private(ip):
        return ""
    target = SONOS_ART / (hashlib.sha256(art.encode()).hexdigest()[:24] + ".jpg")
    if target.is_file():
        return str(target)
    try:
        with urllib.request.urlopen(f"http://{ip}:{SONOS_PORT}{art}", timeout=3) as reply:
            kind = reply.headers.get("Content-Type", "")
            data = reply.read(3 * 1024 * 1024 + 1)
    except OSError:
        return ""
    if len(data) > 3 * 1024 * 1024 or not kind.startswith("image/"):
        return ""
    SONOS_ART.mkdir(parents=True, exist_ok=True)
    old = sorted(SONOS_ART.glob("*.jpg"), key=lambda p: p.stat().st_mtime)
    for stale in old[:-40]:
        stale.unlink(missing_ok=True)
    target.write_bytes(data)
    return str(target)


def sonos_room(settings, rooms):
    wanted = (settings.get("sonos") or {}).get("room", "")
    return next((r for r in rooms if r["id"] == wanted), None)


def sonos_now(room):
    """What the room is doing: playing state, track, volume, mute."""
    ip = room["ip"]
    transport = sonos_call(ip, "AVTransport", "GetTransportInfo", {"InstanceID": 0}) or {}
    position = sonos_call(ip, "AVTransport", "GetPositionInfo", {"InstanceID": 0}) or {}
    volume = sonos_call(ip, "GroupRenderingControl", "GetGroupVolume", {"InstanceID": 0}) or {}
    mute = sonos_call(ip, "GroupRenderingControl", "GetGroupMute", {"InstanceID": 0}) or {}
    track = sonos_parse_track(position.get("TrackMetaData", ""), position.get("TrackURI", ""))
    track["art"] = sonos_art(ip, track["art"]) if track["art"] else ""
    state = transport.get("CurrentTransportState", "")
    try:
        level = max(0, min(100, int(volume.get("CurrentVolume", ""))))
    except ValueError:
        level = None
    return {"playing": state in {"PLAYING", "TRANSITIONING"}, "state": state.lower(), "track": track,
            "volume": level, "muted": mute.get("CurrentMute") == "1",
            "canSkip": not track["title"] in {"TV", "Line-in"}}


def sonos_state(settings):
    """For the Player tab: rooms, which one is picked, and what it's doing."""
    rooms = sonos_rooms()
    picked = sonos_room(settings, rooms)
    on = bool((settings.get("sonos") or {}).get("on")) and picked is not None
    return {"available": bool(rooms), "on": on,
            "rooms": [{"id": r["id"], "name": r["name"]} for r in rooms],
            "room": {"id": picked["id"], "name": picked["name"], **sonos_now(picked)} if picked else None}


def sonos_set_target(settings, on):
    settings.setdefault("sonos", {})["on"] = bool(on)
    save(settings)
    if on:
        write_atomic(SONOS_TARGET, settings["sonos"].get("room", "") + "\n")
    else:
        SONOS_TARGET.unlink(missing_ok=True)


def sonos_use(settings, room_id):
    rooms = sonos_rooms()
    room = next((r for r in rooms if r["id"] == room_id), None)
    if room is None:
        sys.exit("That Sonos room isn't there.")
    settings.setdefault("sonos", {})["room"] = room_id
    sonos_set_target(settings, True)
    deck_follow(room_id)            # the Deck plays where Baseline points
    # Say what the room is playing, with its cover.
    now = sonos_now(room)
    track = now["track"]
    if now["playing"] and track["title"]:
        toast(f"Playing in {room['name']}", " · ".join(x for x in (track["title"], track["artist"]) if x),
              art=track["art"])
    else:
        toast(room["name"], "Nothing playing here: the volume keys now follow this room")


def sonos_volume(settings, value, osd=False):
    """Set ('30'), nudge ('+5', '-5', 'raise', 'lower') or mute ('mute-toggle')
    the picked room's group volume."""
    room = sonos_room(settings, sonos_rooms())
    if room is None:
        sys.exit("No Sonos room picked.")
    ip = room["ip"]
    def failed():
        if osd:
            run("omarchy-osd", "-i", "volume-muted", "-m", f"{room['name']} isn't answering")
        sys.exit("That Sonos room didn't answer.")
    if value == "mute-toggle":
        reply = sonos_call(ip, "GroupRenderingControl", "GetGroupMute", {"InstanceID": 0})
        if reply is None:
            failed()
        muted = reply.get("CurrentMute") == "1"
        sonos_call(ip, "GroupRenderingControl", "SetGroupMute", {"InstanceID": 0, "DesiredMute": 0 if muted else 1})
        if osd:
            run("omarchy-osd", "-i", "volume-muted" if not muted else "volume", "-m", f"{room['name']} · " +
                ("muted" if not muted else "sound on"))
        return
    step = {"raise": f"+{SONOS_STEP}", "lower": f"-{SONOS_STEP}"}.get(value, value)
    if not re.fullmatch(r"[+-]?\d{1,3}", step):
        sys.exit("Volume is 0-100, or +N / -N.")
    sonos_call(ip, "GroupRenderingControl", "SnapshotGroupVolume", {"InstanceID": 0})
    if step[0] in "+-":
        reply = sonos_call(ip, "GroupRenderingControl", "SetRelativeGroupVolume", {"InstanceID": 0, "Adjustment": int(step)})
        if reply is None:
            failed()
        level = int(reply.get("NewVolume", "0") or 0)
    else:
        level = max(0, min(100, int(step)))
        if sonos_call(ip, "GroupRenderingControl", "SetGroupVolume", {"InstanceID": 0, "DesiredVolume": level}) is None:
            failed()
    if osd:
        run("omarchy-osd", "-i", "volume", "-p", str(level), "-m", room["name"])


def sonos_transport(settings, action):
    room = sonos_room(settings, sonos_rooms())
    if room is None:
        sys.exit("No Sonos room picked.")
    ip = room["ip"]
    if action == "toggle":
        state = (sonos_call(ip, "AVTransport", "GetTransportInfo", {"InstanceID": 0}) or {}).get("CurrentTransportState")
        action = "pause" if state in {"PLAYING", "TRANSITIONING"} else "play"
    args = {"InstanceID": 0, **({"Speed": 1} if action == "play" else {})}
    name = {"play": "Play", "pause": "Pause", "next": "Next", "previous": "Previous"}[action]
    if sonos_call(ip, "AVTransport", name, args) is None:
        sys.exit("Sonos didn't take that (nothing to skip on TV or line-in).")


# Music messages (Sonos sending, playing, or not) show in the bar's music
# popup near the top of the screen, beside the track popups, rather than as
# notifications: the bar watches this file.
TOAST = STATE.parent / "toast.json"


def toast(title, detail="", art="", glyph="󰜟"):
    art = f"file://{art}" if art and Path(art).is_file() else ""
    write_atomic(TOAST, json.dumps({"title": clean_text(title, 120), "detail": clean_text(detail, 160),
                                    "art": art, "glyph": glyph[:2], "at": time.time()}) + "\n")


# Send to Sonos: the laptop's song carries on in a room. Sonos can't play a
# browser tab, so Grok's Sonos tools find the same album on Apple Music and
# start it there; then Baseline, over the home network, jumps to the same
# song and second and pauses the laptop. The laptop keeps playing until the
# room has started, so there's no gap.

def laptop_track():
    """What the laptop plays (MPRIS): title, artist, album, position in
    seconds, and the player's bus name. Playing players first."""
    found = []
    for line in quiet_out("busctl", "--user", "list", "--no-legend").splitlines():
        name = line.split()[0] if line.strip() else ""
        if not name.startswith("org.mpris.MediaPlayer2."):
            continue
        def prop(p):
            try:
                return json.loads(quiet_out("busctl", "--user", "get-property", "--json=short", name,
                                            "/org/mpris/MediaPlayer2", "org.mpris.MediaPlayer2.Player", p)).get("data")
            except ValueError:
                return None
        meta = prop("Metadata") or {}
        title = (meta.get("xesam:title") or {}).get("data", "")
        if not title:
            continue
        artists = (meta.get("xesam:artist") or {}).get("data", [])
        position = prop("Position")
        art = str((meta.get("mpris:artUrl") or {}).get("data", ""))
        found.append({"title": clean_text(title, 120), "art": art[7:] if art.startswith("file:///") else "",
                      "artist": clean_text(", ".join(artists) if isinstance(artists, list) else str(artists), 120),
                      "album": clean_text((meta.get("xesam:album") or {}).get("data", ""), 120),
                      "position": int(position) // 1_000_000 if isinstance(position, int) else 0,
                      "length": int((meta.get("mpris:length") or {}).get("data", 0) or 0) // 1_000_000,
                      "playing": prop("PlaybackStatus") == "Playing", "player": name})
    found.sort(key=lambda t: not t["playing"])
    return found[0] if found else None


def song_key(title):
    """A title made comparable across services: no "(feat. …)", "- Remastered",
    brackets or punctuation."""
    title = re.sub(r"\s*[(\[][^)\]]*[)\]]", "", title.lower())
    title = re.sub(r"\s+-\s+.*$", "", title)
    return re.sub(r"[^\w]+", " ", title).strip()


def sonos_queue(ip, limit=200):
    """Titles in the room's queue, in order."""
    import xml.etree.ElementTree as ET
    reply = sonos_call(ip, "ContentDirectory", "Browse", {
        "ObjectID": "Q:0", "BrowseFlag": "BrowseDirectChildren", "Filter": "dc:title",
        "StartingIndex": 0, "RequestedCount": limit, "SortCriteria": ""}, timeout=4) or {}
    try:
        root = ET.fromstring(reply.get("Result") or "<x/>")
    except ET.ParseError:
        return []
    return [(next((c.text or "" for c in item if c.tag.endswith("}title")), ""))
            for item in root if item.tag.endswith("}item")]


def hms(seconds):
    seconds = max(0, int(seconds))
    return f"{seconds // 3600}:{seconds // 60 % 60:02d}:{seconds % 60:02d}"


def grok_has_sonos():
    import tomllib
    config = Path(os.environ.get("GROK_HOME") or HOME / ".grok") / "config.toml"
    try:
        entry = tomllib.loads(config.read_text()).get("mcp_servers", {}).get("sonos")
    except (OSError, tomllib.TOMLDecodeError):
        return False
    return isinstance(entry, dict) and entry.get("enabled", True) is not False


def sonos_send_brief(track, room_name):
    said = lambda s: s.replace("«", "").replace("»", "")[:120]
    album = f' from the album «{said(track["album"])}»' if track["album"] else ""
    return f"""You control the user's Sonos speakers with the sonos tools, and nothing else.

Start the song «{said(track["title"])}» by «{said(track["artist"])}»{album} in the Sonos room «{said(room_name)}», using music_service "{SONOS_SERVICE}".

- Look up the room's group first.
- Best: play that album, so the songs after it follow (another program will skip to the right song). If the album can't be found, play the song itself.
- Don't change the volume or grouping, and don't use any other music service.
- Don't ask questions: nobody can answer.

Reply with one short line, under 90 characters, saying what you started, or why it couldn't be done."""


def sonos_find_room(rooms, said):
    """A room by id, or by name said loosely ("the kitchen", "lounge sonos"):
    the whole name first, then a room whose name holds every word said."""
    match = next((r for r in rooms if r["id"] == said), None)
    if match:
        return match
    plain = lambda text: re.sub(r"[^\w]+", " ", text.lower()).split()
    words = [w for w in plain(said) if w not in {"the", "my", "room", "sonos", "speaker", "speakers"}]
    if not words:
        return None
    for room in rooms:
        if [w for w in plain(room["name"]) if w != "room"] == words:
            return room
    hits = [r for r in rooms if set(words) <= set(plain(r["name"]))]
    return min(hits, key=lambda r: len(r["name"])) if hits else None


def sonos_send(settings, room_id=""):
    """Carry the laptop's song on in a room (the picked one by default).
    Takes as long as Grok does (15-45 s); says how it went in a notification."""
    def done(headline, detail="", failed=False, art=""):
        toast(headline, detail, art=art, glyph="󰀦" if failed else "󰜟")
        if failed:
            sys.exit(f"{headline}: {detail}")
    rooms = sonos_rooms()
    room = sonos_find_room(rooms, room_id) if room_id else sonos_room(settings, rooms)
    if room is None:
        done("Send to Sonos", f"No Sonos room called {room_id[:40]}" if room_id else "Pick a Sonos room first", failed=True)
    track = laptop_track()
    if track is None:
        done("Send to Sonos", "Nothing is playing on the laptop", failed=True)
    if not shutil.which("grok") or not grok_has_sonos():
        done("Send to Sonos", "Needs the Grok agent with Sonos set up (see the README's Sonos section)", failed=True)
    toast(f"Sending to {room['name']}…", f"{track['title']} · {track['artist']}, finding it on {SONOS_SERVICE}",
          art=track["art"])
    started = time.time()
    workdir = STATE.parent / "sonos-grok"
    workdir.mkdir(parents=True, exist_ok=True)
    try:
        result = subprocess.run(["grok", "-p", sonos_send_brief(track, room["name"]), "--allow", "MCPTool(sonos__*)",
                                 "--deny", "Bash", "--deny", "Edit", "--deny", "Write", "--deny", "WebFetch",
                                 "--deny", "WebSearch", "--max-turns", "24", "--no-auto-update"],
                                cwd=workdir, capture_output=True, text=True, timeout=SONOS_GROK_TIMEOUT,
                                stdin=subprocess.DEVNULL)
        lines = [line.strip() for line in result.stdout.splitlines() if line.strip()]
        answer = re.sub(r"[`*_#>]", "", lines[-1])[:120] if lines else ""
    except subprocess.TimeoutExpired:
        done("Send to Sonos", "Sonos took too long to answer", failed=True)
    except OSError:
        done("Send to Sonos", "Couldn't start the Grok agent", failed=True)
    ip = room["ip"]
    # Wait for the room to start, then find the laptop's song in its queue.
    for _ in range(20):
        if (sonos_call(ip, "AVTransport", "GetTransportInfo", {"InstanceID": 0}) or {}).get(
                "CurrentTransportState") == "PLAYING":
            break
        time.sleep(0.5)
    else:
        done("Sonos didn't play", answer or "Grok couldn't start it", failed=True)
    wanted = song_key(track["title"])
    queue = sonos_queue(ip)
    number = next((i + 1 for i, title in enumerate(queue) if song_key(title) == wanted), None)
    if number is None:
        now = sonos_now(room)["track"]
        if song_key(now["title"]) != wanted:
            done(f"Playing in {room['name']}", f"{answer or now['title']} (not the same song: "
                 f"{track['title']} wasn't on {SONOS_SERVICE})")
            return
    elif int((sonos_call(ip, "AVTransport", "GetPositionInfo", {"InstanceID": 0}) or {}).get("Track") or 0) != number:
        sonos_call(ip, "AVTransport", "Seek", {"InstanceID": 0, "Unit": "TRACK_NR", "Target": number})
    # The laptop has kept playing meanwhile: take its second now, then pause it.
    latest = laptop_track()
    if latest and latest["player"] == track["player"] and song_key(latest["title"]) == wanted:
        second = latest["position"]
    else:
        second = track["position"] + (int(time.time() - started) if track["playing"] else 0)
    if media_command("pause") != "tab":
        quiet_out("busctl", "--user", "call", track["player"], "/org/mpris/MediaPlayer2",
                  "org.mpris.MediaPlayer2.Player", "Pause")
    if second > 2:
        sonos_call(ip, "AVTransport", "Seek", {"InstanceID": 0, "Unit": "REL_TIME", "Target": hms(second + 1)})
    done(f"Playing in {room['name']}", f"{track['title']} · {track['artist']}, from {hms(second)[2:] if second < 3600 else hms(second)}"
         f" ({SONOS_SERVICE})", art=sonos_now(room)["track"].get("art", "") or track["art"])


def quiet_out(*argv, timeout=4):
    try:
        return subprocess.run(argv, capture_output=True, text=True, timeout=timeout).stdout
    except (OSError, subprocess.SubprocessError):
        return ""


SPEAKER_TUNING = REPO / "plugin/mortalfish.baseline/tuning/speaker.py"


def sound_extras():
    """Mic and speaker tuning, beside the outputs."""
    mic = quiet_out("wpctl", "get-volume", "@DEFAULT_AUDIO_SOURCE@")
    tuning = {"available": False, "tuned": False}
    if SPEAKER_TUNING.exists():
        try:
            tuning = json.loads(quiet_out("python3", str(SPEAKER_TUNING), "status", timeout=6))
        except ValueError:
            pass
    return {"mic": {"present": mic.startswith("Volume:"), "muted": "MUTED" in mic},
            "tuning": {"available": bool(tuning.get("available")), "tuned": bool(tuning.get("tuned"))}}


def quick_state():
    """Wi-Fi, Bluetooth, do not disturb and stay awake, for the System tab."""
    wifi = {"on": quiet_out("nmcli", "radio", "wifi").strip() == "enabled", "ssid": "", "signal": None}
    for line in quiet_out("nmcli", "-t", "-f", "IN-USE,SIGNAL,SSID", "dev", "wifi", "list", "--rescan", "no").splitlines():
        if line.startswith("*:"):
            _, signal, ssid = line.split(":", 2)
            wifi.update(ssid=ssid.replace("\\:", ":"), signal=int(signal) if signal.isdigit() else None)
            break
    bt_on = quiet_out("omarchy-bluetooth-power", "is-on").strip() == "on"
    devices = [line.split(" ", 2)[2] for line in quiet_out("bluetoothctl", "devices", "Connected").splitlines()
               if line.startswith("Device ") and line.count(" ") >= 2] if bt_on else []
    return {"wifi": wifi, "bluetooth": {"on": bt_on, "devices": devices},
            "dnd": quiet_out("omarchy-shell", "notifications", "isDnd").strip() == "on",
            "awake": (Path.home() / ".local/state/omarchy/indicators/stay-awake").exists(),
            "focus": "focus" in load_state()}


def wifi_list():
    on = quiet_out("nmcli", "radio", "wifi").strip() == "enabled"
    known = {line.rsplit(":", 1)[0].replace("\\:", ":") for line in
             quiet_out("nmcli", "-t", "-f", "NAME,TYPE", "con", "show").splitlines()
             if line.endswith(":802-11-wireless")}
    nets = {}
    if on:
        for line in quiet_out("nmcli", "-t", "-f", "IN-USE,SIGNAL,SECURITY,SSID", "dev", "wifi", "list",
                              "--rescan", "no").splitlines():
            parts = re.split(r"(?<!\\):", line, maxsplit=3)
            if len(parts) != 4 or not parts[3]:
                continue
            use, signal, security, ssid = parts
            ssid = ssid.replace("\\:", ":")
            signal = int(signal) if signal.isdigit() else 0
            net = nets.setdefault(ssid, {"ssid": ssid, "signal": 0, "secure": False, "known": ssid in known,
                                         "active": False})
            net["signal"] = max(net["signal"], signal)
            net["secure"] = net["secure"] or security not in {"", "--"}
            net["active"] = net["active"] or use == "*"
    order = sorted(nets.values(), key=lambda n: (not n["active"], not n["known"], -n["signal"]))
    return {"on": on, "networks": order[:12]}


def wifi_command(args):
    action = args[0] if args else "list"
    if action == "list":
        print(json.dumps(wifi_list()))
    elif action == "scan":
        quiet_out("nmcli", "dev", "wifi", "rescan", timeout=10)
        print(json.dumps(wifi_list()))
    elif action == "power" and len(args) == 2 and args[1] in {"on", "off"}:
        run("nmcli", "radio", "wifi", args[1])
    elif action == "connect" and len(args) == 2:
        ssid = args[1]
        if ssid in {n["ssid"] for n in wifi_list()["networks"] if n["known"]}:
            result = subprocess.run(["nmcli", "con", "up", "id", ssid], capture_output=True, text=True, timeout=40)
        else:
            # A password, if any, arrives on stdin so it never shows in the process list.
            password = sys.stdin.read().strip() if not sys.stdin.isatty() else ""
            result = subprocess.run(["nmcli", "--ask", "dev", "wifi", "connect", ssid],
                                    input=(password + "\n") if password else "", capture_output=True,
                                    text=True, timeout=40)
        if result.returncode != 0:
            sys.exit((result.stderr or result.stdout).strip().splitlines()[-1] if (result.stderr or result.stdout).strip()
                     else "Couldn't connect.")
    elif action == "disconnect":
        for line in quiet_out("nmcli", "-t", "-f", "DEVICE,TYPE", "dev").splitlines():
            if line.endswith(":wifi"):
                run("nmcli", "dev", "disconnect", line.split(":")[0])
    else:
        sys.exit("Usage: afterlight wifi [list|scan|power on|off|connect <ssid>|disconnect]")


def bt_list():
    on = quiet_out("omarchy-bluetooth-power", "is-on").strip() == "on"
    def devices(*which):
        found = {}
        for line in quiet_out("bluetoothctl", "devices", *which).splitlines():
            bits = line.split(" ", 2)
            if len(bits) == 3 and bits[0] == "Device":
                found[bits[1]] = bits[2]
        return found
    every, paired, connected = devices(), devices("Paired"), devices("Connected") if on else {}
    rows = [{"address": a, "name": n, "paired": a in paired, "connected": a in connected}
            for a, n in every.items()
            # Unpaired devices only when they have a proper name (scan noise otherwise).
            if a in paired or not re.fullmatch(r"([0-9A-F]{2}-){5}[0-9A-F]{2}", n)]
    rows.sort(key=lambda d: (not d["connected"], not d["paired"], d["name"].lower()))
    return {"on": on, "devices": rows[:12]}


def bt_command(args):
    action = args[0] if args else "list"
    if action == "list":
        print(json.dumps(bt_list()))
    elif action == "scan":
        quiet_out("bluetoothctl", "--timeout", "8", "scan", "on", timeout=12)
        print(json.dumps(bt_list()))
    else:
        sys.exit("Usage: afterlight bt [list|scan]")


def audio_swap():
    """Move to the next output (Speaker -> Headphones -> ...), with an OSD."""
    outputs = audio_outputs()["outputs"]
    if len(outputs) < 2:
        return
    index = next((i for i, o in enumerate(outputs) if o["default"]), -1)
    target = outputs[(index + 1) % len(outputs)]
    audio_use(target["name"])
    # Omarchy's OSD knows a few icon names; anything else is drawn as given, so glyphs.
    icon = {"headphones": "󰋋", "bluetooth": "󰂯", "speaker": "volume-high"}.get(target["kind"], "volume")
    run("omarchy-osd", "-i", icon, "-m", target["label"])


# ---------------------------------------------------------------- liked tracks

LIKED = STATE.parent / "liked.json"
LIKED_ART = STATE.parent / "liked-art"


def playing_track():
    """Title, artist, album and cover of what's playing (MPRIS), or None."""
    best = None
    for line in quiet_out("busctl", "--user", "list", "--no-legend").splitlines():
        name = line.split()[0] if line.strip() else ""
        if not name.startswith("org.mpris.MediaPlayer2."):
            continue
        def prop(p):
            try:
                return json.loads(quiet_out("busctl", "--user", "get-property", "--json=short", name,
                                            "/org/mpris/MediaPlayer2", "org.mpris.MediaPlayer2.Player", p)).get("data")
            except ValueError:
                return None
        meta = prop("Metadata") or {}
        title = (meta.get("xesam:title") or {}).get("data", "")
        if not title:
            continue
        artists = (meta.get("xesam:artist") or {}).get("data", [])
        track = {"title": title, "artist": ", ".join(artists) if isinstance(artists, list) else str(artists),
                 "album": (meta.get("xesam:album") or {}).get("data", ""),
                 "art": (meta.get("mpris:artUrl") or {}).get("data", "")}
        if prop("PlaybackStatus") == "Playing":
            return track
        best = best or track
    return best


def track_key(track):
    return hashlib.sha1(f"{track['title'].lower()}|{track['artist'].lower()}".encode()).hexdigest()[:12]


def liked_list():
    try:
        value = json.loads(LIKED.read_text())
        return value if isinstance(value, list) else []
    except (OSError, ValueError):
        return []


def like_current():
    track = playing_track()
    if not track:
        run("omarchy-osd", "-i", "󰋑", "-m", "Nothing playing")
        sys.exit("Nothing is playing.")
    items = liked_list()
    key = track_key(track)
    if any(i["id"] == key for i in items):
        run("omarchy-osd", "-i", "󰋑", "-m", "Already liked")
        return
    art = ""
    source = track["art"][7:] if track["art"].startswith("file://") else ""
    if source and Path(source).is_file():
        LIKED_ART.mkdir(parents=True, exist_ok=True)
        art = str(LIKED_ART / f"{key}.jpg")
        shutil.copy(source, art)
    # Beatport playing: put it straight into <3. Anything else (or Beatport
    # not answering) stays on the list for adding by hand.
    added = beatport_is_playing(track["title"]) and beatport_add_playing("<3")
    items.insert(0, {"id": key, "title": track["title"], "artist": track["artist"], "album": track["album"],
                     "art": art, "at": datetime.datetime.now().isoformat(timespec="minutes"), "added": bool(added)})
    write_atomic(LIKED, json.dumps(items, indent=2) + "\n")
    run("omarchy-osd", "-i", "󰋑", "-m", f"♥ {track['title']}" + ("  → <3" if added else ""))
    if not added and beatport_bridge({"type": "tabs"}, timeout=3) is not None:
        # Liked on YouTube or YouTube Music: look for it on Beatport and add it
        # from a background tab. Stays on the list if it isn't found.
        try:
            like_add(key)
        except SystemExit:
            pass


def beatport_is_playing(title):
    """Is this title the one in Beatport's player bar (not YouTube's)?"""
    reply = beatport_bridge({"type": "page", "op": {"type": "probe", "region": "bar", "filter": "^Go to track page"}}, timeout=4)
    base = spoken(re.sub(r"\s*\([^)]*\)\s*$", "", title))
    for item in (reply or {}).get("items", []):
        if base and spoken(item.get("label", "")).startswith("go to track page " + base):
            return True
    return False


def media_playing():
    try:
        return bool(json.loads(quiet_out("omarchy-shell", "media", "status") or "{}").get("playing"))
    except ValueError:
        return False


def beatport_player_playing():
    """Is Beatport itself playing (its player bar shows Pause)? Something
    else (YouTube Music) playing doesn't count."""
    reply = beatport_bridge({"type": "page", "op": {"type": "probe", "region": "bar", "filter": "^Pause$"}}, timeout=3) or {}
    return any(i.get("label") == "Pause" for i in reply.get("items", []))


def beatport_press_play(url, wait=20, first=False):
    """Once the Beatport tab shows url, press the page's Play button (the
    chart's or playlist's, data-testid play-button) and check music started.
    Presses again only while nothing plays, so it never pauses by mistake."""
    target = url.split("#")[0].split("?")[0].rstrip("/")
    deadline = time.time() + wait
    time.sleep(1.5)   # let the old page go
    while time.time() < deadline:
        reply = beatport_bridge({"type": "page", "op": {"type": "probe", "region": "page", "filter": "^play-button$"}}, timeout=3) or {}
        here = str(reply.get("url", "")).split("#")[0].split("?")[0].rstrip("/")
        if here == target and any(i.get("testid") == "play-button" for i in reply.get("items", [])):
            if beatport_player_playing():
                return True
            beatport_bridge({"type": "page", "op": {"type": "click", "testid": "^play-button$", "region": "page",
                                                    **({"first": True} if first else {})}}, timeout=3)
            for _ in range(8):
                time.sleep(0.5)
                if beatport_player_playing():
                    return True
        else:
            time.sleep(0.5)
    return False


def beatport_resume():
    """Start Beatport playing when there's nothing to resume (after a reboot,
    or a page change): press the player bar's Play, else the page's own Play,
    else start the last chart or playlist again. True when something started."""
    for op in ({"type": "click", "label": "^Play$", "region": "bar", "wait": 800},
               {"type": "click", "testid": "^play-button$", "region": "page", "wait": 800}):
        if (beatport_bridge({"type": "page", "op": op}, timeout=4) or {}).get("ok"):
            return True
    music_last = load_state().get("musicLast") or {}
    if music_last.get("service") == "ytmusic" and isinstance(music_last.get("item"), dict):
        ytm_play(music_last["item"])
        return True
    last = load_state().get("beatportLast")
    if last and BEATPORT_URL.match(last):
        beatport_open(last, play=True)
        return True
    return False


def media_command(action):
    """Play, pause, next or previous in the tab you were listening to
    (Beatport, YouTube Music or YouTube), through the browser add-on, which
    knows which tab that was; the system's media keys go to whichever tab
    Chrome last picked. With nothing to resume, play starts the last chart,
    playlist or search result again. True when it worked."""
    reply = beatport_bridge({"type": "media", "action": action}, timeout=5)
    if reply and reply.get("ok"):
        return "tab"
    if action == "play" and beatport_resume():
        return "restarted"
    return ""


def beatport_add_playing(playlist="<3"):
    """Add the track in Beatport's player bar to one of your playlists, the
    way you would: Add to playlist, tick the playlist, Add to Playlist.
    True when every step was pressed."""
    row = "^" + re.escape(playlist) + r"(\s|$)"
    reply = beatport_bridge({"type": "page", "op": {"type": "steps", "steps": [
        # The player bar's button (it has a label); a chart's own button,
        # which would add the whole chart, has none.
        {"testid": "^add-to-playlist-button$", "label": "^Add to playlist$", "region": "bar", "wait": 1500},
        # The dialog's tick box: no words of its own, on the playlist's row.
        # (The sidebar's "<3" link has words, so it can't be picked by mistake.)
        {"row": row, "text": "^$", "label": "^$", "region": "page", "wait": 4000, "pause": 400},
        {"text": "^Add to Playlist$", "region": "any", "wait": 3000},
    ]}}, timeout=15)
    if reply and reply.get("ok"):
        return True
    # Leave nothing half-open.
    beatport_bridge({"type": "page", "op": {"type": "click", "text": "^Cancel$", "wait": 500}}, timeout=3)
    return False


# ---- Liked elsewhere (YouTube, YouTube Music) → found on Beatport → <3

NOISE = re.compile(r"\s*[\(\[](?:official|lyric|lyrics|audio|video|visuali[sz]er|hd|hq|4k|music video|"
                   r"official (?:music )?video|official audio|out now|free download|premiere)[^\)\]]*[\)\]]", re.I)


def track_query(item):
    """(artist, title, mix) from a liked item, undoing YouTube's habits:
    "Artist - Title (Official Video)", channels called "Artist - Topic" or "ArtistVEVO"."""
    title, artist = item["title"], item.get("artist", "")
    artist = re.sub(r"\s*-\s*Topic$|VEVO$", "", artist).strip()
    title = NOISE.sub("", title).strip()
    if " - " in title:   # YouTube's "Artist - Title"
        left, right = title.split(" - ", 1)
        artist, title = left.strip(), right.strip()
    mix = ""
    m = re.search(r"\s*\(([^)]*(?:mix|edit|remix|version|dub|rework|vip)[^)]*)\)\s*$", title, re.I)
    if m:
        mix, title = m.group(1).strip(), title[:m.start()].strip()
    title = re.sub(r"\s*[\(\[](?:ft\.?|feat\.?|featuring|with)\s[^\)\]]*[\)\]]", "", title, flags=re.I)
    title = re.sub(r"\s+(?:ft\.?|feat\.?|featuring)\s+.*$", "", title, flags=re.I).strip()
    return artist, title, mix


def beatport_find(item):
    """The Beatport track a liked item most likely is: {id, name, mix, artists}, or None."""
    from difflib import SequenceMatcher
    import urllib.parse
    artist, title, mix = track_query(item)
    reply = beatport_bridge({"type": "fetch", "url": "https://www.beatport.com/search/tracks?q="
                             + urllib.parse.quote(f"{artist} {title}".strip())}, timeout=20)
    m = re.search(r'<script id="__NEXT_DATA__"[^>]*>(.*?)</script>', (reply or {}).get("text", ""), re.S)
    if not m:
        return None
    try:
        queries = json.loads(m.group(1))["props"]["pageProps"]["dehydratedState"]["queries"]
        tracks = next(q["state"]["data"]["data"] for q in queries if q["queryKey"][0] == "search-tracks")
    except (ValueError, KeyError, StopIteration, TypeError):
        return None
    best, best_score = None, 0
    for t in tracks[:40]:
        name = spoken(t.get("track_name", ""))
        names = spoken(" ".join(a.get("artist_name", "") for a in t.get("artists", [])))
        title_score = SequenceMatcher(None, spoken(title), name).ratio()
        artist_score = SequenceMatcher(None, spoken(artist), names).ratio() if artist else 0.5
        if artist and spoken(artist).split()[0] in names.split():
            artist_score = max(artist_score, 0.8)
        # The mix named, or with none named the original rather than a remix.
        mix_name = spoken(t.get("mix_name", ""))
        mix_score = (0.1 if spoken(mix) == mix_name else 0) if mix else \
            (0.1 if mix_name in {"original mix", "extended mix", "extended", "original"} else 0)
        score = title_score * 0.6 + artist_score * 0.4 + mix_score
        if title_score >= 0.75 and artist_score >= 0.5 and score > best_score:
            best, best_score = t, score
    if not best:
        return None
    return {"id": best["track_id"], "name": best["track_name"], "mix": best.get("mix_name", ""),
            "artists": ", ".join(a["artist_name"] for a in best.get("artists", [])),
            "bpm": best.get("bpm") if isinstance(best.get("bpm"), (int, float)) else 0,
            "key": str(best.get("key_name") or "")[:20],
            "length": round(best["length"] / 1000) if isinstance(best.get("length"), int) else 0}


def beatport_add_track(track_id, playlist="<3"):
    """Add a Beatport track to a playlist from its own page, in a background
    tab, so the player is left alone. True when every step was pressed."""
    url = f"https://www.beatport.com/track/t/{int(track_id)}"
    row = "^" + re.escape(playlist) + r"(\s|$)"
    reply = beatport_bridge({"type": "scratch", "url": url, "op": {"type": "steps", "steps": [
        # The track's own button (no label), not the player bar's.
        {"testid": "^add-to-playlist-button$", "label": "^$", "region": "page", "wait": 6000},
        {"row": row, "text": "^$", "label": "^$", "region": "page", "wait": 5000, "pause": 400},
        # The dialog's own button: its words are unique, and in a short
        # background tab it can sit where the player bar would be.
        {"text": "^Add to Playlist$", "region": "any", "wait": 3000, "pause": 1500},
    ]}}, timeout=45)
    beatport_bridge({"type": "scratch-close"}, timeout=5)
    return bool(reply and reply.get("ok"))


def like_add(key):
    """Find a liked track on Beatport and add it to <3. Prints what happened."""
    items = liked_list()
    item = next((i for i in items if i["id"] == key), None)
    if not item:
        sys.exit("No liked track with that id.")
    found = beatport_find(item)
    if not found:
        run("omarchy-osd", "-i", "󰀦", "-m", f"Couldn't find {item['title'][:40]} on Beatport")
        sys.exit("Not found on Beatport.")
    if not beatport_add_track(found["id"]):
        run("omarchy-osd", "-i", "󰀦", "-m", "Found it, but couldn't add it to <3")
        sys.exit("Couldn't add it.")
    item["added"] = True
    item["beatport"] = found["id"]
    write_atomic(LIKED, json.dumps(items, indent=2) + "\n")
    run("omarchy-osd", "-i", "󰋑", "-m", f"♥ {found['name']} → <3")
    print(f"Added {found['artists']} – {found['name']} ({found['mix']}) to <3")


def like_update(key, action):
    items = liked_list()
    if action == "remove":
        for i in items:
            if i["id"] == key and i.get("art"):
                Path(i["art"]).unlink(missing_ok=True)
        items = [i for i in items if i["id"] != key]
    else:
        for i in items:
            if i["id"] == key:
                i["added"] = action == "added"
    write_atomic(LIKED, json.dumps(items, indent=2) + "\n")


# ---------------------------------------------------------------- beatport

BEATPORT_APP = "jopilafkghibglefecikcmpaoolnpcjg"
BEATPORT_CLASS = f"chrome-{BEATPORT_APP}-Default"
BEATPORT_URL = re.compile(r"^https://(www\.)?beatport\.com/[A-Za-z0-9_./?=&%+-]*$")


# Genre Top 100 charts: Baseline's chips and spoken "play … top 100". Checked
# against beatport.com on 2026-11-26 (afterlight beatport check).
BEATPORT_GENRES = [
    {"name": "All genres", "path": "top-100", "say": ["all", "everything", "beatport", "overall"]},
    {"name": "House", "path": "genre/house/5/top-100", "say": []},
    {"name": "Funky House", "path": "genre/funky-groove-jackin-house/81/top-100", "say": ["funky", "groove", "funky groove"]},
    {"name": "Jackin House", "path": "genre/jackin-house/97/top-100", "say": ["jacking house", "jackin", "jacking"]},
    {"name": "Nu Disco", "path": "genre/nu-disco-disco/50/top-100", "say": ["new disco", "disco", "nudisco"]},
    {"name": "Deep House", "path": "genre/deep-house/12/top-100", "say": ["deep"]},
    {"name": "Tech House", "path": "genre/tech-house/11/top-100", "say": ["tech"]},
    {"name": "Afro House", "path": "genre/afro-house/89/top-100", "say": ["afro"]},
    {"name": "Melodic H&T", "path": "genre/melodic-house-techno/90/top-100", "say": ["melodic", "melodic house", "melodic techno", "melodic house and techno"]},
    {"name": "Indie Dance", "path": "genre/indie-dance/37/top-100", "say": ["indie"]},
    {"name": "Organic House", "path": "genre/organic-house/93/top-100", "say": ["organic", "downtempo"]},
    {"name": "Progressive", "path": "genre/progressive-house/15/top-100", "say": ["progressive house", "prog"]},
    {"name": "Techno", "path": "genre/techno-peak-time-driving/6/top-100", "say": ["peak time techno", "techno peak time"]},
    {"name": "Drum & Bass", "path": "genre/drum-bass/1/top-100", "say": ["drum and bass", "dnb", "d and b", "drum n bass", "jungle"]},
    {"name": "UK Garage", "path": "genre/uk-garage-bassline/86/top-100", "say": ["garage", "ukg", "bassline", "uk garage bassline"]},
]
BEATPORT_STATE = STATE.parent / "beatport.json"
# Ways to say the playlist called "<3".
HEART_WORDS = ["heart", "hearts", "love", "love heart", "less than three", "favourites", "favorites"]


def beatport_playlists(settings):
    """Library playlists the extension reported, then your pinned links."""
    known = read_json(BEATPORT_STATE, {}).get("playlists", [])
    return [p for p in known if isinstance(p, dict)] + list(settings["beatport"]["pins"])


def spoken(text):
    text = text.lower().replace("&", " and ").replace("<3", " heart ")
    return " ".join(re.sub(r"[^a-z0-9 ]+", " ", text).split())


def beatport_say(settings, words):
    """Play what someone asked for by name: "nu disco top 100", "my heart
    playlist", "funky practice". Prints what it chose."""
    from difflib import SequenceMatcher
    said = spoken(words)
    said = re.sub(r"^(?:please |can you |could you )?(?:play|put on|start|listen to)\s+", "", said)
    wants_chart = bool(re.search(r"\b(?:top (?:100|one hundred|hundred)|chart|charts)\b", said))
    wants_list = bool(re.search(r"\bplay ?lists?\b", said))
    target = re.sub(r"\b(?:the|my|a|some|on beatport|beatport s|from|top (?:100|one hundred|hundred)|chart|charts"
                    r"|play ?lists?|music|tracks|please|now)\b", " ", said)
    target = " ".join(target.split())
    def likeness(names):
        if not target:
            return 0
        best = 0
        for n in names:
            if not n:
                continue
            best = max(best, SequenceMatcher(None, target, n).ratio())
            # Every word said is in the name: "liked tracks" for "Liked Tracks (djay)".
            if set(target.split()) <= set(n.split()):
                best = max(best, 0.85)
        return best

    choices = []   # (score, label, url)
    if not wants_chart:
        for p in beatport_playlists(settings):
            names = [spoken(p["name"])] + (HEART_WORDS if p["name"].strip() == "<3" else [])
            choices.append((likeness(names) + (0.05 if wants_list else 0), p["name"], p["url"]))
    if not wants_list:
        for g in BEATPORT_GENRES:
            names = [spoken(g["name"])] + g["say"]
            best = likeness(names) if target else (1 if wants_chart and g["path"] == "top-100" else 0)
            choices.append((best, g["name"] + " Top 100", "https://www.beatport.com/" + g["path"]))
    choices.sort(reverse=True)
    if AM_SAID.search(words):
        return am_say(words)
    if re.search(r"\b(?:youtube music|yt music|you tube music|on youtube)\b", words, re.I):
        return ytm_say(words)
    if not choices or choices[0][0] < 0.6:
        # Not a Beatport chart or playlist: an artist, song or album, so look
        # on your music service (YouTube Music unless set to Apple Music).
        if (settings.get("music") or {}).get("service") == "applemusic":
            return am_say(words)
        return ytm_say(words)
    _, label, url = choices[0]
    beatport_open(url, play=True)
    run("omarchy-osd", "-i", "media-play", "-m", f"Playing {label}")
    print(f"Playing {label}")


def beatport_windows():
    try:
        clients = json.loads(out("hyprctl", "clients", "-j"))
    except ValueError:
        return []
    return [c["address"] for c in clients if c.get("class") == BEATPORT_CLASS]


BEATPORT_SOCK = Path(os.environ.get("XDG_RUNTIME_DIR") or "/tmp") / "afterlight-beatport.sock"


def beatport_bridge(request, timeout=5):
    """Send one request to the Baseline for Beatport extension through its
    native host (repo chrome/native). Returns the extension's reply, or None
    when the bridge is down (Chrome closed, extension off)."""
    import socket
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
            conn.settimeout(timeout + 3)
            conn.connect(str(BEATPORT_SOCK))
            conn.sendall((json.dumps({**request, "timeout": timeout}) + "\n").encode())
            reply = json.loads(conn.makefile().readline() or "null")
    except (OSError, ValueError):
        return None
    return reply if isinstance(reply, dict) else None


def addon_wanted():
    return str(read_json(REPO / "chrome/beatport-baseline/manifest.json", {}).get("version", ""))


def addon_version():
    """The version of the add-on running in Chrome: "" when it's too old to
    say, None when Chrome or the add-on isn't running."""
    reply = beatport_bridge({"type": "version"}, timeout=2)
    if reply is None:
        return None
    return str(reply.get("version") or "")


def addon_reload():
    """Ask the add-on to reload itself, so a pulled update takes; True when
    it's then on the repo's version."""
    if not (beatport_bridge({"type": "reload"}, timeout=2) or {}).get("ok"):
        return False
    for _ in range(20):
        time.sleep(0.5)
        if addon_version() == addon_wanted():
            return True
    return False


def beatport_open(url, play=False):
    """Open a Beatport page in the Beatport app; the new window replaces the
    old one, so there's only ever one player. With play, the Baseline for
    Beatport extension (repo chrome/) presses the page's Play button. When
    the extension's bridge is up, the page loads in place instead."""
    if not BEATPORT_URL.match(url):
        sys.exit("Not a Beatport link.")
    if play:
        # Remember it, so a bare "play" can start it again later.
        state = load_state()
        state["beatportLast"] = url.split("#")[0]
        state["musicLast"] = {"service": "beatport", "url": url.split("#")[0]}
        save_state(state)
    # Load it in the Beatport tab that's already open, so nothing moves, then
    # press that page's own Play once it has loaded.
    reply = beatport_bridge({"type": "open", "url": url, "play": False})
    if (reply or {}).get("inPlace"):
        if play and not beatport_press_play(url):
            run("omarchy-osd", "-i", "󰀦", "-m", "Opened in Beatport, but couldn't press Play")
        return
    if reply is None and beatport_windows():
        # Beatport is open but the add-on isn't answering (Chrome dropped it once after a reboot).
        run("omarchy-osd", "-i", "󰀦", "-d", "4000",
            "-m", "Beatport add-on isn't running: reload it in chrome://extensions")
    if play:
        url = url.split("#")[0] + "#baseline-play"
    before = set(beatport_windows())
    subprocess.Popen(["/opt/google/chrome/google-chrome", "--profile-directory=Default", f"--app-id={BEATPORT_APP}",
                      f"--app-launch-url-for-shortcuts-menu-item={url}"],
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    for _ in range(40):
        time.sleep(0.25)
        new = [a for a in beatport_windows() if a not in before]
        if new:
            for address in before:
                run("hyprctl", "dispatch", f'hl.dsp.window.close({{ window = "address:{address}" }})')
            run("hyprctl", "dispatch", f'hl.dsp.focus({{ window = "address:{new[0]}" }})')
            return
    run("hyprctl", "dispatch", 'hl.dsp.focus({ workspace = "6" })')


def beatport_pin_clipboard(settings):
    url = out("wl-paste", "--no-newline").strip()
    if not BEATPORT_URL.match(url):
        run("omarchy-osd", "-i", "󰀦", "-m", "Copy a Beatport link first")
        sys.exit("The clipboard doesn't hold a Beatport link.")
    pins = settings["beatport"]["pins"]
    if any(p["url"] == url for p in pins):
        return
    parts = [p for p in url.split("?")[0].split("/") if p and not p.isdigit()]
    name = parts[-1].replace("-", " ").title() if len(parts) > 2 else "Beatport"
    pins.append({"name": name[:40], "url": url})
    save(settings)
    run("omarchy-osd", "-i", "󰋑", "-m", f"Pinned {name[:40]}")


# ---------------------------------------------------------------- youtube music

YTM = "https://music.youtube.com"
YTM_CLASS = "chrome-music.youtube.com__-Default"
YTM_STATE = STATE.parent / "ytmusic.json"
YTM_ID = re.compile(r"^[A-Za-z0-9_-]{2,64}$")
YTM_KINDS = {"MUSIC_PAGE_TYPE_ARTIST": "artist", "MUSIC_PAGE_TYPE_ALBUM": "album",
             "MUSIC_PAGE_TYPE_PLAYLIST": "playlist", "MUSIC_PAGE_TYPE_AUDIOBOOK": "album"}


def ytm_call(endpoint, body):
    """YouTube Music's own web API, signed out (search needs no account)."""
    import urllib.request
    payload = {"context": {"client": {"clientName": "WEB_REMIX", "clientVersion": "1.20261118.01.00",
                                      "hl": "en", "gl": "GB"}}, **body}
    request = urllib.request.Request(f"{YTM}/youtubei/v1/{endpoint}?prettyPrint=false",
                                     data=json.dumps(payload).encode(),
                                     headers={"Content-Type": "application/json", "Origin": YTM,
                                              "Referer": YTM + "/", "User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(request, timeout=12) as response:
        return json.loads(response.read(4_000_000))


def _runs(obj):
    return "".join(r.get("text", "") for r in (obj or {}).get("runs", []))


def _find(obj, key):
    stack = [obj]
    while stack:
        o = stack.pop(0)
        if isinstance(o, dict):
            if key in o:
                return o[key]
            stack.extend(o.values())
        elif isinstance(o, list):
            stack.extend(o)
    return None


def _ytm_item(r, top=False):
    if top:
        title, subtitle = _runs(r.get("title")), _runs(r.get("subtitle"))
        nav = (r.get("title", {}).get("runs") or [{}])[0].get("navigationEndpoint") or {}
    else:
        cols = r.get("flexColumns", [])
        col = lambda n: _runs(cols[n]["musicResponsiveListItemFlexColumnRenderer"]["text"]) if len(cols) > n else ""
        title, subtitle = col(0), col(1)
        nav = r.get("navigationEndpoint") or {}
    browse = nav.get("browseEndpoint") or {}
    kind = YTM_KINDS.get(_find(browse, "pageType") or "", "")
    video = (r.get("playlistItemData") or {}).get("videoId") or (nav.get("watchEndpoint") or {}).get("videoId") or ""
    if not kind and video:
        kind = {"song": "song", "video": "video"}.get(subtitle.split(" • ")[0].strip().lower(), "")
    play = _find(r.get("overlay") or r.get("thumbnailOverlay") or {}, "watchPlaylistEndpoint") or {}
    playlist = play.get("playlistId") or ""
    browse_id = browse.get("browseId", "")
    if kind == "playlist" and not playlist and browse_id.startswith("VL"):
        playlist = browse_id[2:]
    if not kind or (kind in {"song", "video"} and not video) or (kind in {"album", "playlist"} and not playlist) \
            or (kind == "artist" and not browse_id):
        return None
    thumbs = _find(r.get("thumbnail") or {}, "thumbnails") or []
    return {"kind": kind, "title": title[:100], "subtitle": " • ".join(subtitle.split(" • ")[1:])[:120],
            "video": video, "playlist": playlist, "browse": browse_id,
            "thumb": thumbs[-1]["url"] if thumbs and str(thumbs[-1].get("url", "")).startswith("https://") else ""}


def ytm_search(query):
    """Songs, videos, albums, artists and playlists for a query, best first."""
    data = ytm_call("search", {"query": query[:200]})
    items = []
    try:
        sections = data["contents"]["tabbedSearchResultsRenderer"]["tabs"][0]["tabRenderer"]["content"][
            "sectionListRenderer"]["contents"]
    except (KeyError, IndexError, TypeError):
        return items
    for section in sections:
        if "musicCardShelfRenderer" in section:
            item = _ytm_item(section["musicCardShelfRenderer"], top=True)
            if item:
                items.append({**item, "top": True})
        for c in (section.get("itemSectionRenderer") or section.get("musicShelfRenderer") or {}).get("contents", []):
            if "musicResponsiveListItemRenderer" in c:
                item = _ytm_item(c["musicResponsiveListItemRenderer"])
                if item and not any(i["kind"] == item["kind"] and i["title"] == item["title"] for i in items):
                    items.append(item)
    return items[:40]


def ytm_rows(data):
    rows, stack = [], [data]
    while stack:
        o = stack.pop(0)
        if isinstance(o, dict):
            if isinstance(o.get("musicResponsiveListItemRenderer"), dict):
                rows.append(o["musicResponsiveListItemRenderer"])
                continue
            stack.extend(o.values())
        elif isinstance(o, list):
            stack.extend(o)
    return rows


def ytm_video_title(title, uploader):
    """An uploaded video's 'Artist - Song (Official Video) (1999)' as song and
    artist; anything else stays as it is, with the uploader as the artist."""
    title = re.sub(r"\s*[\(\[][^)\]]*\b(official|video|audio|lyrics?|visuali[sz]er|hd|hq|remaster(ed)?|\d{4})\b[^)\]]*[\)\]]",
                   "", title, flags=re.I).strip()
    if " - " in title:
        artist, song = (part.strip() for part in title.split(" - ", 1))
        if artist and song:
            return song, artist
    return title, uploader


def ytm_tracks(item, limit=200):
    """The songs of a YouTube Music playlist or album, in order:
    [{video, title, artist, album, thumb}]. Public ones are read signed out;
    your own private ones through the open YouTube Music window."""
    kind = item.get("kind")
    if kind == "playlist" and YTM_ID.match(str(item.get("playlist", ""))):
        browse = "VL" + item["playlist"]
    elif kind == "album" and re.fullmatch(r"MPRE[\w-]{4,60}", str(item.get("browse", ""))):
        browse = item["browse"]
    else:
        return []
    by = str(item.get("subtitle", "")).split(" • ")[0] if kind == "album" else ""
    tracks, seen = [], set()
    def take(data):
        for r in ytm_rows(data):
            video = (r.get("playlistItemData") or {}).get("videoId") or ""
            cols = r.get("flexColumns", [])
            col = lambda n: _runs(cols[n]["musicResponsiveListItemFlexColumnRenderer"]["text"]) if len(cols) > n else ""
            if not YTM_ID.match(video) or video in seen or not col(0):
                continue
            seen.add(video)
            thumbs = _find(r.get("thumbnail") or {}, "thumbnails") or []
            thumb = thumbs[-1]["url"] if thumbs and str(thumbs[-1].get("url", "")).startswith("https://") else item.get("thumb", "")
            title, artist = col(0), col(1) or by
            if kind == "playlist" and not col(2):
                title, artist = ytm_video_title(title, artist)
            tracks.append({"video": video, "title": title[:120], "artist": artist[:120],
                           "album": (item["title"] if kind == "album" else col(2))[:120], "thumb": thumb})
    try:
        data = ytm_call("browse", {"browseId": browse})
        take(data)
        for _ in range(6):          # the next pages of a long playlist
            token = (_find(data, "continuationCommand") or {}).get("token") or ""
            if len(tracks) >= limit or not token:
                break
            data = ytm_call("browse", {"continuation": token})
            take(data)
    except (OSError, ValueError):
        pass
    if not tracks:                  # private: ask the signed-in window
        reply = beatport_bridge({"type": "page", "site": "ytmusic", "op": {"type": "ytm-browse", "browseId": browse}},
                                timeout=15) or {}
        try:
            take(json.loads(reply.get("text") or ""))
        except ValueError:
            pass
    return tracks[:limit]


def ytm_url(item):
    kind = item.get("kind")
    for key in ("video", "playlist", "browse"):
        if item.get(key) and not YTM_ID.match(item[key]):
            sys.exit("Bad YouTube Music id.")
    if kind in {"song", "video"}:
        return f"{YTM}/watch?v={item['video']}"
    if kind in {"album", "playlist"}:
        return f"{YTM}/watch?list={item['playlist']}"
    if kind == "artist":
        return f"{YTM}/channel/{item['browse']}"
    sys.exit("Can't play that.")


def ytm_player_state():
    """'playing', 'paused' or '' from YouTube Music's own Play/Pause button."""
    reply = beatport_bridge({"type": "page", "site": "ytmusic", "op": {"type": "probe", "region": "any",
                             "filter": "^(Play|Pause)$"}}, timeout=3) or {}
    labels = {i.get("label") for i in reply.get("items", []) if i.get("y", 0) > reply.get("height", 0) - 160}
    return "playing" if "Pause" in labels else "paused" if "Play" in labels else ""


def ytm_play(item):
    """Play a search result in the YouTube Music window without moving you there."""
    url = ytm_url(item)
    state = load_state()
    state["musicLast"] = {"service": "ytmusic", "item": item}
    save_state(state)
    opened = False
    for attempt in range(30):
        reply = beatport_bridge({"type": "open", "url": url, "play": False})
        if reply is None:
            run("omarchy-osd", "-i", "󰀦", "-d", "4000",
                "-m", "Baseline's browser add-on isn't running: reload it in chrome://extensions")
            sys.exit("The add-on isn't answering.")
        if reply.get("inPlace"):
            opened = True
            break
        if attempt == 0:
            # No YouTube Music window yet: open the app (it lands on workspace 6).
            subprocess.Popen(["omarchy-launch-webapp", YTM + "/"], stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL, start_new_session=True)
        time.sleep(0.5)
    if not opened:
        sys.exit("YouTube Music didn't open.")
    time.sleep(2.5)
    if item["kind"] == "artist":
        # An artist's page: press its Shuffle (or Play) like you would.
        # The real button carries the label; its styled wrapper doesn't.
        beatport_bridge({"type": "page", "site": "ytmusic", "op": {"type": "click", "label": "^Shuffle$",
                         "region": "page", "wait": 8000}}, timeout=12)
    for _ in range(12):
        if ytm_player_state() == "playing":
            break
        time.sleep(0.5)
    else:
        # Didn't start on its own: press the player's Play once.
        if ytm_player_state() == "paused":
            beatport_bridge({"type": "page", "site": "ytmusic", "op": {"type": "click", "label": "^Play$",
                             "region": "bar", "wait": 2000}}, timeout=5)
    label = item["title"] + (f" ({item['kind']})" if item["kind"] in {"artist", "album", "playlist"} else "")
    run("omarchy-osd", "-i", "media-play", "-m", f"Playing {label[:60]}")
    print(f"Playing {label}")


def ytm_say(words):
    """Play the best YouTube Music match for something said or typed."""
    said = re.sub(r"\b(?:on|from|in|with)\s+(?:youtube music|yt music|you tube music|youtube)\b", " ", words, flags=re.I)
    said = re.sub(r"^\s*(?:please\s+)?(?:play|put on|start playing|listen to)\s+", "", said, flags=re.I)
    kind = None
    m = re.search(r"\b(?:the\s+)?(album|playlist|artist|song|track|video)\b\s*$", said, re.I) or \
        re.match(r"^\s*(?:the\s+)?(album|playlist|artist|song|track|video)\s+", said, re.I)
    if m:
        kind = {"track": "song"}.get(m.group(1).lower(), m.group(1).lower())
        said = (said[:m.start()] + " " + said[m.end():])
    query = " ".join(re.sub(r"^(?:some|the|my)\s+", "", said.strip(), flags=re.I).split())
    if not query:
        sys.exit("Say what to play.")
    # One of your own playlists, by name, first.
    for p in ytm_playlists() if kind in {None, "playlist"} else []:
        if song_key(p["name"]) == song_key(query) and YTM_ID.match(p["playlist"]):
            return ytm_play({"kind": "playlist", "title": p["name"], "playlist": p["playlist"], "video": "",
                             "browse": "", "subtitle": ""})
    try:
        items = ytm_search(query)
    except (OSError, ValueError):
        items = []
    if kind:
        items = [i for i in items if i["kind"] == kind] or items
    if items and confident(items[0], query):
        return ytm_play(items[0])
    suggest("ytmusic", query, items)


def ytm_playlists(refresh=False):
    """Your YouTube Music library playlists, asked for from the open YouTube
    Music window (signed in), kept in ytmusic.json for up to a day."""
    known = read_json(YTM_STATE, {})
    if not refresh and time.time() - known.get("updated", 0) < 86400:
        return known.get("playlists", [])
    reply = beatport_bridge({"type": "page", "site": "ytmusic",
                             "op": {"type": "ytm-browse", "browseId": "FEmusic_liked_playlists"}}, timeout=15) or {}
    try:
        data = json.loads(reply.get("text") or "")
    except ValueError:
        return known.get("playlists", [])
    playlists, stack = [], [data]
    while stack:
        o = stack.pop(0)
        if isinstance(o, dict):
            r = o.get("musicTwoRowItemRenderer")
            if isinstance(r, dict):
                browse = _find(r.get("navigationEndpoint") or {}, "browseId") or ""
                name = _runs(r.get("title"))
                if browse.startswith("VL") and name and YTM_ID.match(browse[2:]):
                    playlists.append({"name": "Liked music" if browse == "VLLM" else name[:60], "playlist": browse[2:]})
                continue
            stack.extend(o.values())
        elif isinstance(o, list):
            stack.extend(o)
    seen, unique = set(), []
    for p in playlists:
        if p["playlist"] not in seen:
            seen.add(p["playlist"])
            unique.append(p)
    write_atomic(YTM_STATE, json.dumps({"playlists": unique[:30], "updated": int(time.time())}, indent=2) + "\n")
    return unique[:30]


# ---------------------------------------------------------------- apple music

# Searched with Apple's public catalogue search (no account), played in the
# Apple Music web app through Apple's own player there (the add-on's
# "applemusic" request), so a whole album or the artist's top songs queue up.
AM = "https://music.apple.com"
AM_CLASS = "chrome-music.apple.com__-Default"
AM_SAID = re.compile(r"\b(?:on|from|in|with|using)\s+(?:apple music|apple|i ?tunes)\b|\bapple music\b", re.I)


def am_country():
    """The catalogue to search: the storefront of your region (en_GB: gb)."""
    for var in ("LC_ALL", "LC_MESSAGES", "LANG"):
        m = re.match(r"^[a-z]{2,3}_([A-Z]{2})", os.environ.get(var, ""))
        if m:
            return m.group(1).lower()
    return "us"


AM_CACHE = CACHE / "afterlight/applemusic"


def am_lookup(params):
    """Apple's catalogue search or lookup. Answers are kept for a day (Apple
    allows only about 20 searches a minute), and a refusal waits and retries."""
    import urllib.error
    import urllib.parse
    import urllib.request
    query = urllib.parse.urlencode({**params, "country": am_country()})
    endpoint = "lookup" if "id" in params else "search"
    cached = AM_CACHE / (hashlib.sha256(f"{endpoint}?{query}".encode()).hexdigest()[:24] + ".json")
    try:
        if time.time() - cached.stat().st_mtime < 86400:
            return json.loads(cached.read_text())
    except (OSError, ValueError):
        pass
    request = urllib.request.Request(f"https://itunes.apple.com/{endpoint}?{query}", headers={"User-Agent": "Mozilla/5.0"})
    for attempt in range(3):
        try:
            with urllib.request.urlopen(request, timeout=10) as response:
                results = json.loads(response.read(2_000_000)).get("results", [])
            break
        except urllib.error.HTTPError as error:
            if error.code not in {403, 429} or attempt == 2:
                raise
            time.sleep(2 + attempt * 3)
    AM_CACHE.mkdir(parents=True, exist_ok=True)
    write_atomic(cached, json.dumps(results))
    for stale in sorted(AM_CACHE.glob("*.json"), key=lambda f: f.stat().st_mtime)[:-400]:
        stale.unlink(missing_ok=True)
    return results


def am_songs(query, limit=10):
    """Songs only, in one call: for looking up songs Grok named."""
    return [{"kind": "song", "title": clean_text(t.get("trackName", ""), 100),
             "subtitle": clean_text(f"{t.get('artistName', '')} • {t.get('collectionName', '')}", 120),
             "id": str(t["trackId"]), "album": str(t.get("collectionId", "")), "thumb": am_art(t.get("artworkUrl100", ""))}
            for t in am_lookup({"term": query[:200], "media": "music", "entity": "song", "limit": limit})
            if t.get("trackId") and t.get("isStreamable", True)]


def am_art(url):
    return re.sub(r"/\d+x\d+bb\.", "/300x300bb.", url) if str(url).startswith("https://") else ""


def am_search(query):
    """Songs, albums and artists for a query, best first, as items like
    YouTube Music's: {kind, title, subtitle, id, album, thumb}."""
    query = query[:200]
    items = []
    try:
        songs = am_lookup({"term": query, "media": "music", "entity": "song", "limit": 12})
        albums = am_lookup({"term": query, "media": "music", "entity": "album", "limit": 6})
        artists = am_lookup({"term": query, "media": "music", "entity": "musicArtist", "limit": 3})
    except (OSError, ValueError):
        return items
    for a in artists:
        if a.get("artistId"):
            items.append({"kind": "artist", "title": clean_text(a.get("artistName", ""), 100),
                          "subtitle": clean_text(a.get("primaryGenreName", ""), 60), "id": str(a["artistId"]), "thumb": ""})
    for a in albums:
        if a.get("collectionId"):
            items.append({"kind": "album", "title": clean_text(a.get("collectionName", ""), 100),
                          "subtitle": clean_text(a.get("artistName", ""), 100), "id": str(a["collectionId"]),
                          "thumb": am_art(a.get("artworkUrl100", ""))})
    for t in songs:
        if t.get("trackId") and t.get("isStreamable", True):
            items.append({"kind": "song", "title": clean_text(t.get("trackName", ""), 100),
                          "subtitle": clean_text(f"{t.get('artistName', '')} • {t.get('collectionName', '')}", 120),
                          "id": str(t["trackId"]), "album": str(t.get("collectionId", "")),
                          "thumb": am_art(t.get("artworkUrl100", ""))})
    # Apple's own order within each kind; an artist first when the words are
    # just their name; live, remixed and karaoke takes last unless asked for.
    said = song_key(query)
    # An artist goes first only when it's the one the songs found are by: an
    # unknown band called "Get Lucky" doesn't beat Daft Punk's song.
    song_artists = {song_key(t.get("artistName", "")) for t in songs}
    extra = re.compile(r"\b(?:live|remix|karaoke|cover|instrumental|acoustic|sped up|slowed)\b", re.I)
    def rank(item):
        if item["kind"] == "artist":
            return 0 if song_key(item["title"]) == said and song_key(item["title"]) in song_artists else 3
        unwanted = bool(extra.search(item["title"])) and not extra.search(query)
        words = set(said.split())
        by = set(song_key(item["subtitle"].split(" • ")[0]).split())
        named = set(song_key(item["title"]).split()) <= words and (song_key(item["title"]) == said or bool(by & words))
        if item["kind"] == "album":     # a single is a song: the song comes first
            single = bool(re.search(r" - (?:Single|EP)$", item["title"]))
            # Named with its artist: the album. Its name alone: a song of that name first.
            return (0.5 if named and bool(by & words) and not single else 1.2 if named else 2) + unwanted * 2
        return (1 if named else 1.5) + unwanted * 2
    items.sort(key=rank)
    return items[:30]


def am_bridge(op, timeout=8):
    return beatport_bridge({"type": "applemusic", "op": op}, timeout=timeout)


AM_PLAYLIST = re.compile(r"^(pl\.[A-Za-z0-9.-]{1,80}|p\.[A-Za-z0-9]{1,40})$")


def am_playlists(query):
    """Apple Music playlists for a query: yours first (library), then Apple's
    and curators' (catalogue). Through Apple's own player in the page, so the
    Apple Music window has to be open and signed in."""
    reply = am_bridge({"action": "playlists", "term": query[:100]}, timeout=12) or {}
    out = []
    for p in reply.get("items") or []:
        if not isinstance(p, dict) or not AM_PLAYLIST.match(str(p.get("id", ""))):
            continue
        art = str(p.get("art", ""))
        out.append({"kind": "playlist", "id": str(p["id"]), "title": clean_text(str(p.get("name", "")), 100),
                    "subtitle": clean_text(str(p.get("curator", "")), 100), "mine": bool(p.get("library")),
                    "thumb": art if art.startswith("https://") else ""})
    return out[:100 if query == "*" else 20]


def am_playlist_tracks(playlist_id):
    """A playlist's songs, as catalogue songs (library songs not in the
    catalogue are left out: Sonos and the Deck can't play them)."""
    if not AM_PLAYLIST.match(str(playlist_id)):
        return []
    reply = am_bridge({"action": "tracks", "id": playlist_id}, timeout=25) or {}
    out = []
    for t in reply.get("items") or []:
        if isinstance(t, dict) and re.fullmatch(r"\d{1,15}", str(t.get("id", ""))):
            art = str(t.get("art", ""))
            out.append({"id": str(t["id"]), "title": str(t.get("title", "")), "artist": str(t.get("artist", "")),
                        "album_name": str(t.get("album", "")), "thumb": art if art.startswith("https://") else ""})
    return out[:300]


def am_now():
    """What the Apple Music app is playing, from its player: item, time,
    signed in. None when the app or add-on isn't there."""
    reply = am_bridge({"action": "now"}, timeout=3)
    return reply if reply and reply.get("ok") else None


def am_play(item):
    """Play a search result in the Apple Music app without moving you there:
    a song plays within its album, so the album carries on after it."""
    kind = item.get("kind")
    ident = str(item.get("id", ""))
    if not re.fullmatch(r"\d{1,15}", ident) or kind not in {"song", "album", "artist"}:
        sys.exit("Bad Apple Music item.")
    if kind == "artist":
        tops = [t for t in am_lookup({"id": ident, "entity": "song", "limit": 25, "sort": "popular"})
                if t.get("wrapperType") == "track" and t.get("trackId")]
        op = {"action": "queue", "kind": "songs", "ids": [str(t["trackId"]) for t in tops]}
        if not op["ids"]:
            sys.exit("No songs for that artist.")
    elif kind == "song" and re.fullmatch(r"\d{1,15}", str(item.get("album", ""))):
        op = {"action": "queue", "kind": "album", "id": item["album"], "start": ident}
    else:
        op = {"action": "queue", "kind": kind, "id": ident}
    state = load_state()
    state["musicLast"] = {"service": "applemusic", "item": item}
    save_state(state)
    reply = None
    for attempt in range(40):
        reply = am_bridge(op, timeout=12)
        if reply is None and attempt == 0 and not Path(BEATPORT_SOCK).exists():
            run("omarchy-osd", "-i", "󰀦", "-d", "4000",
                "-m", "Baseline's browser add-on isn't running: reload it in chrome://extensions")
            sys.exit("The add-on isn't answering.")
        if reply and reply.get("ok"):
            break
        if reply and reply.get("error") == "signed out":
            run("omarchy-osd", "-i", "󰀦", "-d", "4000", "-m", "Sign in to Apple Music first")
            sys.exit("Apple Music is signed out.")
        if attempt == 0 and (not reply or reply.get("error") == "no Apple Music tab"):
            # No Apple Music window yet: open the app (it lands on workspace 6).
            subprocess.Popen(["omarchy-launch-webapp", AM + "/"], stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL, start_new_session=True)
        time.sleep(0.5)
    else:
        sys.exit("Apple Music didn't play it.")
    label = item.get("title", "") + (f" ({kind})" if kind in {"artist", "album"} else "")
    run("omarchy-osd", "-i", "media-play", "-m", f"Playing {label[:60]}")
    print(f"Playing {label}")


def am_say(words):
    """Play the best Apple Music match for something said or typed."""
    said = AM_SAID.sub(" ", words)
    said = re.sub(r"^\s*(?:please\s+)?(?:play|put on|start playing|listen to)\s+", "", said, flags=re.I)
    kind = None
    m = re.search(r"\b(?:the\s+)?(album|artist|song|track)\b\s*$", said, re.I) or \
        re.match(r"^\s*(?:the\s+)?(album|artist|song|track)\s+", said, re.I)
    if m:
        kind = {"track": "song"}.get(m.group(1).lower(), m.group(1).lower())
        said = said[:m.start()] + " " + said[m.end():]
    query = " ".join(re.sub(r"^(?:some|the|my)\s+", "", said.strip(), flags=re.I).split())
    if not query:
        sys.exit("Say what to play.")
    items = am_search(query)
    if kind:
        items = [i for i in items if i["kind"] == kind] or items
    if items and confident(items[0], query):
        return am_play(items[0])
    suggest("applemusic", query, items)


# ---------------------------------------------------------------- suggestions
# "Play …" plays only when the best match is clearly what was asked for.
# Otherwise nothing plays: the Player tab opens on suggestions, the closest
# matches at once and, a few seconds later, ideas from Grok's fast model
# (searched for on the same service, so each one plays). suggest.json holds them.
SUGGEST = STATE.parent / "suggest.json"
GROK_FAST = "grok-4.7-build-fast"
FILLER = {"the", "a", "an", "my", "some", "songs", "song", "music", "playlist", "please", "by", "from", "track",
          "tracks", "album", "artist", "on", "of", "for", "me", "by"}


MOODS = {"chill", "chilled", "relaxing", "relax", "calm", "sunset", "sunrise", "party", "workout", "gym", "focus",
         "study", "sleep", "sleepy", "happy", "sad", "upbeat", "dinner", "cooking", "morning", "evening", "night",
         "summer", "winter", "rainy", "rain", "background", "easy", "mellow", "dance", "something", "anything",
         "kitchen", "lounge", "vibes", "vibe", "mood", "good", "nice", "new", "fresh", "old", "classic", "hits"}


def confident(item, query):
    """Is this search result clearly what was asked for? The title is all
    said, and for a song or album the artist is said too (or nothing else is).
    A mood ("chill music", "something for dinner") is never a match: that's
    what suggestions are for."""
    said = set(song_key(query).split()) - FILLER
    if said and said <= MOODS:
        return False
    title = set(song_key(item.get("title", "")).split()) - FILLER
    if not said or not title or not title <= said:
        return False
    if item.get("kind") in {"artist", "playlist"}:
        return title == said
    by = set(song_key(str(item.get("subtitle", "")).split(" • ")[0]).split()) - FILLER
    rest = said - title - by
    return title == said or (bool(by & said) and len(rest) <= 1)


def suggest_write(value):
    write_atomic(SUGGEST, json.dumps({**value, "at": time.time()}) + "\n")


def suggest(service, query, items, open_tab=True):
    """No clear match: show the closest ones and ask Grok for more."""
    suggest_write({"service": service, "query": query[:120], "close": items[:6], "grok": [], "try": [],
                   "pending": bool(shutil.which("grok"))})
    if open_tab:
        # The panel says it itself; a popup at the same moment would close it.
        run("omarchy-shell", "-q", "mortalfish.baseline", "openTab", "player")
    if shutil.which("grok"):
        subprocess.Popen([str(REPO / "bin/afterlight"), "music", "grok", service, query[:200]],
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         start_new_session=True)
    print(f"No exact match for {query}: suggestions are in the Player tab")


CHAPTERS = ("Warm up", "Build", "Peak", "Wind down")


def grok_ideas(query, ask=None, count=6, timeout=45, shape=False, mix=False):
    """Songs that fit what was asked, and searches to try, from Grok's fast
    model with every tool off: {"songs": [{"t", "a", "w"}], "q": [...]}."""
    ask = ask or (f"Someone asked to play: «{query.replace('»', '')[:200]}». There was no exact match.")
    song = '{"t":"title","a":"artist","w":"why it fits, max 30 chars"' + (',"e":7,"c":"Build"' if shape else "") \
        + (',"e":7,"b":118,"k":"8A"' if mix and not shape else "") + "}"
    prompt = (f"Answer from your own knowledge; use no tools. Music helper. {ask} Reply with ONLY compact JSON, no prose: "
              '{"songs":[' + song + '],"q":["search phrase"]} '
              f"with {count} real, findable songs that fit (or the song they most likely meant first) and 3 short searches."
              + (' "e" is the song\'s energy from 1 (calm) to 10 (peak); "c" is its chapter of the set, one of '
                 '"Warm up", "Build", "Peak", "Wind down".' if shape else "")
              + (' "e" is its energy from 1 (calm) to 10 (peak), "b" its tempo in BPM and "k" its key on the Camelot wheel '
                 '(1A to 12B): rough is fine, don\'t deliberate.' if mix else ""))
    workdir = STATE.parent / "grok-music"
    workdir.mkdir(parents=True, exist_ok=True)
    try:
        # Every tool off, the Sonos MCP's too: it answers from what it knows.
        result = subprocess.run(["grok", "-m", GROK_FAST, "--effort", "low", "--tools", "", "--deny", "MCPTool(*)", "-p", prompt,
                                 "--max-turns", "1", "--no-auto-update"], cwd=workdir, capture_output=True,
                                text=True, timeout=timeout, stdin=subprocess.DEVNULL)
        text = result.stdout
        value = json.loads(text[text.index("{"):text.rindex("}") + 1])
    except (OSError, subprocess.SubprocessError, ValueError):
        return {"songs": [], "q": []}
    songs = [{"t": clean_text(str(x.get("t", "")), 100), "a": clean_text(str(x.get("a", "")), 100),
              "w": clean_text(str(x.get("w", "")), 40),
              "e": x["e"] if isinstance(x.get("e"), int) and 1 <= x["e"] <= 10 else 0,
              "c": x["c"] if x.get("c") in CHAPTERS else "",
              "b": x["b"] if isinstance(x.get("b"), (int, float)) and 50 <= x["b"] <= 220 else 0,
              "k": x["k"] if camelot_ok(x.get("k")) else ""}
             for x in value.get("songs", []) if isinstance(x, dict) and x.get("t")][:max(8, count + 4)]
    searches = [clean_text(str(q), 60) for q in value.get("q", []) if isinstance(q, str) and q.strip()][:4]
    return {"songs": songs, "q": searches}


def find_songs(service, ideas):
    """Each of Grok's ideas looked up on the service at once: [(idea, best song or None)]."""
    from concurrent.futures import ThreadPoolExecutor
    search = am_songs if service == "applemusic" else beatport_search_tracks if service == "beatport" else ytm_search
    def look(idea):
        try:
            results = [i for i in search(f"{idea['t']} {idea['a']}") if i["kind"] == "song"]
        except (OSError, ValueError):
            return idea, None
        same = [i for i in results if song_key(i["title"]) == song_key(idea["t"])]
        artist = set(song_key(idea["a"]).split())
        by = lambda i: set(song_key(str(i.get("subtitle", "")).split(" • ")[0]).split())
        # The artist Grok named, not a cover or a tribute act.
        return idea, next((i for i in same if artist & by(i)), None) or (same[0] if same and not artist else None)
    with ThreadPoolExecutor(max_workers=3 if service in {"applemusic", "beatport"} else 6) as pool:
        return list(pool.map(look, ideas))


def grok_suggest(service, query):
    """Fill in Grok's ideas, each found on the service so it plays."""
    ideas = grok_ideas(query)
    found = []
    for idea, match in find_songs(service, ideas["songs"]):
        if match and not any(f.get("id", f.get("video")) == match.get("id", match.get("video")) for f in found):
            found.append({**match, "why": idea["w"]})
    current = read_json(SUGGEST, {})
    if current.get("query") != query[:120] or current.get("service") != service:
        return      # a newer search has taken over
    current.update(grok=found, pending=False, **{"try": ideas["q"]})
    suggest_write(current)


# ---------------------------------------------------------------- the deck
# The Deck: a set of songs from YouTube Music and Apple Music you arrange by
# hand (the Deck window), played on the laptop or in a Sonos room.
#   deck.json      the set: now, up next, played, pinned, where it plays
#   deck-now.json  where the song is (time, length, playing), for the window
# On the laptop, songs play one at a time in their own app and a watcher
# (`afterlight deck run`, started on play) starts the next when one ends; if
# you start something else yourself, the Deck steps back. In a Sonos room the
# set becomes the room's queue (Apple Music songs, added by their catalogue
# number), so the speaker plays it gaplessly and the watcher follows along.
DECK = STATE.parent / "deck.json"
DECK_NOW = STATE.parent / "deck-now.json"
DECK_LOCK = STATE.parent / "deck.lock"
DECK_RUN_LOCK = STATE.parent / "deck-run.lock"
DECK_DETAILS = STATE.parent / "deck-details.json"     # each song's length, tempo, key and energy
DECK_DETAILS_LOCK = STATE.parent / "deck-details.lock"
DECK_UNDO = STATE.parent / "deck-undo.json"           # the set before each of the last changes
DECK_SETS = STATE.parent / "deck-sets.json"           # sets you saved
DECK_EMPTY = {"now": None, "set": [], "played": [], "pinned": [], "where": {"kind": "laptop"}, "playing": False,
              "paused": False, "sleep": None, "crossfade": False, "autodj": False, "autodjAt": 0, "handoff": "",
              "pushed": [], "pushedFrom": 1, "expect": None, "was": None, "updated": 0,
              "lock": False, "requests": [], "guests": None, "requestsAuto": False, "votes": {}, "lastCall": 0,
              "shaped": [], "voice": True, "spoken": [], "voiceUntil": 0, "voicePrep": {}, "voiceName": "",
              "micViz": False, "speaking": None, "asks": [], "awoke": False, "phoneSeen": 0, "ready": None,
              "recapAt": 0, "closedAt": 0, "skipped": [], "direction": ""}
APPLE_SID = 204                 # Apple Music's service number on Sonos
DECK_HISTORY = 300              # songs kept in what's played (a whole night)
SONOS_AHEAD = 30                # songs put in a room's queue at a time (topped up as it plays)
DECK_SERVICES = {"applemusic", "ytmusic", "beatport"}


def deck_read():
    value = read_json(DECK, {})
    deck = copy.deepcopy(DECK_EMPTY)
    if isinstance(value, dict):
        deck.update({k: v for k, v in value.items() if k in DECK_EMPTY})
    deck["set"] = [i for i in deck["set"] if isinstance(i, dict) and i.get("uid")][:300]
    deck["played"] = [i for i in deck["played"] if isinstance(i, dict) and i.get("uid")][-DECK_HISTORY:]
    return deck


def deck_update(change):
    """Read, change and write deck.json under a lock (the window and the
    watcher both write it). Returns what change returned."""
    DECK.parent.mkdir(parents=True, exist_ok=True)
    with open(DECK_LOCK, "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        deck = deck_read()
        result = change(deck)
        deck["updated"] = time.time()
        write_atomic(DECK, json.dumps(deck) + "\n")
    return result


def deck_item(service, item):
    """A search result as a Deck song: checked ids, plain text."""
    if service not in DECK_SERVICES or not isinstance(item, dict):
        sys.exit("Only YouTube Music and Apple Music songs go in the Deck for now.")
    subtitle = str(item.get("subtitle", "")).split(" • ")
    song = {"uid": os.urandom(4).hex(), "service": service, "title": clean_text(str(item.get("title", "")), 120),
            "artist": clean_text(str(item.get("artist") or subtitle[0]), 120),
            "album": clean_text(str(item.get("album_name") or (subtitle[1] if len(subtitle) > 1 else "")), 120),
            "thumb": str(item.get("thumb", "")) if str(item.get("thumb", "")).startswith("https://") else ""}
    if re.fullmatch(r"\d{1,2}(:\d{2}){1,2}", song["album"]):
        song["album"] = ""                  # YouTube Music's search puts the length where the album goes
    if item.get("from"):                    # picked out of a playlist or album you opened
        song["from"] = clean_text(str(item["from"]), 80)
    if service == "applemusic":
        if not re.fullmatch(r"\d{1,15}", str(item.get("id", ""))):
            sys.exit("Bad Apple Music song.")
        song["id"] = str(item["id"])
    elif service == "beatport":
        if not re.fullmatch(r"\d{1,12}", str(item.get("id", ""))):
            sys.exit("Bad Beatport track.")
        song["id"] = str(item["id"])
        song["slug"] = re.sub(r"[^a-z0-9-]+", "", str(item.get("slug", "")).lower())[:120] or "track"
        known = {k: item[k] for k in ("bpm", "length") if isinstance(item.get(k), (int, float)) and item[k] > 0}
        if camelot_ok(item.get("key")):
            known["key"] = item["key"]
        if known:
            deck_details_note(song, **known)
    else:
        if not YTM_ID.match(str(item.get("video", ""))):
            sys.exit("Bad YouTube Music song.")
        song["video"] = str(item["video"])
    return song


def deck_expand(service, item):
    """A song is one song; an album or playlist is its songs, in order, each
    remembering where it came from."""
    songs = deck_expand_songs(service, item)
    if item.get("kind") in {"album", "playlist"}:
        origin = clean_text(str(item.get("title", "")), 60)
        for song in songs:
            song["from"] = origin
    return songs


def deck_expand_songs(service, item):
    if service == "applemusic" and item.get("kind") == "album" and re.fullmatch(r"\d{1,15}", str(item.get("id", ""))):
        tracks = [t for t in am_lookup({"id": item["id"], "entity": "song", "limit": 60})
                  if t.get("wrapperType") == "track" and t.get("trackId")]
        tracks.sort(key=lambda t: (t.get("discNumber", 1), t.get("trackNumber", 0)))
        return [deck_item(service, {"id": t["trackId"], "title": t.get("trackName", ""), "artist": t.get("artistName", ""),
                                    "album_name": t.get("collectionName", ""), "thumb": am_art(t.get("artworkUrl100", ""))})
                for t in tracks]
    if service == "applemusic" and item.get("kind") == "playlist":
        return [deck_item(service, t) for t in am_playlist_tracks(item.get("id", ""))]
    if service == "beatport" and item.get("kind") == "playlist":
        return [deck_item(service, t) for t in beatport_playlist_tracks(str(item.get("url", "")))]
    if service == "ytmusic" and item.get("kind") in {"playlist", "album"}:
        return [deck_item(service, {**t, "album_name": t["album"]}) for t in ytm_tracks(item)]
    if item.get("kind") not in {"song", "video"}:
        sys.exit("Add songs, albums or playlists to the Deck.")
    return [deck_item(service, item)]


# ---- Sonos: Apple Music songs straight into a room's queue

def sonos_apple_sn(refresh=False):
    """Your Apple Music account's number on Sonos, read from any room's queue
    or favourites that holds an Apple Music song (it's in every one of them)."""
    cache = read_json(SONOS_CACHE, {})
    if cache.get("appleSn") and not refresh:
        return str(cache["appleSn"])
    for room in sonos_rooms():
        for folder in ("Q:0", "FV:2"):
            reply = sonos_call(room["ip"], "ContentDirectory", "Browse", {
                "ObjectID": folder, "BrowseFlag": "BrowseDirectChildren", "Filter": "*", "StartingIndex": 0,
                "RequestedCount": 100, "SortCriteria": ""}, timeout=4) or {}
            m = re.search(rf"sid={APPLE_SID}&(?:amp;)?flags=\d+&(?:amp;)?sn=(\d+)", reply.get("Result") or "")
            if m:
                cache["appleSn"] = m.group(1)
                write_atomic(SONOS_CACHE, json.dumps(cache) + "\n")
                return m.group(1)
    return ""


def sonos_apple_uri(song_id, sn):
    uri = f"x-sonos-http:song%3a{song_id}.mp4?sid={APPLE_SID}&flags=8232&sn={sn}"
    service = APPLE_SID * 256 + 7
    meta = ('<DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" '
            'xmlns:r="urn:schemas-rinconnetworks-com:metadata-1-0/" xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/">'
            f'<item id="10032020song%3a{song_id}" parentID="" restricted="true"><dc:title></dc:title>'
            '<upnp:class>object.item.audioItem.musicTrack</upnp:class>'
            f'<desc id="cdudn" nameSpace="urn:schemas-rinconnetworks-com:metadata-1-0/">SA_RINCON{service}_X_#Svc{service}-0-Token</desc>'
            '</item></DIDL-Lite>')
    return uri, meta


def deck_apple_id(song):
    """The Apple Music song for a Deck song: its own, or a YouTube Music song
    found on Apple Music by title and artist (remembered on the song)."""
    if song.get("service") == "applemusic":
        return song.get("id", "")
    if song.get("am") is not None:
        return song["am"]
    try:
        found = am_songs(f"{re.sub(r'[(\[][^)\]]*[)\]]', '', song['title']).strip()} {song['artist']}")
    except (OSError, ValueError):
        return ""
    match = next((i for i in found if song_key(i["title"]) == song_key(song["title"])), None)
    song["am"] = match["id"] if match else ""
    return song["am"]


def deck_sonos_add(ip, song, sn):
    """One Deck song onto the end of a room's queue. True if it went on."""
    apple = deck_apple_id(song)
    if not apple:
        return False
    uri, meta = sonos_apple_uri(apple, sn)
    return sonos_call(ip, "AVTransport", "AddURIToQueue", {"InstanceID": 0, "EnqueuedURI": uri, "EnqueuedURIMetaData": meta,
                                                           "DesiredFirstTrackNumberEnqueued": 0, "EnqueueAsNext": 0},
                      timeout=6) is not None


def deck_sonos_push(room, songs, sn, start_at=0):
    """Make the first song (that Apple Music has) the room's queue and play it
    from start_at seconds, straight away; the songs after it are added in the
    background (deck_sonos_soon). Returns the uids queued."""
    ip = room["ip"]
    sonos_call(ip, "AVTransport", "RemoveAllTracksFromQueue", {"InstanceID": 0}, timeout=5)
    pushed = []
    for song in songs[:SONOS_AHEAD + 1]:
        if deck_sonos_add(ip, song, sn):
            pushed.append(song["uid"])
            break
    if not pushed:
        return []
    sonos_call(ip, "AVTransport", "SetAVTransportURI", {"InstanceID": 0, "CurrentURI": f"x-rincon-queue:{room['id']}#0",
                                                       "CurrentURIMetaData": ""})
    sonos_call(ip, "AVTransport", "Seek", {"InstanceID": 0, "Unit": "TRACK_NR", "Target": 1})
    if start_at > 2:
        sonos_call(ip, "AVTransport", "Seek", {"InstanceID": 0, "Unit": "REL_TIME", "Target": hms(start_at)})
    sonos_call(ip, "AVTransport", "Play", {"InstanceID": 0, "Speed": 1})
    return pushed


def deck_sonos_plan(pushed, pushed_from, current, now_uid, wanted):
    """What to change in a room's queue so that after the song it's on come
    the wanted songs (uids, in order): (keep, add). keep is how many queued
    songs after the current one are already right; the rest after them go,
    and add goes on the end. Only what differs is touched."""
    at = current - pushed_from
    if not (0 <= at < len(pushed)) or pushed[at] != now_uid:
        return 0, list(wanted)          # the queue isn't what we think: redo what follows
    queued = pushed[at + 1:]
    keep = 0
    while keep < len(queued) and keep < len(wanted) and queued[keep] == wanted[keep]:
        keep += 1
    return keep, list(wanted[keep:])


def deck_sonos_sync():
    """Bring the room's queue in line with the set, after the song it's on:
    only the songs that differ are taken off or added. Runs outside the Deck's
    lock (one at a time), so pausing or skipping never waits for it."""
    DECK.parent.mkdir(parents=True, exist_ok=True)
    with open(DECK.with_name("deck-sonos.lock"), "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        while True:                         # again while asked again meanwhile
            try:
                DECK.with_name("deck-sonos.again").unlink()
            except FileNotFoundError:
                return
            deck_sonos_sync_once()


def deck_sonos_sync_once():
    """One pass of deck_sonos_sync."""
    deck = deck_read()
    room = deck_where_room(deck)
    if not room or not deck["playing"] or not deck.get("now"):
        return
    if (deck.get("voiceUntil") or 0) > time.time():
        return                              # saying a dedication: the room isn't on its queue; deck_say syncs after
    ip, sn = room["ip"], sonos_apple_sn()
    if not sn:
        return
    position = sonos_call(ip, "AVTransport", "GetPositionInfo", {"InstanceID": 0}) or {}
    total = int((sonos_call(ip, "AVTransport", "GetMediaInfo", {"InstanceID": 0}) or {}).get("NrTracks") or 0)
    current = int(position.get("Track") or 1)
    at = current - (deck.get("pushedFrom") or 1)
    if 0 <= at < len(deck["pushed"]) and deck["pushed"][at] != deck["now"]["uid"]:
        return                              # the room moved on; the watcher catches up, then this runs again
    wanted = [x for x in deck["set"] if deck_apple_id(x)][:SONOS_AHEAD]
    keep, add = deck_sonos_plan(deck["pushed"], deck.get("pushedFrom") or 1, current, deck["now"]["uid"],
                                [x["uid"] for x in wanted])
    if total > current + keep:
        sonos_call(ip, "AVTransport", "RemoveTrackRangeFromQueue", {"InstanceID": 0, "UpdateID": 0,
                                                                   "StartingIndex": current + keep + 1,
                                                                   "NumberOfTracks": total - current - keep}, timeout=5)
    pushed = [deck["now"]["uid"]] + (deck["pushed"][at + 1:at + 1 + keep] if keep else [])
    by_uid = {x["uid"]: x for x in wanted}
    for uid in add:
        if deck_sonos_add(ip, by_uid[uid], sn):
            pushed.append(uid)
    def record(d):
        # Only if nothing restarted the room's queue meanwhile (a skip, a new
        # room): then this pass is stale, and the next one puts it right.
        if (d.get("now") or {}).get("uid") == deck["now"]["uid"] and d.get("pushed") == deck["pushed"] \
                and d.get("pushedFrom") == deck.get("pushedFrom"):
            d.update(pushed=pushed, pushedFrom=current)
            return True
        return False
    if not deck_update(record):
        DECK.with_name("deck-sonos.again").touch()


def deck_sonos_soon():
    """deck_sonos_sync in the background: one at a time; asked while one
    runs, that one goes round again."""
    DECK.parent.mkdir(parents=True, exist_ok=True)
    DECK.with_name("deck-sonos.again").touch()
    try:
        with open(DECK.with_name("deck-sonos.lock"), "a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        return
    subprocess.Popen([str(REPO / "bin/afterlight"), "deck", "sonos-sync"], stdin=subprocess.DEVNULL,
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)


# ---- playing

def deck_where_room(deck):
    where = deck.get("where") or {}
    if where.get("kind") != "sonos":
        return None
    return next((r for r in sonos_rooms() if r["id"] == where.get("room")), None)


def deck_play_laptop(song, start_at=0):
    """Start one song in its app on the laptop."""
    if song["service"] == "beatport":
        # Load the track's page now; press its Play in the background, so the
        # Deck isn't held up while the page loads.
        url = beatport_track_url(song)
        beatport_open(url)
        subprocess.Popen([str(REPO / "bin/afterlight"), "beatport", "press", url], stdin=subprocess.DEVNULL,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        return
    if song["service"] == "applemusic":
        reply, give_up = None, time.time() + 25
        for attempt in range(30):
            reply = am_bridge({"action": "queue", "kind": "song", "id": song["id"]}, timeout=12)
            if (reply and reply.get("ok")) or time.time() > give_up:
                break
            if attempt == 0 and (not reply or reply.get("error") == "no Apple Music tab"):
                subprocess.Popen(["omarchy-launch-webapp", AM + "/"], stdout=subprocess.DEVNULL,
                                 stderr=subprocess.DEVNULL, start_new_session=True)
                give_up = time.time() + 40          # the window has to open first
            time.sleep(0.5)
        if not (reply and reply.get("ok")):
            toast("Apple Music couldn't play it", song["title"][:80], glyph="󰝛")
            note = STATE.parent / "deck-errors.log"
            with open(note, "a") as log:
                log.write(json.dumps({"at": int(time.time()), "song": song.get("id"), "title": song["title"][:80],
                                      "reply": reply}, default=str)[:600] + "\n")
        if start_at > 2:
            am_bridge({"action": "seek", "seconds": start_at}, timeout=4)
    else:
        with open(os.devnull, "w") as quiet, contextlib.redirect_stdout(quiet):
            ytm_play({"kind": "song", "video": song["video"], "title": song["title"], "playlist": "", "browse": "",
                      "subtitle": ""})


def deck_status(deck):
    """Where the playing song is: {time, length, playing}, from its player."""
    room = deck_where_room(deck)
    if room:
        position = sonos_call(room["ip"], "AVTransport", "GetPositionInfo", {"InstanceID": 0}) or {}
        state = (sonos_call(room["ip"], "AVTransport", "GetTransportInfo", {"InstanceID": 0}) or {}).get("CurrentTransportState", "")
        def secs(text):
            try:
                h, m, s = (int(x) for x in text.split(":"))
                return h * 3600 + m * 60 + s
            except ValueError:
                return 0
        return {"time": secs(position.get("RelTime", "")), "length": secs(position.get("TrackDuration", "")),
                "playing": state in {"PLAYING", "TRANSITIONING"}, "track": int(position.get("Track") or 0)}
    song = deck.get("now") or {}
    if song.get("service") == "applemusic":
        now = am_now() or {}
        item = now.get("item") or {}
        return {"time": now.get("time", 0), "length": now.get("duration", 0), "playing": bool(now.get("playing")),
                "id": str(item.get("id", "")), "title": str(item.get("title", ""))}
    track = laptop_track() or {}
    return {"time": track.get("position", 0), "length": track.get("length", 0), "playing": bool(track.get("playing")),
            "title": track.get("title", "")}


def deck_start(deck, song=None, start_at=0):
    """Play song (or the next in the set) wherever the Deck plays."""
    was = deck.get("now") or deck.pop("was", None)
    was_playing = deck.get("playing")
    if song is None:
        if not deck["set"]:
            deck["playing"] = False
            return False
        song = deck["set"].pop(0)
    if deck.get("now") and deck["now"]["uid"] != song["uid"]:
        deck["played"] = (deck["played"] + [{**deck["now"], "playedAt": int(time.time())}])[-DECK_HISTORY:]
    deck["now"] = song
    deck["set"] = [s for s in deck["set"] if s["uid"] != song["uid"]]
    deck["playing"] = True
    deck["paused"] = False
    room = deck_where_room(deck)
    if room:
        sn = sonos_apple_sn()
        if not sn:
            toast("Sonos needs one Apple Music song first", "Play any Apple Music song in a room once (Send to Sonos does it)",
                  glyph="󰀦")
            deck["playing"] = False
            return False
        pushed = deck.get("pushed") or []
        on_queue = (sonos_call(room["ip"], "AVTransport", "GetMediaInfo", {"InstanceID": 0}) or {}).get(
            "CurrentURI", "").startswith("x-rincon-queue:")
        if start_at <= 2 and on_queue and song["uid"] in pushed and sonos_call(
                room["ip"], "AVTransport", "Seek",
                {"InstanceID": 0, "Unit": "TRACK_NR", "Target": (deck.get("pushedFrom") or 1) + pushed.index(song["uid"])}) is not None:
            # Already in the room's queue (Next, or a song further on): jump to it.
            sonos_call(room["ip"], "AVTransport", "Play", {"InstanceID": 0, "Speed": 1})
        else:
            deck["pushed"] = deck_sonos_push(room, [song] + deck["set"], sn, start_at)
            deck["pushedFrom"] = 1
            if deck.get("crossfade"):
                sonos_call(room["ip"], "AVTransport", "SetCrossfadeMode", {"InstanceID": 0, "CrossfadeMode": 1})
            laptop = laptop_track()
            if laptop and laptop["playing"] and media_command("pause") != "tab":
                quiet_out("busctl", "--user", "call", laptop["player"], "/org/mpris/MediaPlayer2", "org.mpris.MediaPlayer2.Player", "Pause")
        deck_sonos_soon()
        if song["uid"] not in deck["pushed"]:
            toast(f"{song['title']} isn't on Apple Music", "Sonos plays the Deck from Apple Music; skipped it", glyph="󰀦")
        toast(f"Playing in {room['name']}", f"{song['title']} · {song['artist']}", art=sonos_now(room)["track"].get("art", ""))
    else:
        # One app at a time: the one that played before stops. When it can be
        # paused on its own, the new song starts first (no silence between);
        # otherwise it's paused first, so the pause can't catch the new one.
        other = was and was.get("service") != song.get("service") and was_playing
        if other and deck_can_quiet(was):
            deck_play_laptop(song, start_at)
            deck_quiet(was)
        else:
            if other:
                deck_quiet(was)
            deck_play_laptop(song, start_at)
    deck["expect"] = {"uid": song["uid"], "since": time.time()}
    deck_watch()
    return True


def deck_page(song, op):
    """An op for the page a song plays in (YouTube Music or Beatport)."""
    request = {"type": "page", "op": op}
    if song.get("service") == "ytmusic":
        request["site"] = "ytmusic"
    return beatport_bridge(request, timeout=3) or {}


def deck_can_quiet(song):
    """Can the app a song plays in be paused on its own, without touching any
    other tab? (Apple Music always; the others with add-on 1.12.)"""
    if song.get("service") == "applemusic":
        return True
    reply = deck_page(song, {"type": "pause-media", "dry": True})
    # Beatport's player isn't an element on the page; its bar's Pause button is.
    return bool(reply.get("ok")) and (reply.get("count", 0) > 0 or song.get("service") == "beatport")


def deck_quiet(song):
    """Pause the app a song played in (switching to another app mid-song)."""
    if song.get("service") == "applemusic":
        am_bridge({"action": "pause"}, timeout=4)
        return
    reply = deck_page(song, {"type": "pause-media"})
    if song.get("service") == "beatport" and reply.get("ok") and not reply.get("count"):
        if beatport_player_playing():
            beatport_bridge({"type": "page", "op": {"type": "click", "label": "^Pause$", "region": "bar", "wait": 1500}}, timeout=4)
        return
    if not reply.get("ok") or not reply.get("count"):
        media_command("pause")


def deck_previous(deck):
    """Back: to the start of the song if it's a few seconds in, else the song
    before it (from what's played), with this one next again."""
    if deck.get("now") and deck["playing"] and deck_status(deck).get("time", 0) > 5:
        return deck_start(deck, deck["now"])
    if not deck["played"]:
        return deck_start(deck, deck["now"]) if deck.get("now") else False
    before = deck["played"].pop()
    if deck.get("now"):
        deck["set"].insert(0, deck["now"])
        deck["was"] = deck["now"]   # its app stops, if the one before plays elsewhere
        deck["now"] = None          # so it isn't counted as played again
    return deck_start(deck, before)


def deck_watch():
    """Start the watcher if it isn't running."""
    try:
        with open(DECK_RUN_LOCK, "a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        return
    except OSError:
        return
    subprocess.Popen([str(REPO / "bin/afterlight"), "deck", "run"], stdin=subprocess.DEVNULL,
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)


def deck_tick(last):
    """One look at the player: move the set along when a song ends, follow a
    Sonos room through its queue, step back if you've taken over. Returns the
    status for next time."""
    deck = deck_read()
    deck_closing(deck)
    if not deck["playing"] or not deck.get("now"):
        return None
    if deck_autodj_due(deck):
        deck_update(lambda d: d.update(autodjAt=time.time()))
        service = (deck.get("now") or {}).get("service") or "applemusic"
        subprocess.Popen([str(REPO / "bin/afterlight"), "deck", "fill", "--auto", "--service", service], stdin=subprocess.DEVNULL,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    if deck_sleep_due(deck):
        deck_update(lambda d: (deck_pause(d), d.update(sleep=None)) if d["playing"] else None)
        toast("Good night", "The Deck stopped, as asked", glyph="󰒲")
        return None
    if deck_voice_due(deck):
        rid = deck["now"]["rid"]
        deck_update(lambda d: d.update(spoken=((d.get("spoken") or []) + [rid])[-200:]))
        subprocess.Popen([str(REPO / "bin/afterlight"), "deck", "say", deck["now"]["uid"]], stdin=subprocess.DEVNULL,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    # The next song has a dedication: have its clip ready (in the voice picked,
    # and as an mp3 for a room) long before it's needed.
    coming = deck["set"][0] if deck["set"] else None
    if coming and deck_voice_due({**deck, "now": coming}) and not deck_voice_made(coming, deck) \
            and time.time() - (deck.get("voicePrep") or {}).get(coming["rid"], 0) > 45:
        deck_update(lambda d: d.update(voicePrep={coming["rid"]: time.time()}))
        subprocess.Popen([str(REPO / "bin/afterlight"), "deck", "voice", "make", coming["rid"]], stdin=subprocess.DEVNULL,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    if (deck.get("voiceUntil") or 0) > time.time():
        return last         # a Sonos room is saying a dedication: don't follow its queue meanwhile
    status = deck_status(deck)
    write_atomic(DECK_NOW, json.dumps({**status, "uid": deck["now"]["uid"], "at": time.time()}) + "\n")
    room = deck_where_room(deck)
    if room:
        # The room plays the queue itself: follow which song it's on.
        index = status.get("track", 0) - deck.get("pushedFrom", 1)
        pushed = deck.get("pushed") or []
        if 0 < index < len(pushed) and pushed[index] != deck["now"]["uid"]:
            uid = pushed[index]
            def advance(d):
                ordered = [d["now"]] + d["set"] if d.get("now") else d["set"]
                at = next((i for i, s in enumerate(ordered) if s["uid"] == uid), None)
                if at is None:
                    return
                d["played"] = (d["played"] + [{**x, "playedAt": int(time.time())} for x in ordered[:at]])[-DECK_HISTORY:]
                d["now"], d["set"] = ordered[at], ordered[at + 1:]
            deck_update(advance)
        # The next song has a dedication: as this one ends, the room says it
        # first and then goes straight into the song.
        left = status.get("length", 0) - status.get("time", 0)
        if status.get("playing") and status.get("length") and 0 < left <= 3.5 and 0 <= index < len(pushed) - 1:
            coming = next((s for s in deck["set"][:1] if s["uid"] == pushed[index + 1]), None)
            if coming and deck_voice_due({**deck, "now": coming}):
                rid = coming["rid"]
                deck_update(lambda d: d.update(spoken=((d.get("spoken") or []) + [rid])[-200:]))
                subprocess.Popen([str(REPO / "bin/afterlight"), "deck", "say", coming["uid"], "--before"], stdin=subprocess.DEVNULL,
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        # Near the end of what the room was given: give it the next songs.
        if pushed and index >= len(pushed) - 3 and len(deck["set"]) > len(pushed) - 1 - max(index, 0):
            deck_sonos_soon()
        return status
    if last is None or time.time() - (deck.get("expect") or {}).get("since", 0) < 6:
        return status       # give a song a moment to start
    song = deck["now"]
    started = (deck.get("expect") or {}).get("since")
    def same(d):
        return d.get("playing") and (d.get("now") or {}).get("uid") == song["uid"] \
            and (d.get("expect") or {}).get("since") == started
    # Nearly over, with more to come: fade it out, then the next one.
    left = status.get("length", 0) - status.get("time", 0)
    if status.get("playing") and status.get("length", 0) > 40 and 0 < left <= 8 and deck["set"] \
            and deck.get("handoff") != song["uid"] and not (deck.get("sleep") or {}).get("song"):
        deck_update(lambda d: d.update(handoff=song["uid"]))
        was = deck_handoff(song, left)
        if was is not None:
            deck_update(lambda d: deck_start(d) if same(d) else None)
            deck_app_volume(song, was)
            return None
    ran_out = last.get("length", 0) and last.get("time", 0) >= last["length"] - 12
    if song["service"] == "applemusic":
        # Apple sometimes plays a song under another catalogue number (the
        # same recording in another album): it's only "something else" when
        # the title differs too.
        changed = status.get("id") and status["id"] != song["id"] \
            and song_key(status.get("title", "")) != song_key(song["title"])
        stopped = not status["playing"] and status.get("time", 0) == 0 and last.get("time", 0) > 5
    else:
        changed = status.get("title") and song_key(status["title"]) != song_key(song["title"])
        stopped = False
    if not (changed or stopped):
        return status
    # Only if the song judged is still the Deck's (same): pressing Next (or
    # Previous, or playing a song) while this looked would otherwise skip again.
    if ran_out or stopped or not last.get("length"):
        deck_update(lambda d: deck_start(d) if same(d) else None)        # the song finished: next
    else:
        # You played something else; or nothing plays at all (a Beatport page
        # Chrome wouldn't start), when the Deck counts as paused, so Play tries again.
        quiet = not status.get("playing")
        deck_update(lambda d: d.update(playing=False, paused=quiet) if same(d) else None)
    return None


def deck_run():
    """The watcher: one at a time, until the Deck stops playing."""
    with open(DECK_RUN_LOCK, "a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return
        last, idle = None, 0
        while idle < 3:
            try:
                status = deck_tick(last)
            except Exception:       # a flaky player never kills the watcher
                status = last
            idle = idle + 1 if status is None else 0
            last = status
            time.sleep(1.5 if deck_where_room(deck_read()) is None else 2.5)


# ---- Beatport in the Deck: tracks found through Beatport's own search, your
# library playlists read in a background tab, each track's details from its
# page, played in the Beatport app (on Sonos: the same song from Apple Music).

def beatport_image(release, size=300):
    for key in ("release_image_dynamic_uri", "image_dynamic_uri", "dynamic_uri"):
        uri = str((release or {}).get(key) or "")
        if "{w}x{h}" in uri and uri.startswith("https://"):
            return uri.replace("{w}x{h}", f"{size}x{size}")
    image = (release or {}).get("image")
    if isinstance(image, dict):
        return beatport_image(image, size)
    uri = str((release or {}).get("release_image_uri") or "")
    return uri if uri.startswith("https://") else ""


def beatport_item(t):
    """A Beatport track (from search or its page) as a Deck search result."""
    name = clean_text(str(t.get("track_name") or t.get("name") or ""), 100)
    mix = clean_text(str(t.get("mix_name") or ""), 60)
    artists = ", ".join(clean_text(str(a.get("artist_name") or a.get("name") or ""), 60) for a in t.get("artists") or [] if isinstance(a, dict))
    label = clean_text(str((t.get("label") or {}).get("label_name") or (t.get("label") or {}).get("name") or ""), 60)
    length = t.get("length") or t.get("track_length_ms") or t.get("length_ms") or 0
    key = str(t.get("key_camelot") or "") or camelot(t.get("key_name") or t.get("key") or "")
    return {"kind": "song", "id": str(t.get("track_id") or t.get("id") or ""), "title": f"{name} ({mix})" if mix else name,
            "subtitle": f"{artists} • {label}" if label else artists, "thumb": beatport_image(t.get("release") or {}),
            "slug": re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")[:80],
            "bpm": round(t["bpm"]) if isinstance(t.get("bpm"), (int, float)) else 0, "key": key,
            "length": round(length / 1000) if isinstance(length, int) and length > 1000 else 0}


def beatport_next_data(url):
    reply = beatport_bridge({"type": "fetch", "url": url}, timeout=20) or {}
    m = re.search(r'<script id="__NEXT_DATA__"[^>]*>(.*?)</script>', reply.get("text", ""), re.S)
    try:
        return json.loads(m.group(1))["props"]["pageProps"] if m else {}
    except (ValueError, KeyError):
        return {}


def beatport_search_tracks(query):
    import urllib.parse
    page = beatport_next_data("https://www.beatport.com/search/tracks?q=" + urllib.parse.quote(query[:200]))
    try:
        tracks = next(q["state"]["data"]["data"] for q in page["dehydratedState"]["queries"] if q["queryKey"][0] == "search-tracks")
    except (KeyError, StopIteration, TypeError):
        return []
    return [i for i in (beatport_item(t) for t in tracks[:24] if isinstance(t, dict)) if i["id"].isdigit()]


def beatport_my_playlists():
    known = read_json(BEATPORT_STATE, {}).get("playlists", [])
    return [{"kind": "playlist", "title": re.sub(r"[\x00-\x1f]", "", str(p.get("name", "")))[:100], "subtitle": "Your playlist",
             "url": p["url"], "thumb": "", "mine": True}
            for p in known if isinstance(p, dict) and BEATPORT_URL.match(str(p.get("url", ""))) and "/playlists/" in p["url"]]


def beatport_playlist_tracks(url, limit=100):
    """A Beatport playlist's tracks: the page opened in a background tab (it
    loads its tracks as you, signed in), then each track's details from its page."""
    from concurrent.futures import ThreadPoolExecutor
    if not BEATPORT_URL.match(str(url)) or "/playlists/" not in url:
        return []
    links, last = [], -1
    for _ in range(12):             # until the list has loaded and stopped growing
        reply = beatport_bridge({"type": "scratch", "url": url, "op": {"type": "probe", "region": "page", "filter": "/track/"}}, timeout=25) or {}
        links = [i.get("href", "") for i in reply.get("items", []) if re.fullmatch(r"/track/[\w-]+/\d{1,12}", str(i.get("href", "")))]
        if links and len(links) == last:
            break
        last = len(links)
        time.sleep(1)
    beatport_bridge({"type": "scratch-close"}, timeout=5)
    links = list(dict.fromkeys(links))[:limit]
    def detail(href):
        track = beatport_next_data("https://www.beatport.com" + href).get("track")
        return beatport_item(track) if isinstance(track, dict) else None
    with ThreadPoolExecutor(max_workers=4) as pool:
        return [i for i in pool.map(detail, links) if i and i["id"].isdigit()]


def beatport_track_url(song):
    return f"https://www.beatport.com/track/{song.get('slug') or 'track'}/{song['id']}"


def deck_mine(service):
    """Your own playlists, for the Deck's search before you type."""
    if service == "applemusic":
        return [p for p in am_playlists("*") if p["mine"]]
    if service == "beatport":
        return beatport_my_playlists()
    return [{"kind": "playlist", "title": p["name"], "subtitle": "Your playlist", "playlist": p["playlist"],
             "video": "", "browse": "VL" + p["playlist"], "thumb": p.get("thumb", ""), "mine": True}
            for p in ytm_playlists() if p.get("playlist")]


def deck_search(service, query):
    """What the Deck's search shows: your own playlists that match first,
    then songs, albums and playlists from the service."""
    query = query.strip()[:200]
    if service == "beatport":
        words = set(song_key(query).split())
        mine = [p for p in beatport_my_playlists() if words and words <= set(song_key(p["title"]).split())]
        return mine + beatport_search_tracks(query)
    if service == "applemusic":
        try:
            found = [i for i in am_search(query) if i["kind"] in {"song", "album"}]
        except (OSError, ValueError):
            found = []
        lists = am_playlists(query)
        mine = [p for p in lists if p["mine"]]
        return mine + found[:16] + [p for p in lists if not p["mine"]][:8]
    words = set(song_key(query).split())
    mine = [{"kind": "playlist", "title": p["name"], "subtitle": "Your playlist", "playlist": p["playlist"],
             "video": "", "browse": "VL" + p["playlist"], "thumb": "", "mine": True}
            for p in ytm_playlists() if words and words <= set(song_key(p["name"]).split())]
    # Plain searches rarely bring up playlists: ask for them as well, at once.
    from concurrent.futures import ThreadPoolExecutor
    def look(words):
        try:
            return ytm_search(words)
        except (OSError, ValueError):
            return []
    with ThreadPoolExecutor(max_workers=2) as pool:
        found, lists = pool.map(look, [query, query + " playlist"])
    found = [i for i in found if i["kind"] in {"song", "video", "album", "playlist"}]
    have = {i.get("playlist") for i in found if i["kind"] == "playlist"} | {m["playlist"] for m in mine}
    said = words - set(FILLER)
    extra = [i for i in lists if i["kind"] == "playlist" and i.get("playlist") not in have
             and said & set(song_key(i["title"]).split())][:6]
    found = [i for i in found if not (i["kind"] == "playlist" and i.get("playlist") in {m["playlist"] for m in mine})]
    return mine + found[:16] + extra


# ---- the Deck's song details: length, tempo, key and energy
# Kept apart from the set (deck-details.json, by service and id), so a song
# keeps them however often it comes back. Lengths from Apple's catalogue and
# YouTube Music; tempo and key from Beatport through its window, when it's
# open; energy (1-10) from Grok's fast model, all songs in one question.

def camelot_ok(key):
    return isinstance(key, str) and re.fullmatch(r"(?:[1-9]|1[0-2])[AB]", key) is not None


def deck_song_key(song):
    if song.get("service") == "applemusic" and song.get("id"):
        return "am:" + str(song["id"])
    if song.get("service") == "beatport" and song.get("id"):
        return "bp:" + str(song["id"])
    if song.get("service") == "ytmusic" and song.get("video"):
        return "yt:" + str(song["video"])
    return ""


def deck_details_read():
    value = read_json(DECK_DETAILS, {})
    return value if isinstance(value, dict) else {}


def deck_details_note(song, **fields):
    key = deck_song_key(song)
    if not key:
        return
    DECK_DETAILS.parent.mkdir(parents=True, exist_ok=True)
    with open(DECK_DETAILS_LOCK, "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        details = deck_details_read()
        details[key] = {**details.pop(key, {}), **fields}
        write_atomic(DECK_DETAILS, json.dumps(dict(list(details.items())[-3000:])))


CAMELOT_MINOR = ("Ab", "Eb", "Bb", "F", "C", "G", "D", "A", "E", "B", "F#", "Db")      # 1A … 12A
CAMELOT_MAJOR = ("B", "F#", "Db", "Ab", "Eb", "Bb", "F", "C", "G", "D", "A", "E")      # 1B … 12B
SAME_NOTE = {"Gb": "F#", "C#": "Db", "G#": "Ab", "D#": "Eb", "A#": "Bb", "Cb": "B", "E#": "F", "B#": "C", "Fb": "E"}


def camelot(name):
    """'Gb Minor' as the DJ wheel's '11A'; '' when it isn't a key."""
    m = re.fullmatch(r"([A-G][b#]?)\s*(major|minor|maj|min)", str(name).strip(), re.I)
    if not m:
        return ""
    note, minor = SAME_NOTE.get(m.group(1), m.group(1)), m.group(2).lower().startswith("min")
    table = CAMELOT_MINOR if minor else CAMELOT_MAJOR
    return f"{table.index(note) + 1}{'A' if minor else 'B'}" if note in table else ""


def keys_fit(a, b):
    """Neighbours on the wheel mix: the same key, one step round, or its relative."""
    if not a or not b or a == b:
        return True
    na, nb = int(a[:-1]), int(b[:-1])
    return (a[-1] == b[-1] and (na - nb) % 12 in (1, 11)) or na == nb


def tempos_fit(a, b, within=0.08):
    """Within 8% (or within), counting half and double time."""
    if not a or not b:
        return True
    return any(abs(a * f - b) / b <= within for f in (1, 2, 0.5))


DECK_JUMP = 0.15            # a tempo change past this is worth a ◆ (shaping still aims for 8%)


def deck_artists(song):
    return {a.strip() for a in re.split(r"\s*(?:&|,|\bfeat\.?|\bft\.?|\bx\b|\band\b)\s*", song_key(song.get("artist", ""))) if a.strip()}


def deck_with_details(deck):
    """The set with each song's details, and what really doesn't sit well
    after the song before it: a big jump in tempo, or the same artist again.
    A key that clashes isn't flagged on its own (the key shows anyway), and
    songs a shape has already placed aren't flagged at all: only ones added
    since."""
    details = deck_details_read()
    def fill(song):
        d = details.get(deck_song_key(song), {})
        return {**song, **{k: d[k] for k in ("length", "bpm", "key", "energy") if d.get(k)}}
    deck["now"] = fill(deck["now"]) if deck.get("now") else None
    deck["set"] = [fill(s) for s in deck["set"]]
    deck["played"] = [fill(s) for s in deck["played"]]
    before = deck["now"]
    shaped = set(deck.get("shaped") or [])
    for song in deck["set"]:
        warn = []
        if before and song["uid"] not in shaped:
            if not tempos_fit(before.get("bpm"), song.get("bpm"), DECK_JUMP):
                warn.append("tempo")
            if deck_artists(before) & deck_artists(song):
                warn.append("artist")
        song["warn"] = warn
        before = song
    return deck


def deck_details_wanted(deck, details=None):
    """Songs still missing a detail, not looked for in the last hour."""
    details = deck_details_read() if details is None else details
    songs, seen = [], set()
    asked = [r for r in deck.get("requests") or [] if r.get("service")]     # guests' requests: ready to mix in
    for song in ([deck["now"]] if deck.get("now") else []) + asked + deck["set"] + deck["played"][-10:]:
        key = deck_song_key(song)
        d = details.get(key, {})
        unknown = not all(f in d for f in ("length", "bpm", "energy")) \
            or (not d.get("bpm") and not d.get("web") and song.get("service") != "beatport")   # Grok on the web next
        if key and key not in seen and time.time() - d.get("looked", 0) > 3600 and unknown:
            seen.add(key)
            songs.append(song)
    return songs


def grok_json(prompt, timeout=60):
    """One question to Grok's fast model with every tool off; its JSON answer or None."""
    if not shutil.which("grok"):
        return None
    workdir = STATE.parent / "grok-music"
    workdir.mkdir(parents=True, exist_ok=True)
    try:
        result = subprocess.run(["grok", "-m", GROK_FAST, "--effort", "low", "--tools", "", "--deny", "MCPTool(*)", "-p", prompt,
                                 "--max-turns", "1", "--no-auto-update"], cwd=workdir, capture_output=True,
                                text=True, timeout=timeout, stdin=subprocess.DEVNULL)
        text = result.stdout
        return json.loads(text[text.index("{"):text.rindex("}") + 1])
    except (OSError, subprocess.SubprocessError, ValueError):
        return None


def deck_details_fill():
    """Look up what's missing for the songs in the Deck (one run at a time)."""
    from concurrent.futures import ThreadPoolExecutor
    with open(STATE.parent / "deck-details-run.lock", "a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return
        songs = deck_details_wanted(deck_read())
        for song in songs:
            deck_details_note(song, looked=time.time())
        def wanting(field):
            details = deck_details_read()
            return [s for s in songs if field not in details.get(deck_song_key(s), {})]
        # Lengths: Apple's catalogue in one lookup, YouTube Music a few at a time.
        apple = [s for s in wanting("length") if s["service"] == "applemusic"][:150]
        if apple:
            try:
                got = {str(t["trackId"]): round(t.get("trackTimeMillis", 0) / 1000)
                       for t in am_lookup({"id": ",".join(s["id"] for s in apple)}) if t.get("trackId")}
            except (OSError, ValueError):
                got = {}
            for song in apple:
                if song["id"] in got:
                    deck_details_note(song, length=got[song["id"]])
        def yt_length(song):
            try:
                return song, int((ytm_call("player", {"videoId": song["video"]}).get("videoDetails") or {}).get("lengthSeconds") or 0)
            except (OSError, ValueError, TypeError, AttributeError):
                return song, None
        with ThreadPoolExecutor(max_workers=4) as pool:
            for song, length in pool.map(yt_length, [s for s in wanting("length") if s["service"] == "ytmusic"][:60]):
                if length is not None:
                    deck_details_note(song, length=length)
        # Energy: Grok, every song in one question.
        need = wanting("energy")[:80]
        if need:
            listing = "\n".join(f"{i + 1}. {s['title']} by {s['artist']}" for i, s in enumerate(need)).replace("»", "")
            answer = grok_json("Answer from your own knowledge; use no tools. For a DJ, rate each song's energy from 1 "
                               "(calm) to 10 (peak). Reply with ONLY compact JSON, no prose: {\"e\":[7,4]} with one number "
                               "per song, in the same order.\n" + listing[:6000]) or {}
            energies = answer.get("e") if isinstance(answer.get("e"), list) else []
            if len(energies) == len(need):
                for song, energy in zip(need, energies):
                    deck_details_note(song, energy=energy if isinstance(energy, int) and 1 <= energy <= 10 else 0)
        # Tempo and key: Beatport, while its window is open.
        if beatport_windows():
            for song in [s for s in wanting("bpm") if s["service"] != "beatport"][:25]:
                title = re.sub(r"\s*\[[^\]]*\]", "", song["title"])
                artist = sorted(deck_artists(song), key=lambda a: song_key(song["artist"]).find(a))[:1]
                found = beatport_find({"title": title, "artist": artist[0] if artist else song["artist"]})
                if found is None and beatport_bridge({"type": "ping"}, timeout=2) is None:
                    break           # the bridge went away: try again later
                deck_details_note(song, bpm=round((found or {}).get("bpm") or 0),
                                  key=camelot((found or {}).get("key", "")),
                                  **({"length": found["length"]} if found and found.get("length")
                                     and not deck_details_read().get(deck_song_key(song), {}).get("length") else {}))
        # What Beatport didn't have (or with its window closed): Grok on the web, once per song.
        details = deck_details_read()
        missing = [s for s in songs if s["service"] != "beatport"
                   and not details.get(deck_song_key(s), {}).get("bpm") and not details.get(deck_song_key(s), {}).get("web")]
        if missing:
            deck_details_web(missing)


def grok_web_json(prompt, timeout=170):
    """One question to Grok's fast model that may search and read the web
    (nothing else: no shell, no files, no other tools); its JSON or None."""
    if not shutil.which("grok"):
        return None
    workdir = STATE.parent / "grok-music"
    workdir.mkdir(parents=True, exist_ok=True)
    try:
        result = subprocess.run(["grok", "-m", GROK_FAST, "--effort", "low", "--tools", "WebSearch,WebFetch",
                                 "--allow", "WebSearch", "--allow", "WebFetch", "--deny", "MCPTool(*)", "--deny", "Bash",
                                 "--deny", "Edit", "--deny", "Write", "-p", prompt, "--max-turns", "16", "--no-auto-update"],
                                cwd=workdir, capture_output=True, text=True, timeout=timeout, stdin=subprocess.DEVNULL)
        text = result.stdout
        return json.loads(text[text.index("{"):text.rindex("}") + 1])
    except (OSError, subprocess.SubprocessError, ValueError):
        return None


def deck_details_web(songs):
    """Tempo and key for songs Beatport didn't have: Grok looks each up on the
    web (song tempo sites), a few songs to a question. Marked as from the web."""
    from concurrent.futures import ThreadPoolExecutor
    def ask(batch):
        listing = "\n".join(f"{i + 1}. {s['title']} by {s['artist']}" for i, s in enumerate(batch)).replace("»", "")
        answer = grok_web_json(
            "For a DJ: find each song's tempo (BPM) and musical key, looking it up on the web (sites like "
            "songbpm.com, tunebat.com, musicstax.com, getsongbpm.com). Use the original studio version. Reply with "
            "ONLY compact JSON, no prose: {\"s\":[{\"bpm\":120,\"key\":\"A minor\"}]} with one object per song, "
            "in the same order; null for what you can't find.\n" + listing[:3000]) or {}
        found = answer.get("s") if isinstance(answer.get("s"), list) else []
        return batch, found if len(found) == len(batch) else []
    batches = [songs[i:i + 8] for i in range(0, min(len(songs), 24), 8)]
    with ThreadPoolExecutor(max_workers=3) as pool:
        for batch, found in pool.map(ask, batches):
            for song, got in zip(batch, found):
                got = got if isinstance(got, dict) else {}
                bpm = got.get("bpm")
                bpm = round(bpm) if isinstance(bpm, (int, float)) and 50 <= bpm <= 220 else 0
                key = camelot(str(got.get("key") or "").replace("♯", "#").replace("♭", "b"))
                deck_details_note(song, bpm=bpm, key=key, web=True)


def deck_details_soon(deck):
    """Start looking up missing details in the background, if any are."""
    if deck_details_wanted(deck):
        subprocess.Popen([str(REPO / "bin/afterlight"), "deck", "details"], stdin=subprocess.DEVNULL,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)


# ---- changing the set: undo, several songs at once, chapters, saved sets

def deck_edit(change):
    """deck_update for a change you might want to take back: the set as it was
    goes on the undo list first (the last 30)."""
    def remembered(d):
        stack = read_list(DECK_UNDO)
        stack = (stack if isinstance(stack, list) else [])[-29:] + [{"set": d["set"], "pinned": d["pinned"]}]
        write_atomic(DECK_UNDO, json.dumps(stack))
        return change(d)
    return deck_update(remembered)


def deck_undo():
    stack = read_list(DECK_UNDO)
    if not isinstance(stack, list) or not stack:
        return False
    last = stack.pop()
    def back(d):
        gone = ({d["now"]["uid"]} if d.get("now") else set()) | {s["uid"] for s in d["played"]}
        d["set"] = [s for s in last.get("set", []) if isinstance(s, dict) and s.get("uid") not in gone]
        d["pinned"] = [u for u in last.get("pinned", []) if isinstance(u, str)]
    deck_update(back)
    write_atomic(DECK_UNDO, json.dumps(stack))
    return True


def deck_place(d, where, uids):
    """Several songs (from the set or what's played) now, next or last, in set order."""
    wanted = set(uids)
    songs = [s for s in d["set"] if s["uid"] in wanted] + [s for s in d["played"] if s["uid"] in wanted]
    if not songs:
        return False
    d["set"] = [s for s in d["set"] if s["uid"] not in wanted]
    d["played"] = [s for s in d["played"] if s["uid"] not in wanted]
    d["set"] = d["set"] + songs if where == "end" else songs + d["set"]
    return deck_start(d) if where == "now" else True


def deck_chapter_run(d, uid):
    """Where the chapter starting at uid begins and ends in the set."""
    at = next((i for i, s in enumerate(d["set"]) if s["uid"] == uid), None)
    if at is None:
        return None, None
    name = d["set"][at].get("chapter", "")
    end = at + 1
    while end < len(d["set"]) and d["set"][end].get("chapter", "") == name:
        end += 1
    return at, end


def deck_chapter(d, uid, name):
    """Name the chapter from this song on (to where the next one starts);
    an empty name joins it to the one before."""
    at = next((i for i, s in enumerate(d["set"]) if s["uid"] == uid), None)
    if at is None:
        return
    old = d["set"][at].get("chapter", "")
    if not name:
        name = d["set"][at - 1].get("chapter", "") if at > 0 else ""
    for song in d["set"][at:]:
        if song.get("chapter", "") != old:
            break
        if name:
            song["chapter"] = name
        else:
            song.pop("chapter", None)


def deck_move_chapter(d, uid, index):
    at, end = deck_chapter_run(d, uid)
    if at is None:
        return
    run = d["set"][at:end]
    rest = d["set"][:at] + d["set"][end:]
    index = max(0, min(len(rest), index - (len(run) if index > at else 0)))
    d["set"] = rest[:index] + run + rest[index:]


def deck_sets():
    value = read_list(DECK_SETS)
    return [s for s in value if isinstance(s, dict) and s.get("name") and isinstance(s.get("songs"), list)] \
        if isinstance(value, list) else []


def deck_save_set(name, part="next"):
    """Save what's to come (with what's playing), what's been played (with
    what's playing), or the whole night, under a name."""
    name = clean_text(name, 60)
    deck = deck_read()
    now = [deck["now"]] if deck.get("now") else []
    songs = {"played": deck["played"] + now, "all": deck["played"] + now + deck["set"]}.get(part, now + deck["set"])
    if not name or not songs:
        return False
    saved = [s for s in deck_sets() if s["name"].lower() != name.lower()]
    saved.insert(0, {"name": name, "saved": time.time(), "songs": [{k: v for k, v in s.items() if k not in ("warn", "playedAt")} for s in songs][:300]})
    write_atomic(DECK_SETS, json.dumps(saved[:50]))
    return True


def deck_load_set(name, replace=False):
    found = next((s for s in deck_sets() if s["name"].lower() == name.lower()), None)
    if not found:
        return False
    songs = [{**s, "uid": os.urandom(4).hex()} for s in found["songs"] if isinstance(s, dict) and s.get("service") in DECK_SERVICES]
    def load(d):
        if replace:
            d["set"], d["pinned"] = songs, []
        else:
            d["set"] = d["set"] + songs
    deck_edit(load)
    return True


def deck_set_list():
    """Saved sets, each with what's in it: how long, which services, and
    where its songs came from (playlists, albums, a brief), most first."""
    from collections import Counter
    details = deck_details_read()
    names = {"applemusic": "Apple Music", "ytmusic": "YouTube Music", "beatport": "Beatport"}
    out = []
    for s in deck_sets():
        services = Counter(names.get(x.get("service"), "") for x in s["songs"])
        origins = Counter(x.get("from") or "" for x in s["songs"])
        out.append({"name": s["name"], "saved": s.get("saved", 0), "count": len(s["songs"]),
                    "minutes": round(sum(details.get(deck_song_key(x), {}).get("length", 0) for x in s["songs"]) / 60),
                    "services": [f"{n} {c}" for n, c in services.most_common() if n],
                    "from": [o for o, _ in origins.most_common() if o][:3] + (["search"] if origins.get("") else []),
                    "thumbs": [x.get("thumb", "") for x in s["songs"][:4]]})
    return out


# ---- pausing, crossfade and the sleep timer

def deck_shape(d, how):
    """Reorder the set by its details, around pinned songs:
    tempo      slowest to fastest
    smooth     each song the nearest tempo to the one before (from what's playing)
    energy     calm to peak
    arc        ease in, peak about two thirds of the way, wind down
    harmonic   each song in a key that mixes with the one before, near in tempo
    Songs without the detail keep their order, after the others."""
    details = deck_with_details({**d, "set": list(d["set"]), "played": [], "now": d.get("now")})
    full = {s["uid"]: s for s in details["set"]}
    slots = [i for i, s in enumerate(d["set"]) if s["uid"] not in d["pinned"]]
    songs = [d["set"][i] for i in slots]
    info = lambda s: full.get(s["uid"], {})
    d["shaped"] = [s["uid"] for s in d["set"]]      # placed by a shape: no ◆ for these
    if how == "bumps":
        return deck_smooth_bumps(d, full, details.get("now"))
    field = {"tempo": "bpm", "smooth": "bpm", "energy": "energy", "arc": "energy", "harmonic": "key"}.get(how)
    if not field:
        return False
    known = [s for s in songs if info(s).get(field)]
    rest = [s for s in songs if not info(s).get(field)]
    if how == "tempo":
        known.sort(key=lambda s: info(s)["bpm"])
    elif how == "energy":
        known.sort(key=lambda s: info(s)["energy"])
    elif how == "arc":
        rising = sorted(known, key=lambda s: info(s)["energy"])
        head = [s for i, s in enumerate(rising) if i % 3 != 2]
        tail = [s for i, s in enumerate(rising) if i % 3 == 2]
        known = head + tail[::-1]
    else:
        # From the song just before the first one that moves (a pinned one, or what's playing).
        here = (full.get(d["set"][slots[0] - 1]["uid"]) if slots and slots[0] > 0 else details.get("now")) or {}
        ordered, left = [], list(known)
        while left:
            def cost(s):
                x = info(s)
                tempo = abs((x.get("bpm") or 0) - (here.get("bpm") or x.get("bpm") or 0))
                if how == "smooth":
                    return tempo
                return (0 if keys_fit(here.get("key"), x.get("key")) else 40) + tempo / 2 \
                    + abs((x.get("energy") or 5) - (here.get("energy") or 5))
            best = min(left, key=cost)
            ordered.append(best)
            left.remove(best)
            here = info(best)
        known = ordered
    for i, song in zip(slots, known + rest):
        d["set"][i] = song
    return True


def deck_bump(before, song):
    """How badly song sits after before: a key clash or a tempo jump 2 each,
    the same artist again 3."""
    if not before:
        return 0
    return (0 if keys_fit(before.get("key"), song.get("key")) else 2) \
        + (0 if tempos_fit(before.get("bpm"), song.get("bpm")) else 2) \
        + (3 if deck_artists(before) & deck_artists(song) else 0)


def deck_smooth_bumps(d, full, now):
    """Fix the bumps: keep the order, but move a song that doesn't sit well
    (the ◆ ones) to wherever it fits best, one move at a time, while that
    makes the set smoother. Pinned songs stay put."""
    info = lambda s: full.get(s["uid"], s)
    pinned = set(d["pinned"])
    def total(seq):
        return sum(deck_bump(info(a) if a else now, info(b)) for a, b in zip([None] + seq[:-1], seq))
    seq = list(d["set"])
    best = total(seq)
    moved = False
    for _ in range(40):
        bumpy = [i for i, s in enumerate(seq) if s["uid"] not in pinned
                 and (deck_bump(info(seq[i - 1]) if i else now, info(s)) or
                      (i + 1 < len(seq) and deck_bump(info(s), info(seq[i + 1]))))]
        choice = None
        for i in bumpy:
            rest = seq[:i] + seq[i + 1:]
            for j in range(len(rest) + 1):
                if j == i:
                    continue
                trial = rest[:j] + [seq[i]] + rest[j:]
                # pinned songs keep their places
                if any(trial[k]["uid"] != seq[k]["uid"] for k in range(len(seq)) if seq[k]["uid"] in pinned):
                    continue
                score = total(trial)
                if score < best and (choice is None or score < choice[0]):
                    choice = (score, trial)
        if not choice:
            break
        best, seq, moved = choice[0], choice[1], True
    d["set"] = seq
    return moved or True


def deck_pause(d):
    d["playing"] = False
    d["paused"] = bool(d.get("now"))      # the play key carries on with the Deck
    room = deck_where_room(d)
    if room:
        sonos_call(room["ip"], "AVTransport", "Pause", {"InstanceID": 0})
    elif d.get("now", {}) and d["now"].get("service") == "applemusic":
        am_bridge({"action": "pause"}, timeout=4)
    else:
        media_command("pause")


def deck_crossfade(d, on):
    """Sonos fades one song into the next; the laptop plays them one by one."""
    d["crossfade"] = bool(on)
    room = deck_where_room(d)
    if room:
        sonos_call(room["ip"], "AVTransport", "SetCrossfadeMode", {"InstanceID": 0, "CrossfadeMode": 1 if on else 0})


def deck_sleep(d, when):
    """Stop after some minutes, at the end of this song, or not at all."""
    if when == "song" and d.get("now"):
        d["sleep"] = {"song": d["now"]["uid"]}
    elif str(when).isdigit() and 0 < int(when) <= 600:
        d["sleep"] = {"at": time.time() + int(when) * 60}
    else:
        d["sleep"] = None


def deck_sleep_due(d):
    sleep = d.get("sleep") or {}
    if sleep.get("at"):
        return time.time() >= sleep["at"]
    return bool(sleep.get("song")) and (d.get("now") or {}).get("uid") != sleep["song"]


# ---- export: a set as a new playlist on a service, with the songs found there

def deck_match(service, song):
    """The id of this song on service ("" when it isn't there): its own, or
    found by title and artist (the same title, an artist in common)."""
    if song.get("service") == service:
        return str(song.get("video") if service == "ytmusic" else song.get("id", ""))
    if service == "applemusic":
        return deck_apple_id(song)
    title = re.sub(r"[(\[][^)\]]*[)\]]", "", song.get("title", "")).strip()
    try:
        found = beatport_search_tracks(f"{title} {song.get('artist', '')}") if service == "beatport" else ytm_search(f"{title} {song.get('artist', '')}")
    except (OSError, ValueError):
        return ""
    artists = deck_artists(song)
    for item in found:
        if item.get("kind") != "song" or song_key(item["title"]) != song_key(song.get("title", "")):
            continue
        if not artists or artists & deck_artists({"artist": str(item.get("subtitle", "")).split(" • ")[0]}):
            return str(item.get("video") if service == "ytmusic" else item.get("id", ""))
    return ""


def deck_export(service, name, songs):
    """Make a new playlist called name on service with the songs found there.
    Returns {ok, found, missing: [titles]}."""
    from concurrent.futures import ThreadPoolExecutor
    with ThreadPoolExecutor(max_workers=4) as pool:
        ids = list(pool.map(lambda s: deck_match(service, s), songs[:300]))
    found = list(dict.fromkeys(i for i in ids if i))
    missing = [s["title"] for s, i in zip(songs, ids) if not i]
    if not found:
        return {"ok": False, "found": 0, "missing": missing}
    if service == "applemusic":
        reply = am_bridge({"action": "export", "name": name, "ids": found}, timeout=30)
    elif service == "ytmusic":
        reply = beatport_bridge({"type": "page", "site": "ytmusic", "op": {"type": "ytm-export", "title": name, "ids": found}}, timeout=30)
    else:
        reply = beatport_bridge({"type": "page", "op": {"type": "bp-export", "name": name, "ids": found}}, timeout=30)
    return {"ok": bool((reply or {}).get("ok")), "found": len(found), "missing": missing,
            "error": str((reply or {}).get("error") or ("" if reply else "the add-on isn't answering"))[:120]}


# ---- guests' requests: a page on the home network where guests search Apple
# Music and ask for a song; requests wait in the Deck until you take them.

DECK_GUESTS_QR = STATE.parent / "deck-guests.png"
DECK_GUESTS_PEOPLE = STATE.parent / "deck-guests.json"     # who's asked before: a name, maybe a photo
DECK_GUESTS_PHOTOS = STATE.parent / "deck-guests"
DECK_GUESTS_PICKS = 5          # songs a guest can send at once
DECK_GUESTS_ASKS = STATE.parent / "deck-guests-asks.json"  # what each guest asked for (their phone shows it)


def deck_guest_asks(gid):
    asks = read_json(DECK_GUESTS_ASKS, {})
    mine = asks.get(gid) if isinstance(asks, dict) else None
    return mine if isinstance(mine, list) else []


def deck_guest_status(deck, ask, starts):
    """Where a guest's request is now: waiting, in the set (and about when),
    playing, played, or not this time."""
    rid = ask.get("rid")
    if any(r.get("rid") == rid for r in deck.get("requests") or []):
        return {"state": "waiting"}
    if (deck.get("now") or {}).get("rid") == rid:
        return {"state": "playing"}
    for i, (song, at) in enumerate(zip(deck["set"], starts)):
        if song.get("rid") == rid:
            return {"state": "set", "at": int(time.time() + at), **({"next": True} if i == 0 else {})}
    if any(x.get("rid") == rid for x in deck["played"]):
        return {"state": "played"}
    return {"state": "declined"}


def deck_starts(deck):
    """Seconds from now until each song in the set starts."""
    details = deck_details_read()
    length = lambda s: details.get(deck_song_key(s), {}).get("length") or 210
    mark = read_json(DECK_NOW, {})
    t = 0
    if deck.get("now"):
        t = max(0, (mark.get("length") or length(deck["now"])) - (mark.get("time") or 0)) \
            if mark.get("uid") == deck["now"]["uid"] else length(deck["now"]) / 2
    out = []
    for song in deck["set"]:
        out.append(t)
        t += length(song)
    return out
DECK_GUESTS_PORT = 8765
DECK_GUESTS_HOURS = 8           # the page closes itself after a night


def lan_address():
    try:
        out = subprocess.run(["ip", "route", "get", "1.1.1.1"], capture_output=True, text=True, timeout=3).stdout
    except (OSError, subprocess.SubprocessError):
        return ""
    m = re.search(r"\bsrc (\d{1,3}(?:\.\d{1,3}){3})\b", out)
    return m.group(1) if m else ""


# Words a dedication can't have: it's read out to the whole room. Matched as
# whole words after undoing look-alikes (sh1t, @ss), and a few also inside words.
NOTE_BLOCKED = {"fuck", "fucking", "fucker", "fucked", "motherfucker", "shit", "shitty", "bullshit", "cunt", "cunts",
                "twat", "wanker", "wank", "bitch", "bitches", "bastard", "dickhead", "cock", "prick", "pussy",
                "arse", "arsehole", "ass", "asshole", "slut", "whore", "bollocks", "tits", "nigger", "nigga", "faggot",
                "retard", "retarded", "spastic", "spaz", "paki", "chink", "kike", "tranny", "dyke", "rape", "nazi"}
NOTE_BLOCKED_INSIDE = ("fuck", "nigg", "fagg", "motherf")
NOTE_LOOKALIKE = str.maketrans({"0": "o", "1": "i", "!": "i", "3": "e", "4": "a", "@": "a", "5": "s", "$": "s", "7": "t", "*": "u"})


def note_friendly(note):
    """True if a dedication is fine to show and read out."""
    plain = str(note or "").lower().translate(NOTE_LOOKALIKE)
    words = re.findall(r"[a-z]+", plain)
    # Spelt out a letter at a time ("f u c k"): read the run as one word.
    words += ["".join(run.split()) for run in re.findall(r"\b(?:[a-z]\s+){2,}[a-z]\b", plain)]
    squashed = re.sub(r"(.)\1+", r"\1", re.sub(r"[^a-z]", "", plain))          # fuuuck
    return not (any(w in NOTE_BLOCKED or re.sub(r"(.)\1+", r"\1", w) in NOTE_BLOCKED for w in words)
                or any(bad in squashed for bad in NOTE_BLOCKED_INSIDE))


STAY_AWAKE = Path.home() / ".local/state/omarchy/indicators/stay-awake"


def idle_set(how):
    try:
        return subprocess.run(["omarchy-toggle-idle", how], capture_output=True, timeout=5).returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


def deck_awake(on):
    """While requests are open the laptop stays awake (no lock, no sleep), and
    afterwards goes back to how it was: idle is let back only if we stopped it."""
    if on and not STAY_AWAKE.exists():
        if idle_set("stay-awake"):
            deck_update(lambda d: d.update(awoke=True))
    elif not on and deck_read().get("awoke"):
        idle_set("allow-idle")
        deck_update(lambda d: d.update(awoke=False))


RECAP_MINUTES = 10             # how long the recap stays on the stage, unless closed sooner


def deck_tonight(deck):
    """Tonight's songs, in the order they played (and the one playing now)."""
    since = (deck.get("guests") or {}).get("since") or time.time() - 6 * 3600
    return [x for x in deck["played"] if x.get("playedAt", 0) >= since - 3600] + ([deck["now"]] if deck.get("now") else [])


def deck_recap(deck):
    """The night in a card: how many songs and how long, requests and
    dedications, the most loved song, the top guests, and covers to fill it."""
    songs = deck_tonight(deck)
    if not songs:
        return None
    start = min((x.get("playedAt") or time.time()) for x in songs)
    votes = deck.get("votes") or {}
    ups = lambda x: sum(1 for v in (votes.get(x.get("uid")) or {}).values() if v == 1)
    loved = max(songs, key=ups)
    covers = []
    for x in reversed(songs):
        if x.get("thumb") and x["thumb"] not in covers:
            covers.append(x["thumb"])
    return {"songs": len(songs), "minutes": int((time.time() - start) / 60),
            "requests": sum(1 for x in songs if x.get("rid")), "dedications": sum(1 for x in songs if x.get("note")),
            "loved": {k: loved.get(k, "") for k in ("title", "artist", "thumb", "by", "photo")} | {"up": ups(loved)} if ups(loved) else None,
            "top": [{k: p.get(k) for k in ("name", "photo", "played")} for p in deck_people(deck) if p.get("played")][:5],
            "covers": covers[:30]}


def deck_closing(deck):
    """Last call ran out: say thank you, and show the night's recap."""
    closes = deck.get("lastCall") or 0
    if not closes or time.time() < closes or deck.get("closedAt") == closes:
        return False
    deck_update(lambda d: d.update(closedAt=closes, recapAt=time.time()))
    subprocess.Popen([str(REPO / "bin/afterlight"), "deck", "voice", "call", "0"], stdin=subprocess.DEVNULL,
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    return True


def deck_ready():
    """Before the party: is everything in place? Each check is (ok, words):
    ok True, False (needs fixing) or None (can't tell / not in use)."""
    deck = deck_read()
    out = []
    guests = deck.get("guests") or {}
    up = bool(guests) and deck_guests_alive(guests)
    if up:
        try:
            import urllib.request
            with urllib.request.urlopen(guests["url"] + "/now", timeout=3) as r:
                up = r.status == 200
        except OSError:
            up = False
    out.append({"key": "page", "ok": up if guests else None,
                "text": "Requests page is up" if up else "Requests page isn't answering: close and open requests" if guests
                else "Requests are closed: open them to check the page and phones"})
    if guests:
        seen = deck.get("phoneSeen") or 0
        firewall = quiet_out("systemctl", "is-active", "ufw").strip() == "active"
        rule = None
        if firewall:
            status = subprocess.run(["sudo", "-n", "ufw", "status"], capture_output=True, text=True, timeout=5)
            if status.returncode == 0:
                rule = bool(re.search(rf"^{DECK_GUESTS_PORT}(/tcp)?\s+ALLOW", status.stdout, re.M))
        ok = True if seen >= (guests.get("since") or 0) or not firewall or rule else False if rule is False else None
        out.append({"key": "phones", "ok": ok,
                    "text": "A phone has reached the page" if seen >= (guests.get("since") or 0)
                    else "No firewall in the way of phones" if not firewall
                    else "The firewall lets phones in" if rule
                    else f"The firewall blocks phones: sudo ufw allow from 192.168.0.0/16 to any port {DECK_GUESTS_PORT} proto tcp" if rule is False
                    else "Phones: scan the QR code with yours to check"})
    out.append({"key": "qr", "ok": bool(shutil.which("qrencode")),
                "text": "QR code works" if shutil.which("qrencode") else "No QR code without qrencode (omarchy pkg add qrencode)"})
    if not deck.get("voice", True):
        out.append({"key": "voice", "ok": None, "text": "Dedications aren't read out (Read dedications is off)"})
    else:
        out.append({"key": "voice", "ok": voice_ready(),
                    "text": f"Voice ready: {next((v[1] for v in VOICES if v[0] == deck_voice_name(deck)), 'on')}" if voice_ready()
                    else "No voice yet: afterlight voice install"})
    room = deck_where_room(deck)
    if (deck.get("where") or {}).get("kind") == "sonos":
        answer = sonos_call(room["ip"], "AVTransport", "GetTransportInfo", {"InstanceID": 0}, timeout=2) if room else None
        out.append({"key": "sonos", "ok": answer is not None,
                    "text": f"{room['name']} answers" if answer is not None else "The Sonos room isn't answering"})
    else:
        out.append({"key": "sonos", "ok": None, "text": "Playing on the laptop"})
    awake = STAY_AWAKE.exists()
    out.append({"key": "awake", "ok": awake,
                "text": "The laptop stays awake" if awake else "The laptop may lock or sleep: opening requests keeps it awake"})
    people = len(deck_people(deck))
    waiting = len(deck.get("requests") or [])
    if people or waiting:
        out.append({"key": "fresh", "ok": None,
                    "text": f"{people} guest{'s' * (people != 1)} and {waiting} waiting request{'s' * (waiting != 1)} from before: Start fresh for a clean night"})
    deck_update(lambda d: d.update(ready={"at": time.time(), "items": out}))
    return out


def deck_guests_on():
    """Open the requests page: a server on the home network, at a link with a
    secret in it, and a QR code of that link for the Deck to show."""
    was = deck_read().get("guests") or {}
    deck_guests_off(awake=True)
    ip = lan_address()
    if not ip:
        sys.exit("Not on a network.")
    import secrets
    # Open again within the night (or after an update): the same link, so the
    # QR codes guests already scanned keep working.
    old = str(was.get("url", "")).rsplit("/", 1)[-1]
    fresh = time.time() - (was.get("since") or 0) < DECK_GUESTS_HOURS * 3600
    token = old if fresh and re.fullmatch(r"[A-Za-z0-9_-]{8,40}", old) else secrets.token_urlsafe(9)
    url = f"http://{ip}:{DECK_GUESTS_PORT}/{token}"
    for clip in VOICE_DIR.glob("*.*") if VOICE_DIR.is_dir() else []:
        if time.time() - clip.stat().st_mtime > 2 * 86400:
            clip.unlink(missing_ok=True)        # spoken dedications from earlier nights
    proc = subprocess.Popen([str(REPO / "bin/afterlight"), "deck", "guests", "serve", token], stdin=subprocess.DEVNULL,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    try:
        subprocess.run(["qrencode", "-o", str(DECK_GUESTS_QR), "-s", "10", "-m", "2", url], timeout=5, check=True)
    except (OSError, subprocess.SubprocessError):
        DECK_GUESTS_QR.unlink(missing_ok=True)
    since = int(was.get("since") or time.time()) if token == old else int(time.time())
    if token != old:
        deck_update(lambda d: d.update(lastCall=0))
    deck_update(lambda d: d.update(guests={"url": url, "pid": proc.pid, "since": since,
                                           "qr": str(DECK_GUESTS_QR) if DECK_GUESTS_QR.is_file() else ""}))
    deck_awake(True)
    return url


def deck_guests_alive(guests):
    pid = (guests or {}).get("pid")
    try:
        return isinstance(pid, int) and pid > 1 and "deck guests serve" in \
            Path(f"/proc/{pid}/cmdline").read_bytes().replace(b"\0", b" ").decode(errors="ignore")
    except OSError:
        return False


def deck_guests_heal(deck):
    """Requests are open but their server has gone (a crash, a restart): start
    it again, at the same link. Not after the night's 8 hours."""
    guests = deck.get("guests") or {}
    if guests and not deck_guests_alive(guests) and time.time() - (guests.get("since") or 0) < DECK_GUESTS_HOURS * 3600:
        subprocess.Popen([str(REPO / "bin/afterlight"), "deck", "guests", "on"], stdin=subprocess.DEVNULL,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        return True
    return False


def deck_guests_off(awake=False):
    guests = deck_read().get("guests") or {}
    if deck_guests_alive(guests):
        try:
            os.kill(guests["pid"], 15)
        except OSError:
            pass
    if guests:
        deck_update(lambda d: d.update(guests=None))
    DECK_GUESTS_QR.unlink(missing_ok=True)
    if not awake:
        deck_awake(False)


def deck_crowd(deck):
    """What guests voted for tonight: songs with more 👍 than 👎, and the other way."""
    songs = {x["uid"]: x for x in deck["played"][-60:] + ([deck["now"]] if deck.get("now") else [])}
    up, down = [], []
    for uid, votes in (deck.get("votes") or {}).items():
        total = sum(v for v in votes.values() if v in (1, -1))
        song = songs.get(uid)
        if song and total:
            (up if total > 0 else down).append(f"{song['title']} by {song['artist']}".replace("»", ""))
    return {"up": up[-12:], "down": down[-8:]}


def deck_people(deck):
    """Tonight's guests who asked for something: name, face, how many asked,
    how many played. Most played first (the top contributors)."""
    since = (deck.get("guests") or {}).get("since") or 0
    people = read_json(DECK_GUESTS_PEOPLE, {})
    asks = read_json(DECK_GUESTS_ASKS, {})
    if not isinstance(people, dict) or not isinstance(asks, dict):
        return []
    played = {x.get("rid") for x in deck["played"] + ([deck["now"]] if deck.get("now") else []) if x.get("rid")}
    out = []
    for gid, person in people.items():
        tonight = [a for a in asks.get(gid) or [] if a.get("at", 0) >= since - 3600 * 4]
        if not tonight or not isinstance(person, dict):
            continue
        photo = DECK_GUESTS_PHOTOS / f"{gid}.jpg"
        out.append({"gid": gid, "name": person.get("name", ""), "photo": str(photo) if person.get("photo") and photo.is_file() else "",
                    "asked": len(tonight), "played": sum(1 for a in tonight if a.get("rid") in played)})
    return sorted(out, key=lambda p: (-p["played"], -p["asked"], p["name"].lower()))[:40]


def deck_guest_drop(gid):
    """Forget one guest: their name, selfie and what they asked for. Their
    phone asks who they are next time; songs already in the set stay."""
    for path in (DECK_GUESTS_PEOPLE, DECK_GUESTS_ASKS):
        data = read_json(path, {})
        if isinstance(data, dict) and gid in data:
            data.pop(gid)
            write_atomic(path, json.dumps(data))
    (DECK_GUESTS_PHOTOS / f"{gid}.jpg").unlink(missing_ok=True)
    deck_update(lambda d: d.update(requests=[r for r in d.get("requests") or [] if r.get("gid") != gid]))


def deck_guest_person(gid):
    """Who a guest's code belongs to ({} for a stranger)."""
    if not re.fullmatch(r"[A-Za-z0-9_-]{12}", gid or ""):
        return {}
    people = read_json(DECK_GUESTS_PEOPLE, {})
    person = people.get(gid) if isinstance(people, dict) else None
    return person if isinstance(person, dict) else {}


def deck_guest_song(item):
    """A search result as guests see it (only what the page needs)."""
    artist = str(item.get("subtitle", "")).split(" • ")[0]
    return {"id": item["id"], "title": item["title"], "artist": clean_text(artist, 100), "thumb": item.get("thumb", "")}


def deck_guests_serve(token):
    """The requests page. Only three things are possible: see what's playing,
    search Apple Music, and ask for a song that search returned. Each phone
    can ask once every 20 seconds and have at most 5 waiting."""
    import http.server
    import threading
    import urllib.parse
    template = (REPO / "web/requests.html").read_text()
    own, seen_at = lan_address(), [0]
    def page():
        """The page in the theme you're running now (read each time, so a
        theme change reaches the phones on their next refresh)."""
        try:
            colors = read_colors(STATE_HOME / "omarchy/current/theme/colors.toml")
        except OSError:
            colors = {}
        out = template
        for key, name, default in (("BG", "background", "#120c18"), ("INK", "foreground", "#f2e9f5"),
                                   ("ACCENT", "accent", "#ff5aa5"), ("CYAN", "cyan", "#62b6ff")):
            value = str(colors.get(name, ""))
            out = out.replace(f"__{key}__", value if re.fullmatch(r"#[0-9a-fA-F]{6}", value) else default)
        return out.encode()
    served, asked, lock = {}, {}, threading.Lock()
    started = time.time()

    class Page(http.server.BaseHTTPRequestHandler):
        server_version = "Baseline"
        sys_version = ""

        def log_message(self, *args):
            pass

        def send(self, code, body, kind="application/json"):
            data = body if isinstance(body, bytes) else json.dumps(body).encode()
            self.send_response(code)
            self.send_header("Content-Type", kind + ("; charset=utf-8" if kind.startswith(("text/", "application/json")) else ""))
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Content-Security-Policy", "default-src 'self'; img-src https: data: blob:; style-src 'unsafe-inline'; script-src 'unsafe-inline'")
            self.end_headers()
            self.wfile.write(data)

        def route(self):
            path = urllib.parse.urlsplit(self.path)
            parts = path.path.strip("/").split("/")
            if not parts or parts[0] != token or len(parts) > 2:
                return None, None
            return (parts[1] if len(parts) == 2 else ""), urllib.parse.parse_qs(path.query)

        def seen(self):
            # A phone (not this laptop) reached the page: the firewall lets them in.
            if self.client_address[0] not in (own, "127.0.0.1") and time.time() - seen_at[0] > 60:
                seen_at[0] = time.time()
                deck_update(lambda d: d.update(phoneSeen=int(time.time())))

        def do_GET(self):
            self.seen()
            # A spoken dedication, for a Sonos room to play (made by deck say; nothing else is served).
            parts = urllib.parse.urlsplit(self.path).path.strip("/").split("/")
            if len(parts) == 3 and parts[0] == token and parts[1] == "voice":
                clip = VOICE_DIR / parts[2]
                if re.fullmatch(r"(?:[0-9a-f]{8}|sample|call\d{1,3})-[a-z_]{3,12}\.mp3", parts[2]) and clip.is_file():
                    return self.send(200, clip.read_bytes(), "audio/mpeg")
                return self.send(404, b"", "text/plain")
            where, query = self.route()
            if where is None:
                return self.send(404, b"", "text/plain")
            if where == "":
                return self.send(200, page(), "text/html")
            if where == "mine":
                gid = str((query.get("gid") or [""])[0])
                deck = deck_read()
                starts = deck_starts(deck)
                mine = [{"title": a["title"], "artist": a["artist"], "thumb": a.get("thumb", ""), "id": a["id"],
                         **deck_guest_status(deck, a, starts)} for a in reversed(deck_guest_asks(gid))][:20]
                return self.send(200, {"asks": mine})
            if where == "me":
                person = deck_guest_person(str((query.get("gid") or [""])[0]))
                return self.send(200, {"known": bool(person), "name": person.get("name", ""), "photo": bool(person.get("photo"))})
            if where == "now":
                deck = deck_read()
                gid = str((query.get("gid") or [""])[0])
                show = lambda x: {"title": x.get("title", ""), "artist": x.get("artist", ""), "thumb": x.get("thumb", "")}
                now = deck.get("now")
                votes = (deck.get("votes") or {}).get(now["uid"], {}) if now else {}
                closes = deck.get("lastCall") or 0
                speaks = bool(deck.get("voice", True) and voice_ready())
                # How far into the song, so the phone's bar can run on between polls.
                mark = read_json(DECK_NOW, {})
                where_in = {"pos": round((mark.get("time") or 0) + (time.time() - (mark.get("at") or time.time()) if mark.get("playing") else 0), 1),
                            "length": mark.get("length") or 0, "running": bool(mark.get("playing") and deck.get("playing"))} \
                    if now and mark.get("uid") == now["uid"] and mark.get("length") else {}
                return self.send(200, {"now": {**show(now), **where_in, "uid": now["uid"], "by": now.get("by", ""), "note": now.get("note", ""),
                                               "up": sum(1 for v in votes.values() if v == 1),
                                               "down": sum(1 for v in votes.values() if v == -1),
                                               "mine": votes.get(gid, 0)} if now else None,
                                       "next": [show(x) for x in deck["set"][:3]],
                                       "lastCall": closes, "closed": bool(closes and time.time() >= closes), "voice": speaks})
            if where == "played":
                deck = deck_read()
                since = (deck.get("guests") or {}).get("since") or 0
                songs = [x for x in deck["played"] if x.get("playedAt", 0) >= since - 3600] + ([deck["now"]] if deck.get("now") else [])
                mine = {a.get("rid") for a in deck_guest_asks(str((query.get("gid") or [""])[0]))}
                link = lambda x: f"https://music.apple.com/song/{x['id']}" if x.get("service") == "applemusic" and x.get("id") \
                    else "https://music.apple.com/search?term=" + urllib.parse.quote(f"{x.get('title', '')} {x.get('artist', '')}")
                return self.send(200, {"songs": [{"title": x.get("title", ""), "artist": x.get("artist", ""), "thumb": x.get("thumb", ""),
                                                  "link": link(x), "by": x.get("by", ""),
                                                  "mine": bool(x.get("rid") and x["rid"] in mine)} for x in songs][-200:]})
            if where == "search":
                words = clean_text((query.get("q") or [""])[0], 100)
                if not words:
                    return self.send(200, {"songs": []})
                songs = [deck_guest_song(i) for i in am_search(words) if i.get("kind") == "song"][:12]
                with lock:
                    for item in songs:
                        served[item["id"]] = item
                deck = deck_read()
                mine = {a["id"] for a in deck_guest_asks(str((query.get("gid") or [""])[0]))}
                queued = {x.get("id") for x in deck["set"] + [deck.get("now") or {}]} | {r["id"] for r in deck.get("requests") or []}
                for item in songs:
                    item["state"] = "asked" if item["id"] in mine else "set" if item["id"] in queued else ""
                return self.send(200, {"songs": [{k: v for k, v in x.items()} for x in songs]})
            return self.send(404, b"", "text/plain")

        def body(self, most):
            try:
                length = int(self.headers.get("Content-Length") or 0)
                if length > most:
                    return None
                value = json.loads(self.rfile.read(length) or b"{}")
                return value if isinstance(value, dict) else None
            except ValueError:
                return None

        def do_POST(self):
            self.seen()
            where, _ = self.route()
            if where == "hello":
                return self.hello()
            if where == "vote":
                return self.vote()
            if where != "ask":
                return self.send(404, b"", "text/plain")
            body = self.body(4000)
            if body is None:
                return self.send(400, {"ok": False})
            ids = body.get("ids") if isinstance(body.get("ids"), list) else [body.get("id")]
            songs = [served[str(i)] for i in dict.fromkeys(str(i) for i in ids[:DECK_GUESTS_PICKS]) if str(i) in served]
            if not songs:
                return self.send(200, {"ok": False, "error": "Search for it first."})
            closes = deck_read().get("lastCall") or 0
            if closes and time.time() >= closes:
                return self.send(200, {"ok": False, "error": "Requests are closed for tonight. Thanks!"})
            phone = self.client_address[0]
            with lock:
                if time.time() - asked.get(phone, 0) < 20:
                    return self.send(200, {"ok": False, "error": "Hang on a few seconds, then send again."})
                asked[phone] = time.time()
            gid = str(body.get("gid", ""))
            person = deck_guest_person(gid)
            before = {a["id"]: a for a in deck_guest_asks(gid)} if person else {}
            again = [x for x in songs if x["id"] in before]
            songs = [x for x in songs if x["id"] not in before]
            if not songs:
                deck = deck_read()
                state = deck_guest_status(deck, before[again[0]["id"]], deck_starts(deck))["state"]
                words = {"waiting": "it's waiting for the DJ", "set": "it's in the set", "playing": "it's playing now",
                         "played": "it's been played", "declined": "the DJ passed on it this time"}[state]
                return self.send(200, {"ok": False, "error": f"You've asked for {again[0]['title']} already: {words}."})
            by = person.get("name") or clean_text(str(body.get("by", "")), 30)
            note = clean_text(str(body.get("note", "")), 120)
            if note and not note_friendly(note):
                return self.send(200, {"ok": False, "error": "Let's keep the dedication friendly: it's shown and read out to everyone. Try other words."})
            photo = str(DECK_GUESTS_PHOTOS / f"{body.get('gid')}.jpg") if person.get("photo") else ""
            def ask(d):
                waiting = d.get("requests") or []
                mine = sum(1 for r in waiting if r.get("phone") == phone)
                fresh = []
                for song in songs:
                    if any(r["id"] == song["id"] for r in waiting + fresh) or any(x.get("id") == song["id"] for x in d["set"]):
                        continue
                    if mine + len(fresh) >= 8:
                        break
                    fresh.append({**song, "service": "applemusic", "rid": os.urandom(4).hex(), "by": by, "photo": photo, "phone": phone,
                                  "gid": gid if person else "", "note": note, "at": int(time.time())})
                d["requests"] = (waiting + fresh)[-40:]
                d["asks"] = ((d.get("asks") or []) + [{k: r.get(k, "") for k in ("rid", "by", "photo", "title", "artist", "thumb", "note")}
                                                      | {"at": time.time()} for r in fresh])[-8:]
                return [r["rid"] for r in fresh], bool(d.get("requestsAuto"))
            taken, auto = deck_update(ask)
            if person and taken:
                with lock:
                    asks = read_json(DECK_GUESTS_ASKS, {})
                    asks = asks if isinstance(asks, dict) else {}
                    waiting = {r["rid"]: r for r in deck_read().get("requests") or []}
                    mine = asks.pop(gid, []) + [{k: waiting[rid][k] for k in ("rid", "id", "title", "artist", "thumb")}
                                                 | {"at": int(time.time())} for rid in taken if rid in waiting]
                    asks[gid] = mine[-40:]
                    write_atomic(DECK_GUESTS_ASKS, json.dumps(dict(list(asks.items())[-300:])))
            if taken:
                # Its tempo, key and length now, so it's ready to mix in; with
                # Mix in by itself, it goes in once they're known.
                subprocess.Popen([str(REPO / "bin/afterlight"), "deck", "request", "settle", *(taken if auto else [])],
                                 stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                 start_new_session=True)
            if not taken:
                return self.send(200, {"ok": False, "error": "Someone's asked for that already (or you've 8 waiting)."})
            first = songs[0]
            toast(f"Request: {first['title']}" + (f" +{len(taken) - 1}" if len(taken) > 1 else ""),
                  first["artist"] + (f" · from {by}" if by else ""), art=photo, glyph="󰎈")
            return self.send(200, {"ok": True, "sent": len(taken), "again": [x["title"] for x in again]})

        def vote(self):
            """👍 or 👎 for what's playing (or take it back), one per guest per song."""
            body = self.body(500)
            if body is None:
                return self.send(400, {"ok": False})
            gid, uid, v = str(body.get("gid", "")), str(body.get("uid", "")), body.get("v")
            if not deck_guest_person(gid) or v not in (1, -1, 0):
                return self.send(200, {"ok": False})
            def cast(d):
                if (d.get("now") or {}).get("uid") != uid:
                    return False
                votes = d.get("votes") or {}
                mine = votes.pop(uid, {})
                if v:
                    mine[gid] = v
                else:
                    mine.pop(gid, None)
                votes[uid] = mine
                d["votes"] = dict(list(votes.items())[-80:])
                return True
            return self.send(200, {"ok": bool(deck_update(cast))})

        def hello(self):
            """A guest says who they are (a name, maybe a selfie); they're
            remembered by a code their phone keeps, next time too."""
            body = self.body(400000)
            if body is None:
                return self.send(400, {"ok": False})
            name = clean_text(str(body.get("name", "")), 30)
            gid = str(body.get("gid", ""))
            if not re.fullmatch(r"[A-Za-z0-9_-]{12}", gid):
                import secrets
                gid = secrets.token_urlsafe(9)
            if not name and not deck_guest_person(gid):
                return self.send(200, {"ok": False, "error": "Say who you are."})
            photo = None
            raw = str(body.get("photo") or "")
            if raw.startswith("data:image/jpeg;base64,"):
                import base64
                try:
                    data = base64.b64decode(raw.split(",", 1)[1], validate=True)
                except ValueError:
                    data = b""
                if data[:3] == b"\xff\xd8\xff" and len(data) <= 250000:
                    DECK_GUESTS_PHOTOS.mkdir(parents=True, exist_ok=True)
                    (DECK_GUESTS_PHOTOS / f"{gid}.jpg").write_bytes(data)
                    photo = True
            with lock:
                people = read_json(DECK_GUESTS_PEOPLE, {})
                people = people if isinstance(people, dict) else {}
                known = people.pop(gid, {})
                people[gid] = {"name": name or known.get("name", ""), "photo": bool(photo or known.get("photo")),
                               "seen": int(time.time())}
                write_atomic(DECK_GUESTS_PEOPLE, json.dumps(dict(list(people.items())[-300:])))
            return self.send(200, {"ok": True, "gid": gid, "name": people[gid]["name"], "photo": people[gid]["photo"]})

    class Server(http.server.ThreadingHTTPServer):
        daemon_threads = True
        request_queue_size = 16

    server = Server(("0.0.0.0", DECK_GUESTS_PORT), Page)
    server.timeout = 30
    def closing():
        while True:
            time.sleep(30)
            if time.time() - started > DECK_GUESTS_HOURS * 3600 or (deck_read().get("guests") or {}).get("url", "").rsplit("/", 1)[-1] != token:
                server.shutdown()
                return
    threading.Thread(target=closing, daemon=True).start()
    server.serve_forever()
    if (deck_read().get("guests") or {}).get("url", "").endswith(token):
        deck_update(lambda d: d.update(guests=None))
        deck_awake(False)


def deck_request_take(rid, where="end"):
    """Put a guest's request in the set (next, or at the end); True if it was there."""
    def take(d):
        found = next((r for r in d.get("requests") or [] if r.get("rid") == rid), None)
        if not found:
            return None
        d["requests"] = [r for r in d["requests"] if r.get("rid") != rid]
        song = deck_item("applemusic", {"id": found["id"], "title": found["title"], "artist": found["artist"],
                                        "thumb": found.get("thumb", ""),
                                        "from": f"Request · {found['by']}" if found.get("by") else "Request"})
        song.update({k: found[k] for k in ("rid", "gid", "by", "photo", "note") if found.get(k)})
        if where == "next":
            d["set"].insert(0, song)
        elif where == "mix":
            d["set"].insert(deck_mix_spot(d, song), song)
        else:
            d["set"].append(song)
        return song
    song = deck_edit(take)
    if song and song.get("note") and voice_ready():
        subprocess.Popen([str(REPO / "bin/afterlight"), "deck", "voice", "make", rid], stdin=subprocess.DEVNULL,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    return song


DECK_MIX_REACH = 8              # a request mixed in plays within about this many songs


def deck_mix_spot(d, song):
    """Where a song fits best in the next few: the gap it sits in most
    smoothly (key, tempo, artist), a little sooner rather than later, and
    never ahead of a pinned song's place."""
    details = deck_with_details({**d, "set": list(d["set"]) + [song], "played": [], "now": d.get("now")})
    full = {s["uid"]: s for s in details["set"]}
    me = full.get(song["uid"], song)
    ordered = [details.get("now")] + [full.get(s["uid"], s) for s in d["set"]]
    best, spot = None, min(len(d["set"]), 1)
    for i in range(min(len(d["set"]), DECK_MIX_REACH) + 1):
        before, after = ordered[i], ordered[i + 1] if i + 1 < len(ordered) else None
        if after and after.get("uid") in d["pinned"]:
            continue
        cost = deck_bump(before, me) + (deck_bump(me, after) - deck_bump(before, after) if after else 0) + i * 0.3
        if best is None or cost < best:
            best, spot = cost, i
    return spot


# ---- the hand-off on the laptop: the song fades out over its last seconds,
# then the next starts (in whichever app), and the old app's volume goes back.

def deck_app_volume(song, level=None):
    """The volume (0-1) of the app a song plays in; with level, set it first.
    None when it can't be reached."""
    if song.get("service") == "applemusic":
        reply = am_bridge({"action": "volume", "level": level}, timeout=3)
    else:
        request = {"type": "page", "op": {"type": "volume", "level": level}}
        if song.get("service") == "ytmusic":
            request["site"] = "ytmusic"
        reply = beatport_bridge(request, timeout=3)
    value = (reply or {}).get("level") if (reply or {}).get("ok") else None
    return value if isinstance(value, (int, float)) else None


# ---- dedications read aloud: an offline voice (Kokoro; Piper as the
# "robot") says who a request is from and their message as the song starts.
# On the laptop the music dips under it; a Sonos room plays the clip between
# songs (fetched from the guest page's server), then goes on to the song.

KOKORO_DIR = HOME / ".local/share/baseline/kokoro"
KOKORO_URL = "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/"
KOKORO_FILES = ("kokoro-v1.0.onnx", "voices-v1.0.bin")
PIPER_DIR = HOME / ".local/share/baseline/piper"
PIPER_VOICE = "en_GB-cori-high"
PIPER_VOICE_URL = "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_GB/cori/high/"
VOICE_DIR = STATE.parent / "deck-voice"
VOICE_DUCK = 0.3            # the music, while the voice speaks, as a share of its volume
VOICES = [                  # key, name, what it sounds like (the first is the one we'd pick)
    ("am_michael", "Michael", "warm and relaxed"),
    ("am_fenrir", "Fenrir", "deep, a radio DJ"),
    ("af_heart", "Heart", "warm and smooth"),
    ("bf_emma", "Emma", "soft, British"),
    ("bm_george", "George", "rich, British"),
    ("am_puck", "Puck", "light and playful"),
    ("piper", "Robot", "the first voice, for a laugh"),
]
VOICE_SAMPLE = "Hi, I'm {name}. A request from Sam. For Jess, happy birthday! Here's September, by Earth, Wind and Fire."
KOKORO_SAY = """
import sys, soundfile
from kokoro_onnx import Kokoro
model, voices, voice, lang, out = sys.argv[1:6]
samples, rate = Kokoro(model, voices).create(sys.stdin.read(), voice=voice, speed=0.95, lang=lang)
soundfile.write(out, samples, rate, format="WAV")
"""


def kokoro_ready():
    return (KOKORO_DIR / "venv/bin/python").is_file() and all((KOKORO_DIR / f).is_file() for f in KOKORO_FILES)


def piper_ready():
    return (PIPER_DIR / "venv/bin/piper").is_file() and (PIPER_DIR / f"{PIPER_VOICE}.onnx").is_file() \
        and (PIPER_DIR / f"{PIPER_VOICE}.onnx.json").is_file()


def voices_ready():
    """The voices installed, in VOICES' order."""
    kokoro, piper = kokoro_ready(), piper_ready()
    return [v for v in VOICES if (piper if v[0] == "piper" else kokoro)]


def voice_ready():
    return bool(voices_ready())


def deck_voice_name(deck):
    """The voice the Deck speaks in: the one picked, if it's installed, else the first that is."""
    ready = [v[0] for v in voices_ready()]
    wanted = deck.get("voiceName") or VOICES[0][0]
    return wanted if wanted in ready else (ready[0] if ready else "")


def voice_install(which="kokoro"):
    """Kokoro (about 350 MB) or, with "robot", Piper and one voice (about 175
    MB), each in its own Python made with uv, in ~/.local/share/baseline."""
    if not shutil.which("uv"):
        print("needs uv (omarchy pkg add uv)")
        return False
    if which == "robot":
        folder, packages, ready = PIPER_DIR, ["piper-tts"], piper_ready
        files = [(PIPER_VOICE_URL + n, n) for n in (f"{PIPER_VOICE}.onnx", f"{PIPER_VOICE}.onnx.json")]
    else:
        folder, packages, ready = KOKORO_DIR, ["kokoro-onnx", "soundfile"], kokoro_ready
        files = [(KOKORO_URL + n, n) for n in KOKORO_FILES]
    if ready():
        return True
    folder.mkdir(parents=True, exist_ok=True)
    venv = folder / "venv"
    if not (venv / "bin/python").is_file() and subprocess.run(["uv", "venv", "--python", "3.12", str(venv)],
                                                              stdin=subprocess.DEVNULL).returncode != 0:
        return False
    if subprocess.run(["uv", "pip", "install", "--python", str(venv / "bin/python"), *packages],
                      stdin=subprocess.DEVNULL).returncode != 0:
        return False
    for url, name in files:
        target = folder / name
        if not target.is_file() and subprocess.run(["curl", "-fL", "--retry", "2", "-o", str(target) + ".part", url]).returncode == 0:
            os.replace(str(target) + ".part", target)
    return ready()


def voice_speak(text, voice, wav):
    """Text to a .wav in voice (a Kokoro voice, or "piper"). True if it worked."""
    part = Path(str(wav) + ".part")
    if voice == "piper":
        argv = [str(PIPER_DIR / "venv/bin/piper"), "-m", str(PIPER_DIR / f"{PIPER_VOICE}.onnx"), "-f", str(part)]
    else:
        argv = [str(KOKORO_DIR / "venv/bin/python"), "-I", "-c", KOKORO_SAY, *(str(KOKORO_DIR / f) for f in KOKORO_FILES),
                voice, "en-gb" if voice.startswith("b") else "en-us", str(part)]
    try:
        made = subprocess.run(argv, input=text.encode(), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=90)
    except (OSError, subprocess.SubprocessError):
        part.unlink(missing_ok=True)
        return False
    if made.returncode != 0 or not part.is_file():
        part.unlink(missing_ok=True)
        return False
    os.replace(part, wav)
    return True


def voice_mp3(wav):
    """The .mp3 of a clip, for a Sonos room (made once). None if it can't."""
    out = wav.with_suffix(".mp3")
    if not out.is_file():
        if subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(wav), "-af", "apad=pad_dur=0.4", "-codec:a",
                           "libmp3lame", "-b:a", "160k", "-ar", "44100", str(out) + ".part.mp3"],
                          stdin=subprocess.DEVNULL, timeout=60).returncode != 0:
            return None
        os.replace(str(out) + ".part.mp3", out)
    return out


def deck_voice_text(song):
    title = re.split(r"\s+[\(\[]", song.get("title", ""))[0].strip()
    who = song.get("by") or "a guest"
    note = song.get("note", "").strip()
    words = [f"A request from {who}."]
    if note:
        words.append(note if note[-1] in ".!?" else note + ".")
    artist = song.get("artist", "").replace(" & ", " and ")
    words.append(f"Here's {title}" + (f", by {artist}." if artist else "."))
    return " ".join(words)


def deck_voice_clip(song, mp3=False, voice=None):
    """The spoken dedication for a requested song, in voice (made once per
    voice, kept by request id): the .wav, or the .mp3 for a Sonos room."""
    rid = str(song.get("rid", ""))
    if not re.fullmatch(r"[0-9a-f]{8}", rid) or not song.get("note"):
        return None
    voice = voice or deck_voice_name(deck_read())
    if not voice:
        return None
    VOICE_DIR.mkdir(parents=True, exist_ok=True)
    wav = VOICE_DIR / f"{rid}-{voice}.wav"
    if not wav.is_file() and not voice_speak(deck_voice_text(song), voice, wav):
        return None
    return voice_mp3(wav) if mp3 else wav


def deck_voice_made(song, deck):
    """Its dedication is ready to say where the Deck plays (no waiting)."""
    wav = VOICE_DIR / f"{song.get('rid', '')}-{deck_voice_name(deck)}.wav"
    return wav.is_file() and (not deck.get("where", {}).get("kind") == "sonos" or wav.with_suffix(".mp3").is_file())


def clip_seconds(wav):
    import wave
    with wave.open(str(wav)) as w:
        return w.getnframes() / float(w.getframerate() or 1)


def deck_moment(song, length):
    """What the stage shows while a dedication is read: who, what they said,
    for which song, and until when (kind "call" for a last call)."""
    if not song:
        return None
    return {"kind": song.get("kind", "dedication"), "rid": song.get("rid", ""), "by": song.get("by", ""), "photo": song.get("photo", ""), "note": song.get("note", ""),
            "title": song.get("title", ""), "artist": song.get("artist", ""), "thumb": song.get("thumb", ""),
            "start": time.time(), "until": time.time() + length}


def deck_room_clip(deck, room, mp3, length, track, at=0, song=None):
    """A Sonos room plays a clip (from the guest page's server), then goes
    back to its queue at track (from at seconds) and plays on. With song, the
    stage shows its dedication meanwhile."""
    url = (deck.get("guests") or {}).get("url")
    if not url:
        return False
    ip = room["ip"]
    deck_update(lambda d: d.update(voiceUntil=time.time() + length + 12))
    try:
        sonos_call(ip, "AVTransport", "SetAVTransportURI", {"InstanceID": 0, "CurrentURI": f"{url}/voice/{mp3.name}",
                                                            "CurrentURIMetaData": ""})
        sonos_call(ip, "AVTransport", "Play", {"InstanceID": 0, "Speed": 1})
        started = time.time()
        while time.time() - started < 6:    # it fetches the clip first
            state = (sonos_call(ip, "AVTransport", "GetTransportInfo", {"InstanceID": 0}) or {}).get("CurrentTransportState")
            if state == "PLAYING":
                break
            time.sleep(0.3)
        if song:
            deck_update(lambda d: d.update(speaking=deck_moment(song, length)))
        time.sleep(length + 0.6)
    finally:
        sonos_call(ip, "AVTransport", "SetAVTransportURI", {"InstanceID": 0, "CurrentURI": f"x-rincon-queue:{room['id']}#0",
                                                            "CurrentURIMetaData": ""})
        sonos_call(ip, "AVTransport", "Seek", {"InstanceID": 0, "Unit": "TRACK_NR", "Target": track})
        if at > 2:
            sonos_call(ip, "AVTransport", "Seek", {"InstanceID": 0, "Unit": "REL_TIME", "Target": hms(at)})
        if deck.get("crossfade"):
            sonos_call(ip, "AVTransport", "SetCrossfadeMode", {"InstanceID": 0, "CrossfadeMode": 1})
        sonos_call(ip, "AVTransport", "Play", {"InstanceID": 0, "Speed": 1})
        deck_update(lambda d: d.update(voiceUntil=0, speaking=None))
        deck_sonos_soon()
    return True


DECK_DUCK = STATE.parent / "deck-duck.json"


def deck_duck(song, start):
    """Clips can overlap (a voice sample during a dedication): the music's
    level from before the first dip is kept here, so dips never stack and the
    last clip out puts it back. Starting: that level. Ending: True if this was
    the last clip (and the file is gone)."""
    DECK_DUCK.parent.mkdir(parents=True, exist_ok=True)
    with open(str(DECK_DUCK) + ".lock", "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        held = read_json(DECK_DUCK, {})
        held = held if isinstance(held, dict) and isinstance(held.get("level"), (int, float)) else {}
        if start:
            if held:
                # Still dipped from before (even from a clip that died): that's the real level.
                count = held.get("count", 0) + 1 if time.time() - held.get("at", 0) < 120 else 1
                held.update(count=count, at=time.time())
            else:
                level = deck_app_volume(song)
                if not level:
                    return None
                held = {"level": level, "count": 1, "at": time.time()}
            write_atomic(DECK_DUCK, json.dumps(held))
            return held["level"]
        if not held:
            return True
        held["count"] = held.get("count", 1) - 1
        if held["count"] > 0:
            write_atomic(DECK_DUCK, json.dumps(held))
            return False
        DECK_DUCK.unlink(missing_ok=True)
        return True


def deck_laptop_clip(song, wav, length, moment=False):
    """Play a clip on the laptop, the song's app dipping under it (with
    moment, the stage shows the song's dedication meanwhile)."""
    def ramp(start, end, seconds, steps=6):
        for i in range(1, steps + 1):
            deck_app_volume(song, round(start + (end - start) * i / steps, 3))
            time.sleep(seconds / steps)
    was = deck_duck(song, True) if song else None
    if was:
        now = deck_app_volume(song) or was
        if now > was * VOICE_DUCK + 0.01:
            ramp(now, was * VOICE_DUCK, 0.6)
    if moment:
        deck_update(lambda d: d.update(speaking=deck_moment(song, length)))
    try:
        subprocess.run(["pw-play", str(wav)], stdin=subprocess.DEVNULL, timeout=length + 15)
    finally:
        if moment:
            deck_update(lambda d: d.update(speaking=None))
        if was and deck_duck(song, False):     # the last clip out puts the music back
            ramp(was * VOICE_DUCK, was, 1.5)


def deck_say(uid, before=False):
    """Say the dedication for the song now playing (uid), once it's under way;
    before: for the song coming next in a Sonos room, as the one playing ends,
    so the room goes from the clip straight into it."""
    deck = deck_read()
    song = (deck["set"][0] if before and deck["set"] else deck.get("now")) or {}
    if song.get("uid") != uid or not deck.get("voice", True):
        return False
    room = deck_where_room(deck)
    if before and not room:
        return False
    wav = deck_voice_clip(song, voice=deck_voice_name(deck))
    if not wav:
        return False
    length = clip_seconds(wav)
    if room:
        mp3 = voice_mp3(wav)
        track = int((sonos_call(room["ip"], "AVTransport", "GetPositionInfo", {"InstanceID": 0}) or {}).get("Track") or 0)
        return bool(mp3 and track) and deck_room_clip(deck, room, mp3, length, track + (1 if before else 0), song=song)
    time.sleep(2.5)             # let the song get going: the voice talks over its intro
    deck_laptop_clip(song, wav, length, moment=True)
    return True


def deck_announce(name, text, voice, moment=None):
    """The voice says text now, over whatever plays (laptop dipped, or a room
    cut in on and picked up where it was). name keeps the clip (it's made
    once); moment, the stage shows it meanwhile."""
    deck = deck_read()
    if voice not in [v[0] for v in voices_ready()]:
        return False
    VOICE_DIR.mkdir(parents=True, exist_ok=True)
    wav = VOICE_DIR / f"{name}-{voice}.wav"
    if not wav.is_file() and not voice_speak(text, voice, wav):
        return False
    length = clip_seconds(wav)
    room = deck_where_room(deck) if deck.get("playing") else None
    if room:
        mp3 = voice_mp3(wav)
        position = sonos_call(room["ip"], "AVTransport", "GetPositionInfo", {"InstanceID": 0}) or {}
        try:
            h, m, sec = (int(x) for x in (position.get("RelTime") or "0:0:0").split(":"))
        except ValueError:
            h = m = sec = 0
        return bool(mp3) and deck_room_clip(deck, room, mp3, length, int(position.get("Track") or 1), h * 3600 + m * 60 + sec,
                                            song=moment)
    if moment:
        deck_update(lambda d: d.update(speaking=deck_moment(moment, length)))
    try:
        deck_laptop_clip(deck.get("now") if deck.get("playing") else None, wav, length)
    finally:
        if moment:
            deck_update(lambda d: d.update(speaking=None))
    return True


def deck_voice_sample(voice):
    """A voice says hello and a made-up dedication, wherever the Deck plays."""
    name = next((v[1] for v in VOICES if v[0] == voice), "")
    return deck_announce("sample", VOICE_SAMPLE.format(name=name), voice)


def deck_last_call_say(minutes):
    """Last call, out loud: how long's left (or that requests are closed)."""
    deck = deck_read()
    if not deck.get("voice", True) or not voice_ready():
        return False
    if minutes:
        text = (f"Last call for requests! You've got {minutes} minutes to send in your songs. "
                "Scan the code on the screen, and get your dedications in.")
        title = f"{minutes} minutes left to ask"
    else:
        text = "That's it for requests tonight. Thank you for all your songs, and keep dancing!"
        title = "Requests are closed"
    moment = {"kind": "call", "by": "", "note": text, "title": title, "rid": ""}
    return deck_announce(f"call{minutes}", text, deck_voice_name(deck), moment)


def deck_voice_due(deck):
    """The song just started has a dedication not said yet."""
    song = deck.get("now") or {}
    return bool(deck.get("voice", True) and song.get("note") and song.get("rid")
                and song["rid"] not in (deck.get("spoken") or []) and voice_ready())


HANDOFF_LEAD = 2.5           # seconds before the end the next song is started (it takes a moment to load)


def deck_handoff(song, left):
    """Fade the playing song down over what's left of it, until a couple of
    seconds before the end, when the next one is started and the two overlap
    a little. Returns the volume to put back afterwards, or None when it
    couldn't fade."""
    was = deck_app_volume(song)
    if not was:
        return None
    steps = 10
    for i in range(1, steps + 1):
        deck_app_volume(song, round(was * max(0.08, (1 - i / steps) ** 2), 3))
        time.sleep(max(0.15, (left - HANDOFF_LEAD) / steps))
    return was


def deck_autodj_due(deck):
    """Auto-DJ: with three songs or fewer left, Grok adds more that fit (at
    most every three minutes)."""
    return bool(deck.get("autodj") and deck.get("playing") and len(deck["set"]) <= 3
                and time.time() - (deck.get("autodjAt") or 0) > 180)


def deck_command(settings, args):
    action = args[0] if args else "state"
    if action == "state":
        deck = deck_read()
        deck["rooms"] = [{"id": r["id"], "name": r["name"]} for r in sonos_rooms()]
        stack = read_list(DECK_UNDO)
        deck["undo"] = len(stack) if isinstance(stack, list) else 0
        deck_guests_heal(deck)
        deck["people"] = deck_people(deck) if deck.get("guests") or deck.get("requests") else []
        room = deck_where_room(deck)
        if room:
            level = (sonos_call(room["ip"], "GroupRenderingControl", "GetGroupVolume", {"InstanceID": 0}, timeout=1.5) or {}).get("CurrentVolume")
            deck["roomVolume"] = int(level) if str(level or "").isdigit() else None
        deck["voiceReady"] = voice_ready()
        deck["voiceName"] = deck_voice_name(deck)
        if deck.get("recapAt") and time.time() - deck["recapAt"] < RECAP_MINUTES * 60:
            deck["recap"] = deck_recap(deck)
        deck["voices"] = [{"key": k, "name": n, "about": a} for k, n, a in voices_ready()]
        print(json.dumps(deck_with_details(deck)))
        sys.stdout.flush()
        deck_details_soon(deck)
        if deck["playing"]:
            deck_watch()        # the watcher went away (a restart, a crash): it follows the music again
    elif action == "add" and len(args) >= 3 and args[1] in DECK_SERVICES:
        try:
            item = json.loads(args[2])
        except ValueError:
            sys.exit("Bad song.")
        songs = deck_expand(args[1], item)
        at = -1      # the end
        if "--next" in args or "--play" in args:
            at = 0
        if "--at" in args and args.index("--at") + 1 < len(args) and args[args.index("--at") + 1].isdigit():
            at = int(args[args.index("--at") + 1])
        def add(d):
            known = {(s["service"], s.get("id"), s.get("video")) for s in d["set"]}
            fresh = [s for s in songs if (s["service"], s.get("id"), s.get("video")) not in known]
            if "--scatter" in args:
                # Somewhere: each song at a random spot after the next one, so
                # an album or playlist mixes into the set.
                for song in fresh:
                    d["set"].insert(random.randint(min(1, len(d["set"])), len(d["set"])), song)
                return fresh
            where = len(d["set"]) if at < 0 else min(at, len(d["set"]))
            d["set"][where:where] = fresh
            if "--play" in args and fresh:
                deck_start(d, fresh[0])
            return fresh
        fresh = deck_edit(add)
        if fresh and "--play" not in args:
            toast("Added to the Deck", fresh[0]["title"] + (f" and {len(fresh) - 1} more" if len(fresh) > 1 else ""),
                  glyph="󰐒")
        if "--play" not in args:
            deck_after_edit()
    elif action == "move" and len(args) == 3 and args[2].lstrip("-").isdigit():
        def move(d):
            song = next((s for s in d["set"] if s["uid"] == args[1]), None)
            if song is None:
                song = next((s for s in d["played"] if s["uid"] == args[1]), None)
                if song is None:
                    return
                d["played"] = [s for s in d["played"] if s["uid"] != args[1]]
            d["set"] = [s for s in d["set"] if s["uid"] != args[1]]
            d["set"].insert(max(0, min(len(d["set"]), int(args[2]))), song)
        deck_edit(move)
        deck_after_edit()
    elif action == "remove" and len(args) >= 2:
        gone = set(args[1:])
        deck_edit(lambda d: d.update(set=[s for s in d["set"] if s["uid"] not in gone],
                                     pinned=[u for u in d["pinned"] if u not in gone]))
        deck_after_edit()
    elif action == "place" and len(args) >= 3 and args[1] in {"now", "next", "end"}:
        deck_edit(lambda d: deck_place(d, args[1], args[2:]))
        deck_after_edit()
    elif action == "chapter" and len(args) >= 2:
        deck_edit(lambda d: deck_chapter(d, args[1], clean_text(" ".join(args[2:]), 40)))
    elif action == "move-chapter" and len(args) == 3 and args[2].isdigit():
        deck_edit(lambda d: deck_move_chapter(d, args[1], int(args[2])))
        deck_after_edit()
    elif action == "undo":
        if deck_undo():
            deck_after_edit()
    elif action == "details":
        deck_details_fill()
    elif action == "save" and len(args) >= 2:
        part = next((a[2:] for a in args if a in {"--played", "--all", "--next"}), "next")
        name = " ".join(a for a in args[1:] if a not in {"--played", "--all", "--next"})
        if deck_save_set(name, part):
            toast("Set saved", name[:60], glyph="󰆓")
    elif action == "sets":
        print(json.dumps(deck_set_list()))
    elif action == "load" and len(args) >= 2:
        replace = "--replace" in args
        if deck_load_set(" ".join(a for a in args[1:] if a != "--replace"), replace):
            deck_after_edit()
    elif action == "forget" and len(args) >= 2:
        name = " ".join(args[1:]).lower()
        write_atomic(DECK_SETS, json.dumps([x for x in deck_sets() if x["name"].lower() != name]))
    elif action == "shape" and len(args) == 2:
        if deck_edit(lambda d: deck_shape(d, args[1])):
            deck_after_edit()
        if args[1] in DIRECTIONS:           # and Auto-DJ carries on that way
            deck_update(lambda d: d.update(direction=args[1]))
    elif action == "guests" and len(args) == 2 and args[1] in {"on", "off"}:
        if args[1] == "on":
            print(deck_guests_on())
        else:
            deck_guests_off()
    elif action == "guests" and len(args) == 3 and args[1] == "drop" and re.fullmatch(r"[A-Za-z0-9_-]{12}", args[2]):
        deck_guest_drop(args[2])
    elif action == "recap" and args[1:] in ([], ["off"]):
        deck_update(lambda d: d.update(recapAt=0 if args[1:] else time.time()))
    elif action == "ready" and len(args) == 1:
        for item in deck_ready():
            print({True: "ok  ", False: "FIX ", None: "--  "}[item["ok"]] + item["text"])
    elif action == "guests" and args[1:] == ["forget"]:
        DECK_GUESTS_PEOPLE.unlink(missing_ok=True)
        DECK_GUESTS_ASKS.unlink(missing_ok=True)
        shutil.rmtree(DECK_GUESTS_PHOTOS, ignore_errors=True)
        shutil.rmtree(VOICE_DIR, ignore_errors=True)
        deck_update(lambda d: d.update(requests=[]))
        print("forgot every guest, their photos, waiting requests and spoken dedications")
    elif action == "guests" and len(args) == 3 and args[1] == "serve" and re.fullmatch(r"[A-Za-z0-9_-]{8,40}", args[2]):
        deck_guests_serve(args[2])
    elif action == "request" and len(args) >= 2 and args[1] == "settle":
        # A guest's request just came in: look up its details, then (Mix in by
        # itself) put it where it fits.
        with open(STATE.parent / "deck-settle.lock", "w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            rids = set(args[2:])
            for _ in range(20):                      # another lookup may be running: wait for it (2 minutes at most)
                deck_details_fill()
                details = deck_details_read()
                waiting = [r for r in deck_read().get("requests") or [] if r.get("rid") in rids]
                if not any(not details.get(deck_song_key(r), {}).get("bpm") and not details.get(deck_song_key(r), {}).get("web")
                           for r in waiting):
                    break
                time.sleep(6)
        if any([deck_request_take(rid, "mix") for rid in args[2:] if re.fullmatch(r"[0-9a-f]{8}", rid)]):
            deck_after_edit()
    elif action == "request" and len(args) >= 3 and args[1] in {"take", "drop"}:
        if args[1] == "take":
            if deck_request_take(args[2], "next" if "--next" in args else "mix" if "--mix" in args else "end"):
                deck_after_edit()
        else:
            deck_update(lambda d: d.update(requests=[r for r in d.get("requests") or [] if r.get("rid") != args[2]]))
    elif action == "requests" and args[1:] == ["clear"]:
        deck_update(lambda d: d.update(requests=[]))
    elif action == "requests" and len(args) == 3 and args[1] == "lastcall" and (args[2] == "off" or args[2].isdigit()):
        closes = 0 if args[2] == "off" else int(time.time()) + max(0, min(240, int(args[2]))) * 60
        deck_update(lambda d: d.update(lastCall=closes))
        if closes:
            toast("Last call", "Requests close at " + time.strftime("%H:%M", time.localtime(closes)), glyph="󰄜")
        if args[2] not in ("off", "0"):
            subprocess.Popen([str(REPO / "bin/afterlight"), "deck", "voice", "call", args[2]], stdin=subprocess.DEVNULL,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        elif args[2] == "0":
            deck_closing(deck_read())       # closed now: thank you, and the recap
    elif action == "requests" and len(args) == 3 and args[1] == "auto" and args[2] in {"on", "off"}:
        deck_update(lambda d: d.update(requestsAuto=args[2] == "on"))
    elif action == "volume" and len(args) == 2 and re.fullmatch(r"[+-]?\d{1,3}", args[1]):
        # The room the Deck plays in (not Baseline's Sonos card, which may be another).
        room = deck_where_room(deck_read())
        if not room:
            sys.exit("The Deck isn't playing in a Sonos room.")
        if args[1][0] in "+-":
            sonos_call(room["ip"], "GroupRenderingControl", "SetRelativeGroupVolume", {"InstanceID": 0, "Adjustment": int(args[1])})
        else:
            sonos_call(room["ip"], "GroupRenderingControl", "SetGroupVolume",
                       {"InstanceID": 0, "DesiredVolume": max(0, min(100, int(args[1])))})
    elif action == "mic" and len(args) == 2 and args[1] in {"on", "off"}:
        deck_update(lambda d: d.update(micViz=args[1] == "on"))
    elif action == "voice" and len(args) == 2 and args[1] in {"on", "off"}:
        deck_update(lambda d: d.update(voice=args[1] == "on"))
    elif action == "voice" and len(args) == 3 and args[1] == "make":
        deck = deck_read()
        song = next((s for s in [deck.get("now") or {}] + deck["set"] if s.get("rid") == args[2]), None)
        print(deck_voice_clip(song, mp3=bool(deck_where_room(deck))) if song else "")
    elif action == "voice" and len(args) == 3 and args[1] == "use" and args[2] in [v[0] for v in VOICES]:
        deck_update(lambda d: d.update(voiceName=args[2]))
        subprocess.Popen([str(REPO / "bin/afterlight"), "deck", "voice", "sample", args[2]], stdin=subprocess.DEVNULL,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    elif action == "voice" and len(args) == 3 and args[1] == "call" and args[2].isdigit():
        print("said" if deck_last_call_say(min(240, int(args[2]))) else "the voice is off or not installed")
    elif action == "voice" and len(args) == 3 and args[1] == "sample" and args[2] in [v[0] for v in VOICES]:
        print("said" if deck_voice_sample(args[2]) else "that voice isn't installed")
    elif action == "say" and len(args) in (2, 3) and args[2:] in ([], ["--before"]):
        print("said" if deck_say(args[1], before=args[2:] == ["--before"]) else "nothing to say")
    elif action == "lock" and len(args) == 2 and args[1] in {"on", "off"}:
        deck_update(lambda d: d.update(lock=args[1] == "on"))
    elif action == "autodj" and len(args) == 2 and args[1] in {"on", "off"}:
        deck_update(lambda d: d.update(autodj=args[1] == "on", autodjAt=0, **({} if args[1] == "on" else {"direction": ""})))
        if args[1] == "on":
            deck_watch()
    elif action == "autodj" and len(args) == 4 and args[1] == "from" and args[2] in DECK_SERVICES:
        # Auto-DJ from a song you picked: it goes next, songs that grow from it
        # follow, and Auto-DJ carries the night on from there.
        seed = deck_seed(args[2], args[3])
        deck_update(lambda d: d.update(autodj=True, autodjAt=time.time()))
        deck_fill({**settings, "music": {**(settings.get("music") or {}), "service": args[2]}}, count=6, seed=seed)
        deck_watch()
    elif action == "export" and len(args) >= 3 and args[1] in DECK_SERVICES:
        flags = {"--played", "--all", "--saved"}
        name = " ".join(a for a in args[2:] if a not in flags).strip()[:100]
        deck = deck_read()
        now = [deck["now"]] if deck.get("now") else []
        if "--saved" in args:
            songs = next((x["songs"] for x in deck_sets() if x["name"].lower() == name.lower()), [])
        else:
            songs = deck["played"] + now if "--played" in args else deck["played"] + now + deck["set"] if "--all" in args else now + deck["set"]
        names = {"applemusic": "Apple Music", "ytmusic": "YouTube Music", "beatport": "Beatport"}
        if not name or not songs:
            sys.exit("Nothing to export.")
        toast(f"Finding the songs on {names[args[1]]}…", name, glyph="󰆓")
        result = deck_export(args[1], name, songs)
        print(json.dumps(result))
        if result["ok"]:
            toast(f"Saved to {names[args[1]]}: {name}",
                  f"{result['found']} songs" + (f"; {len(result['missing'])} aren't on {names[args[1]]}" if result["missing"] else ""),
                  glyph="󰆓")
        else:
            toast(f"Couldn't save to {names[args[1]]}", result.get("error") or "None of the songs were found there", glyph="󰀦")
    elif action == "crossfade" and len(args) == 2 and args[1] in {"on", "off"}:
        deck_update(lambda d: deck_crossfade(d, args[1] == "on"))
    elif action == "sleep" and len(args) == 2:
        deck_update(lambda d: deck_sleep(d, args[1]))
    elif action == "pin" and len(args) == 2:
        deck_update(lambda d: d.update(pinned=[u for u in d["pinned"] if u != args[1]] if args[1] in d["pinned"]
                                       else d["pinned"] + [args[1]]))
    elif action == "shuffle":
        def shuffle(d):
            slots = [i for i, s in enumerate(d["set"]) if s["uid"] not in d["pinned"]]
            songs = [d["set"][i] for i in slots]
            random.shuffle(songs)
            for i, song in zip(slots, songs):
                d["set"][i] = song
        deck_edit(shuffle)
        deck_after_edit()
    elif action == "clear":
        deck_edit(lambda d: d.update(set=[], pinned=[]))
        deck_after_edit()
    elif action == "play":
        uid = args[1] if len(args) > 1 else ""
        def play(d):
            if not uid and d.get("now") and not d["playing"]:
                d["playing"] = True        # carry on with what was playing
                d["paused"] = False
                deck_resume(d)
                return True
            song = next((s for s in d["set"] + d["played"] if s["uid"] == uid), None) if uid else None
            if song is not None:
                d["played"] = [s for s in d["played"] if s["uid"] != uid]
            return deck_start(d, song)
        deck_update(play)
    elif action == "pause":
        deck_update(deck_pause)
    elif action == "next":
        deck = deck_read()
        if deck.get("now") and deck["playing"]:
            at = (deck_status(deck) or {}).get("time") or 0
            if 3 < at < DECK_SKIP_SECONDS:      # skipped straight away: Auto-DJ hears "not that"
                gone = {k: deck["now"].get(k, "") for k in ("title", "artist")}
                deck_update(lambda d: d.update(skipped=((d.get("skipped") or []) + [gone])[-20:]))
        deck_update(lambda d: deck_start(d))
    elif action == "previous":
        deck_update(deck_previous)
    elif action == "where" and len(args) == 2:
        deck_where(args[1], settings)
    elif action == "rooms":
        print(json.dumps(deck_rooms()))
    elif action == "mine" and len(args) == 2 and args[1] in DECK_SERVICES:
        print(json.dumps(deck_mine(args[1])))
    elif action == "search" and len(args) >= 3 and args[1] in DECK_SERVICES:
        print(json.dumps(deck_search(args[1], " ".join(args[2:]))))
    elif action == "grab":
        # The song you're hearing goes in the set (next with --next).
        song, inside = deck_playing_song(settings)
        if inside:
            toast("It's already on the Deck", song["title"], glyph="󰐒")
        elif not song:
            toast("Couldn't find what's playing", "Nothing playing, or it isn't on your music service", glyph="󰀦")
        else:
            deck_edit(lambda d: d["set"].insert(0, song) if "--next" in args else d["set"].append(song))
            deck_after_edit()
            toast("Added to the Deck" + (", next" if "--next" in args else ""), f"{song['title']} · {song['artist']}", glyph="󰐒")
    elif action == "find-add" and len(args) >= 2:
        # A song by name, the best match on your music service, into the set.
        words = " ".join(a for a in args[1:] if a != "--next").strip()[:200]
        service = (settings.get("music") or {}).get("service", "ytmusic")
        hits = [i for i in deck_search(service, words) if i.get("kind") == "song"] if words else []
        if not hits:
            toast("Couldn't find that song", words, glyph="󰀦")
            return
        song = deck_item(service, hits[0])
        deck_edit(lambda d: d["set"].insert(0, song) if "--next" in args else d["set"].append(song))
        deck_after_edit()
        toast("Added to the Deck" + (", next" if "--next" in args else ""), f"{song['title']} · {song['artist']}", glyph="󰐒")
    elif action == "build-from-playing":
        # A set grown from the song you're hearing.
        minutes = int(args[1]) if len(args) > 1 and args[1].isdigit() else 60
        song, _ = deck_playing_song(settings)
        if not song:
            toast("Couldn't find what's playing", "Play a song first, then ask again", glyph="󰀦")
            return
        seed = {k: v for k, v in song.items() if k not in {"from", "why", "chapter"}}
        seed["uid"] = os.urandom(4).hex()
        settings = {**settings, "music": {**(settings.get("music") or {}), "service": seed["service"]}}
        deck_build(settings, minutes, "", seed=seed, replace=not deck_read()["set"])
    elif action == "sonos-sync":
        deck_sonos_sync()
    elif action == "next-up":
        deck_whats_next()
    elif action == "songs" and len(args) == 3 and args[1] in DECK_SERVICES:
        # An album's or playlist's songs, as search results: to look inside it
        # in the crate and pick some, instead of adding the lot.
        try:
            item = json.loads(args[2])
        except ValueError:
            sys.exit("Bad album or playlist.")
        if not isinstance(item, dict) or item.get("kind") not in {"album", "playlist"}:
            sys.exit("Only an album or playlist has songs to show.")
        print(json.dumps([deck_as_result(s) for s in deck_expand(args[1], item)]))
    elif action == "join" and len(args) == 2:
        deck_join(args[1])
    elif action == "leave" and len(args) == 2:
        deck_leave(args[1])
    elif action == "everywhere":
        deck_everywhere()
    elif action == "volume" and len(args) == 3:
        deck_room_volume(args[1], args[2])
    elif action in {"fill", "build", "autodj"} and "--service" in args:
        at = args.index("--service")
        service = args[at + 1] if at + 1 < len(args) else ""
        if service not in DECK_SERVICES:
            sys.exit("Unknown service.")
        deck_command({**settings, "music": {**(settings.get("music") or {}), "service": service}}, args[:at] + args[at + 2:])
    elif action == "fill":
        deck_fill(settings, auto="--auto" in args)
    elif action == "build" and len(args) >= 2 and args[1].isdigit():
        value = lambda flag: args[args.index(flag) + 1] if flag in args and args.index(flag) + 1 < len(args) else ""
        seed = None
        if value("--seed"):
            seed = deck_seed((settings.get("music") or {}).get("service", "ytmusic"), value("--seed"))
        words = [a for i, a in enumerate(args[2:], 2)
                 if a not in {"--start", "--replace", "--seed"} and args[i - 1] not in {"--start", "--seed"}]
        if not words and not seed:
            sys.exit("Say what the set is for, or give it a song to start from (--seed).")
        deck_build(settings, int(args[1]), " ".join(words), value("--start"), replace="--replace" in args, seed=seed)
    elif action == "run":
        deck_run()
    else:
        sys.exit("Usage: afterlight deck [state|add <ytmusic|applemusic> <item json> [--next|--play|--at <n>|--scatter]|move <uid> <index>|"
                 "remove <uid>…|place <now|next|end> <uid>…|chapter <uid> [name]|move-chapter <uid> <index>|undo|"
                 "save <name> [--played|--all]|sets|load <name> [--replace]|grab [--next]|find-add <words> [--next]|build-from-playing [minutes]|next-up|songs <service> <album or playlist json>|forget <name>|shape <tempo|smooth|energy|arc|harmonic|bumps>|autodj <on|off>|autodj from <service> <item json>|export <service> <name> [--played|--all|--saved]|crossfade <on|off>|sleep <minutes|song|off>|guests <on|off|forget>|request <take|drop> <id> [--next|--mix]|requests <clear|auto on|auto off|lastcall <minutes|off>>|lock <on|off>|details|"
                 "pin <uid>|shuffle|clear|play [uid]|pause|next|previous|where <laptop|room id>|rooms|join <room id>|"
                 "leave <room id>|everywhere|volume <room id> <0-100>|search <service> <words>|mine <service>|fill [--service <s>]|"
                 "build <minutes> [what it's for] [--start <song>|--seed <item json>] [--replace] [--service <s>]|run]")


def deck_as_result(song):
    """A Deck song back as a search result the crate can show and add again."""
    out = {"kind": "song", "title": song["title"], "subtitle": " • ".join(x for x in (song["artist"], song.get("album", "")) if x),
           "thumb": song.get("thumb", "")}
    for key in ("id", "video", "slug", "from"):
        if song.get(key):
            out[key] = song[key]
    return out


def deck_playing_song(settings):
    """The song you're hearing, as a Deck song: the Deck's own, or what an app
    plays (MPRIS), found on your music service. (song, already in the Deck)."""
    deck = deck_read()
    if deck.get("playing") and deck.get("now"):
        return deck["now"], True
    track = playing_track()
    if not track or not track.get("title"):
        return None, False
    service = (settings.get("music") or {}).get("service", "ytmusic")
    [(idea, match)] = find_songs(service, [{"t": track["title"], "a": track.get("artist", ""), "w": ""}])
    if not match:
        return None, False
    song = deck_item(service, match)
    song["from"] = "Playing"
    return song, False


def deck_whats_next():
    """What's next on the Deck, in the music popup."""
    deck = deck_with_details(deck_read())
    if not deck["set"]:
        toast("Nothing next on the Deck", "Add songs, or say “fill the deck”", glyph="󰐒")
        return
    song = deck["set"][0]
    left = len(deck["set"]) - 1
    toast(f"Next: {song['title']}", song["artist"] + (f" · then {left} more" if left else " · the last one"), glyph="󰒭")


def deck_seed(service, text):
    """A song you picked to grow a set from, as a Deck song."""
    try:
        item = json.loads(text)
    except ValueError:
        sys.exit("Bad song.")
    if not isinstance(item, dict) or item.get("kind", "song") != "song":
        sys.exit("Pick a song to start from.")
    return deck_item(service, item)


def deck_fill(settings, count=5, auto=False, seed=None):
    """Grok's fast model picks songs that fit the set; each is found on your
    music service and added to the end. Auto-DJ (auto) looks at the whole
    night so far: what's been played, what's playing and what's left. With a
    seed (a song you picked) it goes in next and the songs that follow grow
    from it."""
    deck = deck_read()
    recent = ([deck["now"]] if deck.get("now") else []) + deck["set"]
    if seed:
        def put(d):
            known = {(s["service"], s.get("id"), s.get("video")) for s in d["set"]}
            if (seed["service"], seed.get("id"), seed.get("video")) not in known:
                d["set"].insert(0, {**seed, "from": "✦ Auto-DJ"})
        deck_edit(put)
        deck = deck_read()
        recent = ([deck["now"]] if deck.get("now") else []) + deck["set"]
    if not recent:
        toast("Add a few songs first", "Grok fills the Deck with songs that fit what's in it", glyph="󰀦")
        return
    if not shutil.which("grok"):
        sys.exit("Filling the Deck needs the Grok agent (grok).")
    anchor = None
    if seed or auto:
        if seed:
            toast("Auto-DJ is listening to your pick…", seed["title"], glyph="∞")
        ask, anchor = deck_autodj_ask(deck, seed)
        ideas = grok_ideas("", ask=ask, count=count + 3, timeout=150, mix=True)
        if not ideas["songs"]:          # Grok stalled: once more, asking less
            ask, anchor = deck_autodj_ask(deck, seed, compact=True)
            ideas = grok_ideas("", ask=ask, count=count + 3, timeout=120, mix=True)
    else:
        toast("Grok is picking songs…", "That fit " + ", ".join(s["title"] for s in recent[-3:]), glyph="✦")
        listing = "; ".join(f"{s['title']} by {s['artist']}" for s in recent[-8:])
        ideas = grok_ideas("", ask="Suggest songs to follow this DJ set, in the same mood and flow, none already in it: "
                               + listing.replace("»", "")[:900] + ".", count=count + 4)
    service = (settings.get("music") or {}).get("service", "ytmusic")
    have = {song_key(s["title"]) for s in recent + deck["played"]}
    recent_artists = (deck_artists(seed) if seed else
                      set().union(*(deck_artists(s) for s in recent[-3:])) if auto and recent else set())
    found, picks = [], []
    for idea, match in find_songs(service, [i for i in ideas["songs"] if song_key(i["t"]) not in have]):
        if match and len(found) < (count + 3 if anchor else count) and song_key(match["title"]) not in have:
            song = deck_item(service, match)
            if (auto or seed) and deck_artists(song) & recent_artists:
                continue                    # not the same artists again straight away
            found.append({**song, "from": "✦ Auto-DJ" if auto or seed else "✦ Fill"})
            picks.append((found[-1], idea))
            have.add(song_key(match["title"]))
            if idea.get("e"):
                deck_details_note(song, energy=idea["e"])
    if anchor:
        # Near the song they follow in tempo, in an order that mixes, the way the shape points.
        found = deck_mix_pick(picks, anchor, count, deck.get("direction") or "")
    def place(d):
        if seed:                            # straight after the pick
            at = next((i + 1 for i, x in enumerate(d["set"]) if x["uid"] == seed["uid"] or
                       (x["service"], x.get("id"), x.get("video")) == (seed["service"], seed.get("id"), seed.get("video"))), 0)
            d["set"][at:at] = found
        else:
            d["set"].extend(found)
    deck_edit(place)
    deck_after_edit()
    toast((f"Auto-DJ added {len(found)} songs" if auto or seed else f"Grok added {len(found)} songs") if found else "Grok couldn't find songs that fit",
          ", ".join(s["title"] for s in found[:3]) + ("…" if len(found) > 3 else ""), glyph="✦")


# A shape picked while Auto-DJ runs is the way it takes the night.
DIRECTIONS = {
    "arc": ("the night's arc", "Follow the shape of a good night: ease in, build, peak about two thirds of the way through, "
                               "then wind down. It's {clock} and the music started {hours} ago: judge where we are on that curve."),
    "energy": ("building energy", "Build the energy: each song a little more lift than the one before, towards a peak."),
    "tempo": ("rising tempo", "Nudge the tempo up with each song, a few BPM at a time."),
    "harmonic": ("in key", "Mix in key: each song a step from the one before on the Camelot wheel (or the same key), "
                           "and close in tempo."),
    "smooth": ("steady tempo", "Hold the tempo steady: each song within a few BPM of the one before."),
}
DECK_SKIP_SECONDS = 45          # skipped sooner than this: a "not that"


def deck_night(deck):
    """Tonight's played songs (the last few hours), oldest first."""
    return [x for x in deck["played"] if x.get("playedAt", 0) >= time.time() - 4 * 3600][-24:]


def deck_mix_words(song, picked=False):
    """A song for Auto-DJ: title and artist, what's known of its tempo, key
    and energy, and whether a guest asked for it or Auto-DJ picked it."""
    # Title and artist only: exact tempo and key figures make Grok deliberate
    # for minutes; it knows the songs, and the tempo is checked afterwards.
    words = f"{song['title']} by {song['artist']}".replace("»", "")[:120]
    if song.get("rid"):
        words += " [guest request]"
    elif not picked and str(song.get("from", "")).startswith("✦ Auto-DJ"):
        words += " [Auto-DJ's pick]"
    return words


def deck_autodj_ask(deck, seed=None, compact=False):
    """What Auto-DJ asks Grok: where the night is now (the newest songs
    weighted most, with their tempo, key and energy), what follows them, the
    room's taste (requests, votes, skips), and the direction, if a shape set one."""
    upcoming = ([deck["now"]] if deck.get("now") else []) + deck["set"]
    night = deck_night(deck) + upcoming
    if seed:
        at = next((i for i, x in enumerate(night) if x.get("uid") == seed.get("uid")), len(night) - 1)
        night = night[:at + 1]
    anchor = night[-1]
    window, earlier = night[-6:], night[:-6][-12:]
    if compact:                     # the retry: just where the night is now
        window, earlier = night[-4:], []
    ask = "You're the DJ. "
    if earlier:
        ask += "Earlier tonight: " + "; ".join(f"{x['title']} by {x['artist']}" + (" [guest request]" if x.get("rid") else "")
                                               for x in earlier).replace("»", "")[:1400] + ". "
    if len(window) > 1:
        ask += ("Where the night is now, oldest to newest (these matter most, the newest most of all): "
                + "; ".join(deck_mix_words(x, picked=bool(seed) and x is anchor) for x in window)[:1400] + ". ")
    ask += (f"The next song follows «{deck_mix_words(anchor, picked=bool(seed))}»"
            + (", which the listener just picked" if seed or len(night) == 1 else "")
            + ": close to it in tempo, in a key that mixes with it, and carrying on its sound, genre and era. ")
    if any(x.get("rid") for x in night):
        ask += "Songs marked [guest request] are what the room asked for: lean towards their style. "
    crowd = deck_crowd(deck) if not compact else {"up": [], "down": []}
    if crowd["up"]:
        ask += "The guests loved: " + "; ".join(crowd["up"])[:500] + ". "
    if crowd["down"]:
        ask += "They didn't like: " + "; ".join(crowd["down"])[:400] + ": less like those. "
    skipped = [f"{x['title']} by {x['artist']}" for x in (deck.get("skipped") or [])[-6:]] if not compact else []
    if skipped:
        ask += "The DJ skipped these quickly: " + "; ".join(skipped)[:500] + ": steer away from them. "
    direction = DIRECTIONS.get(deck.get("direction") or "")
    if direction:
        night_start = min((x.get("playedAt") or time.time()) for x in night) if night else time.time()
        hours = (time.time() - night_start) / 3600
        ask += direction[1].format(clock=time.strftime("%H:%M"),
                                   hours=f"{hours:.1f} hours" if hours >= 1 else f"{int(hours * 60)} minutes") + " "
    ask += ("Vary the artists (none of the last few again), and nothing already played. "
            "List them in play order, each flowing into the next.")
    return ask, anchor


def deck_mix_pick(found, anchor, count, direction=""):
    """Of Auto-DJ's finds [(song, idea)], keep the ones that sit near the
    song they follow in tempo (by Grok's estimates), and put them in an order
    that mixes: each the nearest in key, tempo and energy to the one before,
    leaning the way the direction goes."""
    info = deck_details_read().get(deck_song_key(anchor), {})
    here = {"bpm": info.get("bpm") or 0, "key": info.get("key") or "", "energy": info.get("energy") or 0}
    est = lambda idea: {"bpm": idea.get("b") or 0, "key": idea.get("k") or "", "energy": idea.get("e") or 0}
    def gap(a, b):
        return min(abs(a * f - b) for f in (1, 2, 0.5)) if a and b else 0
    if here["bpm"]:
        near = [x for x in found if not x[1].get("b") or tempos_fit(here["bpm"], x[1]["b"], 0.12)]
        if len(near) < min(count, len(found)) // 2 + 1:      # too few: the nearest ones, then
            near = sorted(found, key=lambda x: gap(here["bpm"], x[1].get("b") or here["bpm"]))[:count]
        found = near
    ordered, left = [], list(found)
    while left and len(ordered) < count:
        def cost(x):
            e = est(x[1])
            c = (0 if keys_fit(here["key"], e["key"]) else 40) + gap(here["bpm"], e["bpm"]) / 2 \
                + abs((e["energy"] or 5) - (here["energy"] or 5)) * 2
            if direction == "energy" and e["energy"] and here["energy"] and e["energy"] < here["energy"]:
                c += 15
            if direction == "tempo" and e["bpm"] and here["bpm"] and gap(here["bpm"], e["bpm"]) > 1 \
                    and min((e["bpm"] * f for f in (1, 2, 0.5)), key=lambda v: abs(v - here["bpm"])) < here["bpm"]:
                c += 15
            if direction == "smooth":
                c = gap(here["bpm"], e["bpm"])
            return c
        best = min(left, key=cost)
        ordered.append(best)
        left.remove(best)
        e = est(best[1])
        here = {k: e[k] or here[k] for k in here}
    return [song for song, _ in ordered]


def deck_seed_words(song):
    """A seed song for Grok: title, artist, and what's known of its tempo,
    key and energy."""
    info = deck_details_read().get(deck_song_key(song)) or {}
    extra = [f"{round(info['bpm'])} BPM" if isinstance(info.get("bpm"), (int, float)) and info["bpm"] > 0 else "",
             f"key {info['key']}" if camelot_ok(info.get("key")) else "",
             f"energy {info['energy']}/10" if isinstance(info.get("energy"), int) and info["energy"] else ""]
    extra = ", ".join(x for x in extra if x)
    return (f"{song['title']} by {song['artist']}" + (f" ({extra})" if extra else "")).replace("»", "")[:200]


def deck_build(settings, minutes, brief, start="", replace=False, seed=None):
    """Build a set from a brief: what it's for, how long, maybe a first song.
    A seed is a song you picked: it opens the set as it is, and the rest grows
    from its sound, tempo and key.
    Grok's fast model curates it in play order (a build, a peak, a wind-down);
    each song is found on your music service and the set lands in the Deck."""
    if not shutil.which("grok"):
        sys.exit("Building a set needs the Grok agent (grok).")
    minutes = max(10, min(240, minutes))
    count = max(5, min(45, round(minutes / 3.7)))
    brief = brief.replace("»", "").strip()[:600]
    start = start.replace("»", "").strip()[:120]
    if seed:
        start = ""
        brief = brief or f"music that grows from {seed['title']} by {seed['artist']}"
    toast("Grok is building your set…", f"About {minutes} minutes, {count} songs: {brief[:60]}", glyph="✦")
    ask = (f"Curate a DJ set of about {minutes} minutes ({count} songs), in play order, for: «{brief}». "
           + (f"Start with «{start}». " if start else "")
           + (f"It opens with «{deck_seed_words(seed)}», already chosen: don't list it; carry on from its sound, era, "
              "tempo and key, and let the set grow out of it. " if seed else "")
           + "Shape it like a good DJ: ease in, build the energy, peak around two thirds of the way, then wind down. "
             "Keep neighbouring songs compatible in tempo and mood; no song twice; well-known enough to be on streaming "
             "services. In each 'w', say its job in the set in a few words (opener, builds, peak, cool-down…).")
    ideas = grok_ideas("", ask=ask, count=count + 3, timeout=150, shape=True)
    service = (settings.get("music") or {}).get("service", "ytmusic")
    found, seen = [], set()
    if seed:
        found.append({**seed, "from": "✦ " + brief[:50], "why": "your pick"})
        seen.add(song_key(seed["title"]))
    for idea, match in find_songs(service, ideas["songs"]):
        if match and song_key(match["title"]) not in seen and len(found) < count:
            seen.add(song_key(match["title"]))
            song = deck_item(service, match)
            song["why"] = idea["w"]
            song["from"] = "✦ " + brief[:50]
            if idea["c"]:
                song["chapter"] = idea["c"]
            if idea["e"]:
                deck_details_note(song, energy=idea["e"])
            found.append(song)
    if len(found) <= (1 if seed else 0):
        toast("Grok couldn't build that set", "Try saying more about the mood or the music", glyph="󰀦")
        return
    def place(d):
        d["set"] = found + ([] if replace else d["set"])
        if replace:
            d["pinned"] = []
    deck_edit(place)
    deck_after_edit()
    total = sum(1 for _ in found)
    toast(f"Your set is ready: {total} songs", f"{found[0]['title']} → {found[-1]['title']}", glyph="✦")


def deck_resume(deck):
    """Carry on with the Deck's song where it was paused. On the laptop the
    app may have moved on to something else meanwhile (the Deck played in a
    room, or you played something): then the Deck's song starts again from
    where it was, rather than whatever the app had."""
    room = deck_where_room(deck)
    song = deck["now"]
    if room:
        sonos_call(room["ip"], "AVTransport", "Play", {"InstanceID": 0, "Speed": 1})
    elif song.get("service") == "applemusic" and \
            str(((am_now() or {}).get("item") or {}).get("id", "")) == str(song.get("id")):
        am_bridge({"action": "play"}, timeout=4)
    elif song.get("service") == "ytmusic" and song_key((laptop_track() or {}).get("title", "")) == song_key(song["title"]):
        media_command("play")
    else:
        mark = read_json(DECK_NOW, {})
        deck_play_laptop(song, start_at=mark.get("time", 0) if mark.get("uid") == song["uid"] else 0)
    deck["expect"] = {"uid": deck["now"]["uid"], "since": time.time()}
    deck_watch()


def deck_after_edit():
    """The set changed: a Sonos room playing it gets the new order after the
    song it's on."""
    deck = deck_read()
    if deck["playing"] and (deck.get("where") or {}).get("kind") == "sonos":
        deck_sonos_soon()


def deck_where(target, settings=None):
    """Move the Deck between the laptop and a Sonos room, from the same second.
    With settings, Baseline's Sonos room (the Player tab, the volume keys)
    follows; sonos_use calls it without, having set that itself."""
    def move(d):
        rooms = sonos_rooms()
        room = None if target == "laptop" else sonos_find_room(rooms, target)
        if room is None and target != "laptop":
            # A room inside another group: on its own first, then the Deck moves there.
            speaker = next((s for s in sonos_speakers(rooms) if s["id"] == target), None)
            if speaker and sonos_call(speaker["ip"], "AVTransport", "BecomeCoordinatorOfStandaloneGroup",
                                      {"InstanceID": 0}, timeout=5) is not None:
                time.sleep(1)
                room = sonos_find_room(sonos_rooms(), target)
        if target != "laptop" and room is None:
            sys.exit("That Sonos room isn't there.")
        before = deck_where_room(d)
        if (room and before and room["id"] == before["id"]) or (room is None and before is None):
            return room["id"] if room else ""
        status = deck_status(d) if d.get("now") and d["playing"] else {"time": 0}
        if before:
            sonos_call(before["ip"], "AVTransport", "Pause", {"InstanceID": 0})
        d["where"] = {"kind": "sonos", "room": room["id"]} if room else {"kind": "laptop"}
        if d.get("now") and d["playing"]:
            deck_start(d, d["now"], start_at=status.get("time", 0))
            if room is None:
                where_toast()
        return room["id"] if room else ""
    room_id = deck_update(move)
    if settings is not None:
        sonos_remember(settings, room_id)
    return room_id


def sonos_remember(settings, room_id):
    """Baseline's Sonos room, quietly: a room id, or "" for the laptop."""
    sonos = settings.setdefault("sonos", {})
    if room_id and (sonos.get("room") != room_id or not sonos.get("on")):
        sonos["room"] = room_id
        sonos_set_target(settings, True)
    elif not room_id and sonos.get("on"):
        sonos_set_target(settings, False)


def deck_follow(room_id):
    """The Player tab picked a room ("" for the laptop's own speakers): the
    Deck goes there too, taking its music if it's playing."""
    where = deck_read().get("where") or {}
    now = where.get("room", "") if where.get("kind") == "sonos" else ""
    if now != room_id:
        try:
            deck_where(room_id or "laptop")
        except SystemExit:
            pass


# ---- rooms together: Sonos groups
# Any room can join the room the Deck plays in; they play in step. A room that
# joins is never louder than the loudest one already playing; a room that
# leaves goes quiet (and if it led the group, the next room takes over with the
# queue, so the music carries on).

def sonos_speakers(rooms=None):
    """Every room on its own: [{id, name, ip, group (its group's id), lead}]."""
    out = []
    for room in rooms if rooms is not None else sonos_rooms():
        for speaker in room.get("speakers") or []:
            out.append({**speaker, "group": room["id"], "lead": speaker["id"] == room["id"]})
    return out


def sonos_speaker_volume(speaker):
    reply = sonos_call(speaker["ip"], "RenderingControl", "GetVolume", {"InstanceID": 0, "Channel": "Master"}) or {}
    try:
        return max(0, min(100, int(reply.get("CurrentVolume", ""))))
    except ValueError:
        return None


def deck_rooms():
    """For the Deck window: the laptop's rooms list, each Sonos room with its
    group and volume, and which group the Deck plays in."""
    from concurrent.futures import ThreadPoolExecutor
    speakers = sonos_speakers()
    with ThreadPoolExecutor(max_workers=8) as pool:
        volumes = list(pool.map(sonos_speaker_volume, speakers))
    where = deck_read().get("where") or {}
    group = where.get("room") if where.get("kind") == "sonos" else ""
    leads = {s["group"]: s for s in speakers if s["lead"]}
    with ThreadPoolExecutor(max_workers=8) as pool:
        states = dict(zip(leads, pool.map(lambda s: (sonos_call(s["ip"], "AVTransport", "GetTransportInfo", {"InstanceID": 0})
                                                     or {}).get("CurrentTransportState", ""), leads.values())))
    return {"group": group, "rooms": [{"id": s["id"], "name": s["name"], "group": s["group"], "lead": s["lead"],
                                       "volume": v, "here": s["group"] == group,
                                       "busy": s["group"] != group and states.get(s["group"]) in {"PLAYING", "TRANSITIONING"}}
                                      for s, v in zip(speakers, volumes)]}


def deck_join(speaker_id, quiet=False):
    """Add a room to the group the Deck plays in."""
    deck = deck_read()
    lead = deck_where_room(deck)
    if lead is None:
        sys.exit("Play the Deck in a Sonos room first, then add rooms to it.")
    speakers = sonos_speakers()
    speaker = next((s for s in speakers if s["id"] == speaker_id), None)
    if speaker is None:
        sys.exit("That Sonos room isn't there.")
    if speaker["group"] == lead["id"]:
        return False
    party = [s for s in speakers if s["group"] == lead["id"]]
    loudest = max((v for v in map(sonos_speaker_volume, party) if v is not None), default=None)
    volume = sonos_speaker_volume(speaker)
    if loudest is not None and volume is not None and volume > loudest:
        sonos_call(speaker["ip"], "RenderingControl", "SetVolume",
                   {"InstanceID": 0, "Channel": "Master", "DesiredVolume": loudest})
    done = sonos_call(speaker["ip"], "AVTransport", "SetAVTransportURI",
                      {"InstanceID": 0, "CurrentURI": f"x-rincon:{lead['id']}", "CurrentURIMetaData": ""}, timeout=5)
    if done is None:
        sys.exit(f"{speaker['name']} didn't join.")
    if not quiet:
        names = [s["name"] for s in party] + [speaker["name"]]
        title = (deck.get("now") or {}).get("title", "")
        toast(f"{speaker['name']} joined", f"Playing in {' + '.join(names)}" + (f" · {title}" if title else ""),
              art=(deck.get("now") or {}).get("thumb", ""), glyph="󰓃")
    return True


def deck_leave(speaker_id):
    """Take a room out of its group. If it led the group the Deck plays in,
    the next room takes over (queue and all) and the Deck follows."""
    speakers = sonos_speakers()
    speaker = next((s for s in speakers if s["id"] == speaker_id), None)
    if speaker is None:
        sys.exit("That Sonos room isn't there.")
    others = [s for s in speakers if s["group"] == speaker["group"] and s["id"] != speaker["id"]]
    if not others:
        return False
    if speaker["lead"]:
        heir = others[0]
        done = sonos_call(speaker["ip"], "AVTransport", "DelegateGroupCoordinationTo",
                          {"InstanceID": 0, "NewCoordinator": heir["id"], "RejoinGroup": 0}, timeout=6)
        if done is None:
            sys.exit(f"{speaker['name']} couldn't hand the music on.")
        def follow(d):
            where = d.get("where") or {}
            if where.get("kind") == "sonos" and where.get("room") == speaker["id"]:
                d["where"] = {"kind": "sonos", "room": heir["id"]}
        deck_update(follow)
        settings = load()
        if (settings.get("sonos") or {}).get("room") == speaker["id"]:
            settings["sonos"]["room"] = heir["id"]
            sonos_set_target(settings, bool(settings["sonos"].get("on")))
    else:
        if sonos_call(speaker["ip"], "AVTransport", "BecomeCoordinatorOfStandaloneGroup", {"InstanceID": 0}, timeout=5) is None:
            sys.exit(f"{speaker['name']} didn't leave.")
    toast(f"{speaker['name']} left", "Playing in " + " + ".join(s["name"] for s in others), glyph="󰓄")
    return True


def deck_everywhere():
    """Every free room into the Deck's group: one already playing something
    else (a TV, its own music) is left alone."""
    deck = deck_read()
    lead = deck_where_room(deck)
    if lead is None:
        sys.exit("Play the Deck in a Sonos room first.")
    rooms = sonos_rooms()
    # A room busy with something else (the TV, someone's own music) is left alone.
    busy = {r["id"] for r in rooms if r["id"] != lead["id"] and (sonos_call(r["ip"], "AVTransport", "GetTransportInfo",
            {"InstanceID": 0}) or {}).get("CurrentTransportState") in {"PLAYING", "TRANSITIONING"}}
    speakers = sonos_speakers(rooms)
    left = [s["name"] for s in speakers if s["group"] in busy]
    joined = [s for s in speakers if s["group"] != lead["id"] and s["group"] not in busy and deck_join(s["id"], quiet=True)]
    names = [s["name"] for s in sonos_speakers() if s["group"] == lead["id"]]
    toast("Playing everywhere" if joined else "Already everywhere",
          f"{len(names)} rooms" + (f" · left {', '.join(left)} alone: busy playing" if left else ""),
          art=(deck.get("now") or {}).get("thumb", ""), glyph="󰓃")


def deck_room_volume(speaker_id, value):
    speaker = next((s for s in sonos_speakers() if s["id"] == speaker_id), None)
    if speaker is None or not str(value).isdigit():
        sys.exit("Usage: afterlight deck volume <room id> <0-100>")
    sonos_call(speaker["ip"], "RenderingControl", "SetVolume",
               {"InstanceID": 0, "Channel": "Master", "DesiredVolume": max(0, min(100, int(value)))})


# ---------------------------------------------------------------- plugin copies
# Built-in Omarchy plugins copied into ~/.config with `omarchy plugin clone`
# and changed (popups at the top, the notification filter, workspace names).
# An Omarchy update brings new versions of the originals, so each copy's
# changes are kept as a patch in this repo: `plugins restore` (run by the
# post-update hook) re-applies them on top of the new version.

PLUGINS_DIR = HOME / ".config/omarchy/plugins"
OMARCHY_PLUGINS = Path("/usr/share/omarchy/shell/plugins")
PATCHES = REPO / "system/plugin-patches"


def plugin_copies():
    """{copy id: (copy dir, source id)} for copies of built-in plugins."""
    copies = {}
    for manifest in sorted(PLUGINS_DIR.glob("*/manifest.json")):
        source = (read_json(manifest, {}).get("omarchy") or {}).get("clonedFrom")
        if source:
            copies[manifest.parent.name] = (manifest.parent, source)
    return copies


def plugin_source_dir(source_id):
    """Where Omarchy keeps the original: the folder of its manifest."""
    for manifest in OMARCHY_PLUGINS.rglob("*.json"):
        if manifest.name.endswith("manifest.json") and read_json(manifest, {}).get("id") == source_id:
            return manifest.parent
    return None


def plugin_files(copy_dir):
    return sorted(str(f.relative_to(copy_dir)) for f in copy_dir.rglob("*")
                  if f.is_file() and f.name != "manifest.json" and "__pycache__" not in f.parts)


def file_hash(path):
    return hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else ""


def plugins_save(force=False):
    """Record each copy's changes against the Omarchy version it came from."""
    PATCHES.mkdir(parents=True, exist_ok=True)
    for copy_id, (copy_dir, source_id) in plugin_copies().items():
        src = plugin_source_dir(source_id)
        if not src:
            print(f"{copy_id}: can't find {source_id} in Omarchy; skipped")
            continue
        files = plugin_files(copy_dir)
        old = read_json(PATCHES / f"{copy_id}.json", {})
        if old.get("base") and not force and \
                {rel: file_hash(src / rel) for rel in old.get("files", [])} != old["base"]:
            print(f"{copy_id}: Omarchy's original changed since the last save; run `afterlight plugins restore` first")
            continue
        diff = ""
        for rel in files:
            result = subprocess.run(["diff", "-u", "--label", f"a/{rel}", "--label", f"b/{rel}",
                                     str(src / rel) if (src / rel).is_file() else "/dev/null", str(copy_dir / rel)],
                                    capture_output=True, text=True)
            diff += result.stdout
        (PATCHES / f"{copy_id}.patch").write_text(diff)
        shutil.copy(copy_dir / "manifest.json", PATCHES / f"{copy_id}.manifest")
        base = {"source": source_id, "files": files, "base": {rel: file_hash(src / rel) for rel in files},
                "saved": datetime.date.today().isoformat()}
        (PATCHES / f"{copy_id}.json").write_text(json.dumps(base, indent=2) + "\n")
        print(f"{copy_id}: {diff.count(chr(10) + '@@') + diff.startswith('@@')} change(s) against {source_id}")


def plugin_in_use(copy_id, source_id):
    """Make the shell use the copy, not the original (an update can switch it back)."""
    data = read_json(SHELL_JSON, {})
    if not data:
        return False
    changed = False

    def widgets(node):
        if isinstance(node, dict):
            if "id" in node:
                yield node
            for value in node.values():
                yield from widgets(value)
        elif isinstance(node, list):
            for value in node:
                yield from widgets(value)

    for entry in widgets(data.get("bar", {})):
        if entry.get("id") == source_id:
            entry["id"] = copy_id
            changed = True
    in_bar = any(entry.get("id") == copy_id for entry in widgets(data.get("bar", {})))
    if not in_bar:
        plugins = data.setdefault("plugins", [])
        if not any(isinstance(p, dict) and p.get("id") == copy_id for p in plugins):
            plugins.append({"id": copy_id})
            changed = True
        disabled = data.setdefault("disabledPlugins", [])
        if source_id not in disabled:
            disabled.append(source_id)
            changed = True
    if changed:
        shutil.copy(SHELL_JSON, SHELL_JSON.with_name(f"shell.json.bak-plugins-{int(time.time())}"))
        write_atomic(SHELL_JSON, json.dumps(data, indent=2) + "\n")
    return changed


def plugins_missing():
    """Copies the patches describe that this machine doesn't have yet."""
    return [r.stem for r in sorted(PATCHES.glob("*.json")) if not (PLUGINS_DIR / r.stem / "manifest.json").is_file()]


def plugins_install():
    """Make each missing copy afresh (a new machine): Omarchy's original, our
    patch on top, the manifest renamed, and the shell switched over to it."""
    for copy_id in plugins_missing():
        info = read_json(PATCHES / f"{copy_id}.json", {})
        source_id = info.get("source", "")
        src = plugin_source_dir(source_id)
        if not src:
            raise RuntimeError(f"Omarchy has no {source_id} to copy")
        dest = PLUGINS_DIR / copy_id
        source_manifest = next(m for m in src.glob("*manifest.json") if read_json(m, {}).get("id") == source_id)
        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp) / copy_id
            # Only the files the copy carries: one folder can hold several widgets.
            for rel in info.get("files", []):
                (work / rel).parent.mkdir(parents=True, exist_ok=True)
                if (src / rel).is_file():
                    shutil.copy(src / rel, work / rel)
            shutil.copy(source_manifest, work / "manifest.json")
            result = subprocess.run(["patch", "-p1", "--forward", "--batch", "--no-backup-if-mismatch", "-r", "-",
                                     "-d", str(work), "-i", str(PATCHES / f"{copy_id}.patch")],
                                    capture_output=True, text=True)
            if result.returncode:
                raise RuntimeError(f"{copy_id}: Omarchy's {source_id} changed too much for the saved changes")
            manifest = read_json(PATCHES / f"{copy_id}.manifest", {}) or read_json(work / "manifest.json", {})
            manifest["id"] = copy_id
            if not (PATCHES / f"{copy_id}.manifest").is_file():
                manifest["name"] = "My " + manifest.get("name", source_id)
            manifest.setdefault("omarchy", {})["clonedFrom"] = source_id
            (work / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copytree(work, dest)
        info["base"] = {rel: file_hash(src / rel) for rel in info.get("files", [])}
        (PATCHES / f"{copy_id}.json").write_text(json.dumps(info, indent=2) + "\n")
        plugin_in_use(copy_id, source_id)


def plugins_restore(quiet=False):
    """After an Omarchy update: put each copy's changes on the new version."""
    report, problems = [], []
    copies = plugin_copies()
    for record in sorted(PATCHES.glob("*.json")):
        copy_id = record.stem
        info = read_json(record, {})
        patch = PATCHES / f"{copy_id}.patch"
        source_id = info.get("source", "")
        src = plugin_source_dir(source_id)
        if not src or not patch.is_file():
            problems.append(f"{copy_id}: Omarchy no longer has {source_id}")
            continue
        copy_dir = copies.get(copy_id, (PLUGINS_DIR / copy_id, source_id))[0]
        if not copy_dir.is_dir():
            problems.append(f"{copy_id}: your copy is missing (restore it from the dotfiles backup)")
            continue
        files = info.get("files", [])
        now = {rel: file_hash(src / rel) for rel in files}
        if now == info.get("base"):
            if plugin_in_use(copy_id, source_id):
                report.append(f"{copy_id}: switched back to your copy")
            continue
        # Omarchy changed the original: start from its new version, add ours.
        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp)
            for rel in files:
                (work / rel).parent.mkdir(parents=True, exist_ok=True)
                if (src / rel).is_file():
                    shutil.copy(src / rel, work / rel)
            result = subprocess.run(["patch", "-p1", "--forward", "--batch", "--no-backup-if-mismatch", "-r", "-",
                                     "-d", str(work), "-i", str(patch)], capture_output=True, text=True)
            if result.returncode:
                problems.append(f"{copy_id}: Omarchy changed {source_id} too much to re-apply your changes; "
                                f"your old copy is still in use")
                continue
            backup = PLUGINS_DIR.parent / f"plugin-backups/{copy_id}-{int(time.time())}"
            shutil.copytree(copy_dir, backup)
            for rel in files:
                (copy_dir / rel).parent.mkdir(parents=True, exist_ok=True)
                shutil.copy(work / rel, copy_dir / rel)
            # Pick up any new files the original gained.
            for extra in src.rglob("*"):
                rel = str(extra.relative_to(src))
                if extra.is_file() and not extra.name.endswith("manifest.json") and rel not in files \
                        and src.joinpath("manifest.json").is_file():
                    (copy_dir / rel).parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy(extra, copy_dir / rel)
        info["base"] = now
        info["restored"] = datetime.date.today().isoformat()
        record.write_text(json.dumps(info, indent=2) + "\n")
        plugin_in_use(copy_id, source_id)
        report.append(f"{copy_id}: your changes re-applied to Omarchy's new {source_id}")
    for line in report + problems:
        print(line)
    if (report or problems) and not quiet:
        run("omarchy-notification-send", "--app-name", "Baseline", "-u", "critical" if problems else "low",
            "Your Omarchy plugin copies", "\n".join(report + problems))
    return not problems


def plugins_status(as_json=False):
    rows = []
    for record in sorted(PATCHES.glob("*.json")):
        info = read_json(record, {})
        src = plugin_source_dir(info.get("source", ""))
        same = bool(src) and {rel: file_hash(src / rel) for rel in info.get("files", [])} == info.get("base")
        rows.append({"id": record.stem, "name": record.stem.split(".", 1)[-1], "source": info.get("source"),
                     "current": same, "restored": info.get("restored") or info.get("saved")})
    if as_json:
        print(json.dumps({"copies": rows, "behind": sum(not r["current"] for r in rows)}))
        return
    for r in rows:
        print(f"{r['id']}: from {r['source']}, "
              + ("Omarchy's original unchanged" if r["current"] else "Omarchy's original has changed: run afterlight plugins restore"))


# ---------------------------------------------------------------- your coding and chat apps

APPS_LUA = CONFIG / "hypr/baseline_apps.lua"
# Built-in choices for workspace 3 (code) and 4 (chat): a window class to pin
# there, and how to start it at login. "custom" ones come from settings.
APP_CHOICES = {
    "coding": {
        "t3code": {"name": "T3 Code", "class": "^com[.]t3tools[.]T3Code$",
                   "launch": str(HOME / ".local/share/t3code/T3-Code.AppImage")},
        "none": {"name": "None"},
    },
    "chat": {
        "grok": {"name": "Grok Bot", "class": "^grok-bot$", "launch": "grok-bot"},
        "none": {"name": "None"},
    },
}
APP_WORKSPACE = {"coding": "3", "chat": "4"}


def app_choices(settings, role):
    choices = dict(APP_CHOICES[role])
    custom = (settings.get("apps", {}).get("custom") or {}).get(role)
    if custom and custom.get("class"):
        choices["custom"] = {"name": custom.get("name") or "Custom", "class": custom["class"],
                             "launch": custom.get("launch", "")}
    return choices


def app_chosen(settings, role):
    choices = app_choices(settings, role)
    key = settings.get("apps", {}).get(role, "")
    return key if key in choices else next(iter(choices))


def apps_lua_text(settings):
    lines = ["-- Written by `afterlight apps` (Baseline > Setup > Apps): the apps that own",
             "-- the code and chat workspaces, and start there at login.", ""]
    for role in ("coding", "chat"):
        app = app_choices(settings, role)[app_chosen(settings, role)]
        if not app.get("class"):
            lines.append(f"-- {role}: none")
            continue
        lines.append(f"-- {role}: {app['name']}")
        lines.append(f"o.window({{ class = {json.dumps(app['class'])} }}, {{ workspace = \"{APP_WORKSPACE[role]}\" }})")
        if app.get("launch"):
            lines.append(f"o.launch_on_start({json.dumps(app['launch'])})")
    return "\n".join(lines) + "\n"


def write_apps(settings):
    text = apps_lua_text(settings)
    if APPS_LUA.is_file() and APPS_LUA.read_text() == text:
        return False
    write_atomic(APPS_LUA, text)
    return True


def apps_state(settings):
    return {role: {"chosen": app_chosen(settings, role),
                   "choices": [{"id": k, "name": v["name"]} for k, v in app_choices(settings, role).items()]}
            for role in ("coding", "chat")}


# ---------------------------------------------------------------- built-in looks' pictures

def look_pictures(look_id=None):
    """Download the built-in looks' pictures from their original sites (the
    repo holds only their links, in pictures.json). Skips any already here."""
    got = missing = 0
    for i in [look_id] if look_id else look_ids():
        info = look_info(i)
        if not info["builtin"]:
            continue
        for entry in fetchable_pictures(info):
            target = info["dir"] / "backgrounds" / entry["file"]
            if target.is_file():
                continue
            if fetch_picture(entry["image"], target):
                got += 1
            else:
                missing += 1
    return got, missing


def fetchable_pictures(info):
    """A built-in look's pictures.json entries that can be downloaded: a safe
    file name and a source that allows it (stock sites are left out)."""
    return [e for e in read_list(info["dir"] / "pictures.json")
            if re.fullmatch(r"[a-z0-9][a-z0-9.-]{0,60}\.(jpe?g|png|webp)", str(e.get("file", "")))
            and ".." not in e["file"] and shareable(e)[0]]


def look_pictures_missing():
    return [f"{i}/{e['file']}" for i in look_ids() if look_info(i)["builtin"]
            for e in fetchable_pictures(look_info(i))
            if not (look_info(i)["dir"] / "backgrounds" / e["file"]).is_file()]


# ---------------------------------------------------------------- health: check & repair

# Everything Baseline puts into the system, so one command can tell whether an
# Omarchy update (or a refresh) has knocked any of it out, and put it back.
BAR_REF = REPO / "system/shell/baseline.json"
HOOKS = CONFIG / "omarchy/hooks"
SYSTEMD_USER = CONFIG / "systemd/user"
HEALTH = STATE.parent / "health.json"
UDEV_RULE = Path("/etc/udev/rules.d/99-afterlight-charge-limit.rules")
CHROME_POLICY = Path("/etc/opt/chrome/policies/managed/color.json")
# Hook names from before the rename, removed when their replacement goes in.
OLD_HOOKS = (HOOKS / "post-boot.d/afterlight-boot", HOOKS / "post-update.d/restore-plugin-copies",
             HOOKS / "theme-set.d/afterlight-t3-neon")


def append_text(path, text):
    with path.open("a") as handle:
        handle.write(text)


def repo_links():
    """Every link from the system into the repo: (where, what it points at, label)."""
    links = [
        (LOCAL_BIN / "afterlight", REPO / "bin/afterlight", "afterlight command"),
        (LOCAL_BIN / "afterlight-mode", REPO / "system/bin/afterlight-mode", "Mode helper"),
        (LOCAL_BIN / "afterlight-wallpaper", REPO / "system/bin/afterlight-wallpaper", "Wallpaper helper"),
        (LOCAL_BIN / "baseline-volume", REPO / "system/bin/baseline-volume", "Volume keys helper"),
        (LOCAL_BIN / "baseline-media", REPO / "system/bin/baseline-media", "Media keys helper"),
        (PLUGINS_DIR / "mortalfish.baseline", REPO / "plugin/mortalfish.baseline", "Baseline plugin"),
        (CONFIG / "hypr/home.lua", REPO / "system/hypr/home.lua", "Workspaces and window rules"),
        (HOOKS / "post-boot.d/baseline-boot", REPO / "system/hooks/baseline-boot", "Boot hook"),
        (HOOKS / "post-update.d/baseline-repair", REPO / "system/hooks/baseline-repair", "Update hook"),
        (HOOKS / "theme-set.d/baseline-theme", REPO / "system/hooks/baseline-theme", "Theme hook"),
        (CONFIG / "wireplumber/wireplumber.conf.d/afterlight-honour-chosen-sink.conf",
         REPO / "system/wireplumber/conf.d/afterlight-honour-chosen-sink.conf", "Audio output rule"),
        (HOME / ".local/share/wireplumber/scripts/afterlight",
         REPO / "system/wireplumber/scripts/afterlight", "Audio output script"),
        (CONFIG / "omarchy/branding/screensaver.txt", REPO / "system/branding/screensaver.txt", "Screensaver text"),
    ]
    for unit in ("afterlight-morning.service", "afterlight-morning.timer", "afterlight-mouse.service",
                 "afterlight-mode.service"):
        links.append((SYSTEMD_USER / unit, REPO / "system/systemd" / unit, unit))
    return links


def linked(link, target):
    """Does this path lead to the repo's file, directly or through a linked folder?"""
    return link.absolute() != target.absolute() and link.exists() and link.resolve() == target.resolve()


def relink(link, target):
    # A path whose folder is itself a link into the repo must never be
    # replaced: that would overwrite the repo's own file with a link to itself.
    if link.parent.resolve().is_relative_to(REPO.resolve()):
        raise RuntimeError(f"{link.parent} already leads into the repo; not touching it")
    link.parent.mkdir(parents=True, exist_ok=True)
    if link.exists() and not link.is_symlink():
        link.rename(link.with_name(f"{link.name}.bak-{int(time.time())}"))
    link.unlink(missing_ok=True)
    link.symlink_to(target)


CHROME_HOST = CONFIG / "google-chrome/NativeMessagingHosts/com.mortalfish.baseline_beatport.json"


def chrome_extension_id(folder=None):
    """The ID Chrome gives an unpacked extension: from its folder's path."""
    digest = hashlib.sha256(str(folder or REPO / "chrome/beatport-baseline").encode()).hexdigest()[:32]
    return "".join(chr(ord("a") + int(c, 16)) for c in digest)


def chrome_host_wanted():
    return {"name": "com.mortalfish.baseline_beatport", "description": "Baseline for Beatport bridge",
            "path": str(REPO / "chrome/native/beatport-host.py"), "type": "stdio",
            "allowed_origins": [f"chrome-extension://{chrome_extension_id()}/"]}


def chrome_host_write():
    CHROME_HOST.parent.mkdir(parents=True, exist_ok=True)
    write_atomic(CHROME_HOST, json.dumps(chrome_host_wanted(), indent=2) + "\n")


def bar_reference():
    return read_json(BAR_REF, {})


def bar_now():
    data = read_json(SHELL_JSON, {})
    bar = data.get("bar", {})
    return {"bar": {"layout": bar.get("layout"), "position": bar.get("position")},
            "plugins": data.get("plugins"), "disabledPlugins": data.get("disabledPlugins")}


def bar_restore():
    ref, data = bar_reference(), read_json(SHELL_JSON, {})
    if not ref or not data:
        return
    shutil.copy(SHELL_JSON, SHELL_JSON.with_name(f"shell.json.bak-baseline-{int(time.time())}"))
    data.setdefault("bar", {}).update(ref["bar"])
    data["plugins"], data["disabledPlugins"] = ref["plugins"], ref["disabledPlugins"]
    write_atomic(SHELL_JSON, json.dumps(data, indent=2) + "\n")


def bar_keep():
    """The bar as it is now becomes the one repair puts back."""
    write_atomic(BAR_REF, json.dumps(bar_now(), indent=2) + "\n")


def unit_state(unit):
    return out("systemctl", "--user", "is-enabled", unit), out("systemctl", "--user", "is-active", unit)


def health_checks(settings):
    """(id, group, label, ok, detail, fix) for each part. fix is a function, "sudo"
    for what needs the password (done in a terminal), or None to just report."""
    checks = []

    def add(cid, group, label, ok, detail="", fix=None):
        checks.append((cid, group, label, bool(ok), detail, fix))

    # Links into the repo.
    for link, target, label in repo_links():
        add(f"link:{link.name}", "links", label, linked(link, target),
            "" if linked(link, target) else f"{link} should link to {target}",
            lambda link=link, target=target: (relink(link, target),
                                              link.suffix == ".lua" and "hypr" in link.parts and run("hyprctl", "reload")))
    stale = [h for h in OLD_HOOKS if h.exists() or h.is_symlink()]
    add("hooks:old", "links", "Old hook names cleared", not stale, ", ".join(h.name for h in stale),
        lambda: [h.unlink(missing_ok=True) for h in stale])
    themes_ok = all(linked(THEMES / slug, (look_info(i)["dir"] / MODE_FOLDERS[m]) if MODE_FOLDERS[m] else look_info(i)["dir"])
                    for i in look_ids() for m, slug in look_info(i)["slugs"].items())
    add("looks", "links", f"{len(look_ids())} looks in Omarchy's themes", themes_ok,
        "" if themes_ok else "a look's theme folders are missing", install_looks)

    # The desktop.
    hypr = CONFIG / "hypr/hyprland.lua"
    required = hypr.is_file() and re.search(r'^\s*require\("hypr\.home"\)', hypr.read_text(), flags=re.M)
    add("hypr:home", "desktop", "Hyprland loads the workspace rules", required,
        "" if required else "hyprland.lua no longer requires hypr.home",
        lambda: (append_text(hypr, '\n-- Baseline: home workspaces, window rules, mouse buttons\nrequire("hypr.home")\n'),
                 run("hyprctl", "reload")))
    add("hypr:apps", "desktop", "Coding and chat app workspaces", APPS_LUA.is_file() and APPS_LUA.read_text() == apps_lua_text(settings),
        "", lambda: (write_apps(settings), run("hyprctl", "reload")))
    add("hypr:mouse", "desktop", "Mouse button bindings", MOUSE_LUA.is_file(), "" if MOUSE_LUA.is_file() else "mouse.lua missing",
        lambda: (write_mouse(settings), run("hyprctl", "reload")))
    errors = out("hyprctl", "configerrors")
    errors = "" if not errors or errors.strip().lower() in {"", "no errors"} else errors.strip().splitlines()[0]
    add("hypr:errors", "desktop", "Hyprland config has no errors", not errors, errors)

    # The bar.
    ref = bar_reference()
    add("bar", "bar", "Bar layout", not ref or bar_now() == ref,
        "" if not ref or bar_now() == ref else "differs from the saved layout (repair puts it back, or keep the new one)",
        bar_restore)
    rows = []
    for record in sorted(PATCHES.glob("*.json")):
        info = read_json(record, {})
        src = plugin_source_dir(info.get("source", ""))
        same = bool(src) and {rel: file_hash(src / rel) for rel in info.get("files", [])} == info.get("base")
        rows.append((record.stem, same))
    missing = plugins_missing()
    add("copies:made", "bar", "Plugin copies present", not missing,
        ("missing: " + ", ".join(missing)) if missing else "", plugins_install)
    behind = [r[0].split(".", 1)[-1] for r in rows if not r[1] and r[0] not in missing]
    add("copies", "bar", "Plugin copies on Omarchy's current versions", not behind,
        ("Omarchy changed: " + ", ".join(behind)) if behind else ", ".join(r[0].split(".", 1)[-1] for r in rows),
        lambda: plugins_restore(quiet=True))

    # Services.
    wanted = [("afterlight-mouse.service", True), ("afterlight-morning.timer", True)]
    if settings["schedule"]["auto"]:
        wanted.append(("afterlight-mode.timer", True))
    for unit, active in wanted:
        enabled, running = unit_state(unit)
        ok = enabled == "enabled" and (running == "active" or not active)
        add(f"unit:{unit}", "services", unit.rsplit(".", 1)[0].replace("afterlight-", "").title()
            + (" daemon" if unit.endswith("service") else " timer"), ok, "" if ok else f"{enabled or 'missing'}, {running}",
            lambda unit=unit: (run("systemctl", "--user", "daemon-reload"),
                               run("systemctl", "--user", "enable", "--now", unit)))

    # The look reaching other apps.
    theme = current_slug()
    ours = theme.startswith("afterlight")
    colours = read_colors(STATE_HOME / "omarchy/current/theme/colors.toml") if ours else {}
    starship = CONFIG / "starship.toml"
    prompt_ok = not ours or (starship.is_file() and f'accent = "{colours.get("accent")}"' in starship.read_text()
                             and re.search(r'^palette\s*=\s*"baseline"', starship.read_text(), flags=re.M))
    add("prompt", "look", "Terminal prompt in the look's colours", prompt_ok, "", prompt_palette)
    t3 = HOME / ".t3/userdata/themes/omarchy.json"
    t3_ok = not ours or not t3.is_file() or T3_MARK_START in t3.read_text()
    add("t3", "look", "T3 Code neon layer", t3_ok, "", lambda: t3_neon(theme))
    policy = read_json(CHROME_POLICY, {}) if CHROME_POLICY.is_file() else {}
    chrome_ok = not ours or policy.get("BrowserThemeColor", "").lower() == colours.get("accent", "").lower()
    add("chrome", "look", "Chrome's colour", chrome_ok,
        "" if chrome_ok else f"Chrome has {policy.get('BrowserThemeColor', 'none')}", lambda: run("omarchy-theme-set-browser"))

    # OmaRelay (voice control), installed from its own checkout.
    relay = omarelay_dir()
    if relay:
        checked = run("python3", str(relay / "install.py"), "--check")
        add("omarelay", "services", "OmaRelay voice control", checked and checked.returncode == 0,
            "" if checked and checked.returncode == 0 else "installed copy differs from its checkout",
            lambda: run("python3", str(relay / "install.py")))
    # The built-in looks' pictures, downloaded from their links.
    absent = look_pictures_missing()
    add("pictures", "look", "Pictures for the built-in looks", not absent,
        f"{len(absent)} not downloaded yet" if absent else "", lambda: look_pictures())
    # Looks added from the catalog (fetched again on a new machine).
    gone = [i for i in settings.get("catalog", {}).get("installed", {}) if f"c-{i}" not in look_ids()]
    add("catalog", "look", "Looks from the catalog", not gone, ("missing: " + ", ".join(gone)) if gone else "",
        lambda: [catalog_add(load(), i, settings["catalog"]["installed"][i].get("pictures", True)) for i in gone])

    # The bridge Chrome's "Baseline for Beatport" add-on talks to (the add-on
    # itself is loaded by hand: chrome://extensions, Load unpacked).
    host_ok = read_json(CHROME_HOST, {}) == chrome_host_wanted()
    add("chrome:host", "look", "Chrome add-on bridge registered", host_ok,
        "" if host_ok else "points at the wrong place or extension", chrome_host_write)
    # The add-on running in Chrome is the repo's version (it reloads itself
    # when asked, from 1.12.2; older ones need ↻ in chrome://extensions once).
    have, want = addon_version(), addon_wanted()
    add("chrome:addon", "look", "Chrome add-on up to date", have in (None, want),
        "" if have in (None, want) else f"running {have}, the repo has {want}", addon_reload)

    # Needs the password: done in a terminal.
    rule = REPO / "system/udev/99-afterlight-charge-limit.rules"
    udev_ok = UDEV_RULE.is_file() and UDEV_RULE.read_text() == rule.read_text()
    add("udev", "system", "Charge limit permission", udev_ok, "" if udev_ok else "udev rule missing or changed", "sudo")
    add("openrgb", "system", "OpenRGB for the mouse lights", shutil.which("openrgb"),
        "" if shutil.which("openrgb") else "openrgb isn't installed", "sudo")
    return checks


def health_run(settings, fix=False, quiet=False):
    checks = health_checks(settings)
    fixed, failed = [], []
    if fix:
        for cid, group, label, ok, detail, how in checks:
            if ok or not callable(how):
                continue
            if quiet and cid == "chrome":
                continue    # its policy write can ask for a password; leave it for the button
            try:
                how()
                fixed.append(label)
            except Exception as error:   # one broken part shouldn't stop the rest
                failed.append(f"{label}: {error}")
        if fixed:
            checks = health_checks(settings)
    rows = [{"id": c[0], "group": c[1], "label": c[2], "ok": c[3], "detail": c[4],
             "fix": "sudo" if c[5] == "sudo" else ("auto" if callable(c[5]) else None)} for c in checks]
    result = {"checked": datetime.datetime.now().isoformat(timespec="minutes"), "checks": rows,
              "failing": sum(not r["ok"] for r in rows), "fixed": fixed, "errors": failed,
              "sudo": any(not r["ok"] and r["fix"] == "sudo" for r in rows)}
    HEALTH.parent.mkdir(parents=True, exist_ok=True)
    write_atomic(HEALTH, json.dumps(result, indent=2) + "\n")
    if quiet and (fixed or result["failing"]):
        lines = ([f"Put back: {', '.join(fixed)}"] if fixed else []) \
            + [f"Needs you: {r['label']}" for r in rows if not r["ok"]]
        run("omarchy-notification-send", "--app-name", "Baseline", "-u", "critical" if result["failing"] else "low",
            "Baseline check", "\n".join(lines))
    return result


def health_system():
    """The parts that need the password, run in a terminal so sudo can ask."""
    rule = REPO / "system/udev/99-afterlight-charge-limit.rules"
    script = (f"echo 'Baseline: repairing the system parts (asks for your password)'; "
              f"sudo install -m 0644 {shlex.quote(str(rule))} {UDEV_RULE} && "
              "sudo udevadm control --reload && sudo udevadm trigger --subsystem-match=power_supply; "
              "command -v openrgb >/dev/null || sudo pacman -S --needed openrgb; "
              f"{shlex.quote(str(LOCAL_BIN / 'afterlight'))} repair >/dev/null; echo; read -rp 'Done. Press Enter to close.'")
    subprocess.Popen(["xdg-terminal-exec", "--title=Baseline repair", "bash", "-c", script],
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)


def health_print(result):
    for group in ("links", "desktop", "bar", "services", "look", "system"):
        for r in [r for r in result["checks"] if r["group"] == group]:
            print(f"{'ok ' if r['ok'] else 'XX '} {group:9} {r['label']}" + (f"  ({r['detail']})" if r["detail"] and not r["ok"] else ""))
    for label in result["fixed"]:
        print(f"put back: {label}")
    for error in result["errors"]:
        print(f"failed: {error}")


# ---------------------------------------------------------------- the mouse

MOUSE_LUA = CONFIG / "hypr/mouse.lua"
MOUSE_GLOB = "usb-Razer_Razer_Basilisk_V3*"
LOCAL_BIN = HOME / ".local/bin"
# What a button can do: (press, release) shell commands, release None for a tap.
MOUSE_ACTIONS = {
    "default": (None, None),
    "dictate": ("superwhisper start", "superwhisper stop"),
    "dictateToggle": ("superwhisper record", None),
    "voice": (f"{LOCAL_BIN}/omarchy-voice-nav start", f"{LOCAL_BIN}/omarchy-voice-nav stop"),
    "compose": (f"{LOCAL_BIN}/omarchy-voice-nav compose", None),
    "playPause": (f"{LOCAL_BIN}/afterlight media toggle", None),
    "next": (f"{LOCAL_BIN}/afterlight media next", None),
    "previous": (f"{LOCAL_BIN}/afterlight media previous", None),
    "workspacePrev": ("hyprctl dispatch 'hl.dsp.focus({ workspace = \"m-1\" })'", None),
    "workspaceNext": ("hyprctl dispatch 'hl.dsp.focus({ workspace = \"m+1\" })'", None),
    "screenshot": ("omarchy capture screenshot", None),
}
# The side buttons, which Hyprland binds. The slow-down button and the wheel
# tilt are read from the mouse itself by `afterlight mouse daemon`: the first
# sends no click, and a Hyprland tilt binding would also catch the touchpad's
# sideways scrolling.
MOUSE_KEYS = {"rear": "mouse:275", "front": "mouse:276"}
MOUSE_BUTTONS = ("sniper", "front", "rear", "tiltLeft", "tiltRight")
# A tilt is a scroll, with no release: only tap actions fit it.
TILTS = {"tiltLeft", "tiltRight"}
# The lights, in the order OpenRGB lists the zones, and what each can show.
MOUSE_ZONES = ("logo", "wheel", "strip")
MOUSE_COLOURS = {"orange": "accent", "blue": "cyan", "red": "red", "white": None, "off": None}


def mouse_hidraw(interface="if01"):
    name = f"{MOUSE_GLOB}-{interface}-hidraw" if interface else f"{MOUSE_GLOB}-hidraw"
    found = sorted(Path("/dev/input/by-id").glob(name))
    return found[0] if found else None


def write_mouse(settings):
    """Hyprland bindings for the side buttons, from settings."""
    lines = ["-- Written by `afterlight mouse` from settings.json; change it in Baseline > System > Mouse."]
    for button, key in MOUSE_KEYS.items():
        action = settings["mouse"].get(button, "default")
        press, release = MOUSE_ACTIONS.get(action, (None, None))
        if not press:
            continue
        label = f"Mouse {button}: {action}"
        if release:
            lines.append(f"o.bind_hold({json.dumps(key)}, {json.dumps(label)}, {json.dumps(press)}, "
                         f"{json.dumps(label + ' (release)')}, {json.dumps(release)})")
        else:
            lines.append(f"o.bind({json.dumps(key)}, {json.dumps(label)}, {json.dumps(press)})")
    text = "\n".join(lines) + "\n"
    try:
        if MOUSE_LUA.read_text() == text:
            return False
    except OSError:
        pass
    write_atomic(MOUSE_LUA, text)
    return True


def mouse_colours(settings, mode):
    """Each light's colour as hex: the Day theme's colour, pushed towards full
    colour by `strength` (LEDs wash pale tints out), dimmed for the mode."""
    m = settings["mouse"]
    theme = palette("day")
    brightness = m.get("brightness" + mode.capitalize(), 100) / 100 if mode in SLUGS else 1
    result = {}
    for zone in MOUSE_ZONES:
        name = m.get(zone, "off")
        if name == "off":
            rgb = (0, 0, 0)
        elif name == "white":
            rgb = (1, 1, 1)
        else:
            hexa = theme.get(MOUSE_COLOURS[name]) or {"accent": "#f29a4a", "cyan": "#6db5b9", "red": "#e5675d"}[MOUSE_COLOURS[name]]
            r, g, b = (int(hexa[i:i + 2], 16) / 255 for i in (1, 3, 5))
            h, sat, _ = colorsys.rgb_to_hsv(r, g, b)
            sat = sat + (1 - sat) * float(m.get("strength", 0.8))
            rgb = colorsys.hsv_to_rgb(h, sat, 1.0)
        result[zone] = "".join(f"{round(c * brightness * 255):02x}" for c in rgb)
    return result


def mouse_light(settings, mode=None):
    """The mouse lit in the theme's colours for the mode."""
    if not mouse_hidraw("if03") or not shutil.which("openrgb"):
        return False
    mode = mode or current_mode()
    if not settings["mouse"]["lighting"]:
        args = ["-m", "Off"]
    else:
        colours = mouse_colours(settings, mode)
        args = ["-m", "Direct", "-c", ",".join(colours[z] for z in MOUSE_ZONES)]
    result = run("openrgb", "--noautoconnect", "-d", "Basilisk", *args)
    return bool(result and result.returncode == 0)


def mouse_status(settings):
    m = settings["mouse"]
    mode = current_mode()
    return {"connected": mouse_hidraw() is not None, "buttons": {b: m.get(b, "default") for b in MOUSE_BUTTONS},
            "lighting": m["lighting"], "actions": list(MOUSE_ACTIONS), "tapOnly": sorted(TILTS),
            "holds": [a for a, (_, release) in MOUSE_ACTIONS.items() if release],
            "zones": {z: m.get(z, "off") for z in MOUSE_ZONES}, "colourNames": list(MOUSE_COLOURS),
            "strength": m.get("strength", 0.8),
            "brightness": {k: m.get("brightness" + k.capitalize(), 100) for k in ("day", "night", "saver")},
            "mode": mode, "now": {z: "#" + c for z, c in mouse_colours(settings, mode).items()}}


def mouse_daemon():
    """Run the slow-down button's and the wheel tilt's actions, and light the
    mouse whenever it's plugged in.

    The slow-down button sends no click: holding it drops the mouse to its
    sniper speed, which it reports on its second interface (05 02 <dpi x>
    <dpi y>), and letting go puts the speed back. The tilt is the third byte
    (sideways scroll, signed) of the mouse's own reports; reading them here
    leaves the touchpad's sideways scrolling alone."""
    def spawn(command):
        if command:
            subprocess.Popen(command, shell=True, start_new_session=True,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def action(button):
        return MOUSE_ACTIONS.get(load()["mouse"].get(button, "default"), (None, None))

    while True:
        side, main = mouse_hidraw("if01"), mouse_hidraw("")
        if not side or not main:
            time.sleep(3)
            continue
        time.sleep(1)   # let the other interfaces settle before lighting it
        mouse_light(load())
        try:
            fds = {os.open(side, os.O_RDONLY): "side", os.open(main, os.O_RDONLY): "main"}
        except OSError:
            time.sleep(3)
            continue
        held_release, normal = None, None
        last_tilt, last_fire = 0.0, 0.0
        try:
            while True:
                ready, _, _ = select.select(list(fds), [], [])
                for fd in ready:
                    data = os.read(fd, 64)
                    if not data:
                        raise OSError("unplugged")
                    if fds[fd] == "main":
                        if len(data) < 3 or data[2] == 0:
                            continue
                        # A held tilt repeats: act once, then again only every
                        # half second while it stays held.
                        now = time.monotonic()
                        fresh = now - last_tilt > 0.25
                        last_tilt = now
                        if fresh or now - last_fire > 0.5:
                            last_fire = now
                            spawn(action("tiltLeft" if data[2] >= 0x80 else "tiltRight")[0])
                        continue
                    if len(data) < 6 or data[0] != 0x05 or data[1] != 0x02:
                        continue
                    dpi = data[2] << 8 | data[3]
                    if dpi == normal and held_release is None:
                        continue
                    # Lower than the speed it was at is the button going down
                    # (or, until a first report, the default sniper speed).
                    if held_release is None and (dpi < normal if normal is not None else dpi <= 400):
                        press, release = action("sniper")
                        spawn(press)
                        held_release = release or ""
                        continue
                    if held_release is not None:
                        spawn(held_release)
                        held_release = None
                    normal = dpi
        except OSError:
            pass
        finally:
            for fd in fds:
                os.close(fd)
            if held_release:
                spawn(held_release)

# ---------------------------------------------------------------- bar rescue

SHELL_JSON = HOME / ".config/omarchy/shell.json"
RESCUE_WIDGETS = {"center": [{"id": "omarchy.clock"}], "right": [{"id": "omarchy.power"}]}


def bar_rescue(on):
    """Put Omarchy's own clock and battery back (for when Baseline won't load),
    or take them away again."""
    data = json.loads(SHELL_JSON.read_text())
    layout = data["bar"]["layout"]
    shutil.copy(SHELL_JSON, SHELL_JSON.with_name(f"shell.json.bak.{int(time.time())}"))
    for section, widgets in RESCUE_WIDGETS.items():
        current = [w for w in layout.get(section, []) if w.get("id") not in {x["id"] for x in widgets}]
        layout[section] = current + widgets if on else current
    write_atomic(SHELL_JSON, json.dumps(data, indent=2) + "\n")


# ---------------------------------------------------------------- focus scene

def pause_media():
    names = [line.split()[0] for line in quiet_out("busctl", "--user", "list", "--no-legend").splitlines()
             if line.startswith("org.mpris.MediaPlayer2.")]
    for name in names:
        quiet_out("busctl", "--user", "call", name, "/org/mpris/MediaPlayer2",
                  "org.mpris.MediaPlayer2.Player", "Pause")


def focus(settings, want):
    """Focus: do not disturb, plain black, Night, music paused. Off puts the
    first three back as they were (music stays paused)."""
    state = load_state()
    saved = state.get("focus")
    on = (saved is None) if want == "toggle" else want == "on"
    if on and saved is None:
        state["focus"] = {"dnd": quiet_out("omarchy-shell", "notifications", "isDnd").strip() == "on",
                          "black": bool(settings["wallpapers"].get("black")), "mode": current_mode()}
        save_state(state)
        quiet_out("omarchy-shell", "notifications", "setDnd", "on")
        pause_media()
        if current_mode() not in {"night", "other"}:
            set_mode(settings, "night")
        wallpaper_black(settings, "on")
        run("omarchy-osd", "-i", "󰽥", "-m", "Focus on")
    elif not on and saved is not None:
        state.pop("focus", None)
        save_state(state)
        quiet_out("omarchy-shell", "notifications", "setDnd", "on" if saved.get("dnd") else "off")
        if not saved.get("black"):
            settings["wallpapers"]["black"] = False
            save(settings)
        if saved.get("mode") in {"day", "saver"} and current_mode() != saved["mode"]:
            set_mode(settings, saved["mode"])
        elif not saved.get("black"):
            wallpaper_next(settings, shuffle=True)
        run("omarchy-osd", "-i", "󰖨", "-m", "Focus off")


# ---------------------------------------------------------------- morning check

def morning(settings):
    """One notification each morning: update, GitHub, agent limits, reminders."""
    lines = []
    today = datetime.date.today().isoformat()
    for reminder in settings.get("reminders", []):
        if reminder.get("from", "") <= today <= reminder.get("until", "9999"):
            lines.append("󰀦  " + reminder.get("text", ""))
    try:
        if subprocess.run(["omarchy-update-available"], capture_output=True, timeout=60).returncode == 0:
            lines.append("󰚰  An Omarchy update is ready")
    except (OSError, subprocess.SubprocessError):
        pass
    try:
        gh = json.loads(quiet_out("python3", "-I", "-B", str(REPO / "plugin/mortalfish.baseline/github.py"), timeout=40))
        if gh.get("ok"):
            reviews, notes = len(gh.get("reviews", [])), gh.get("notifications", 0)
            if reviews or notes:
                parts = ([f"{reviews} review{'s' if reviews != 1 else ''}"] if reviews else []) + \
                        ([f"{notes} notification{'s' if notes != 1 else ''}"] if notes else [])
                lines.append("󰊤  GitHub: " + ", ".join(parts))
    except ValueError:
        pass
    try:
        usage = []
        quiet_out("omarchy-agent-usage-update", "--limits-only", "claude", "codex", "grok", timeout=60)
        for provider in json.loads(quiet_out("omarchy", "agent", "account", "list", "--json", timeout=30)):
            account = next((a for a in provider.get("accounts", []) if a.get("active")), None)
            if account and account.get("signedIn"):
                peak = max((l.get("percent", 0) for l in account.get("limits", [])), default=0)
                usage.append(f"{provider['name']} {round(peak * 100)}%")
            elif account:
                usage.append(f"{provider['name']} signed out")
        if usage:
            lines.append("󰚩  " + " · ".join(usage))
    except (ValueError, KeyError, TypeError):
        pass
    # Beatport open but the add-on silent: Chrome has dropped it before.
    if beatport_windows() and beatport_bridge({"type": "tabs"}, timeout=5) is None:
        lines.append("󰎈  Beatport add-on isn't running: Load unpacked in chrome://extensions, "
                     "folder ~/Projects/baseline/chrome/beatport-baseline")
    waiting = [i for i in liked_list() if not i.get("added")]
    if waiting:
        lines.append(f"󰋑  {len(waiting)} liked track{'s' if len(waiting) != 1 else ''} not in <3 yet (Baseline › Player)")
    worth = [l for l in lines if not l.startswith("󰚩")]
    headline = "Good morning" if not worth else f"Good morning · {len(worth)} to look at"
    run("omarchy-notification-send", "--app-name", "Baseline", "-u", "low", headline,
        "\n".join(lines) or "All clear")


BATTERY = Path("/sys/class/power_supply/qcom-battmgr-bat")


def read_sys(name):
    try:
        return (BATTERY / name).read_text().strip()
    except OSError:
        return ""


def battery_status(settings):
    full, design = read_sys("energy_full"), read_sys("energy_full_design")
    health = round(100 * int(full) / int(design)) if full.isdigit() and design.isdigit() and int(design) else None
    end = read_sys("charge_control_end_threshold")
    writable = os.access(BATTERY / "charge_control_end_threshold", os.W_OK)
    return {"health": health, "limit": settings["battery"]["limit"], "limitPercent": settings["battery"]["limitPercent"],
            "end": int(end) if end.isdigit() else None, "canLimit": writable}


def battery_apply(settings):
    """Write the chosen charge limit to the firmware (100 = no limit)."""
    target = settings["battery"]["limitPercent"] if settings["battery"]["limit"] else 100
    try:
        (BATTERY / "charge_control_end_threshold").write_text(f"{target}\n")
    except OSError as error:
        sys.exit(f"Couldn't set the charge limit: {error.strerror}")


# ---------------------------------------------------------------- main

# ---------------------------------------------------------------- before and after: snapshot and uninstall

# The installer takes a snapshot of everything Baseline is about to change,
# before it changes anything; `afterlight uninstall` puts it all back.
BEFORE = HOME / ".local/share/baseline-before"
BASELINE_PACKAGES = ("python", "imagemagick", "rsync", "patch", "diffutils", "starship", "openrgb", "cava")
# The apps the installer adds when missing: how to tell, and how to take one off.
BASELINE_APPS = {
    "T3 Code": (lambda: (HOME / ".local/share/t3code/T3-Code.AppImage").exists(), "omarchy remove ai t3 code"),
    "Grok Bot": (lambda: bool(shutil.which("grok-bot")), "omarchy remove ai grok bot"),
    "Superwhisper": (lambda: bool(shutil.which("superwhisper")), "omarchy remove dictation superwhisper"),
    "Google Chrome": (lambda: bool(shutil.which("google-chrome-stable")), "omarchy remove browser chrome"),
}
THEME_NAME = STATE_HOME / "omarchy/current/theme.name"
SERVICES = ("afterlight-mouse.service", "afterlight-mode.timer", "afterlight-mode.service",
            "afterlight-morning.timer", "afterlight-morning.service")


def dotfile_paths():
    """Settings the installer may restore from a dotfiles backup."""
    return [CONFIG / f"hypr/{name}" for name in ("bindings.lua", "input.lua", "looknfeel.lua", "autostart.lua",
                                                 "hyprsunset.conf")] + [
        CONFIG / "omarchy/extensions", CONFIG / "foot", CONFIG / "mimeapps.list", CONFIG / "chrome-flags.conf",
        PLUGINS_DIR / "mortalfish.calendar",
        PLUGINS_DIR / "mortalfish.focus"]


def baseline_data():
    """Baseline's own settings, state, your looks and caches: none of it exists before."""
    return [SETTINGS.parent, STATE.parent, HOME / ".local/share/baseline", HOME / ".cache/afterlight",
            HOME / ".cache/baseline"]


def managed_paths():
    """Every path Baseline links, writes or replaces (no path inside another)."""
    paths = [link for link, _, _ in repo_links()]
    paths += [CONFIG / "hypr/hyprland.lua", APPS_LUA, MOUSE_LUA, SHELL_JSON, CONFIG / "starship.toml", TIMER,
              CHROME_HOST]
    paths += [PLUGINS_DIR / name for name in ("mortalfish.notifications", "mortalfish.osd", "mortalfish.workspaces")]
    paths += dotfile_paths() + baseline_data()
    unique = list(dict.fromkeys(Path(os.path.abspath(p)) for p in paths))
    return [p for p in unique if not any(other != p and p.is_relative_to(other) for other in unique)]


def kept_copy(path):
    return BEFORE / "files" / str(path).lstrip("/")


def snapshot(added=()):
    """Record how things are before Baseline goes in. Only the first snapshot
    counts, and none is taken once Baseline is already installed."""
    if (BEFORE / "manifest.json").is_file():
        return "kept"
    if any(link.is_symlink() and linked(link, target) for link, target, _ in repo_links()):
        return "installed"
    entries = []
    for path in managed_paths():
        entry = {"path": str(path)}
        if path.is_symlink():
            entry.update(kind="link", target=os.readlink(path))
        elif path.is_dir():
            shutil.copytree(path, kept_copy(path), symlinks=True)
            entry["kind"] = "dir"
        elif path.is_file():
            kept_copy(path).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, kept_copy(path))
            entry["kind"] = "file"
        else:
            entry["kind"] = "absent"
        entries.append(entry)
    present = lambda p: (r := run("pacman", "-Q", p)) is not None and r.returncode == 0
    manifest = {
        "taken": int(time.time()),
        "omarchy": out("omarchy", "version"),
        "theme": THEME_NAME.read_text().strip() if THEME_NAME.is_file() else "",
        "themes": sorted(p.name for p in THEMES.iterdir()) if THEMES.is_dir() else [],
        "backgrounds": sorted(p.name for p in USER_BG.iterdir()) if USER_BG.is_dir() else [],
        "packages": {p: present(p) and p not in added for p in BASELINE_PACKAGES},
        "apps": {name: check() for name, (check, _) in BASELINE_APPS.items()},
        "udev": UDEV_RULE.exists(),
        "entries": entries,
    }
    write_atomic(BEFORE / "manifest.json", json.dumps(manifest, indent=2) + "\n")
    return "taken"


def strip_line(path, pattern):
    if path.is_file() and not path.is_symlink():
        text = path.read_text()
        kept = "".join(line for line in text.splitlines(True) if not re.search(pattern, line))
        if kept != text:
            write_atomic(path, kept)
            return True
    return False


def uninstall_plan():
    """What uninstall would do, without doing it: (path, action) pairs."""
    manifest = read_json(BEFORE / "manifest.json", {})
    before = {e["path"]: e for e in manifest.get("entries", [])}
    plan = []
    for path in managed_paths():
        entry = before.get(str(path))
        here = path.exists() or path.is_symlink()
        if path == CONFIG / "hypr/hyprland.lua":
            plan.append((path, "remove Baseline's line"))
        elif entry and entry["kind"] != "absent":
            plan.append((path, f"put back as it was ({entry['kind']})"))
        elif here and not entry and path in dotfile_paths():
            continue    # no snapshot: your own settings stay as they are
        elif here and not entry and path == CONFIG / "starship.toml":
            plan.append((path, "Omarchy's default"))
        elif here and not entry and path == SHELL_JSON:
            plan.append((path, "Omarchy's default bar"))
        elif here and not entry and path == CONFIG / "omarchy/branding/screensaver.txt":
            plan.append((path, "Omarchy's default screensaver"))
        elif here:
            plan.append((path, "remove"))
    return manifest, plan


def uninstall(dry=False, remove_packages=False):
    """Take Baseline off and put back what was there before. Everything
    removed or replaced is moved to a folder, never deleted."""
    manifest, plan = uninstall_plan()
    archive = HOME / f".local/share/baseline-removed-{datetime.datetime.now():%Y%m%d-%H%M%S}"
    stash = lambda p: (archive / str(p).lstrip("/"))
    themes = [p for p in THEMES.iterdir() if p.is_symlink() and p.name not in manifest.get("themes", [])
              and (p.resolve().is_relative_to(REPO.resolve())
                   or p.resolve().is_relative_to((HOME / ".local/share/baseline").resolve()))] \
        if THEMES.is_dir() else []
    slugs = {s for i in look_ids() for s in look_info(i)["slugs"].values()}
    backgrounds = [p for p in USER_BG.iterdir() if p.name in slugs and p.name not in manifest.get("backgrounds", [])] \
        if USER_BG.is_dir() else []
    theme = manifest.get("theme") or ""
    if not theme or theme in slugs or not (THEMES / theme).exists() and not out("omarchy", "theme", "dir", theme):
        theme = "tokyo-night"
    added = [p for p, had in manifest.get("packages", {}).items() if not had]
    apps = [(name, command) for name, (check, command) in BASELINE_APPS.items()
            if manifest and not manifest.get("apps", {}).get(name, True) and check()]
    udev = UDEV_RULE.exists() and not manifest.get("udev", False)

    print("Baseline uninstall" + (" (dry run: nothing changes)" if dry else ""))
    print("  snapshot from " + (datetime.datetime.fromtimestamp(manifest["taken"]).strftime("%Y-%m-%d %H:%M")
                                if manifest else "none: falling back to Omarchy's defaults"))
    for path, action in plan:
        print(f"  {action:32} {str(path).replace(str(HOME), '~')}")
    print(f"  {'remove':32} {len(themes)} look themes, {len(backgrounds)} wallpaper folders")
    print(f"  {'switch theme to':32} {theme}")
    print(f"  {'stop':32} " + ", ".join(SERVICES))
    if udev:
        print(f"  {'remove (password)':32} {UDEV_RULE}")
    if dry:
        return plan

    run("systemctl", "--user", "disable", "--now", *SERVICES)
    for path, action in plan:
        here = path.exists() or path.is_symlink()
        if action == "remove Baseline's line":
            strip_line(path, r'require\("hypr\.home"\)')
            continue
        if here:
            if path.is_symlink() and linked(path, path.resolve()) and path.resolve().is_relative_to(REPO.resolve()):
                path.unlink()      # a link into the repo: nothing to keep
            else:
                stash(path).parent.mkdir(parents=True, exist_ok=True)
                shutil.move(str(path), stash(path))
        entry = next((e for e in manifest.get("entries", []) if e["path"] == str(path)), None)
        if entry and entry["kind"] == "link":
            path.parent.mkdir(parents=True, exist_ok=True)
            path.symlink_to(entry["target"])
        elif entry and entry["kind"] == "file":
            path.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(kept_copy(path), path)
        elif entry and entry["kind"] == "dir":
            shutil.copytree(kept_copy(path), path, symlinks=True)
        elif action == "Omarchy's default":
            run("omarchy", "refresh", "config", "starship.toml")
        elif action == "Omarchy's default bar":
            run("omarchy", "refresh", "config", "omarchy/shell.json")
        elif action == "Omarchy's default screensaver":
            omarchy = Path(os.environ.get("OMARCHY_PATH") or "/usr/share/omarchy")
            if (omarchy / "logo.txt").is_file():
                shutil.copy2(omarchy / "logo.txt", path)
    # Copies repair made (<name>.bak-<time>) since the snapshot go too.
    for path in managed_paths():
        for copy in path.parent.glob(path.name + ".bak-*") if path.parent.is_dir() else []:
            stamp = copy.name.rsplit("-", 1)[-1]
            if stamp.isdigit() and int(stamp) >= manifest.get("taken", 0):
                stash(copy).parent.mkdir(parents=True, exist_ok=True)
                shutil.move(str(copy), stash(copy))
    # Back to the theme you had, now Baseline's theme hook is gone; then
    # take the looks out of Omarchy's theme list.
    run("omarchy", "theme", "set", theme)
    for link in themes:
        link.unlink()
    for folder in backgrounds:
        stash(folder).parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(folder), stash(folder))
    t3 = HOME / ".t3/userdata/themes/omarchy.json"
    data = read_json(t3, {})
    if T3_MARK_START in data.get("css", ""):
        data["css"] = re.sub(re.escape(T3_MARK_START) + r".*?" + re.escape(T3_MARK_END) + r"\n?", "", data["css"],
                             flags=re.S)
        write_atomic(t3, json.dumps(data, indent=2) + "\n")
    if udev:
        if sys.stdin.isatty():
            subprocess.run(["sudo", "rm", "-f", str(UDEV_RULE)])
            subprocess.run(["sudo", "udevadm", "control", "--reload"])
        else:
            print(f"Remove the charge-limit rule yourself: sudo rm {UDEV_RULE}")
    if remove_packages and added:
        run("omarchy", "pkg", "drop", *added, quiet=False)
    # The snapshot goes with the rest, so a later install takes a fresh one.
    if BEFORE.exists():
        stash(BEFORE).parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(BEFORE), stash(BEFORE))
    run("hyprctl", "reload")
    run("omarchy", "restart", "shell")

    print("\nBaseline is off.")
    if archive.exists():
        print(f"  Everything it removed or replaced is in {str(archive).replace(str(HOME), '~')}")
    if added and not remove_packages:
        print("  Packages it added (kept): " + ", ".join(added) + "  -> afterlight uninstall --packages, or omarchy pkg drop")
    for name, command in apps:
        print(f"  {name} was installed with Baseline; to remove it (and its data): {command}")
    print(f"  The checkout is still at {str(REPO).replace(str(HOME), '~')}: delete it when you like.")
    print("  If you loaded the Chrome add-on, remove it in chrome://extensions.")
    print("  OmaRelay has its own: python3 install.py --uninstall in its checkout.")
    print("  Log out and back in to finish.")
    return plan


def main(argv):
    # These run before settings are read, so they leave no trace of their own.
    if argv[:1] == ["snapshot"]:
        added = next((a.split("=", 1)[1].split(",") for a in argv[1:] if a.startswith("--added=")), [])
        print({"taken": "Snapshot taken: afterlight uninstall can put everything back.",
               "kept": "Keeping the first snapshot.",
               "installed": "Baseline is already installed here, so there's no before to record."}[snapshot(added)])
        return
    if argv[:1] == ["uninstall"]:
        dry = "--dry-run" in argv
        if not dry and "--yes" not in argv:
            uninstall(dry=True)
            if not sys.stdin.isatty() or input("\nTake Baseline off? [y/N] ").strip().lower() != "y":
                return
        uninstall(dry=dry, remove_packages="--packages" in argv)
        return
    settings = load()
    use_look(settings["look"])
    command = argv[0] if argv else "state"
    args = argv[1:]

    lock_path = STATE.parent / "lock"
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    with lock_path.open("a") as lock:
        # Read-only and network-bound commands don't hold the lock (a slow
        # GitHub shouldn't freeze the panel); `share` saves only the author.
        if command not in {"state", "agents", "audio", "quick", "wifi", "bt", "media", "updates", "share", "check", "sonos",
                           "deck", "music", "applemusic", "toast"} \
                and not (command == "mouse" and args[:1] in (["daemon"], ["status"])) \
                and not (command == "catalog" and args[:1] in ([], ["list"])):
            fcntl.flock(lock, fcntl.LOCK_EX)

        if command == "state":
            print(json.dumps(panel_state(settings)))
        elif command == "mode":
            want = args[0] if args else "toggle"
            mode = current_mode()
            if want == "status":
                print(mode)
            elif want == "auto":
                auto_mode(settings)
            elif want == "toggle":
                # Out of Saver goes to whatever the clock says; otherwise flip.
                if mode == "saver":
                    set_mode(settings, period_now(settings))
                else:
                    set_mode(settings, "day" if mode == "night" else "night")
            elif want in SLUGS:
                set_mode(settings, want)
            else:
                sys.exit("Usage: afterlight mode [day|night|saver|toggle|auto|status]")
        elif command == "wallpaper":
            action = args[0] if args else "next"
            if action == "next":
                wallpaper_next(settings)
            elif action == "shuffle":
                wallpaper_next(settings, shuffle=True)
            elif action == "set" and len(args) == 2:
                wallpaper_set(settings, args[1])
            elif action == "black" and len(args) <= 2 and (args[1:] or ["toggle"])[0] in {"on", "off", "toggle"}:
                wallpaper_black(settings, (args[1:] or ["toggle"])[0])
            elif action == "toggle" and len(args) == 3:
                toggle_wallpaper(settings, args[1], args[2])
            elif action in {"add", "paste"}:
                # --looks a,b: which looks the new pictures join (for Day).
                looks, rest = None, []
                it = iter(args[1:])
                for arg in it:
                    if arg == "--looks":
                        looks = [l for l in next(it, "").split(",") if l in look_ids()] or None
                    else:
                        rest.append(arg)
                if action == "paste":
                    paste_wallpaper(settings, looks)
                elif rest:
                    for source in rest:
                        add_wallpaper(settings, source, looks)
                else:
                    sys.exit("Usage: afterlight wallpaper add <file|url>... [--looks a,b]")
            elif action == "remove" and len(args) == 2:
                remove_wallpaper(settings, args[1])
            else:
                sys.exit("Usage: afterlight wallpaper [next|shuffle|set <id>|black [on|off|toggle]|toggle <id> day|night|add <file|url>...|paste|remove <id>]")
        elif command == "set" and len(args) == 2:
            try:
                value = json.loads(args[1])
            except ValueError:
                value = args[1]
            keys = set_path(settings, args[0], value)
            save(settings)
            apply_change(settings, keys)
        elif command == "bar" and len(args) == 1 and args[0] in {"glassy", "opaque", "none"}:
            run("omarchy-bar", "background", args[0])
            # Leaving Saver puts back this choice rather than the one before it.
            state = load_state()
            if state.get("saverRestore"):
                state["saverRestore"]["bar"] = args[0]
                save_state(state)
        elif command == "agents":
            action = args[0] if args else "report"
            if action == "report":
                print(json.dumps(agents_report(settings)))
            elif action == "open" and len(args) == 2:
                open_thread(args[1])
            else:
                sys.exit("Usage: afterlight agents [report|open <thread id>]")
        elif command == "audio":
            action = args[0] if args else "list"
            if action == "list":
                print(json.dumps({**audio_outputs(), **sound_extras()}))
            elif action == "use" and len(args) == 2:
                audio_use(args[1])
            elif action == "swap":
                audio_swap()
            else:
                sys.exit("Usage: afterlight audio [list|use <sink name>|swap]")
        elif command == "sonos":
            action = args[0] if args else "state"
            if action == "state":
                print(json.dumps(sonos_state(settings)))
            elif action == "rooms":
                print(json.dumps(sonos_rooms(refresh="--find" in args)))
            elif action == "use" and len(args) == 2:
                sonos_use(settings, args[1])
            elif action == "off":
                sonos_set_target(settings, False)
                deck_follow("")
                if "--quiet" not in args:
                    where_toast()
            elif action == "volume" and len(args) >= 2:
                sonos_volume(settings, args[1], osd="--osd" in args)
            elif action in {"play", "pause", "toggle", "next", "previous"}:
                sonos_transport(settings, action)
            elif action == "send" and len(args) <= 2:
                sonos_send(settings, args[1] if len(args) == 2 else "")
            else:
                sys.exit("Usage: afterlight sonos [state|rooms|use <room id>|off|volume <n|+n|-n|raise|lower|mute-toggle>"
                         " [--osd]|play|pause|toggle|next|previous|send [room id]]")
        elif command == "wifi":
            wifi_command(args)
        elif command == "bt":
            bt_command(args)
        elif command == "beatport":
            action = args[0] if args else ""
            if action in {"open", "play"} and len(args) == 2:
                beatport_open(args[1], play=action == "play")
            elif action == "press" and len(args) == 2 and BEATPORT_URL.match(args[1]):
                # The Deck's Beatport song: press its page's own Play. Chrome only
                # lets a page start sound after a real click in it since it loaded.
                if not beatport_press_play(args[1], wait=10, first="/track/" in args[1]):
                    toast("Beatport needs a click", "Press Play in the Beatport window once; Chrome won't let it start on its own until you do",
                          glyph="󰀦")
            elif action == "resume":
                if not beatport_resume():
                    run("omarchy-osd", "-i", "󰀦", "-m", "Nothing to play yet: pick a chart or playlist")
                    sys.exit("Nothing to play.")
                print("Playing")
            elif action == "say" and len(args) >= 2:
                beatport_say(settings, " ".join(args[1:]))
            elif action == "pin":
                beatport_pin_clipboard(settings)
            elif action == "check" and len(args) >= 2:
                # Do these links exist? Fetched by the extension, not shown.
                print(json.dumps(beatport_bridge({"type": "check", "urls": args[1:]}, timeout=60), indent=2))
            elif action == "page" and len(args) == 2:
                # Debugging: send one bridge.js op (JSON) to the open Beatport page.
                print(json.dumps(beatport_bridge({"type": "page", "op": json.loads(args[1])}, timeout=15), indent=2))
            elif action == "unpin" and len(args) == 2:
                settings["beatport"]["pins"] = [p for p in settings["beatport"]["pins"] if p["url"] != args[1]]
                save(settings)
            else:
                sys.exit("Usage: afterlight beatport [open <url>|play <url>|pin|unpin <url>|say <words>|resume|check <url>...|page <json>]")
        elif command == "media":
            action = args[0] if args else ""
            if action not in {"play", "pause", "toggle", "next", "previous"}:
                sys.exit("Usage: afterlight media [play|pause|toggle|next|previous]")
            how = media_command(action)
            if not how:
                sys.exit(1)
            if how == "restarted":
                print("Restarted")   # the last chart, playlist or result, with its own OSD
                return
            print({"play": "Playing", "pause": "Paused", "toggle": "Done", "next": "Next track",
                   "previous": "Previous track"}[action])
        elif command == "plugins":
            action = args[0] if args else "status"
            if action == "save":
                plugins_save(force="--force" in args)
            elif action == "restore":
                if not plugins_restore(quiet="--quiet" in args):
                    sys.exit(1)
            elif action == "status":
                plugins_status(as_json="--json" in args)
            else:
                sys.exit("Usage: afterlight plugins [status [--json]|save [--force]|restore [--quiet]]")
        elif command == "ytmusic":
            action = args[0] if args else ""
            if action == "search" and len(args) >= 2:
                print(json.dumps(ytm_search(" ".join(args[1:]))))
            elif action == "play" and len(args) == 2:
                ytm_play(json.loads(args[1]))
            elif action == "say" and len(args) >= 2:
                ytm_say(" ".join(args[1:]))
            elif action == "playlists":
                print(json.dumps(ytm_playlists(refresh=len(args) > 1 and args[1] == "refresh")))
            else:
                sys.exit("Usage: afterlight ytmusic [search <words>|play <item json>|say <words>|playlists [refresh]]")
        elif command == "toast" and 1 <= len(args) <= 3:
            # A music message in the bar's popup: afterlight toast <title> [detail] [glyph]
            toast(args[0], args[1] if len(args) > 1 else "", glyph=args[2] if len(args) > 2 else "󰜟")
        elif command == "deck":
            deck_command(settings, args)
        elif command == "music":
            action = args[0] if args else ""
            if action == "suggest" and len(args) >= 3 and args[1] in {"ytmusic", "applemusic"}:
                # Suggestions for a search typed in the Player tab (no playing).
                query = " ".join(args[2:])
                items = am_search(query) if args[1] == "applemusic" else ytm_search(query)
                suggest(args[1], query, items, open_tab=False)
            elif action == "grok" and len(args) >= 3 and args[1] in {"ytmusic", "applemusic"}:
                grok_suggest(args[1], " ".join(args[2:]))
            elif action == "clear":
                SUGGEST.unlink(missing_ok=True)
            else:
                sys.exit("Usage: afterlight music [suggest|grok] ytmusic|applemusic <words> | clear")
        elif command == "applemusic":
            action = args[0] if args else ""
            if action == "search" and len(args) >= 2:
                print(json.dumps(am_search(" ".join(args[1:]))))
            elif action == "play" and len(args) == 2:
                am_play(json.loads(args[1]))
            elif action == "say" and len(args) >= 2:
                am_say(" ".join(args[1:]))
            elif action == "now":
                print(json.dumps(am_now()))
            else:
                sys.exit("Usage: afterlight applemusic [search <words>|play <item json>|say <words>|now]")
        elif command == "like":
            action = args[0] if args else "now"
            if action == "now":
                like_current()
            elif action == "list":
                print(json.dumps({"items": liked_list(), "current": playing_track()}))
            elif action == "add" and len(args) == 2:
                like_add(args[1])
            elif action in {"added", "unadded", "remove"} and len(args) == 2:
                like_update(args[1], action)
            else:
                sys.exit("Usage: afterlight like [now|list|added <id>|unadded <id>|remove <id>]")
        elif command == "bar" and args[:1] in (["rescue"], ["restore"]):
            bar_rescue(args[0] == "rescue")
        elif command == "morning":
            morning(settings)
        elif command == "focus":
            action = args[0] if args else "toggle"
            if action == "status":
                print(json.dumps({"on": "focus" in load_state()}))
            elif action in {"on", "off", "toggle"}:
                focus(settings, action)
            else:
                sys.exit("Usage: afterlight focus [on|off|toggle|status]")
        elif command == "battery":
            action = args[0] if args else "status"
            if action == "status":
                print(json.dumps(battery_status(settings)))
            elif action == "limit" and len(args) == 2 and args[1] in {"on", "off"}:
                settings["battery"]["limit"] = args[1] == "on"
                save(settings)
                battery_apply(settings)
            elif action == "apply":
                battery_apply(settings)
            else:
                sys.exit("Usage: afterlight battery [status|limit on|off|apply]")
        elif command == "t3-neon":
            t3_neon(args[0] if args else current_slug())
            prompt_palette()
        elif command == "prompt":
            prompt_palette()
        elif command == "looks" and args[:1] == ["backup"]:
            print("backed up" if looks_backup(args[1] if len(args) > 1 else "Looks: backup") else "nothing to back up")
        elif command == "catalog":
            action = args[0] if args else "list"
            if action == "list":
                print(json.dumps(catalog_list(settings, force="--refresh" in args)))
            elif action in {"add", "update"} and len(args) >= 2:
                keep = catalog_installed(settings).get(args[1], {}).get("pictures", True)
                catalog_add(settings, args[1], with_pictures=keep if action == "update" else "--no-pictures" not in args)
            elif action == "remove" and len(args) == 2:
                catalog_remove(settings, args[1])
            else:
                sys.exit("Usage: afterlight catalog [list [--refresh]|add <id> [--no-pictures]|update <id>|remove <id>]")
        elif command == "share" and args:
            author = next((a.split("=", 1)[1] for a in args if a.startswith("--author=")), "")
            if "--preview" in args:
                print(json.dumps(share_preview(settings, args[0], author)))
            else:
                include = next((a.split("=", 1)[1] for a in args if a.startswith("--include=")), "")
                share_look(settings, args[0], author, [i for i in include.split(",") if i])
        elif command == "apps":
            if args[:1] == ["set"] and len(args) == 3 and args[1] in APP_CHOICES:
                if args[2] not in app_choices(settings, args[1]):
                    sys.exit(f"Choose one of: {', '.join(app_choices(settings, args[1]))}")
                settings["apps"][args[1]] = args[2]
                save(settings)
                if write_apps(settings):
                    run("hyprctl", "reload")
            elif args[:1] == ["custom"] and len(args) == 5 and args[1] in APP_CHOICES:
                settings["apps"].setdefault("custom", {})[args[1]] = {"name": args[2][:40], "class": args[3], "launch": args[4]}
                settings["apps"][args[1]] = "custom"
                save(settings)
                if write_apps(settings):
                    run("hyprctl", "reload")
            elif not args:
                print(json.dumps(apps_state(settings)))
            else:
                sys.exit("Usage: afterlight apps [set coding|chat <id> | custom coding|chat <name> <class regex> <command>]")
        elif command == "pictures":
            got, missing = look_pictures(args[0] if args else None)
            print(f"downloaded {got}" + (f", {missing} couldn't be fetched" if missing else ""))
        elif command == "updates":
            print(json.dumps(updates_state(fetch="--fetch" in args)))
        elif command == "update":
            update_all(settings)
            if addon_version() not in (None, addon_wanted()):
                addon_reload()
        elif command == "voice" and args[:1] in (["install"], ["status"]) and args[1:] in ([], ["robot"]):
            if args[0] == "install":
                print("ready" if voice_install(args[1] if args[1:] else "kokoro") else "couldn't install the voice")
            else:
                print(json.dumps({"voices": [v[0] for v in voices_ready()], "using": deck_voice_name(deck_read())}))
        elif command == "addon" and args[:1] in (["version"], ["reload"]):
            if args[0] == "reload":
                print("reloaded" if addon_reload() else "couldn't: press ↻ on the add-on in chrome://extensions")
            else:
                print(json.dumps({"running": addon_version(), "repo": addon_wanted()}))
        elif command == "check":
            result = health_run(settings)
            print(json.dumps(result)) if "--json" in args else health_print(result)
        elif command == "repair":
            if args and args[0] == "--system":
                health_system()
            elif args and args[0] == "--keep-bar":
                bar_keep()
                health_run(settings)
            else:
                result = health_run(settings, fix=True, quiet="--quiet" in args)
                print(json.dumps(result)) if "--json" in args else health_print(result)
        elif command == "library":
            print(json.dumps(library_state(settings)))
        elif command == "assign" and len(args) == 4 and args[3] in {"on", "off"}:
            assign(settings, args[0], args[1], args[2], args[3] == "on")
        elif command == "look":
            action = args[0] if args else "list"
            if action == "list":
                print(json.dumps({"look": settings["look"], "looks": looks_state()}))
            elif action in {"next", "previous"}:
                ids = look_ids()
                at = ids.index(settings["look"]) if settings["look"] in ids else 0
                set_look(settings, ids[(at + (1 if action == "next" else -1)) % len(ids)])
            elif action == "set" and len(args) == 2:
                set_look(settings, args[1])
            elif action == "install":
                install_looks()
            elif action == "show" and len(args) == 2:
                print(json.dumps(look_detail(args[1])))
            elif action == "save" and len(args) == 2:
                save_look(settings, json.loads(args[1]))
            elif action == "derive" and len(args) == 2:
                print(json.dumps(derive_palette(json.loads(args[1]))))
            elif action == "inspire" and len(args) == 2:
                source = by_id().get(args[1], {}).get("path") or args[1]
                if source.startswith("file://"):
                    from urllib.parse import unquote, urlparse
                    source = unquote(urlparse(source).path)
                if not Path(source).expanduser().is_file():
                    sys.exit("No such picture.")
                found = image_palette(Path(source).expanduser())
                found["palette"] = derive_palette(found)
                print(json.dumps(found))
            elif action == "delete" and len(args) == 2:
                delete_look(settings, args[1])
            elif action == "build" and len(args) == 2:
                build_look(args[1])
                install_looks()
            else:
                sys.exit("Usage: afterlight look [list|set <id>|next|previous|show <id>|save <json>|derive <json>|inspire <picture>|delete <id>|install|build <id>]")
        elif command == "mouse":
            action = args[0] if args else "status"
            if action == "status":
                print(json.dumps(mouse_status(settings)))
            elif action == "light":
                if not mouse_light(settings):
                    sys.exit("No Razer mouse (or OpenRGB) found")
            elif action == "bind":
                write_mouse(settings)
                run("hyprctl", "reload")
            elif action == "daemon":
                lock.close()
                mouse_daemon()
            else:
                sys.exit("Usage: afterlight mouse [status|light|bind|daemon]")
        elif command == "quick":
            print(json.dumps(quick_state()))
        elif command == "sync":
            save(settings)
            write_tweaks(settings)
            write_timer(settings)
            write_mouse(settings)
            sync_wallpapers(settings)
            reload_hyprland()
        else:
            print(__doc__.strip())
            sys.exit(1)


if __name__ == "__main__":
    main(sys.argv[1:])
