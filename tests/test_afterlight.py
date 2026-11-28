"""Tests for bin/afterlight: the parts that can break a system or let bad
data in. Every path the script writes to is pointed into a temporary folder,
and nothing here touches the network or runs hyprctl, systemctl or omarchy.

Run from the repo root: python3 -m unittest discover -s tests -q
"""

import contextlib
import copy
import io
import importlib.machinery
import importlib.util
import json
import os
import shutil
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent.parent
_loader = importlib.machinery.SourceFileLoader("afterlight_under_test", str(ROOT / "bin/afterlight.py"))
al = importlib.util.module_from_spec(importlib.util.spec_from_loader(_loader.name, _loader))
_loader.exec_module(al)

GOOD_SEED = {"accent": "#ff5aa5", "cyan": "#62b6ff", "background": "#130c15", "foreground": "#f2dde8"}


class Done:
    """What a stubbed `run` hands back: a finished, successful command."""
    returncode = 0
    stdout = ""
    stderr = ""


def palette_text(colours=None, extra=""):
    colours = colours or al.derive_palette(GOOD_SEED)
    lines = ['mode = "dark"', "", "# a comment"] + [f'{k} = "{colours[k]}"' for k in al.LOOK_KEYS]
    lines.append('hyprland_active_border = "rgba(ff5aa5ee) rgba(62b6ffee) 45deg"')
    return "\n".join(lines) + "\n" + extra


def wallhaven_picture(n=1, **changes):
    picture = {"title": f"alley {n}", "page": "https://wallhaven.cc/w/g8m1gl",
               "image": "https://w.wallhaven.cc/full/g8/wallhaven-g8m1gl.jpg",
               "credit": "uploaded to Wallhaven by someone", "source": "https://www.deviantart.com/x/art/y"}
    picture.update(changes)
    return picture


_STATE = tempfile.TemporaryDirectory()


def setUpModule():
    """No test ever touches the Deck's real files, or starts a lookup in the background."""
    here = Path(_STATE.name)
    for name in ("DECK", "DECK_NOW", "DECK_LOCK", "DECK_RUN_LOCK", "DECK_UNDO", "DECK_DETAILS", "DECK_DETAILS_LOCK", "DECK_SETS"):
        mock.patch.object(al, name, here / name.lower()).start()
    mock.patch.object(al, "deck_details_soon", lambda deck: None).start()


def tearDownModule():
    mock.patch.stopall()
    _STATE.cleanup()


REAL_AGENT_ASK = al.agent_ask
REAL_HOME = al.HOME


class TempCase(unittest.TestCase):
    """A fresh temporary folder per test, removed afterwards."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.addCleanup(self._tmp.cleanup)
        # No test touches anything real: every path afterlight keeps under
        # your home folder (state, settings, config) points into this test's
        # folder instead (the repo stays), and starting afterlight itself in
        # the background (a watcher, a Sonos sync) is only recorded.
        self.home = self.tmp / "home"
        for name, value in list(vars(al).items()):
            if isinstance(value, Path) and value.is_absolute() and value.is_relative_to(REAL_HOME) \
                    and not value.is_relative_to(al.REPO):
                self.patch(name, self.home / value.relative_to(REAL_HOME))
        self.spawned = []
        real_popen = al.subprocess.Popen
        def popen(argv, *args, **kwargs):
            if any("afterlight" in str(a) for a in (argv if isinstance(argv, (list, tuple)) else [argv])[:2]):
                self.spawned.append(argv)
                return mock.Mock(pid=0, returncode=0, wait=lambda *a, **k: 0, poll=lambda: 0)
            return real_popen(argv, *args, **kwargs)
        patcher = mock.patch.object(al.subprocess, "Popen", popen)
        patcher.start()
        self.addCleanup(patcher.stop)
        for name, file in (("AGENTS_FILE", "deck-agents.json"), ("AGENT_LOG", "agent-calls.jsonl"),
                           ("AGENT_NOW", "agents-now.json"), ("DECK_PREP", "deck-prep.json")):
            self.patch(name, self.tmp / file)
        self.patch("KEYFINDER", self.tmp / "bin" / "baseline-keyfinder")
        self.patch("measure_ready", lambda: False)         # no real measuring unless a test asks
        self.patch("agent_ask", lambda *a, **kw: None)     # and no real agent is ever asked

    def patch(self, name, value):
        patcher = mock.patch.object(al, name, value)
        patcher.start()
        self.addCleanup(patcher.stop)


# ---------------------------------------------------------------- links

class LinkTests(TempCase):

    def test_direct_link_counts(self):
        target = self.tmp / "repo-file"
        target.write_text("x")
        link = self.tmp / "link"
        link.symlink_to(target)
        self.assertTrue(al.linked(link, target))

    def test_missing_or_wrong_link_does_not_count(self):
        target = self.tmp / "repo-file"
        target.write_text("x")
        other = self.tmp / "other"
        other.write_text("y")
        link = self.tmp / "link"
        self.assertFalse(al.linked(link, target))
        link.symlink_to(other)
        self.assertFalse(al.linked(link, target))

    def test_the_target_itself_is_not_a_link_to_it(self):
        target = self.tmp / "repo-file"
        target.write_text("x")
        self.assertFalse(al.linked(target, target))

    def test_linked_parent_folder_counts(self):
        real = self.tmp / "repo/scripts"
        real.mkdir(parents=True)
        (real / "script.lua").write_text("-- x")
        folder_link = self.tmp / "share/scripts"
        folder_link.parent.mkdir()
        folder_link.symlink_to(real)
        self.assertTrue(al.linked(folder_link / "script.lua", real / "script.lua"))

    def test_relink_refuses_a_path_inside_a_linked_repo_folder(self):
        # The bug this guards: the folder was a link into the repo, so
        # "fixing" the file inside replaced the repo's own file with a link
        # to itself.
        repo = self.tmp / "repo"
        (repo / "scripts").mkdir(parents=True)
        original = repo / "scripts/script.lua"
        original.write_text("-- the real script")
        self.patch("REPO", repo)
        folder_link = self.tmp / "share/scripts"
        folder_link.parent.mkdir()
        folder_link.symlink_to(repo / "scripts")
        with self.assertRaises(RuntimeError):
            al.relink(folder_link / "script.lua", original)
        self.assertFalse(original.is_symlink())
        self.assertEqual(original.read_text(), "-- the real script")

    def test_relink_moves_a_real_file_aside(self):
        self.patch("REPO", self.tmp / "repo")
        target = self.tmp / "repo/home.lua"
        target.parent.mkdir()
        target.write_text("-- repo")
        link = self.tmp / "config/hypr/home.lua"
        link.parent.mkdir(parents=True)
        link.write_text("-- someone's own")
        al.relink(link, target)
        self.assertTrue(link.is_symlink())
        self.assertTrue(al.linked(link, target))
        backups = list(link.parent.glob("home.lua.bak-*"))
        self.assertEqual(len(backups), 1)
        self.assertRegex(backups[0].name, r"^home\.lua\.bak-\d+$")
        self.assertEqual(backups[0].read_text(), "-- someone's own")

    def test_relink_replaces_a_wrong_link_and_makes_folders(self):
        self.patch("REPO", self.tmp / "repo")
        target = self.tmp / "repo/bin/afterlight"
        target.parent.mkdir(parents=True)
        target.write_text("#!/bin/sh")
        link = self.tmp / "new/deep/afterlight"
        al.relink(link, target)
        self.assertTrue(al.linked(link, target))
        (self.tmp / "elsewhere").write_text("")
        link.unlink()
        link.symlink_to(self.tmp / "elsewhere")
        al.relink(link, target)
        self.assertTrue(al.linked(link, target))
        self.assertEqual(list(link.parent.glob("*.bak-*")), [])


# ---------------------------------------------------------------- plugin copies

class PluginCopyTests(TempCase):

    def test_copies_rebuild_byte_identical(self):
        if not al.OMARCHY_PLUGINS.is_dir():
            self.skipTest("no Omarchy plugins on this machine")
        live = Path.home() / ".config/omarchy/plugins"
        records = sorted(al.PATCHES.glob("*.json"))
        if not records or not all((live / r.stem / "manifest.json").is_file() for r in records):
            self.skipTest("no live plugin copies to compare with")
        before = {r: r.read_bytes() for r in records}
        self.patch("PLUGINS_DIR", self.tmp / "plugins")
        self.patch("SHELL_JSON", self.tmp / "shell.json")
        try:
            self.assertEqual(al.plugins_missing(), [r.stem for r in records])
            al.plugins_install()
            self.assertEqual(al.plugins_missing(), [])
            for record in records:
                new, real = self.tmp / "plugins" / record.stem, live / record.stem
                files = sorted(str(f.relative_to(new)) for f in new.rglob("*") if f.is_file())
                self.assertEqual(files, sorted(str(f.relative_to(real)) for f in real.rglob("*") if f.is_file()),
                                 record.stem)
                for rel in files:
                    self.assertEqual((new / rel).read_bytes(), (real / rel).read_bytes(), f"{record.stem}/{rel}")
            for record, data in before.items():
                self.assertEqual(record.read_bytes(), data, f"{record.name} was changed")
        finally:
            for record, data in before.items():
                record.write_bytes(data)


# ---------------------------------------------------------------- the bar

class BarTests(TempCase):

    def setUp(self):
        super().setUp()
        self.shell = self.tmp / "shell.json"
        self.ref = self.tmp / "baseline.json"
        self.patch("SHELL_JSON", self.shell)
        self.patch("BAR_REF", self.ref)
        self.good = {"bar": {"background": "glassy", "position": "bottom",
                             "layout": {"left": [{"id": "omarchy.menu"}], "right": [{"id": "mortalfish.baseline"}]}},
                     "plugins": [{"id": "mortalfish.osd"}], "disabledPlugins": ["omarchy.osd"],
                     "idle": {"lock": 300}}
        self.shell.write_text(json.dumps(self.good))

    def test_keep_then_restore_puts_the_bar_back(self):
        al.bar_keep()
        self.assertEqual(al.bar_now(), al.bar_reference())
        broken = copy.deepcopy(self.good)
        broken["bar"]["position"] = "top"
        broken["bar"]["layout"]["right"] = []
        broken["disabledPlugins"] = []
        self.shell.write_text(json.dumps(broken))
        self.assertNotEqual(al.bar_now(), al.bar_reference())
        al.bar_restore()
        restored = json.loads(self.shell.read_text())
        self.assertEqual(al.bar_now(), al.bar_reference())
        self.assertEqual(restored["bar"]["position"], "bottom")
        # Settings outside the bar are left alone, and a backup is kept.
        self.assertEqual(restored["idle"], {"lock": 300})
        self.assertEqual(restored["bar"]["background"], "glassy")
        self.assertEqual(len(list(self.tmp.glob("shell.json.bak-baseline-*"))), 1)

    def test_restore_without_a_reference_does_nothing(self):
        al.bar_restore()
        self.assertEqual(json.loads(self.shell.read_text()), self.good)
        self.assertEqual(list(self.tmp.glob("shell.json.bak-*")), [])


# ---------------------------------------------------------------- the prompt

class PromptTests(TempCase):

    def setUp(self):
        super().setUp()
        self.patch("CONFIG", self.tmp / "config")
        self.patch("STATE_HOME", self.tmp / "state")
        theme = self.tmp / "state/omarchy/current/theme"
        theme.mkdir(parents=True)
        (theme / "colors.toml").write_text(palette_text())
        self.starship = self.tmp / "config/starship.toml"
        self.starship.parent.mkdir(parents=True)
        self.colours = al.derive_palette(GOOD_SEED)

    def test_writes_the_palette_block(self):
        self.starship.write_text('format = "$directory$character"\n\n[character]\nsuccess_symbol = "[◇](bold accent)"\n')
        al.prompt_palette()
        text = self.starship.read_text()
        self.assertTrue(text.startswith('palette = "baseline"\n'))
        self.assertIn("[palettes.baseline]", text)
        self.assertIn(f'accent = "{self.colours["accent"]}"', text)
        self.assertIn(f'highlight = "{self.colours["cyan"]}"', text)
        self.assertIn(f'alert = "{self.colours["red"]}"', text)
        self.assertIn('success_symbol = "[◇](bold accent)"', text)

    def test_replaces_a_wrong_palette_line(self):
        self.starship.write_text('palette = "x"\nadd_newline = true\n')
        al.prompt_palette()
        text = self.starship.read_text()
        self.assertEqual(text.count("palette = "), 1)
        self.assertIn('palette = "baseline"', text)
        self.assertNotIn('palette = "x"', text)

    def test_is_idempotent_and_replaces_its_own_block(self):
        self.starship.write_text("add_newline = true\n")
        al.prompt_palette()
        first = self.starship.read_text()
        al.prompt_palette()
        self.assertEqual(self.starship.read_text(), first)
        self.assertEqual(first.count(al.PROMPT_MARK_END), 1)
        self.assertEqual(first.count("[palettes.baseline]"), 1)
        # A new look's colours replace the block rather than adding another.
        other = al.derive_palette({**GOOD_SEED, "accent": "#4d9bff"})
        (self.tmp / "state/omarchy/current/theme/colors.toml").write_text(palette_text(other))
        al.prompt_palette()
        text = self.starship.read_text()
        self.assertEqual(text.count("[palettes.baseline]"), 1)
        self.assertIn('accent = "#4d9bff"', text)

    def test_leaves_a_missing_config_alone(self):
        al.prompt_palette()
        self.assertFalse(self.starship.exists())


# ---------------------------------------------------------------- shared looks

class PaletteTests(unittest.TestCase):

    def test_good_palette_parses(self):
        colours, mode = al.parse_palette(palette_text())
        self.assertEqual(mode, "dark")
        self.assertEqual(set(colours), set(al.LOOK_KEYS))

    def test_rejects(self):
        good = palette_text()
        bad = {
            "unknown key": good + 'evil = "#000000"\n',
            "non-hex colour": good.replace('accent = "#ff5aa5"', 'accent = "red"'),
            "short hex": good.replace('accent = "#ff5aa5"', 'accent = "#fff"'),
            "missing key": "\n".join(l for l in good.splitlines() if not l.startswith("magenta ")),
            "bad mode": good.replace('mode = "dark"', 'mode = "neon"'),
            "unquoted line": good + "accent = #ff5aa5\n",
            "table": good + "[section]\n",
        }
        for why, text in bad.items():
            with self.subTest(why), self.assertRaises(ValueError):
                al.parse_palette(text)


class SharedLookTests(TempCase):

    def make(self, look_id="neon-rose", meta=None, colours=None, pictures=None):
        folder = self.tmp / look_id
        folder.mkdir()
        base = {"format": 1, "id": look_id, "name": "Neon Rose", "tagline": "Rain", "author": "someone",
                "version": 2}
        base.update(meta or {})
        (folder / "look.json").write_text(json.dumps(base))
        (folder / "colors.toml").write_text(colours if colours is not None else palette_text())
        if pictures is not None:
            (folder / "pictures.json").write_text(json.dumps(pictures))
        return folder

    def test_accepts_a_good_look(self):
        meta, colours, pictures, mode = al.validate_shared(self.make(pictures=[wallhaven_picture()]))
        self.assertEqual((meta["id"], meta["name"], meta["version"]), ("neon-rose", "Neon Rose", 2))
        self.assertEqual(len(pictures), 1)
        self.assertEqual(set(colours), set(al.LOOK_KEYS))

    def test_palette_only_is_fine(self):
        self.assertEqual(al.validate_shared(self.make())[2], [])

    def test_names_lose_markup_and_control_characters(self):
        meta = al.validate_shared(self.make(meta={"name": "<img src=x>Neon\x07 Rose", "tagline": "a\nb"}))[0]
        self.assertNotIn("<", meta["name"])
        self.assertNotIn("\x07", meta["name"])
        self.assertNotIn("\n", meta["tagline"])
        self.assertEqual(al.clean_text("x" * 100, 40), "x" * 40)

    def test_rejects_a_name_that_is_only_markup(self):
        with self.assertRaises(ValueError):
            al.validate_shared(self.make(meta={"name": "<<>>"}))

    def test_rejects_wrong_format_id_and_version(self):
        for why, meta, folder_id in (("format", {"format": 2}, "a"), ("id mismatch", {"id": "other"}, "b"),
                                     ("bad id", {"id": "Bad_ID"}, "Bad_ID"), ("version", {"version": "2"}, "c"),
                                     ("version 0", {"version": 0}, "d")):
            with self.subTest(why), self.assertRaises(ValueError):
                al.validate_shared(self.make(folder_id, meta=meta))

    def test_rejects_extra_files(self):
        folder = self.make()
        (folder / "install.sh").write_text("rm -rf ~")
        with self.assertRaises(ValueError):
            al.validate_shared(folder)

    def test_rejects_symlinked_files(self):
        folder = self.make()
        secret = self.tmp / "secret.json"
        secret.write_text((folder / "look.json").read_text())
        (folder / "look.json").unlink()
        (folder / "look.json").symlink_to(secret)
        with self.assertRaises(ValueError):
            al.validate_shared(folder)

    def test_rejects_oversized_files(self):
        with self.assertRaises(ValueError):
            al.validate_shared(self.make(colours=palette_text() + "# " + "x" * 70000 + "\n"))

    def test_rejects_bad_pictures(self):
        bad = {
            "http image": [wallhaven_picture(image="http://w.wallhaven.cc/full/g8/wallhaven-g8m1gl.jpg")],
            "http page": [wallhaven_picture(page="http://wallhaven.cc/w/g8m1gl")],
            "http source": [wallhaven_picture(source="http://example.com/art")],
            "host not allowed": [wallhaven_picture(image="https://evil.example.com/a.jpg")],
            "stock source": [wallhaven_picture(source="https://www.istockphoto.com/photo/x")],
            "not an image": [wallhaven_picture(image="https://w.wallhaven.cc/full/g8/x.svg")],
            "no page": [wallhaven_picture(page="")],
            "too many": [wallhaven_picture(n) for n in range(al.MAX_PICTURES + 1)],
            "not a list": {"image": "x"},
            "entry not an object": ["https://w.wallhaven.cc/full/g8/a.jpg"],
        }
        for n, (why, pictures) in enumerate(bad.items()):
            with self.subTest(why), self.assertRaises(ValueError):
                al.validate_shared(self.make(f"look-{n}", meta={"id": f"look-{n}"}, pictures=pictures))

    def test_shareable_reasons(self):
        self.assertEqual(al.shareable(wallhaven_picture()), (True, ""))
        cases = {
            "no recorded source": {"image": "", "page": ""},
            "isn't a site": {"image": "https://evil.example.com/a.jpg"},
            "stock photo": {"source": "https://www.shutterstock.com/image/1"},
            "not a jpg": {"image": "https://w.wallhaven.cc/full/g8/a.gif"},
        }
        for reason, change in cases.items():
            with self.subTest(reason):
                ok, said = al.shareable(wallhaven_picture(**change))
                self.assertFalse(ok)
                self.assertIn(reason, said)


# ---------------------------------------------------------------- colours and small helpers

class ColourTests(TempCase):

    def test_derived_palette_is_complete(self):
        colours = al.derive_palette(GOOD_SEED)
        self.assertEqual(set(al.LOOK_KEYS) - set(colours), set())
        for key in al.LOOK_KEYS:
            self.assertRegex(colours[key], r"^#[0-9a-f]{6}$", key)

    def test_readable_foreground_is_kept(self):
        colours = al.derive_palette(GOOD_SEED)
        self.assertGreaterEqual(al.contrast(colours["foreground"], colours["background"]), 7)

    def test_dim_foreground_is_lifted_to_7_to_1(self):
        # derive_palette lifts a dim foreground until it reads 7:1, but the
        # loop at its end copies every LOOK_KEYS entry in the seed back over
        # the result, and foreground is one: the lifted colour is replaced by
        # the dim original. (bin/afterlight, derive_palette: "for key, value in
        # seed.items()".)
        colours = al.derive_palette({**GOOD_SEED, "foreground": "#5a4a55"})
        self.assertGreaterEqual(al.contrast(colours["foreground"], colours["background"]), 7)

    def test_read_colors(self):
        path = self.tmp / "colors.toml"
        path.write_text('# comment\naccent = "#ff5aa5"\nmuted = "#86687f"\nmode = "dark" # trailing\n'
                        'hyprland_active_border = "rgba(ff5aa5ee) rgba(62b6ffee) 45deg"\n\nbroken line\n')
        colours = al.read_colors(path)
        self.assertEqual(colours["accent"], "#ff5aa5")
        self.assertEqual(colours["muted"], "#86687f")
        self.assertEqual(colours["hyprland_active_border"], "rgba(ff5aa5ee) rgba(62b6ffee) 45deg")
        self.assertEqual(colours["mode"], "dark")
        self.assertNotIn("# comment", colours)

    def test_read_colors_quoted_colour_with_trailing_comment(self):
        # read_colors keeps everything after a quoted "#..." value, so a
        # trailing comment ends up in the colour: '#86687f" # dim'.
        # (bin/afterlight, read_colors: the startswith('"#') branch.)
        path = self.tmp / "colors.toml"
        path.write_text('muted = "#86687f" # dim\n')
        self.assertEqual(al.read_colors(path)["muted"], "#86687f")

    def test_read_list(self):
        path = self.tmp / "list.json"
        self.assertEqual(al.read_list(path), [])
        path.write_text('{"not": "a list"}')
        self.assertEqual(al.read_list(path), [])
        path.write_text("not json")
        self.assertEqual(al.read_list(path), [])
        path.write_text('[{"file": "a.jpg"}]')
        self.assertEqual(al.read_list(path), [{"file": "a.jpg"}])

    def test_look_slug(self):
        self.assertEqual(al.look_slug("Neon Rose!"), "neon-rose")
        self.assertEqual(al.look_slug("  Cobalt   Rain  "), "cobalt-rain")
        self.assertEqual(al.look_slug("Afterlight"), "afterlight-mine")
        self.assertEqual(al.look_slug("!!!"), "look")
        self.assertLessEqual(len(al.look_slug("a very long name for a look indeed")), 24)


# ---------------------------------------------------------------- health check & repair

class HealthTests(TempCase):
    """health_run against a fake home: every link missing, nothing real touched."""

    def setUp(self):
        super().setUp()
        home = self.tmp / "home"
        config = home / ".config"
        (config / "hypr").mkdir(parents=True)
        self.home, self.config = home, config
        self.calls = []

        def fake_run(*cmd, quiet=True):
            self.calls.append(cmd)
            return Done()

        for name, value in {
            "HOME": home, "CONFIG": config, "STATE_HOME": home / ".local/state",
            "LOCAL_BIN": home / ".local/bin", "PLUGINS_DIR": config / "omarchy/plugins",
            "HOOKS": config / "omarchy/hooks", "SYSTEMD_USER": config / "systemd/user",
            "THEMES": config / "omarchy/themes", "MOUSE_LUA": config / "hypr/mouse.lua",
            "SHELL_JSON": config / "omarchy/shell.json", "BAR_REF": self.tmp / "baseline.json",
            "HEALTH": self.tmp / "health.json", "PATCHES": self.tmp / "patches",
            "UDEV_RULE": self.tmp / "udev.rules", "CHROME_POLICY": self.tmp / "policy.json",
            "COMMUNITY_DIR": home / ".local/share/baseline/looks",
            "OLD_HOOKS": (config / "omarchy/hooks/post-boot.d/afterlight-boot",),
            "run": fake_run, "out": lambda *cmd: "", "look_ids": lambda: [],
            "install_looks": lambda: None, "write_mouse": lambda settings: None,
            "omarelay_dir": lambda: None, "current_slug": lambda: "some-other-theme",
        }.items():
            self.patch(name, value)
        (self.tmp / "patches").mkdir()
        self.settings = copy.deepcopy(al.DEFAULTS)

    def test_reports_every_missing_link(self):
        result = al.health_run(self.settings)
        failing = {r["id"] for r in result["checks"] if not r["ok"]}
        for link, target, label in al.repo_links():
            self.assertIn(f"link:{link.name}", failing, label)
        self.assertIn("hypr:home", failing)
        self.assertGreater(result["failing"], 0)
        self.assertEqual(json.loads((self.tmp / "health.json").read_text())["failing"], result["failing"])
        self.assertTrue(all(not c[0].startswith("systemctl") or "enable" not in c for c in self.calls),
                        "a plain check must not change anything")

    def test_repair_puts_the_links_back(self):
        stale = self.config / "omarchy/hooks/post-boot.d/afterlight-boot"
        stale.parent.mkdir(parents=True)
        stale.write_text("#!/bin/bash")
        result = al.health_run(self.settings, fix=True)
        by_id = {r["id"]: r for r in result["checks"]}
        for link, target, label in al.repo_links():
            self.assertTrue(by_id[f"link:{link.name}"]["ok"], label)
            self.assertTrue(al.linked(link, target), label)
            self.assertTrue(link.is_relative_to(self.home), "repair wrote outside the fake home")
        self.assertTrue(by_id["hooks:old"]["ok"])
        self.assertFalse(stale.exists())
        self.assertTrue(by_id["hypr:home"]["ok"])
        self.assertIn('require("hypr.home")', (self.config / "hypr/hyprland.lua").read_text())
        self.assertIn("Workspaces and window rules", result["fixed"])
        self.assertEqual(result["errors"], [])
        # Services can't come up in a fake home, but repair did ask for them.
        self.assertIn(("systemctl", "--user", "enable", "--now", "afterlight-mouse.service"), self.calls)
        # The sudo-only parts are reported, never attempted.
        self.assertFalse(by_id["udev"]["ok"])
        self.assertEqual(by_id["udev"]["fix"], "sudo")
        self.assertFalse(any("sudo" in c for c in self.calls))

    def test_repair_never_touches_the_repo(self):
        before = {p: p.stat().st_mtime_ns for p in (ROOT / "system").rglob("*") if p.is_file()}
        al.health_run(self.settings, fix=True)
        after = {p: p.stat().st_mtime_ns for p in (ROOT / "system").rglob("*") if p.is_file()}
        self.assertEqual(before, after)
        for path in (ROOT / "system").rglob("*"):
            self.assertFalse(path.is_symlink(), f"{path} became a link")

    def test_quiet_repair_notifies_only_when_something_changed(self):
        al.health_run(self.settings, fix=True, quiet=True)
        self.assertTrue(any(c[0] == "omarchy-notification-send" for c in self.calls))


class DeckTests(TempCase):
    """The Deck's set: songs in, moved, shuffled around pins, built from a brief."""

    def setUp(self):
        super().setUp()
        for name, value in {"DECK": self.tmp / "deck.json", "DECK_LOCK": self.tmp / "deck.lock",
                            "DECK_NOW": self.tmp / "deck-now.json", "DECK_UNDO": self.tmp / "deck-undo.json",
                            "DECK_DETAILS": self.tmp / "deck-details.json", "DECK_DETAILS_LOCK": self.tmp / "details.lock",
                            "DECK_SETS": self.tmp / "deck-sets.json"}.items():
            self.patch(name, value)
        self.patch("toast", lambda *a, **k: None)
        self.patch("deck_after_edit", lambda: None)
        self.patch("sonos_rooms", lambda: [])

    def apple(self, n, title=None, by="Someone"):
        return {"kind": "song", "id": str(1000 + n), "title": title or f"Song {n}", "subtitle": f"{by} • An Album",
                "thumb": "https://example.com/a.jpg"}

    def deck(self, *args):
        al.deck_command({}, list(args))
        return al.deck_read()

    def test_add_checks_and_places_songs(self):
        for n in range(3):
            self.deck("add", "applemusic", json.dumps(self.apple(n)))
        d = self.deck("add", "applemusic", json.dumps(self.apple(9)), "--at", "1")
        self.assertEqual([s["title"] for s in d["set"]], ["Song 0", "Song 9", "Song 1", "Song 2"])
        self.assertEqual(d["set"][0]["artist"], "Someone")
        # The same song twice is one song; a bad id or a web page link never gets in.
        self.assertEqual(len(self.deck("add", "applemusic", json.dumps(self.apple(0)))["set"]), 4)
        with self.assertRaises(SystemExit):
            self.deck("add", "applemusic", json.dumps({**self.apple(5), "id": "1; rm -rf ~"}))
        with self.assertRaises(SystemExit):
            self.deck("add", "spotify", json.dumps(self.apple(5)))
        with self.assertRaises(SystemExit):
            self.deck("add", "beatport", json.dumps({**self.apple(5), "id": "../x"}))
        bad_art = self.deck("add", "applemusic", json.dumps({**self.apple(6), "thumb": "file:///etc/passwd"}))
        self.assertEqual(bad_art["set"][-1]["thumb"], "")

    def test_move_remove_and_back_from_played(self):
        for n in range(4):
            self.deck("add", "applemusic", json.dumps(self.apple(n)))
        uids = [s["uid"] for s in al.deck_read()["set"]]
        d = self.deck("move", uids[3], "0")
        self.assertEqual([s["title"] for s in d["set"]], ["Song 3", "Song 0", "Song 1", "Song 2"])
        d = self.deck("remove", uids[0])
        self.assertNotIn("Song 0", [s["title"] for s in d["set"]])
        al.deck_update(lambda d: d.update(played=[{"uid": "old1", "title": "Earlier", "service": "applemusic", "id": "7"}]))
        d = self.deck("move", "old1", "1")
        self.assertEqual(d["set"][1]["title"], "Earlier")
        self.assertEqual(d["played"], [])

    def test_shuffle_leaves_pinned_songs_in_place(self):
        for n in range(8):
            self.deck("add", "applemusic", json.dumps(self.apple(n)))
        uids = [s["uid"] for s in al.deck_read()["set"]]
        self.deck("pin", uids[0])
        self.deck("pin", uids[5])
        for _ in range(5):
            d = self.deck("shuffle")
            self.assertEqual((d["set"][0]["uid"], d["set"][5]["uid"]), (uids[0], uids[5]))
            self.assertEqual(sorted(s["uid"] for s in d["set"]), sorted(uids))
        self.assertEqual(self.deck("pin", uids[0])["pinned"], [uids[5]])

    def test_build_asks_for_the_right_length_and_keeps_reasons(self):
        asked = {}
        def ideas(query, ask=None, count=6, timeout=45, shape=False, mix=False, job=""):
            asked.update(ask=ask, count=count, shape=shape)
            return {"songs": [{"t": "Lady", "a": "Modjo", "w": "opener", "e": 5, "c": "Warm up"},
                              {"t": "Finally", "a": "CeCe Peniston", "w": "builds", "e": 7, "c": "Build"},
                              {"t": "Lady", "a": "Modjo", "w": "again", "e": 0, "c": ""}], "q": []}
        self.patch("grok_ideas", ideas)
        self.patch("find_songs", lambda service, wanted: [(i, self.apple(n, i["t"], i["a"])) for n, i in enumerate(wanted)])
        with mock.patch("shutil.which", return_value="/usr/bin/grok"):
            al.deck_command({"music": {"service": "applemusic"}},
                            ["build", "60", "rooftop", "at", "sunset", "--start", "Lady by Modjo", "--replace"])
        d = al.deck_read()
        self.assertEqual(asked["count"], 16 + 3)                     # an hour is about 16 songs
        self.assertIn("«rooftop at sunset»", asked["ask"])
        self.assertIn("Start with «Lady by Modjo»", asked["ask"])
        self.assertEqual([(s["title"], s["why"]) for s in d["set"]], [("Lady", "opener"), ("Finally", "builds")])
        self.assertTrue(asked["shape"])
        self.assertEqual([s["chapter"] for s in d["set"]], ["Warm up", "Build"])
        self.assertEqual(al.deck_with_details(d)["set"][1]["energy"], 7)

    def test_prep_pools_the_scouts_checks_the_catalogue_and_lets_the_judge_order(self):
        asked = []
        scouts = {"digger": [{"t": "Lady", "a": "Modjo"}, {"t": "Made Up", "a": "Nobody"}],
                  "connector": [{"t": "Lady", "a": "Modjo (radio edit)"}, {"t": "Finally", "a": "CeCe Peniston", "e": 8}],
                  "crowd": [{"t": "Finally", "a": "CeCe Peniston"}, {"t": "Music Sounds Better", "a": "Stardust"}]}
        def ask(prompt, tier="fast", job="", web=False, timeout=60, turns=1, agent=None):
            asked.append((tier, job, agent))
            if tier == "scout":
                angle = next(a for a in al.SCOUT_ANGLES if al.SCOUT_ANGLES[a] in prompt)
                return {"songs": scouts[angle]}
            self.assertIn("named by digger, connector", prompt)        # the judge sees who agreed
            self.assertNotIn("Made Up", prompt)                         # and only real songs
            return {"set": [{"n": 3, "c": "Warm up", "w": "opener"}, {"n": 1, "c": "Peak", "w": "the peak"},
                            {"n": 99}, {"n": 1}], "note": "A warm, rising night."}
        self.patch("agent_ask", ask)
        self.patch("agents_installed", lambda: ["grok", "claude", "codex"])
        self.patch("AGENTS_FILE", self.tmp / "deck-agents.json")
        al.agents_set("scout", "mix")
        self.patch("find_songs", lambda service, wanted: [
            (i, None if i["t"] == "Made Up" else self.apple(n, i["t"], i["a"])) for n, i in enumerate(wanted)])
        with mock.patch("shutil.which", return_value="/usr/bin/x"):
            al.deck_command({"music": {"service": "applemusic"}}, ["build", "60", "disco", "--replace", "--deep"])
        # Three scouts at once, each on a different agent; then one judge.
        self.assertEqual(sorted(a for t, j, a in asked if t == "scout"), ["claude", "codex", "grok"])
        self.assertEqual([j for t, j, a in asked if t == "judge"], ["judging"])
        d = al.deck_read()
        self.assertEqual([(s["title"], s["chapter"], s["why"]) for s in d["set"]],
                         [("Music Sounds Better", "Warm up", "opener"), ("Lady", "Peak", "the peak")])
        report = json.loads((self.tmp / "deck-prep.json").read_text())
        self.assertEqual(report["pool"], 4)
        self.assertEqual(report["agreed"], 2)
        self.assertEqual({s["angle"]: (s["ideas"], s["real"], s["kept"]) for s in report["scouts"]},
                         {"digger": (2, 1, 1), "connector": (2, 2, 1), "crowd": (2, 2, 1)})
        self.assertEqual(report["judge"]["note"], "A warm, rising night.")

    def test_prep_judge_that_times_out_gets_a_stand_in(self):
        asked = []
        def ask(prompt, tier="fast", job="", web=False, timeout=60, turns=1, agent=None):
            asked.append((tier, job))
            if tier == "scout":
                return {"songs": [{"t": "A", "a": "One"}, {"t": "B", "a": "Two"}]}
            return None if tier == "judge" else {"set": [{"n": 2}, {"n": 1}]}
        self.patch("agent_ask", ask)
        self.patch("find_songs", lambda service, wanted: [(i, self.apple(n, i["t"], i["a"])) for n, i in enumerate(wanted)])
        with mock.patch("shutil.which", return_value="/usr/bin/x"):
            al.deck_command({"music": {"service": "applemusic"}}, ["build", "30", "x", "--replace", "--deep"])
        self.assertEqual(asked[-2:], [("judge", "judging"), ("fast", "judging")])
        self.assertEqual([s["title"] for s in al.deck_read()["set"]], ["B", "A"])
        self.assertTrue(json.loads((self.tmp / "deck-prep.json").read_text())["judge"]["stoodIn"])

    def test_finding_a_song_prefers_the_original_version(self):
        hits = [{"kind": "song", "title": "Le Freak (Live)", "subtitle": "Chic • Live", "id": "1"},
                {"kind": "song", "title": "Le Freak (Instrumental)", "subtitle": "Chic • X", "id": "2"},
                {"kind": "song", "title": "Le Freak", "subtitle": "Chic • C'est Chic", "id": "3"}]
        self.patch("am_songs", lambda words: hits)
        [(idea, match)] = al.find_songs("applemusic", [{"t": "Le Freak", "a": "Chic"}])
        self.assertEqual(match["id"], "3")
        [(idea, match)] = al.find_songs("applemusic", [{"t": "Le Freak (Live)", "a": "Chic"}])
        self.assertEqual(match["id"], "1")

    def test_prep_goes_on_without_a_scout_that_lags(self):
        import threading
        release = threading.Event()
        stopped = []
        def ask(prompt, tier="fast", job="", web=False, timeout=60, turns=1, agent=None):
            if tier == "scout" and "crate digger" in prompt:
                release.wait(5)                     # the slow one
                return {"songs": [{"t": "Late", "a": "Slow"}]}
            if tier == "scout":
                return {"songs": [{"t": "Quick", "a": "One"}]}
            return {"set": [{"n": 1}]}
        self.patch("agent_ask", ask)
        self.patch("PREP_GRACE", 0.3)
        self.patch("agent_stop", lambda agent: (stopped.append(agent), release.set()))
        self.patch("find_songs", lambda service, wanted: [(i, self.apple(n, i["t"], i["a"])) for n, i in enumerate(wanted)])
        with mock.patch("shutil.which", return_value="/usr/bin/x"):
            al.deck_command({"music": {"service": "applemusic"}}, ["build", "30", "x", "--replace", "--deep"])
        self.assertEqual([s["title"] for s in al.deck_read()["set"]], ["Quick"])
        self.assertEqual(stopped, ["grok"])
        report = json.loads((self.tmp / "deck-prep.json").read_text())
        self.assertTrue(next(s for s in report["scouts"] if s["angle"] == "digger")["late"])

    def test_prep_without_a_verdict_keeps_what_the_scouts_agreed_on(self):
        def ask(prompt, tier="fast", job="", web=False, timeout=60, turns=1, agent=None):
            if job == "judging":
                return None             # the judge and its stand-in both fail
            return {"songs": [{"t": "Solo", "a": "One"}] + ([{"t": "Both", "a": "Two"}] if "crate digger" in prompt or "mixing DJ" in prompt else [])}
        self.patch("agent_ask", ask)
        self.patch("find_songs", lambda service, wanted: [(i, self.apple(n, i["t"], i["a"])) for n, i in enumerate(wanted)])
        with mock.patch("shutil.which", return_value="/usr/bin/x"):
            al.deck_command({"music": {"service": "applemusic"}}, ["build", "30", "x", "--replace", "--deep"])
        self.assertEqual([s["title"] for s in al.deck_read()["set"]], ["Solo", "Both"])

    def test_build_from_a_picked_song_opens_with_it(self):
        asked = {}
        def ideas(query, ask=None, count=6, timeout=45, shape=False, mix=False, job=""):
            asked.update(ask=ask)
            return {"songs": [{"t": "Lady", "a": "Modjo", "w": "follows", "e": 6, "c": "Build"},
                              {"t": "Seed", "a": "Someone", "w": "again", "e": 0, "c": ""}], "q": []}
        self.patch("grok_ideas", ideas)
        self.patch("find_songs", lambda service, wanted: [(i, self.apple(n + 5, i["t"], i["a"])) for n, i in enumerate(wanted)])
        with mock.patch("shutil.which", return_value="/usr/bin/grok"):
            al.deck_command({"music": {"service": "applemusic"}},
                            ["build", "30", "--seed", json.dumps(self.apple(1, "Seed", "Someone")), "--replace"])
        d = al.deck_read()
        self.assertEqual([s["title"] for s in d["set"]], ["Seed", "Lady"])     # the pick first, never twice
        self.assertIn("It opens with «Seed by Someone»", asked["ask"])
        self.assertIn("grows from Seed by Someone", asked["ask"])
        with self.assertRaises(SystemExit):                                     # neither a brief nor a song
            al.deck_command({"music": {"service": "applemusic"}}, ["build", "30"])

    def test_autodj_from_a_picked_song_puts_it_next_and_follows_it(self):
        self.patch("deck_watch", lambda: None)
        for n in range(2):
            self.deck("add", "applemusic", json.dumps(self.apple(n)))
        def ideas(query, ask=None, count=6, timeout=45, shape=False, mix=False, job=""):
            self.assertIn("The next song follows «Seed by Someone», which the listener just picked", ask)
            self.assertTrue(mix)
            return {"songs": [{"t": "More", "a": "Someone", "w": ""}, {"t": "Other", "a": "Else", "w": ""}], "q": []}
        self.patch("grok_ideas", ideas)
        self.patch("find_songs", lambda service, wanted: [(i, self.apple(n + 9, i["t"], i["a"])) for n, i in enumerate(wanted)])
        with mock.patch("shutil.which", return_value="/usr/bin/grok"):
            al.deck_command({"music": {"service": "applemusic"}},
                            ["autodj", "from", "applemusic", json.dumps(self.apple(7, "Seed", "Someone"))])
        d = al.deck_read()
        self.assertTrue(d["autodj"])
        self.assertEqual([s["title"] for s in d["set"]], ["Seed", "Other", "Song 0", "Song 1"])   # same artist skipped

    def test_autodj_songs_that_land_after_its_turned_off_or_a_new_set_dont_go_in(self):
        self.patch("deck_watch", lambda: None)
        self.patch("toast", lambda *a, **k: None)
        self.deck("add", "applemusic", json.dumps(self.apple(1)))
        meanwhile = {"do": None}
        def ideas(query, ask=None, count=6, timeout=45, shape=False, mix=False, job=""):
            meanwhile["do"]()                      # what happens while Grok thinks
            return {"songs": [{"t": "Late", "a": "Elsewhere", "w": ""}], "q": []}
        self.patch("grok_ideas", ideas)
        self.patch("find_songs", lambda service, wanted: [(i, self.apple(n + 9, i["t"], i["a"])) for n, i in enumerate(wanted)])
        al.deck_update(lambda d: d.update(autodj=True))
        with mock.patch("shutil.which", return_value="/usr/bin/grok"):
            meanwhile["do"] = lambda: al.deck_command({}, ["autodj", "off"])
            al.deck_fill_now({"music": {"service": "applemusic"}}, auto=True)
            self.assertNotIn("Late", [s["title"] for s in al.deck_read()["set"]])
            al.deck_update(lambda d: d.update(autodj=True))
            meanwhile["do"] = lambda: al.deck_command({}, ["clear"])
            al.deck_fill_now({"music": {"service": "applemusic"}}, auto=True)
            self.assertEqual(al.deck_read()["set"], [])
            meanwhile["do"] = lambda: None
            self.deck("add", "applemusic", json.dumps(self.apple(2)))
            al.deck_fill_now({"music": {"service": "applemusic"}}, auto=True)          # still on, same set: it lands
        self.assertIn("Late", [s["title"] for s in al.deck_read()["set"]])

    def test_an_opened_playlist_lists_its_songs_to_pick_from(self):
        self.patch("deck_expand_songs", lambda service, item: [al.deck_item(service, self.apple(3, "Picked", "Them"))])
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.deck("songs", "applemusic", json.dumps({"kind": "playlist", "id": "pl.x", "title": "Friday"}))
        [song] = json.loads(out.getvalue())
        self.assertEqual((song["kind"], song["title"], song["subtitle"], song["from"]), ("song", "Picked", "Them • An Album", "Friday"))
        self.patch("deck_expand_songs", lambda service, item: [al.deck_item(service, item)])
        d = self.deck("add", "applemusic", json.dumps(song))                 # picked and added: it remembers where from
        self.assertEqual((d["set"][0]["title"], d["set"][0]["from"]), ("Picked", "Friday"))
        with self.assertRaises(SystemExit):
            self.deck("songs", "applemusic", json.dumps(self.apple(1)))

    def test_voice_helpers_add_what_plays_a_named_song_and_say_whats_next(self):
        toasts = []
        self.patch("toast", lambda title, detail="", art="", glyph="": toasts.append((title, detail)))
        self.patch("playing_track", lambda: {"title": "Heard", "artist": "Band", "album": "", "art": ""})
        self.patch("find_songs", lambda service, wanted: [(wanted[0], self.apple(4, "Heard", "Band"))])
        self.deck("add", "applemusic", json.dumps(self.apple(1)))
        al.deck_command({"music": {"service": "applemusic"}}, ["grab", "--next"])
        d = al.deck_read()
        self.assertEqual([(s["title"], s.get("from")) for s in d["set"]], [("Heard", "Playing"), ("Song 1", None)])
        self.patch("deck_search", lambda service, words: [{"kind": "playlist", "title": "x"}, self.apple(6, "Blue Monday", "New Order")])
        al.deck_command({"music": {"service": "applemusic"}}, ["find-add", "blue", "monday"])
        self.assertEqual(al.deck_read()["set"][-1]["title"], "Blue Monday")
        al.deck_command({}, ["next-up"])
        self.assertEqual(toasts[-1], ("Next: Heard", "Band · then 2 more"))

    def test_mix_in_scatters_songs_after_the_next_one(self):
        for n in range(6):
            self.deck("add", "applemusic", json.dumps(self.apple(n)))
        first = al.deck_read()["set"][0]["uid"]
        self.patch("deck_expand", lambda service, item: [al.deck_item(service, self.apple(20)), al.deck_item(service, self.apple(21))])
        d = self.deck("add", "applemusic", json.dumps({"kind": "playlist", "id": "pl.x", "title": "Mix"}), "--scatter")
        self.assertEqual(len(d["set"]), 8)
        self.assertEqual(d["set"][0]["uid"], first)                   # what's next stays next
        self.assertEqual([s["title"] for s in d["set"] if s["title"] not in ("Song 20", "Song 21")],
                         [f"Song {n}" for n in range(6)])              # the rest keep their order

    def test_previous_goes_back_or_restarts(self):
        started = []
        self.patch("deck_start", lambda deck, song=None, start_at=0: (started.append(song["uid"]), deck.update(now=song))[1] or True)
        deck = {**al.DECK_EMPTY, "set": [{"uid": "c"}], "played": [{"uid": "a"}], "now": {"uid": "b"}, "playing": True}
        self.patch("deck_status", lambda d: {"time": 30})
        al.deck_previous(deck)                                         # well into a song: back to its start
        self.assertEqual(started, ["b"])
        self.patch("deck_status", lambda d: {"time": 2})
        al.deck_previous(deck)                                         # just started: the one before
        self.assertEqual(started, ["b", "a"])
        self.assertEqual([s["uid"] for s in deck["set"]], ["b", "c"])
        self.assertEqual(deck["played"], [])

    def test_next_pressed_while_the_watcher_looks_skips_only_once(self):
        a, b, c = ({"uid": u, "service": "applemusic", "id": i, "title": u} for u, i in (("a", "1"), ("b", "2"), ("c", "3")))
        self.patch("deck_where_room", lambda d: None)
        self.patch("deck_play_laptop", lambda song, start_at=0: None)
        self.patch("deck_watch", lambda: None)
        al.deck_update(lambda d: d.update(now=a, set=[b, c], playing=True, expect={"uid": "a", "since": 1}))
        def status(deck):
            # You press Next just as the watcher asks the player: the old song has
            # stopped and the new one is loading.
            al.deck_update(lambda d: al.deck_start(d))
            return {"time": 0, "length": 0, "playing": False, "id": "2"}
        self.patch("deck_status", status)
        al.deck_tick({"time": 40, "length": 200, "playing": True, "id": "1"})
        d = al.deck_read()
        self.assertEqual((d["now"]["uid"], [s["uid"] for s in d["set"]]), ("b", ["c"]))

    def test_details_wheel_and_what_does_not_sit_well(self):
        self.assertEqual((al.camelot("Gb Minor"), al.camelot("A Major"), al.camelot("C# minor"), al.camelot("nope")),
                         ("11A", "11B", "12A", ""))
        self.assertTrue(al.keys_fit("8A", "9A") and al.keys_fit("8A", "8B") and al.keys_fit("12A", "1A"))
        self.assertFalse(al.keys_fit("8A", "3B"))
        self.assertTrue(al.tempos_fit(124, 126) and al.tempos_fit(70, 140))
        self.assertFalse(al.tempos_fit(100, 128))
        a, b, c = (dict(self.apple(n), service="applemusic") for n in range(3))
        for n in range(3):
            self.deck("add", "applemusic", json.dumps(self.apple(n, by="Same" if n < 2 else "Other")))
        d = al.deck_read()
        al.deck_details_note(d["set"][0], length=200, bpm=124, key="8A", energy=5)
        al.deck_details_note(d["set"][1], length=180, bpm=100, key="3B")
        al.deck_details_note(d["set"][2], bpm=100, key="3B")
        shown = al.deck_with_details(d)
        self.assertEqual(shown["set"][0]["length"], 200)
        self.assertEqual(shown["set"][1]["warn"], ["tempo", "artist"])     # a key clash alone isn't flagged
        self.assertEqual(shown["set"][2]["warn"], [])
        self.assertTrue(al.tempos_fit(124, 110, al.DECK_JUMP))                # 11%: not worth a mark
        d["shaped"] = [d["set"][1]["uid"]]
        self.assertEqual(al.deck_with_details(d)["set"][1]["warn"], [])     # a shape placed it
        self.assertNotIn("warn", al.deck_read()["set"][0])          # shown, never stored

    def test_details_are_looked_up_once_and_kept_apart(self):
        self.patch("STATE", self.tmp / "afterlight/state.json")
        (self.tmp / "afterlight").mkdir()
        for n in range(2):
            self.deck("add", "applemusic", json.dumps(self.apple(n)))
        self.patch("am_lookup", lambda params: [{"trackId": 1000, "trackTimeMillis": 201000}, {"trackId": 1001, "trackTimeMillis": 99000}])
        self.patch("grok_json", lambda prompt, timeout=60, job="": {"e": [4, 9]})
        self.patch("beatport_windows", lambda: [])
        al.deck_details_fill()
        details = al.deck_details_read()
        self.assertEqual((details["am:1000"]["length"], details["am:1001"]["energy"]), (201, 9))
        self.assertEqual(al.deck_details_wanted(al.deck_read()), [])     # Beatport waits; not asked again within the hour

    def test_chapters_name_move_and_join(self):
        for n in range(6):
            self.deck("add", "applemusic", json.dumps(self.apple(n)))
        uids = [s["uid"] for s in al.deck_read()["set"]]
        self.deck("chapter", uids[0], "Warm", "up")
        self.deck("chapter", uids[3], "Peak")
        d = al.deck_read()
        self.assertEqual([s.get("chapter", "") for s in d["set"]], ["Warm up"] * 3 + ["Peak"] * 3)
        d = self.deck("move-chapter", uids[3], "0")                     # the peak first
        self.assertEqual([s["uid"] for s in d["set"]], uids[3:] + uids[:3])
        d = self.deck("chapter", uids[0], "")                           # warm up joins the peak
        self.assertEqual({s.get("chapter") for s in d["set"]}, {"Peak"})

    def test_several_at_once_undo_and_saved_sets(self):
        self.patch("deck_watch", lambda: None)
        self.patch("deck_where_room", lambda d: None)
        for n in range(5):
            self.deck("add", "applemusic", json.dumps(self.apple(n)))
        uids = [s["uid"] for s in al.deck_read()["set"]]
        d = self.deck("place", "next", uids[4], uids[2])
        self.assertEqual([s["uid"] for s in d["set"]][:2], [uids[2], uids[4]])     # in set order
        d = self.deck("remove", uids[0], uids[1])
        self.assertEqual(len(d["set"]), 3)
        d = self.deck("undo")
        self.assertEqual(len(d["set"]), 5)
        d = self.deck("undo")
        self.assertEqual([s["uid"] for s in d["set"]], uids)
        al.deck_command({}, ["save", "Friday"])
        self.deck("clear")
        self.assertEqual(al.deck_set_list()[0]["count"], 5)
        d = self.deck("load", "friday")
        self.assertEqual([s["title"] for s in d["set"]], [f"Song {n}" for n in range(5)])
        self.assertNotEqual(d["set"][0]["uid"], uids[0])                # fresh copies

    def test_sleep_after_a_while_or_this_song(self):
        d = {**al.DECK_EMPTY, "now": {"uid": "a"}}
        al.deck_sleep(d, "song")
        self.assertFalse(al.deck_sleep_due(d))
        d["now"] = {"uid": "b"}
        self.assertTrue(al.deck_sleep_due(d))
        al.deck_sleep(d, "30")
        self.assertFalse(al.deck_sleep_due(d))
        d["sleep"]["at"] -= 31 * 60
        self.assertTrue(al.deck_sleep_due(d))
        al.deck_sleep(d, "off")
        self.assertIsNone(d["sleep"])

    def test_beatport_tracks_join_the_set_with_their_details(self):
        track = {"track_id": 22988389, "track_name": "Pump Up The Jam", "mix_name": "Original Mix", "bpm": 126,
                 "key_name": "C Minor", "length": 278095, "artists": [{"artist_name": "Technotronic"}],
                 "label": {"label_name": "ARS"}, "release": {"release_image_dynamic_uri": "https://geo-media.beatport.com/image_size/{w}x{h}/a.jpg"}}
        item = al.beatport_item(track)
        self.assertEqual((item["title"], item["subtitle"], item["key"], item["length"]),
                         ("Pump Up The Jam (Original Mix)", "Technotronic • ARS", "5A", 278))
        self.assertEqual(item["thumb"], "https://geo-media.beatport.com/image_size/300x300/a.jpg")
        d = self.deck("add", "beatport", json.dumps(item))
        song = d["set"][0]
        self.assertEqual(al.beatport_track_url(song), "https://www.beatport.com/track/pump-up-the-jam/22988389")
        self.assertEqual(al.deck_with_details(d)["set"][0]["bpm"], 126)
        self.assertEqual(al.deck_song_key(song), "bp:22988389")

    def test_fix_the_bumps_moves_only_what_clashes(self):
        song = lambda uid, artist, key, bpm: {"uid": uid, "service": "applemusic", "id": uid, "title": uid,
                                              "artist": artist, "key": key, "bpm": bpm}
        a, b, c, d = song("1", "A", "8A", 120), song("2", "A", "8A", 121), song("3", "B", "9A", 122), song("4", "C", "8A", 120)
        deck = {**al.DECK_EMPTY, "now": None, "set": [a, b, c, d], "pinned": []}
        self.patch("deck_with_details", lambda x: x)
        al.deck_shape(deck, "bumps")
        order = [s["uid"] for s in deck["set"]]
        self.assertNotEqual(order.index("2"), order.index("1") + 1)    # same artist no longer back to back
        self.assertEqual(sorted(order), ["1", "2", "3", "4"])

    def test_a_request_mixed_in_lands_soon_where_it_fits(self):
        song = lambda uid, artist, key: {"uid": uid, "service": "applemusic", "id": uid, "title": uid, "artist": artist, "key": key, "bpm": 120}
        now = song("n", "Now", "8A")
        rest = [song("a", "X", "8A"), song("b", "Y", "1B"), song("c", "Z", "9A")] + [song(f"z{i}", f"Q{i}", "8A") for i in range(20)]
        deck = {**al.DECK_EMPTY, "now": now, "set": rest, "pinned": []}
        self.patch("deck_with_details", lambda x: x)
        spot = al.deck_mix_spot(deck, song("r", "Now", "8A"))
        self.assertLessEqual(spot, al.DECK_MIX_REACH)     # soon, not at the end
        self.assertNotEqual(spot, 0)                      # not straight after the same artist

    def test_taking_a_request_puts_it_in_the_set(self):
        self.patch("deck_with_details", lambda x: x)
        al.deck_update(lambda d: d.update(set=[{"uid": "s1", "service": "applemusic", "id": "1", "title": "One", "artist": "A"}],
                                          requests=[{"rid": "r1", "id": "99", "title": "Asked", "artist": "Guest band",
                                                     "thumb": "", "by": "Sam", "phone": "10.0.0.2", "at": 1}]))
        self.assertTrue(al.deck_request_take("r1", "next"))
        deck = al.deck_read()
        self.assertEqual(deck["requests"], [])
        self.assertEqual(deck["set"][0]["title"], "Asked")
        self.assertEqual(deck["set"][0]["from"], "Request · Sam")
        self.assertFalse(al.deck_request_take("r1"))     # only once

    def test_a_dedication_is_said_once_as_its_song_starts(self):
        self.patch("voice_ready", lambda: True)
        song = {"uid": "u1", "rid": "0a1b2c3d", "by": "Sam", "note": "For Jess, happy birthday!",
                "title": "Lady (Hear Me Tonight) [Radio Edit]", "artist": "Modjo"}
        self.assertEqual(al.deck_voice_text(song),
                         "A request from Sam. For Jess, happy birthday! Here's Lady, by Modjo.")
        deck = {**al.DECK_EMPTY, "now": song, "playing": True}
        self.assertTrue(al.deck_voice_due(deck))
        self.assertFalse(al.deck_voice_due({**deck, "spoken": ["0a1b2c3d"]}))      # said already
        self.assertFalse(al.deck_voice_due({**deck, "voice": False}))              # turned off
        self.assertFalse(al.deck_voice_due({**deck, "now": {**song, "note": ""}}))  # nothing to say
        self.assertIsNone(al.deck_voice_clip({**song, "rid": "../x"}))             # only real request ids name files
        self.assertIn("by Earth, Wind and Fire.", al.deck_voice_text({**song, "artist": "Earth, Wind & Fire"}))
        self.patch("voices_ready", lambda: [v for v in al.VOICES if v[0] != "piper"])
        self.assertEqual(al.deck_voice_name({}), "am_michael")                      # Michael unless you pick
        self.assertEqual(al.deck_voice_name({"voiceName": "bf_emma"}), "bf_emma")
        self.assertEqual(al.deck_voice_name({"voiceName": "piper"}), "am_michael")  # not installed: the default
        al.deck_update(lambda d: d.update(voiceName="bf_emma"))
        self.assertEqual(al.deck_voice_name(al.deck_read()), "bf_emma")             # the pick is kept

    def test_a_sonos_room_says_the_next_dedication_as_the_song_ends(self):
        self.patch("voice_ready", lambda: True)
        room = {"id": "RINCON_X", "ip": "10.0.0.9", "name": "Quiet Room"}
        self.patch("deck_where_room", lambda deck: room)
        self.patch("deck_sonos_soon", lambda: None)
        spawned = []
        self.patch("subprocess", type("S", (), {"Popen": staticmethod(lambda argv, **kw: spawned.append(argv[1:])),
                                                 "DEVNULL": None}))
        now = {"uid": "u1", "service": "applemusic", "id": "1", "title": "One", "artist": "A"}
        asked = {"uid": "u2", "service": "applemusic", "id": "2", "title": "Two", "artist": "B", "rid": "0a1b2c3d",
                 "by": "Sam", "note": "Hi"}
        al.deck_update(lambda d: d.update(now=now, set=[asked], playing=True, pushed=["u1", "u2"], pushedFrom=1,
                                          where={"kind": "sonos", "room": "RINCON_X"}))
        self.patch("deck_status", lambda deck: {"time": 100, "length": 250, "playing": True, "track": 1})
        al.deck_tick({"time": 99})
        self.assertEqual(spawned, [["deck", "voice", "make", "0a1b2c3d"]])   # made early, ready in time
        al.deck_tick({"time": 100})
        self.assertEqual(len(spawned), 1)                               # once, not every look
        spawned.clear()
        self.patch("deck_status", lambda deck: {"time": 248, "length": 250, "playing": True, "track": 1})
        al.deck_tick({"time": 247})
        self.assertEqual(spawned, [["deck", "say", "u2", "--before"]])
        self.assertEqual(al.deck_read()["spoken"], ["0a1b2c3d"])        # and never again when it starts
        al.deck_update(lambda d: d.update(voiceUntil=time.time() + 30))
        self.assertEqual(al.deck_tick({"time": 1}), {"time": 1})        # mid-clip: the room isn't followed

    def test_beatport_is_quieted_with_its_own_pause_button(self):
        sent, keys = [], []
        self.patch("beatport_bridge", lambda req, timeout=8: sent.append(req["op"]) or {"ok": True, "count": 0})
        self.patch("beatport_player_playing", lambda: True)
        self.patch("media_command", lambda cmd: keys.append(cmd))
        bp = {"uid": "b", "service": "beatport", "id": "1", "title": "B"}
        self.assertTrue(al.deck_can_quiet(bp))
        al.deck_quiet(bp)
        self.assertEqual(sent[-1]["type"], "click")
        self.assertEqual(sent[-1]["label"], "^Pause$")
        self.assertEqual(keys, [])     # never the media keys, which could pause the wrong app
        yt = {"uid": "y", "service": "ytmusic", "video": "abcdefghijk", "title": "Y"}
        self.assertFalse(al.deck_can_quiet(yt))   # no player on the page: can't promise

    def test_switching_apps_pauses_the_one_before(self):
        quieted, played = [], []
        self.patch("deck_where_room", lambda d: None)
        self.patch("deck_watch", lambda: None)
        self.patch("deck_quiet", lambda song: quieted.append(song["uid"]))
        self.patch("deck_play_laptop", lambda song, start_at=0: played.append(song["uid"]))
        yt = {"uid": "y", "service": "ytmusic", "video": "abcdefghijk", "title": "Y"}
        bp = {"uid": "b", "service": "beatport", "id": "1", "title": "B"}
        am = {"uid": "a", "service": "applemusic", "id": "2", "title": "A"}
        deck = {**al.DECK_EMPTY, "now": yt, "set": [bp, am], "playing": True}
        al.deck_start(deck)
        al.deck_start(deck)
        self.assertEqual((played, quieted), (["b", "a"], ["y", "b"]))
        deck["playing"] = False                       # paused: nothing to quiet
        deck["set"] = [{**am, "uid": "a2"}, yt]
        al.deck_start(deck, yt)
        self.assertEqual(quieted, ["y", "b"])

    def test_shaping_the_set_by_its_details(self):
        for n in range(6):
            self.deck("add", "applemusic", json.dumps(self.apple(n)))
        d = al.deck_read()
        uids = [s["uid"] for s in d["set"]]
        for song, (bpm, energy, key) in zip(d["set"], [(128, 8, "8A"), (100, 2, "3B"), (124, 9, "9A"), (110, 4, "3A"), (0, 0, ""), (120, 6, "8B")]):
            if bpm:
                al.deck_details_note(song, bpm=bpm, energy=energy, key=key)
        titles = lambda d: [s["title"] for s in d["set"]]
        self.assertEqual(titles(self.deck("shape", "tempo")), ["Song 1", "Song 3", "Song 5", "Song 2", "Song 0", "Song 4"])
        self.assertEqual(titles(self.deck("shape", "energy")), ["Song 1", "Song 3", "Song 5", "Song 0", "Song 2", "Song 4"])
        arc = titles(self.deck("shape", "arc"))
        self.assertEqual(arc[-1], "Song 4")                              # no energy known: last
        self.assertEqual(arc.index("Song 2"), 3)                         # the peak, two thirds in
        self.deck("move", uids[0], "0")
        self.deck("pin", uids[0])                                        # Song 0 (8A), first and pinned
        d = self.deck("shape", "harmonic")
        self.assertEqual(d["set"][0]["uid"], uids[0])                    # pinned stays put
        self.assertEqual(titles(d)[1:3], ["Song 2", "Song 5"])           # then 9A, 8B: neighbours on the wheel
        self.assertEqual(len(self.deck("undo")["set"]), 6)

    def test_songs_remember_where_they_came_from(self):
        self.patch("am_playlist_tracks", lambda pid: [{"id": "1100", "title": "A", "artist": "X"}, {"id": "1101", "title": "B", "artist": "Y"}])
        self.deck("add", "applemusic", json.dumps({"kind": "playlist", "id": "pl.u-abc", "title": "Friday Disco"}))
        self.deck("add", "beatport", json.dumps({"kind": "song", "id": "22988389", "title": "Pump Up The Jam", "subtitle": "Technotronic"}))
        d = al.deck_read()
        self.assertEqual([s.get("from", "") for s in d["set"]], ["Friday Disco", "Friday Disco", ""])
        al.deck_update(lambda d: d.update(played=[{"uid": "p1", "service": "ytmusic", "video": "abcdefghijk", "title": "Earlier", "from": "Warm-up"}]))
        al.deck_command({}, ["save", "Tonight", "--played"])
        al.deck_command({}, ["save", "Whole", "night", "--all"])
        self.assertEqual({s["name"]: s["count"] for s in al.deck_set_list()}, {"Whole night": 4, "Tonight": 1})
        al.deck_command({}, ["forget", "whole night"])
        al.deck_command({}, ["forget", "tonight"])
        al.deck_command({}, ["save", "Mixed"])
        [saved] = al.deck_set_list()
        self.assertEqual((saved["services"], saved["from"]), (["Apple Music 2", "Beatport 1"], ["Friday Disco", "search"]))

    def test_export_finds_each_song_on_the_service(self):
        songs = [{"uid": "a", "service": "applemusic", "id": "11", "title": "Lady (Hear Me Tonight)", "artist": "Modjo"},
                 {"uid": "b", "service": "ytmusic", "video": "abcdefghijk", "title": "Finally", "artist": "CeCe Peniston"},
                 {"uid": "c", "service": "ytmusic", "video": "bcdefghijkl", "title": "Nowhere", "artist": "Nobody"}]
        self.patch("beatport_search_tracks", lambda q: [
            {"kind": "song", "id": "901", "title": "Lady (Hear Me Tonight) (Original Mix)", "subtitle": "Modjo • Sound of Barclay"},
            {"kind": "song", "id": "902", "title": "Finally (Choice Mix)", "subtitle": "Someone Else • X"},
            {"kind": "song", "id": "903", "title": "Finally (Classic Mix)", "subtitle": "CeCe Peniston • A&M"}])
        sent = {}
        self.patch("beatport_bridge", lambda request, timeout=5: sent.update(request) or {"ok": True, "id": 7})
        result = al.deck_export("beatport", "Friday", songs)
        self.assertEqual(sent["op"], {"type": "bp-export", "name": "Friday", "ids": ["901", "903"]})
        self.assertEqual((result["ok"], result["found"], result["missing"]), (True, 2, ["Nowhere"]))

    def test_the_last_seconds_fade_into_the_next_song(self):
        volumes, started = [], []
        self.patch("deck_where_room", lambda d: None)
        self.patch("deck_watch", lambda: None)
        self.patch("time", mock.Mock(time=lambda: 1000.0, sleep=lambda s: None))
        self.patch("deck_app_volume", lambda song, level=None: volumes.append((song["uid"], level)) or 0.8)
        self.patch("deck_play_laptop", lambda song, start_at=0: started.append(song["uid"]))
        self.patch("deck_quiet", lambda song: None)
        a, b = ({"uid": u, "service": "applemusic", "id": i, "title": u} for u, i in (("a", "1"), ("b", "2")))
        al.deck_update(lambda d: d.update(now=a, set=[b], playing=True, expect={"uid": "a", "since": 900}))
        self.patch("deck_status", lambda d: {"time": 196, "length": 200, "playing": True, "id": "1"})
        al.deck_tick({"time": 194, "length": 200, "playing": True, "id": "1"})
        self.assertEqual(started, ["b"])
        self.assertEqual(volumes[1:4], [("a", 0.648), ("a", 0.512), ("a", 0.392)])     # easing out
        self.assertEqual(volumes[-1], ("a", 0.8))                                      # and put back
        self.assertEqual(al.deck_read()["now"]["uid"], "b")

    def test_autodj_tops_up_a_short_set(self):
        d = {**al.DECK_EMPTY, "autodj": True, "playing": True, "set": [{"uid": "x"}] * 3}
        self.assertTrue(al.deck_autodj_due(d))
        self.assertFalse(al.deck_autodj_due({**d, "set": [{"uid": "x"}] * 4}))
        self.assertFalse(al.deck_autodj_due({**d, "autodjAt": al.time.time()}))
        self.assertFalse(al.deck_autodj_due({**d, "autodj": False}))

    def test_sonos_queue_entry_for_an_apple_song(self):
        uri, meta = al.sonos_apple_uri("1440833098", "13")
        self.assertEqual(uri, "x-sonos-http:song%3a1440833098.mp4?sid=204&flags=8232&sn=13")
        self.assertIn('id="10032020song%3a1440833098"', meta)
        self.assertIn("SA_RINCON52231_X_#Svc52231-0-Token", meta)

    def test_find_songs_prefers_the_named_artist_over_covers(self):
        results = [{"kind": "song", "title": "Music Sounds Better With You", "subtitle": "Dance Fruits Music • Covers", "id": "1"},
                   {"kind": "song", "title": "Music Sounds Better With You", "subtitle": "Stardust • Single", "id": "2"}]
        self.patch("am_songs", lambda query, limit=10: results)
        [(idea, match)] = al.find_songs("applemusic", [{"t": "Music Sounds Better With You", "a": "Stardust", "w": ""}])
        self.assertEqual(match["id"], "2")
        [(idea, match)] = al.find_songs("applemusic", [{"t": "Music Sounds Better With You", "a": "Nobody Here", "w": ""}])
        self.assertIsNone(match)


Q, M, K, L = ("RINCON_000E58BC46FC01400", "RINCON_000E58B234C701400", "RINCON_347E5CF6D52001400", "RINCON_48A6B8BBE5C001400")
GROUPED = f"""<ZoneGroupState><ZoneGroups>
<ZoneGroup Coordinator="{Q}" ID="g1">
  <ZoneGroupMember UUID="{Q}" Location="http://192.168.1.10:1400/x" ZoneName="Quiet Room - Sonos"/>
  <ZoneGroupMember UUID="{M}" Location="http://192.168.1.11:1400/x" ZoneName="Master Bedroom - Sonos"/>
</ZoneGroup>
<ZoneGroup Coordinator="{K}" ID="g2">
  <ZoneGroupMember UUID="{K}" Location="http://192.168.1.12:1400/x" ZoneName="Kitchen"/>
</ZoneGroup>
<ZoneGroup Coordinator="{L}" ID="g3">
  <ZoneGroupMember UUID="{L}" Location="http://192.168.1.13:1400/x" ZoneName="Lounge (Arc)">
    <Satellite UUID="RINCON_000000000000S1400" Location="http://192.168.1.14:1400/x" Invisible="1"/>
  </ZoneGroupMember>
</ZoneGroup>
</ZoneGroups></ZoneGroupState>"""


class DeckRoomTests(TempCase):
    """Rooms playing together: joining, leaving, everywhere, and never
    disturbing a room that's busy (the TV)."""

    def setUp(self):
        super().setUp()
        self.patch("DECK", self.tmp / "deck.json")
        self.patch("DECK_LOCK", self.tmp / "deck.lock")
        self.patch("toast", lambda *a, **k: None)
        self.rooms = al.sonos_parse_groups(GROUPED)
        self.patch("sonos_rooms", lambda refresh=False: self.rooms)
        self.calls = []
        self.volumes = {"192.168.1.10": 20, "192.168.1.11": 15, "192.168.1.12": 60, "192.168.1.13": 30}
        self.playing = {"192.168.1.13"}          # the TV in the lounge
        def call(ip, service, action, args=None, timeout=2.5):
            self.calls.append((ip, action, dict(args or {})))
            if action == "GetVolume":
                return {"CurrentVolume": str(self.volumes[ip])}
            if action == "GetTransportInfo":
                return {"CurrentTransportState": "PLAYING" if ip in self.playing else "STOPPED"}
            return {}
        self.patch("sonos_call", call)
        al.deck_update(lambda d: d.update(where={"kind": "sonos", "room": Q}))

    def sent(self, action):
        return [(ip, args) for ip, a, args in self.calls if a == action]

    def test_every_speaker_on_its_own(self):
        speakers = al.sonos_speakers(self.rooms)
        self.assertEqual([(s["name"], s["ip"], s["lead"]) for s in speakers],
                         [("Kitchen", "192.168.1.12", True), ("Lounge (Arc)", "192.168.1.13", True),
                          ("Quiet Room", "192.168.1.10", True), ("Master Bedroom", "192.168.1.11", False)])
        self.assertEqual({s["group"] for s in speakers if s["name"] in ("Quiet Room", "Master Bedroom")}, {Q})

    def test_join_is_never_louder_than_the_party(self):
        self.assertTrue(al.deck_join(K))
        self.assertEqual(self.sent("SetVolume"), [("192.168.1.12", {"InstanceID": 0, "Channel": "Master", "DesiredVolume": 20})])
        self.assertEqual(self.sent("SetAVTransportURI")[0], ("192.168.1.12", {"InstanceID": 0, "CurrentURI": f"x-rincon:{Q}",
                                                                              "CurrentURIMetaData": ""}))
        self.assertFalse(al.deck_join(M))           # already in

    def test_join_needs_the_deck_in_a_room(self):
        al.deck_update(lambda d: d.update(where={"kind": "laptop"}))
        with self.assertRaises(SystemExit):
            al.deck_join(K)

    def test_lead_leaving_hands_over_and_the_deck_follows(self):
        self.assertTrue(al.deck_leave(Q))
        self.assertEqual(self.sent("DelegateGroupCoordinationTo"),
                         [("192.168.1.10", {"InstanceID": 0, "NewCoordinator": M, "RejoinGroup": 0})])
        self.assertEqual(al.deck_read()["where"], {"kind": "sonos", "room": M})

    def test_member_leaving_goes_quiet_on_its_own(self):
        self.assertTrue(al.deck_leave(M))
        self.assertEqual(self.sent("BecomeCoordinatorOfStandaloneGroup"), [("192.168.1.11", {"InstanceID": 0})])
        self.assertEqual(al.deck_read()["where"], {"kind": "sonos", "room": Q})
        self.assertFalse(al.deck_leave(K))         # alone already: nothing to do

    def test_everywhere_leaves_a_busy_room_alone(self):
        al.deck_everywhere()
        joined = [ip for ip, args in self.sent("SetAVTransportURI")]
        self.assertEqual(joined, ["192.168.1.12"])                # the kitchen, not the lounge's TV
        self.assertNotIn("192.168.1.13", [ip for ip, a, _ in self.calls if a.startswith("Set") or a.startswith("Become")])

    def test_rooms_report_busy_ones(self):
        rooms = {r["name"]: r for r in al.deck_rooms()["rooms"]}
        self.assertTrue(rooms["Lounge (Arc)"]["busy"])
        self.assertFalse(rooms["Kitchen"]["busy"])
        self.assertTrue(rooms["Master Bedroom"]["here"] and not rooms["Master Bedroom"]["busy"])
        self.assertEqual(rooms["Kitchen"]["volume"], 60)


class DeckPlaylistTests(TempCase):
    """Playlists and albums in the Deck: found, read song by song, queued on
    Sonos a few dozen at a time."""

    def row(self, video, title, artist, album=""):
        col = lambda text: {"musicResponsiveListItemFlexColumnRenderer": {"text": {"runs": [{"text": text}]}}}
        return {"musicResponsiveListItemRenderer": {"playlistItemData": {"videoId": video},
                                                    "flexColumns": [col(title), col(artist), col(album)]}}

    def test_video_titles_become_song_and_artist(self):
        self.assertEqual(al.ytm_video_title("Stardust - Music Sounds Better With You (Official Video)", "someone"),
                         ("Music Sounds Better With You", "Stardust"))
        self.assertEqual(al.ytm_video_title("The Buffalo Bunch - Take It To The Street (1999)", "x"),
                         ("Take It To The Street", "The Buffalo Bunch"))
        self.assertEqual(al.ytm_video_title("Lady (Hear Me Tonight)", "Modjo"), ("Lady (Hear Me Tonight)", "Modjo"))

    def test_youtube_playlist_read_in_order_across_pages(self):
        pages = {"VLPLabcdefghij": {"contents": [self.row("aaaaaaaaaaa", "Lady", "Modjo", "Lady"),
                                                 self.row("bbbbbbbbbbb", "Cassius - 1999 (Official Video)", "uploader"),
                                                 self.row("bad id!", "Nope", "x")],
                                    "continuationCommand": {"token": "T1"}},
                 "T1": {"contents": [self.row("ccccccccccc", "Flat Beat", "Mr. Oizo", "Analog Worms Attack"),
                                     self.row("aaaaaaaaaaa", "Lady", "Modjo", "Lady")]}}
        self.patch("ytm_call", lambda endpoint, body: pages[body.get("browseId") or body.get("continuation")])
        tracks = al.ytm_tracks({"kind": "playlist", "playlist": "PLabcdefghij", "title": "Mix"})
        self.assertEqual([(t["video"], t["title"], t["artist"]) for t in tracks],
                         [("aaaaaaaaaaa", "Lady", "Modjo"), ("bbbbbbbbbbb", "1999", "Cassius"),
                          ("ccccccccccc", "Flat Beat", "Mr. Oizo")])

    def test_album_songs_take_the_albums_artist_and_cover(self):
        self.patch("ytm_call", lambda endpoint, body: {"contents": [self.row("aaaaaaaaaaa", "One More Time", "")]})
        [song] = al.deck_expand("ytmusic", {"kind": "album", "browse": "MPREb_7ltM34kr0mH", "title": "Discovery",
                                            "subtitle": "Daft Punk • 2001", "thumb": "https://example.com/d.jpg"})
        self.assertEqual((song["title"], song["artist"], song["album"], song["thumb"]),
                         ("One More Time", "Daft Punk", "Discovery", "https://example.com/d.jpg"))

    def test_apple_playlists_only_checked_ids_and_catalogue_songs(self):
        replies = {"playlists": {"ok": True, "items": [{"id": "p.AbC123", "name": "Halloween", "library": True, "art": "https://a"},
                                                       {"id": "pl.123abc", "name": "Essentials", "curator": "Apple"},
                                                       {"id": "javascript:alert(1)", "name": "bad"}]},
                   "tracks": {"ok": True, "items": [{"id": "1090981930", "title": "1999", "artist": "Cassius"},
                                                    {"id": "i.libraryonly", "title": "Not in the catalogue"}]}}
        self.patch("am_bridge", lambda op, timeout=8: replies[op["action"]])
        found = al.am_playlists("halloween")
        self.assertEqual([(p["id"], p["mine"]) for p in found], [("p.AbC123", True), ("pl.123abc", False)])
        songs = al.deck_expand("applemusic", {"kind": "playlist", "id": "p.AbC123"})
        self.assertEqual([(s["id"], s["title"]) for s in songs], [("1090981930", "1999")])
        self.assertEqual(al.am_playlist_tracks("../../etc"), [])

    def test_search_puts_your_playlists_first(self):
        self.patch("ytm_playlists", lambda refresh=False: [{"name": "French House Classics", "playlist": "PLmineminemine"},
                                                           {"name": "Gym", "playlist": "PLgymgymgymgym"}])
        def search(words):
            if words.endswith(" playlist"):
                return [{"kind": "playlist", "title": "Best French House", "playlist": "PLotherother1"},
                        {"kind": "playlist", "title": "PHONK TRENDING", "playlist": "PLphonkphonk1"}]
            return [{"kind": "song", "title": "Lady", "video": "aaaaaaaaaaa"},
                    {"kind": "artist", "title": "Modjo"},
                    {"kind": "playlist", "title": "French House Classics", "playlist": "PLmineminemine"}]
        self.patch("ytm_search", search)
        found = al.deck_search("ytmusic", "french house")
        self.assertEqual([(i["kind"], i["title"], bool(i.get("mine"))) for i in found],
                         [("playlist", "French House Classics", True), ("song", "Lady", False),
                          ("playlist", "Best French House", False)])

    def test_sonos_gets_the_next_songs_not_the_whole_playlist(self):
        added = []
        def call(ip, service, action, args=None, timeout=2.5):
            if action == "AddURIToQueue":
                added.append(args["EnqueuedURI"])
                return {"FirstTrackNumberEnqueued": str(len(added))}
            return {}
        self.patch("sonos_call", call)
        songs = [{"uid": f"u{n}", "service": "applemusic", "id": str(100 + n)} for n in range(80)]
        room = {"ip": "192.168.1.10", "id": "RINCON_000E58BC46FC01400"}
        pushed = al.deck_sonos_push(room, songs, "13")
        self.assertEqual(pushed, ["u0"])                      # the first plays at once
        # The rest follow in the background, up to SONOS_AHEAD of them.
        al.deck_update(lambda d: d.update(now=songs[0], set=songs[1:], playing=True, pushed=pushed, pushedFrom=1,
                                          where={"kind": "sonos", "room": room["id"]}))
        self.patch("deck_where_room", lambda d: room)
        self.patch("sonos_apple_sn", lambda: "13")
        def call2(ip, service, action, args=None, timeout=2.5):
            if action == "GetPositionInfo":
                return {"Track": "1"}
            if action == "GetMediaInfo":
                return {"NrTracks": str(len(added))}
            return call(ip, service, action, args, timeout)
        self.patch("sonos_call", call2)
        al.DECK.with_name("deck-sonos.again").touch()
        al.deck_sonos_sync()
        d = al.deck_read()
        self.assertEqual(len(d["pushed"]), al.SONOS_AHEAD + 1)
        self.assertEqual(len(added), al.SONOS_AHEAD + 1)
        self.assertEqual(d["pushedFrom"], 1)                  # kept, so the watcher counts from the right place

    def test_next_in_a_room_jumps_within_its_queue(self):
        calls = []
        def call(ip, service, action, args=None, timeout=2.5):
            calls.append((action, (args or {}).get("Target")))
            return {"CurrentURI": "x-rincon-queue:RINCON_X#0"} if action == "GetMediaInfo" else {}
        self.patch("sonos_call", call)
        self.patch("deck_where_room", lambda d: {"ip": "192.168.1.10", "id": "RINCON_X", "name": "Quiet Room"})
        self.patch("sonos_apple_sn", lambda: "13")
        self.patch("sonos_now", lambda room: {"track": {}})
        self.patch("toast", lambda *a, **k: None)
        self.patch("deck_watch", lambda: None)
        synced = []
        self.patch("deck_sonos_soon", lambda: synced.append(1))
        a, b, c = ({"uid": u, "service": "applemusic", "id": str(n), "title": u, "artist": ""} for n, u in enumerate("abc"))
        deck = {**al.DECK_EMPTY, "now": a, "set": [b, c], "playing": True, "pushed": ["a", "b", "c"], "pushedFrom": 4}
        al.deck_start(deck)
        self.assertIn(("Seek", 5), calls)                     # b is track 5: straight there
        self.assertNotIn(("RemoveAllTracksFromQueue", None), calls)
        self.assertEqual((deck["now"]["uid"], synced), ("b", [1]))

    def test_sonos_queue_changes_only_what_differs(self):
        # Playing b (track 2 of a, b, c, d); the set is now c, x, d: c stays, d goes, x and d go on.
        self.assertEqual(al.deck_sonos_plan(["a", "b", "c", "d"], 1, 2, "b", ["c", "x", "d"]), (1, ["x", "d"]))
        self.assertEqual(al.deck_sonos_plan(["a", "b", "c"], 1, 2, "b", ["c", "e"]), (1, ["e"]))      # Auto-DJ added e
        self.assertEqual(al.deck_sonos_plan(["b", "c"], 5, 9, "b", ["c"]), (0, ["c"]))               # lost track: redo


class DeckStreamTests(TempCase):
    """Mixing services in a Sonos room: Apple Music songs from the room's
    queue, Beatport and YouTube Music songs played on the laptop and heard
    through the live stream."""

    def setUp(self):
        super().setUp()
        self.patch("DECK", self.tmp / "deck.json")
        self.patch("DECK_LOCK", self.tmp / "deck.lock")
        self.room = {"ip": "192.168.1.10", "id": "RINCON_X", "name": "Quiet Room"}
        self.calls, self.played, self.quieted, self.switches = [], [], [], []
        self.uri = "x-rincon-queue:RINCON_X#0"
        def call(ip, service, action, args=None, timeout=2.5):
            self.calls.append((action, dict(args or {})))
            return {"CurrentURI": self.uri} if action == "GetMediaInfo" else {}
        self.patch("sonos_call", call)
        self.patch("sonos_rooms", lambda refresh=False: [self.room])
        self.patch("sonos_apple_sn", lambda: "13")
        self.patch("sonos_now", lambda room: {"track": {}})
        self.patch("toast", lambda *a, **k: None)
        self.patch("deck_watch", lambda: None)
        self.patch("deck_sonos_soon", lambda: None)
        self.patch("laptop_track", lambda: None)
        self.patch("deck_stream_ensure", lambda wait=6: {"port": 8766, "token": "abc"})
        self.patch("deck_stream_route", lambda sink, back=None: None)
        self.patch("DECK_STREAM_MARK", self.tmp / "deck-stream-mark")
        self.patch("DECK_STREAM_CATCH", 0)
        self.patch("deck_stream_info", lambda: {"port": 8766, "token": "abc", "lag": 6.0})
        self.patch("lan_address", lambda: "192.168.1.5")
        self.patch("deck_play_laptop", lambda song, start_at=0: self.played.append(song["uid"]))
        self.patch("deck_quiet", lambda song: self.quieted.append(song["uid"]))
        self.patch("deck_can_quiet", lambda song: True)
        self.patch("media_command", lambda *a: "tab")
        real = al.deck_room_switch_soon
        def soon(d, to, after):
            self.switches.append((to, round(after, 1)))
            d["roomSwitch"] = {"to": to, "uid": (d.get("now") or {}).get("uid", ""), "at": 0}
        self.patch("deck_room_switch_soon", soon)
        self.real_switch_soon = real

    def song(self, uid, service):
        return {"uid": uid, "service": service, "id": uid, "title": uid, "artist": "", "video": uid}

    def deck(self, now, rest, **more):
        return {**al.DECK_EMPTY, "now": now, "set": rest, "playing": True,
                "where": {"kind": "sonos", "room": "RINCON_X"}, **more}

    def actions(self, name):
        return [args for action, args in self.calls if action == name]

    def test_a_queue_holds_only_the_run_of_apple_songs(self):
        a, b, y, c = self.song("a", "applemusic"), self.song("b", "applemusic"), self.song("y", "ytmusic"), self.song("c", "applemusic")
        deck = self.deck(None, [])
        self.assertEqual([s["uid"] for s in al.deck_queue_run(deck, [a, b, y, c])], ["a", "b"])
        self.assertTrue(al.deck_streams(deck, y) and not al.deck_streams(deck, a))
        # With the stream off, every song goes to the room as Apple Music (as before).
        self.assertFalse(al.deck_streams({**deck, "roomStream": False}, y))
        self.assertEqual(len(al.deck_queue_run({**deck, "roomStream": False}, [a, y, c])), 3)

    def test_a_streamed_song_plays_on_the_laptop_and_the_room_listens(self):
        y = self.song("y", "beatport")
        deck = self.deck(None, [y], playing=False)
        self.assertTrue(al.deck_start(deck))
        self.assertEqual(self.played, ["y"])
        uris = [args["CurrentURI"] for args in self.actions("SetAVTransportURI")]
        self.assertEqual(uris, ["x-rincon-mp3radio://192.168.1.5:8766/live/abc.mp3"])
        self.assertEqual(self.actions("RemoveAllTracksFromQueue"), [])     # the queue isn't touched
        self.assertIsNone(al.deck_queue_room(deck))                        # the Deck follows the laptop now

    def test_the_room_keeps_listening_from_one_streamed_song_to_the_next(self):
        self.uri = "x-rincon-mp3radio://192.168.1.5:8766/live/abc.mp3"
        y, z = self.song("y", "ytmusic"), self.song("z", "beatport")
        deck = self.deck(y, [z])
        self.assertTrue(al.deck_start(deck, natural=True))
        self.assertEqual((self.played, self.quieted), (["z"], ["y"]))     # another app: the last one stops
        self.assertEqual(self.actions("SetAVTransportURI"), [])

    def test_from_the_queue_to_a_streamed_song_the_laptop_starts_early(self):
        a, y = self.song("a", "applemusic"), self.song("y", "ytmusic")
        deck = self.deck(a, [y], pushed=["a"])
        self.assertTrue(al.deck_start(deck, room_after=4.2))
        self.assertEqual(self.played, ["y"])
        self.assertEqual(self.switches, [("live", 4.2)])                    # the room switches as its song ends
        self.assertTrue((self.tmp / "deck-stream-mark").exists())          # the room hears it from its start
        self.assertEqual(self.actions("SetAVTransportURI"), [])

    def test_a_streamed_song_ending_lets_the_room_finish_it_before_the_queue(self):
        self.uri = "x-rincon-mp3radio://192.168.1.5:8766/live/abc.mp3"
        y, a, b = self.song("y", "ytmusic"), self.song("a", "applemusic"), self.song("b", "applemusic")
        deck = self.deck(y, [a, b])
        self.assertTrue(al.deck_start(deck, natural=True))
        self.assertEqual(self.quieted, ["y"])
        self.assertEqual(self.switches, [("queue", 6.0 - al.DECK_STREAM_QUEUE_EARLY)])    # the measured lag
        self.assertEqual(self.actions("AddURIToQueue"), [])                 # not yet: the room is still playing y
        self.assertTrue(al.deck_switch_pending({**deck, "roomSwitch": {"at": time.time() + 3}}))

    def test_skipping_off_a_streamed_song_goes_to_the_queue_at_once(self):
        self.patch("deck_apple_id", lambda song: song["id"])
        self.uri = "x-rincon-mp3radio://192.168.1.5:8766/live/abc.mp3"
        y, a, z = self.song("y", "ytmusic"), self.song("a", "applemusic"), self.song("z", "ytmusic")
        deck = self.deck(y, [a, z])
        self.assertTrue(al.deck_start(deck))
        self.assertEqual(self.switches, [])
        queued = [args["EnqueuedURI"] for args in self.actions("AddURIToQueue")]
        self.assertEqual(len(queued), 1)                                      # a only: z streams after it
        self.assertEqual(deck["pushed"], ["a"])
        self.assertIn("y", self.quieted)

    def test_pausing_a_streamed_song_hushes_the_room_at_once(self):
        y = self.song("y", "ytmusic")
        deck = self.deck(y, [])
        al.deck_pause(deck)
        self.assertEqual(self.actions("SetGroupMute"), [{"InstanceID": 0, "DesiredMute": 1}])
        self.assertEqual(self.actions("Pause"), [])            # the room keeps listening; the laptop pauses

    def test_play_in_a_room_picked_while_paused_starts_the_decks_song(self):
        # The room's queue still has its own songs: Play mustn't just resume them.
        self.patch("deck_apple_id", lambda song: song["id"])
        a = self.song("a", "applemusic")
        deck = self.deck(a, [], playing=True, pushed=["old"], pushedFrom=13)
        al.deck_resume(deck)
        self.assertEqual(len(self.actions("AddURIToQueue")), 1)
        self.assertEqual(deck["pushed"], ["a"])

    def test_the_firewall_rule_for_the_stream(self):
        rules = self.tmp / "user.rules"
        rules.write_text("-A ufw-user-input -p tcp --dport 8765 -s 192.168.89.0/24 -j ACCEPT\n")
        self.patch("quiet_out", lambda *a, **k: "active\n")
        real = al.Path
        self.patch("Path", lambda p, *rest: rules if p == "/etc/ufw/user.rules" else real(p, *rest))
        self.assertTrue(al.ufw_allows(8765))
        self.assertFalse(al.ufw_allows(8766))
        self.patch("quiet_out", lambda *a, **k: "inactive\n")
        self.assertTrue(al.ufw_allows(8766))


class IsolationTests(TempCase):
    """Tests never touch the real Deck, settings or speakers' state."""

    def test_every_home_path_points_into_the_test_folder(self):
        for name, value in vars(al).items():
            if isinstance(value, Path) and value.is_absolute() and not value.is_relative_to(al.REPO):
                self.assertFalse(value.is_relative_to(REAL_HOME), name)
        al.deck_sonos_soon()                                # would start a real sync
        self.assertEqual(len(self.spawned), 1)


class MeasureTests(TempCase):
    """Tempo and key measured from a song's preview."""

    def test_tempo_is_the_mean_of_the_gaps_that_agree(self):
        beats = [i * 0.5 for i in range(20)]                       # 120 BPM
        beats[10] += 0.2                                            # one stray beat
        bpm, steady = al.beats_tempo(beats)
        self.assertAlmostEqual(bpm, 120, delta=0.3)
        self.assertGreater(steady, 0.85)
        self.assertEqual(al.beats_tempo([0, 0.5, 1]), (0.0, 0.0))  # too few beats

    def test_shaky_beat_keeps_the_key_but_not_the_tempo(self):
        self.patch("DECK_DETAILS", self.tmp / "deck-details.json")
        self.patch("DECK_DETAILS_LOCK", self.tmp / "deck-details.lock")
        self.patch("measure_ready", lambda: True)
        steady = {"service": "applemusic", "id": "1", "title": "A", "artist": "X"}
        shaky = {"service": "applemusic", "id": "2", "title": "B", "artist": "Y"}
        exact = {"service": "applemusic", "id": "3", "title": "C", "artist": "Z"}
        al.deck_details_note(exact, bpm=124, key="8A")             # from Beatport, before the mark
        got = {"1": {"bpm": 126, "steady": 0.95, "key": "3A"}, "2": {"bpm": 118, "steady": 0.6, "key": "4B"},
               "3": {"bpm": 99, "steady": 1.0, "key": "1A"}}
        self.patch("measure_song", lambda song: got[song["id"]])
        al.deck_details_measure([steady, shaky, exact])
        d = al.deck_details_read()
        self.assertEqual((d["am:1"]["bpm"], d["am:1"]["key"], d["am:1"]["measured"]), (126, "3A", 1))
        self.assertNotIn("bpm", d["am:2"])
        self.assertEqual(d["am:2"]["key"], "4B")
        self.assertEqual((d["am:3"]["bpm"], d["am:3"]["key"]), (124, "8A"))   # Beatport's stand

    def test_the_web_never_overrides_a_measured_key(self):
        self.patch("DECK_DETAILS", self.tmp / "deck-details.json")
        self.patch("DECK_DETAILS_LOCK", self.tmp / "deck-details.lock")
        song = {"service": "applemusic", "id": "1", "title": "A", "artist": "X"}
        al.deck_details_note(song, measured=1, key="3A")
        self.patch("grok_web_json", lambda prompt, **kw: {"s": [{"bpm": 125, "key": "C major"}]})
        al.deck_details_web([song])
        d = al.deck_details_read()["am:1"]
        self.assertEqual((d["bpm"], d["key"], d["web"]), (125, "3A", True))

    def test_preview_must_come_from_apple(self):
        self.patch("am_lookup", lambda params: [{"previewUrl": "https://evil.example/a.m4a"}])
        self.assertEqual(al.preview_url({"service": "applemusic", "id": "1", "title": "A"}), "")
        self.patch("am_lookup", lambda params: [{"trackName": "A", "previewUrl": "https://audio-ssl.itunes.apple.com/x.m4a"}])
        self.assertTrue(al.preview_url({"service": "ytmusic", "title": "A (Remastered)", "artist": "X"}).startswith("https://audio"))


class AgentTests(TempCase):
    """Which agent answers: a tier per job, the agent's own program with its
    tools locked down, and every question noted and logged."""

    def setUp(self):
        super().setUp()
        self.patch("agent_ask", REAL_AGENT_ASK)            # the real one, with its program stood in for
        self.patch("AGENTS_FILE", self.tmp / "agents.json")
        self.patch("AGENT_LOG", self.tmp / "agent-calls.jsonl")
        self.patch("AGENT_NOW", self.tmp / "agents-now.json")
        self.patch("STATE", self.tmp / "afterlight" / "state.json")
        self.have = {"grok", "claude", "codex"}
        self.patch("shutil", mock.Mock(which=lambda name: f"/bin/{name}" if name in self.have else None))

    def test_record_sums_each_agent_and_tier(self):
        log = self.tmp / "agent-calls.jsonl"
        rows = [{"agent": "claude", "tier": "fast", "seconds": 2, "ok": True},
                {"agent": "claude", "tier": "fast", "seconds": 4, "ok": False},
                {"agent": "nobody", "tier": "fast", "seconds": 9, "ok": True}]
        log.write_text("\n".join(json.dumps(r) for r in rows) + "\nnot json\n")
        self.assertEqual(al.agent_record(), {"claude": {"fast": {"n": 2, "seconds": 3.0, "ok": 0.5, "last": 0, "fit": "unreliable"}}})

    def log(self, *rows):
        (self.tmp / "agent-calls.jsonl").write_text("".join(
            json.dumps({"at": int(time.time()), "agent": a, "tier": t, "seconds": secs, "ok": ok}) + "\n"
            for a, t, secs, ok in rows))

    def test_too_slow_or_unreliable_needs_two_questions(self):
        self.log(("grok", "scout", 200, True), ("grok", "scout", 180, True), ("codex", "scout", 30, True),
                 ("codex", "fast", 5, False), ("codex", "fast", 6, False), ("codex", "fast", 4, True))
        record = al.agent_record()
        self.assertEqual(record["grok"]["scout"]["fit"], "slow")
        self.assertEqual(record["codex"]["scout"]["fit"], "ok")          # one question isn't enough to say
        self.assertEqual(record["codex"]["fast"]["fit"], "unreliable")

    def test_unchosen_jobs_go_to_the_quickest_fit_agent(self):
        self.log(("grok", "fast", 15, True), ("grok", "fast", 16, True), ("claude", "fast", 5, True),
                 ("claude", "fast", 6, True), ("codex", "fast", 2, False), ("codex", "fast", 3, False))
        self.assertEqual(al.agent_choices()["fast"], "claude")
        al.agents_set("fast", "grok")                                   # your choice stands
        self.assertEqual(al.agent_choices()["fast"], "grok")
        self.assertEqual(al.agent_choices()["judge"], "grok")           # no record: Grok first

    def test_mix_leaves_out_a_slow_scout_until_a_week_passes(self):
        self.log(("grok", "scout", 200, True), ("grok", "scout", 180, True))
        al.agents_set("scout", "mix")
        self.assertEqual(al.scout_agents(3), ["claude", "codex", "claude"])
        with mock.patch.object(al.time, "time", return_value=time.time() + 8 * 86400):
            self.assertIn("grok", al.scout_agents(3))

    def test_tiers_default_to_grok_and_keep_your_choice(self):
        self.assertEqual(al.agent_choices(), {"fast": "grok", "scout": "grok", "judge": "grok"})
        al.agents_set("scout", "claude")
        self.assertEqual(al.agent_for("scout"), "claude")
        self.assertEqual(al.agents_state()["models"]["scout"], "claude-sonnet-5-5")
        self.have.discard("claude")             # uninstalled: back to Grok, not a broken pick
        self.assertEqual(al.agent_for("scout"), "grok")
        with self.assertRaises(SystemExit):
            al.agents_set("scout", "claude")

    def test_each_agent_runs_with_its_tools_locked_down(self):
        out = self.tmp / "answer.txt"
        grok = al.agent_command("grok", "grok-4.7-build-fast", "low", "q", False, 1, out)
        self.assertIn("--deny", grok)
        self.assertEqual(grok[grok.index("--tools") + 1], "")
        claude = al.agent_command("claude", "claude-haiku-5-5", "low", "q", False, 1, out)
        self.assertIn("--tools=", claude)
        self.assertIn("--strict-mcp-config", claude)          # no MCP servers (Sonos stays with Grok)
        web = al.agent_command("claude", "claude-haiku-5-5", "low", "q", True, 8, out)
        self.assertIn("--tools=WebSearch,WebFetch", web)
        codex = al.agent_command("codex", "gpt-6-luna", "low", "q", False, 1, out)
        self.assertEqual(codex[codex.index("-s") + 1], "read-only")
        self.assertNotIn('web_search="live"', codex)
        self.assertIn('web_search="live"', al.agent_command("codex", "gpt-6-luna", "low", "q", True, 1, out))

    def test_a_question_is_noted_while_it_runs_and_logged_after(self):
        seen = []
        def answer(cmd, **kw):
            seen.append([i["agent"] for i in al.agent_working()])
            return mock.Mock(stdout='Sure: {"songs": [{"t": "Finally"}]} hope that helps')
        self.patch("subprocess", mock.Mock(run=answer, SubprocessError=Exception, DEVNULL=-3))
        value = al.agent_ask("q", tier="fast", job="autodj", agent="claude")
        self.assertEqual(value, {"songs": [{"t": "Finally"}]})
        self.assertEqual(seen, [["claude"]])                  # working while it ran
        self.assertEqual(al.agent_working(), [])               # and not after
        logged = json.loads(al.AGENT_LOG.read_text().splitlines()[-1])
        self.assertEqual((logged["job"], logged["agent"], logged["model"], logged["ok"]),
                         ("autodj", "claude", "claude-haiku-5-5", True))

    def test_a_bad_answer_is_none_and_logged_as_failed(self):
        self.patch("subprocess", mock.Mock(run=lambda cmd, **kw: mock.Mock(stdout="I can't help with that"),
                                           SubprocessError=Exception, DEVNULL=-3))
        self.assertIsNone(al.agent_ask("q", agent="grok"))
        self.assertFalse(json.loads(al.AGENT_LOG.read_text().splitlines()[-1])["ok"])
        self.have.clear()
        self.assertIsNone(al.agent_ask("q"))                   # no agent at all


class DeckAndPlayerTabTests(TempCase):
    """The Deck's room and Baseline's Sonos room (the Player tab, the volume
    keys) are the same room, whichever one you change."""

    def setUp(self):
        super().setUp()
        for name, value in {"DECK": self.tmp / "deck.json", "DECK_LOCK": self.tmp / "deck.lock",
                            "SONOS_TARGET": self.tmp / "sonos-target"}.items():
            self.patch(name, value)
        self.rooms = al.sonos_parse_groups(GROUPED)
        self.patch("sonos_rooms", lambda refresh=False: self.rooms)
        self.patch("sonos_call", lambda *a, **k: {})
        self.patch("sonos_now", lambda room: {"playing": False, "track": {"title": "", "artist": "", "art": ""}})
        self.patch("toast", lambda *a, **k: None)
        self.patch("where_toast", lambda: None)
        self.saved = []
        self.patch("save", lambda settings: self.saved.append(copy.deepcopy(settings)))
        self.settings = {"sonos": {"room": "", "on": False}}

    def test_picking_a_room_in_the_deck_picks_it_in_baseline(self):
        al.deck_command(self.settings, ["where", K])
        self.assertEqual(self.settings["sonos"], {"room": K, "on": True})
        self.assertEqual((self.tmp / "sonos-target").read_text().strip(), K)
        al.deck_command(self.settings, ["where", "laptop"])
        self.assertFalse(self.settings["sonos"]["on"])
        self.assertFalse((self.tmp / "sonos-target").exists())

    def test_picking_a_room_in_baseline_moves_the_deck(self):
        al.sonos_use(self.settings, Q)
        self.assertEqual(al.deck_read()["where"], {"kind": "sonos", "room": Q})
        al.deck_follow("")
        self.assertEqual(al.deck_read()["where"], {"kind": "laptop"})

    def test_the_same_room_changes_nothing(self):
        al.deck_command(self.settings, ["where", K])
        count = len(self.saved)
        al.deck_command(self.settings, ["where", K])
        self.assertEqual(len(self.saved), count)


if __name__ == "__main__":
    unittest.main()


# ---------------------------------------------------------------- your looks, apps, built-in pictures

class LookPlaceTests(TempCase):
    """Built-in looks live in the repo and are read-only; yours live outside it."""

    def setUp(self):
        super().setUp()
        self.builtin = self.tmp / "repo-looks"
        self.mine = self.tmp / "mine"
        for folder, name, order in ((self.builtin, "rose", 1), (self.mine, "mine-one", 501)):
            (folder / name).mkdir(parents=True)
            (folder / name / "look.json").write_text(json.dumps({"name": name.title(), "order": order}))
            (folder / name / "colors.toml").write_text(palette_text())
        self.patch("LOOKS_DIR", self.builtin)
        self.patch("MINE_DIR", self.mine)
        self.patch("HOME", self.tmp)

    def test_order_builtins_then_yours(self):
        self.assertEqual(al.look_ids(), ["afterlight", "rose", "mine-one"])

    def test_builtin_flag(self):
        self.assertTrue(al.look_info("afterlight")["builtin"])
        self.assertTrue(al.look_info("rose")["builtin"])
        self.assertFalse(al.look_info("mine-one")["builtin"])
        self.assertEqual(al.look_info("mine-one")["dir"], self.mine / "mine-one")

    def test_builtins_cannot_be_saved_over_or_deleted(self):
        for look in ("afterlight", "rose"):
            with self.assertRaises(SystemExit):
                al.save_look({"look": "afterlight"}, {"id": look, "name": "X", "colours": GOOD_SEED})
            with self.assertRaises(SystemExit):
                al.delete_look({"look": "afterlight"}, look)


class BackupCommandTests(TempCase):

    def test_no_command_does_nothing(self):
        with mock.patch.object(al, "load", return_value={"backup": {"command": ""}}), \
                mock.patch.object(al.subprocess, "Popen") as popen:
            self.assertFalse(al.looks_backup("x"))
            popen.assert_not_called()

    def test_runs_the_command_with_the_reason(self):
        with mock.patch.object(al, "load", return_value={"backup": {"command": "sync.sh"}}), \
                mock.patch.object(al.subprocess, "Popen") as popen:
            self.assertTrue(al.looks_backup("Look: Test"))
            args, kwargs = popen.call_args
            self.assertEqual(args[0], ["bash", "-c", "sync.sh"])
            self.assertEqual(kwargs["env"]["BASELINE_BACKUP_REASON"], "Look: Test")


class AppTests(TempCase):

    def test_defaults_are_t3_and_grok(self):
        text = al.apps_lua_text({})
        self.assertIn('o.window({ class = "^com[.]t3tools[.]T3Code$" }, { workspace = "3" })', text)
        self.assertIn('o.window({ class = "^grok-bot$" }, { workspace = "4" })', text)
        self.assertIn('o.launch_on_start("grok-bot")', text)

    def test_none_writes_no_rules(self):
        text = al.apps_lua_text({"apps": {"coding": "none", "chat": "none"}})
        self.assertNotIn("o.window", text)
        self.assertNotIn("o.launch_on_start", text)

    def test_custom_app_is_quoted_safely(self):
        settings = {"apps": {"coding": "custom", "custom": {"coding": {
            "name": "Herdr", "class": '^herdr"$', "launch": 'herdr --x "y"'}}}}
        text = al.apps_lua_text(settings)
        self.assertIn('o.window({ class = "^herdr\\"$" }, { workspace = "3" })', text)
        self.assertIn('o.launch_on_start("herdr --x \\"y\\"")', text)

    def test_unknown_choice_falls_back(self):
        self.assertEqual(al.app_chosen({"apps": {"chat": "nope"}}, "chat"), "grok")

    def test_write_apps_only_when_changed(self):
        self.patch("APPS_LUA", self.tmp / "baseline_apps.lua")
        self.assertTrue(al.write_apps({}))
        self.assertFalse(al.write_apps({}))


class BuiltinPictureTests(TempCase):

    def setUp(self):
        super().setUp()
        self.looks = self.tmp / "looks"
        (self.looks / "rose").mkdir(parents=True)
        (self.looks / "rose" / "look.json").write_text("{}")
        (self.looks / "rose" / "colors.toml").write_text(palette_text())
        pictures = [dict(wallhaven_picture(1), file="1-alley.jpg"),
                    dict(wallhaven_picture(2), file="2-stock.jpg", source="https://www.istockphoto.com/x"),
                    dict(wallhaven_picture(3), file="../escape.jpg")]
        (self.looks / "rose" / "pictures.json").write_text(json.dumps(pictures))
        self.patch("LOOKS_DIR", self.looks)
        self.patch("MINE_DIR", self.tmp / "mine")
        self.patch("HOME", self.tmp)

    def test_fetches_only_shareable_pictures_with_safe_names(self):
        fetched = []

        def fake_fetch(url, target):
            fetched.append(target)
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(b"x")
            return True

        with mock.patch.object(al, "fetch_picture", side_effect=fake_fetch):
            self.assertEqual(al.look_pictures("rose"), (1, 0))
        self.assertEqual(fetched, [self.looks / "rose/backgrounds/1-alley.jpg"])
        # Stock pictures are never fetched, so they don't count as missing.
        self.assertEqual(al.look_pictures_missing(), [])


# ---------------------------------------------------------------- Sonos on the home network

ZONES = """<ZoneGroupState><ZoneGroups>
<ZoneGroup Coordinator="RINCON_A" ID="g1">
  <ZoneGroupMember UUID="RINCON_A" Location="http://192.168.1.20:1400/xml/device_description.xml" ZoneName="Kitchen - Sonos"/>
  <ZoneGroupMember UUID="RINCON_B" Location="http://192.168.1.21:1400/xml/device_description.xml" ZoneName="Lounge  (Arc) - Sonos">
    <Satellite UUID="RINCON_S" Location="http://192.168.1.22:1400/x" ZoneName="Lounge (Arc) - Sonos" Invisible="1"/>
  </ZoneGroupMember>
</ZoneGroup>
<ZoneGroup Coordinator="RINCON_C" ID="g2">
  <ZoneGroupMember UUID="RINCON_C" Location="http://192.168.1.30:1400/x" ZoneName="Quiet Room"/>
  <ZoneGroupMember UUID="RINCON_D" Location="http://192.168.1.31:1400/x" ZoneName="Quiet Room" Invisible="1"/>
</ZoneGroup>
<ZoneGroup Coordinator="RINCON_X" ID="g3">
  <ZoneGroupMember UUID="RINCON_X" Location="http://8.8.8.8:1400/x" ZoneName="Somewhere else"/>
</ZoneGroup>
</ZoneGroups></ZoneGroupState>"""


class SonosTests(TempCase):

    def test_rooms_from_groups(self):
        rooms = al.sonos_parse_groups(ZONES)
        self.assertEqual([(r["name"], r["ip"], r["id"]) for r in rooms],
                         [("Kitchen + Lounge (Arc)", "192.168.1.20", "RINCON_A"), ("Quiet Room", "192.168.1.30", "RINCON_C")])

    def test_escaped_reply_parses_too(self):
        import html
        self.assertEqual(len(al.sonos_parse_groups(html.escape(ZONES))), 2)

    def test_only_local_addresses(self):
        for ip in ("192.168.1.5", "10.0.0.7", "172.16.4.2"):
            self.assertTrue(al.sonos_private(ip), ip)
        for ip in ("8.8.8.8", "127.0.0.1", "example.com", ""):
            self.assertFalse(al.sonos_private(ip), ip)
        with mock.patch("urllib.request.urlopen") as urlopen:
            self.assertIsNone(al.sonos_call("8.8.8.8", "AVTransport", "Play"))
            urlopen.assert_not_called()

    def test_track_metadata(self):
        didl = ('<DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" '
                'xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/"><item><dc:title>Second Hand News</dc:title>'
                '<dc:creator>Fleetwood Mac</dc:creator><upnp:album>Rumours</upnp:album>'
                '<upnp:albumArtURI>/getaa?s=1&amp;u=x</upnp:albumArtURI></item></DIDL-Lite>')
        track = al.sonos_parse_track(didl, "x-sonos-spotify:abc")
        self.assertEqual((track["title"], track["artist"], track["album"], track["art"]),
                         ("Second Hand News", "Fleetwood Mac", "Rumours", "/getaa?s=1&u=x"))
        self.assertEqual(al.sonos_parse_track("", "x-sonos-htastream:RINCON_A:spdif")["title"], "TV")
        self.assertEqual(al.sonos_parse_track("", "x-rincon-stream:RINCON_A")["title"], "Line-in")
        self.assertEqual(al.sonos_parse_track("not xml", "")["title"], "")

    def test_radio_stream_content(self):
        didl = ('<DIDL-Lite xmlns:r="urn:schemas-rinconnetworks-com:metadata-1-0/" xmlns:dc="http://purl.org/dc/elements/1.1/">'
                '<item><dc:title>x-sonosapi-stream</dc:title><r:streamContent>Bonobo - Kerala</r:streamContent></item></DIDL-Lite>')
        track = al.sonos_parse_track(didl, "x-sonosapi-stream:s1")
        self.assertEqual((track["artist"], track["title"]), ("Bonobo", "Kerala"))

    def test_art_only_from_the_speaker(self):
        self.patch("SONOS_ART", self.tmp / "art")
        with mock.patch("urllib.request.urlopen") as urlopen:
            self.assertEqual(al.sonos_art("192.168.1.20", "https://example.com/cover.jpg"), "")
            self.assertEqual(al.sonos_art("8.8.8.8", "/getaa?x"), "")
            urlopen.assert_not_called()

    def test_volume_values_are_checked(self):
        rooms = [{"id": "RINCON_A", "name": "Kitchen", "ip": "192.168.1.20", "members": ["Kitchen"]}]
        settings = {"sonos": {"on": True, "room": "RINCON_A"}}
        with mock.patch.object(al, "sonos_rooms", return_value=rooms), \
                mock.patch.object(al, "sonos_call", return_value={"NewVolume": "30"}) as call:
            for bad in ("loud", "1000", "+", "5; rm"):
                with self.assertRaises(SystemExit):
                    al.sonos_volume(settings, bad)
            al.sonos_volume(settings, "150")
            self.assertEqual(call.call_args[0][3]["DesiredVolume"], 100)
            al.sonos_volume(settings, "raise")
            self.assertEqual(call.call_args[0][3]["Adjustment"], al.SONOS_STEP)

    def test_volume_keys_follow_the_target(self):
        """baseline-volume: Sonos while picked, the laptop otherwise."""
        bin_dir = self.tmp / "bin"
        (self.tmp / ".local/bin").mkdir(parents=True)
        bin_dir.mkdir()
        log = self.tmp / "calls"
        for name, where in (("afterlight", self.tmp / ".local/bin"), ("omarchy-audio-output-volume", bin_dir)):
            tool = where / name
            tool.write_text(f'#!/bin/bash\necho "{name} $*" >> "{log}"\n')
            tool.chmod(0o755)
        env = {"HOME": str(self.tmp), "PATH": f"{bin_dir}:/usr/bin:/bin", "XDG_STATE_HOME": str(self.tmp / "state")}
        script = str(ROOT / "system/bin/baseline-volume")
        import subprocess
        subprocess.run([script, "raise"], env=env, check=True)
        target = self.tmp / "state/afterlight/sonos-target"
        target.parent.mkdir(parents=True)
        target.write_text("RINCON_A\n")
        subprocess.run([script, "-1"], env=env, check=True)
        subprocess.run([script, "mute-toggle"], env=env, check=True)
        self.assertEqual(log.read_text().splitlines(), [
            "omarchy-audio-output-volume raise", "afterlight sonos volume -1 --osd",
            "afterlight sonos volume mute-toggle --osd"])


    def test_media_keys_drive_the_deck_while_it_plays(self):
        """baseline-media: the Deck while playing or paused by you, Omarchy otherwise."""
        bin_dir = self.tmp / "bin"
        (self.tmp / ".local/bin").mkdir(parents=True)
        bin_dir.mkdir()
        log = self.tmp / "calls"
        for name, where in (("afterlight", self.tmp / ".local/bin"), ("omarchy-shell", bin_dir)):
            tool = where / name
            tool.write_text(f'#!/bin/bash\necho "{name} $*" >> "{log}"\n')
            tool.chmod(0o755)
        env = {"HOME": str(self.tmp), "PATH": f"{bin_dir}:/usr/bin:/bin", "XDG_STATE_HOME": str(self.tmp / "state")}
        script = str(ROOT / "system/bin/baseline-media")
        import subprocess
        deck = self.tmp / "state/afterlight/deck.json"
        subprocess.run([script, "next"], env=env, check=True)                       # no Deck yet
        deck.parent.mkdir(parents=True)
        deck.write_text(json.dumps({"playing": True, "now": {"uid": "a"}}))
        subprocess.run([script, "playPause"], env=env, check=True)
        subprocess.run([script, "previous"], env=env, check=True)
        deck.write_text(json.dumps({"playing": False, "paused": True, "now": {"uid": "a"}}))
        subprocess.run([script, "playPause"], env=env, check=True)
        deck.write_text(json.dumps({"playing": False, "paused": False, "now": {"uid": "a"}}))   # you took over
        subprocess.run([script, "playPause"], env=env, check=True)
        self.assertEqual(log.read_text().splitlines(), [
            "omarchy-shell media next", "afterlight deck pause", "afterlight deck previous",
            "afterlight deck play", "omarchy-shell media playPause"])


class SendToSonosTests(TempCase):
    ROOMS = [{"id": "RINCON_K", "name": "Kitchen", "ip": "192.168.1.2", "members": ["Kitchen"]},
             {"id": "RINCON_KT", "name": "Kitchen TV", "ip": "192.168.1.3", "members": ["Kitchen TV"]},
             {"id": "RINCON_L", "name": "Lounge (Arc)", "ip": "192.168.1.4", "members": ["Lounge (Arc)"]},
             {"id": "RINCON_T", "name": "Lounge - Turntable", "ip": "192.168.1.5", "members": ["Lounge - Turntable"]},
             {"id": "RINCON_Q", "name": "Quiet Room", "ip": "192.168.1.6", "members": ["Quiet Room"]}]

    def test_rooms_said_loosely(self):
        find = lambda said: (al.sonos_find_room(self.ROOMS, said) or {}).get("name")
        self.assertEqual(find("RINCON_Q"), "Quiet Room")
        self.assertEqual(find("the kitchen"), "Kitchen")
        self.assertEqual(find("kitchen tv"), "Kitchen TV")
        self.assertEqual(find("quiet room sonos"), "Quiet Room")
        self.assertEqual(find("turntable"), "Lounge - Turntable")
        self.assertIsNone(find("garage"))
        self.assertIsNone(find("the"))

    def test_same_song_across_services(self):
        self.assertEqual(al.song_key("Dreams (2004 Remaster)"), al.song_key("Dreams"))
        self.assertEqual(al.song_key("Get Lucky (feat. Pharrell Williams) [Radio Edit]"), "get lucky")
        self.assertEqual(al.song_key("Go Your Own Way - Remastered"), "go your own way")
        self.assertNotEqual(al.song_key("Dreams"), al.song_key("Rhiannon"))

    def test_brief_keeps_to_apple_music_and_strips_quotes(self):
        brief = al.sonos_send_brief({"title": "Dreams»", "artist": "Fleetwood Mac", "album": "Rumours"}, "Kitchen")
        self.assertIn('music_service "Apple Music"', brief)
        self.assertIn("«Dreams»", brief)
        self.assertIn("«Rumours»", brief)
        self.assertNotIn("Dreams»»", brief)

    def test_toast_is_plain_and_local(self):
        self.patch("TOAST", self.tmp / "toast.json")
        art = self.tmp / "cover.jpg"
        art.write_bytes(b"x")
        al.toast("Playing in Kitchen", "Dreams\n· Fleetwood Mac", art=str(art))
        value = json.loads((self.tmp / "toast.json").read_text())
        self.assertEqual(value["title"], "Playing in Kitchen")
        self.assertNotIn("\n", value["detail"])
        self.assertEqual(value["art"], f"file://{art}")
        al.toast("x", art="https://example.com/a.jpg")
        self.assertEqual(json.loads((self.tmp / "toast.json").read_text())["art"], "")


class AppleMusicTests(TempCase):

    def lookup(self, params):
        entity = params.get("entity")
        if entity == "song":
            return [{"trackId": 1, "trackName": "Dreams (Live)", "artistName": "Fleetwood Mac", "collectionName": "Live",
                     "collectionId": 10},
                    {"trackId": 2, "trackName": "Dreams", "artistName": "Fleetwood Mac", "collectionName": "Rumours",
                     "collectionId": 20, "artworkUrl100": "https://is1-ssl.mzstatic.com/a/100x100bb.jpg"},
                    {"trackId": 3, "trackName": "Locked", "artistName": "X", "isStreamable": False}]
        if entity == "album":
            return [{"collectionId": 30, "collectionName": "Dreams - Single", "artistName": "Fleetwood Mac Tribute"},
                    {"collectionId": 20, "collectionName": "Rumours", "artistName": "Fleetwood Mac"}]
        return [{"artistId": 99, "artistName": "Fleetwood Mac", "primaryGenreName": "Rock"}]

    def test_search_ranks_what_was_said(self):
        self.patch("am_lookup", self.lookup)
        songs = al.am_search("fleetwood mac dreams")
        self.assertEqual((songs[0]["kind"], songs[0]["id"], songs[0]["album"]), ("song", "2", "20"))
        self.assertEqual(songs[0]["thumb"], "https://is1-ssl.mzstatic.com/a/300x300bb.jpg")
        self.assertNotIn("3", [i["id"] for i in songs if i["kind"] == "song"])     # not streamable
        self.assertEqual(al.am_search("rumours fleetwood mac")[0]["id"], "20")
        self.assertEqual(al.am_search("fleetwood mac")[0]["kind"], "artist")

    def test_play_checks_ids_and_queues_the_album(self):
        sent = []
        self.patch("load_state", lambda: {})
        self.patch("save_state", lambda s: None)
        self.patch("run", lambda *a, **k: None)
        self.patch("am_bridge", lambda op, timeout=8: sent.append(op) or {"ok": True})
        with mock.patch("builtins.print"):
            al.am_play({"kind": "song", "id": "2", "album": "20", "title": "Dreams"})
        self.assertEqual(sent[-1], {"action": "queue", "kind": "album", "id": "20", "start": "2"})
        with self.assertRaises(SystemExit):
            al.am_play({"kind": "song", "id": "2; rm -rf"})
        with self.assertRaises(SystemExit):
            al.am_play({"kind": "station", "id": "2"})

    def test_said_service_routes(self):
        for words in ("play rumours on apple music", "play dreams from itunes", "apple music daft punk"):
            self.assertTrue(al.AM_SAID.search(words), words)
        self.assertFalse(al.AM_SAID.search("play big apple"))

    def test_music_service_setting_is_checked(self):
        settings = copy.deepcopy(al.DEFAULTS)
        al.set_path(settings, "music.service", "applemusic")
        self.assertEqual(settings["music"]["service"], "applemusic")
        with self.assertRaises(SystemExit):
            al.set_path(settings, "music.service", "spotify")


class SuggestionTests(TempCase):

    def song(self, title, by, kind="song"):
        return {"kind": kind, "title": title, "subtitle": f"{by} • Some Album", "id": "1"}

    def test_clear_matches_play(self):
        self.assertTrue(al.confident(self.song("Dreams", "Fleetwood Mac"), "dreams by fleetwood mac"))
        self.assertTrue(al.confident(self.song("Get Lucky", "Daft Punk"), "get lucky"))
        self.assertTrue(al.confident(self.song("Rumours", "Fleetwood Mac", "album"), "rumours fleetwood mac"))
        self.assertTrue(al.confident({"kind": "artist", "title": "Bonobo", "subtitle": "Electronic"}, "bonobo"))

    def test_unclear_ones_become_suggestions(self):
        self.assertFalse(al.confident(self.song("Castle on the Hill", "Ed Sheeran"), "sunset playlist for the kitchen"))
        self.assertFalse(al.confident({"kind": "album", "title": "Chill Music", "subtitle": "Various"}, "chill music"))
        self.assertFalse(al.confident(self.song("Dreams", "The Cranberries"), "dreams fleetwood mac live in boston"))
        self.assertFalse(al.confident({"kind": "artist", "title": "Daft Punk", "subtitle": ""}, "daft punk remixes"))

    def test_suggest_plays_nothing_and_asks_grok(self):
        self.patch("SUGGEST", self.tmp / "suggest.json")
        self.patch("run", lambda *a, **k: None)
        self.patch("toast", lambda *a, **k: None)
        started = []
        with mock.patch("shutil.which", return_value="/usr/bin/grok"), \
                mock.patch("subprocess.Popen", side_effect=lambda argv, **k: started.append(argv)), \
                mock.patch("builtins.print"):
            al.suggest("applemusic", "sunset playlist", [self.song("Sunset Lover", "Petit Biscuit")])
        value = json.loads((self.tmp / "suggest.json").read_text())
        self.assertEqual((value["service"], value["query"], value["pending"]), ("applemusic", "sunset playlist", True))
        self.assertEqual(started[0][-4:], ["music", "grok", "applemusic", "sunset playlist"])

    def test_grok_ideas_parse_and_run_without_tools(self):
        self.patch("agent_ask", REAL_AGENT_ASK)            # the real one, with its program stood in for
        reply = 'Sure:\n{"songs":[{"t":"Lovely Day","a":"Bill Withers","w":"Sunny classic"},{"x":1}],"q":["golden hour",3]}'
        with mock.patch("subprocess.run", return_value=mock.Mock(stdout=reply)) as runner:
            self.patch("STATE", self.tmp / "state.json")
            ideas = al.grok_ideas("something for the kitchen")
        argv = runner.call_args[0][0]
        self.assertEqual(argv[argv.index("-m") + 1], al.GROK_FAST)
        self.assertEqual(argv[argv.index("--tools") + 1], "")
        self.assertEqual(ideas, {"songs": [{"t": "Lovely Day", "a": "Bill Withers", "w": "Sunny classic", "e": 0, "c": "", "b": 0, "k": ""}], "q": ["golden hour"]})
        with mock.patch("subprocess.run", return_value=mock.Mock(stdout="no json here")):
            self.assertEqual(al.grok_ideas("x"), {"songs": [], "q": []})

    def test_a_newer_search_wins(self):
        self.patch("SUGGEST", self.tmp / "suggest.json")
        al.suggest_write({"service": "applemusic", "query": "newer", "close": [], "grok": [], "try": [], "pending": True})
        self.patch("grok_ideas", lambda q, **kw: {"songs": [], "q": ["x"]})
        al.grok_suggest("applemusic", "older")
        self.assertTrue(json.loads((self.tmp / "suggest.json").read_text())["pending"])


class GuestStatusTest(unittest.TestCase):
    def test_first_in_set_is_up_next(self):
        deck = {"requests": [], "now": {"rid": "a"}, "set": [{"rid": "b"}, {"rid": "c"}], "played": []}
        self.assertEqual(al.deck_guest_status(deck, {"rid": "a"}, [0, 200])["state"], "playing")
        first = al.deck_guest_status(deck, {"rid": "b"}, [60, 260])
        second = al.deck_guest_status(deck, {"rid": "c"}, [60, 260])
        self.assertTrue(first.get("next"))
        self.assertEqual(second["state"], "set")
        self.assertNotIn("next", second)


class DedicationFilterTest(unittest.TestCase):
    def test_friendly_notes_pass(self):
        for note in ["For Jess's birthday!", "Scunthorpe massive", "For Dick and Jane", "Cocktails for B and Q", "assassin's creed"]:
            self.assertTrue(al.note_friendly(note), note)

    def test_swearing_is_caught_through_disguises(self):
        for note in ["sh1t song", "f u c k this", "fuuuck yeah", "what the fuckkk", "you @sshole"]:
            self.assertFalse(al.note_friendly(note), note)


class RecapTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.patches = [mock.patch.object(al, "DECK_GUESTS_PEOPLE", Path(self.tmp.name) / "people.json"),
                        mock.patch.object(al, "DECK_GUESTS_ASKS", Path(self.tmp.name) / "asks.json")]
        for p in self.patches:
            p.start()
            self.addCleanup(p.stop)

    def test_recap_counts_the_night(self):
        now = time.time()
        deck = {"guests": {"since": now - 3600}, "now": {"uid": "c", "title": "C", "thumb": "https://x/c"},
                "played": [{"uid": "a", "title": "A", "playedAt": now - 1800, "rid": "r1", "note": "hi", "thumb": "https://x/a"},
                           {"uid": "b", "title": "B", "playedAt": now - 900, "thumb": "https://x/a"}],
                "votes": {"b": {"g1": 1, "g2": 1}, "a": {"g1": 1}}}
        r = al.deck_recap(deck)
        self.assertEqual((r["songs"], r["requests"], r["dedications"]), (3, 1, 1))
        self.assertEqual(r["loved"]["title"], "B")
        self.assertEqual(r["loved"]["up"], 2)
        self.assertEqual(r["covers"], ["https://x/c", "https://x/a"])
        self.assertGreaterEqual(r["minutes"], 29)

    def test_closing_once_when_last_call_runs_out(self):
        state = {"lastCall": int(time.time()) - 5, "closedAt": 0}
        with mock.patch.object(al, "deck_update", side_effect=lambda f: f(state)), \
             mock.patch.object(al.subprocess, "Popen") as popen:
            self.assertTrue(al.deck_closing(dict(state)))
            self.assertFalse(al.deck_closing(dict(state)))
        self.assertEqual(popen.call_count, 1)
        self.assertEqual(popen.call_args[0][0][-3:], ["voice", "call", "0"])
        self.assertTrue(state["recapAt"])


class AutoDJMixTest(unittest.TestCase):
    def test_keeps_near_tempo_and_orders_into_key(self):
        anchor = {"service": "applemusic", "id": "1"}
        found = [({"title": "Far"}, {"b": 160, "k": "8A", "e": 6}),
                 ({"title": "Clash"}, {"b": 121, "k": "3B", "e": 6}),
                 ({"title": "Fits"}, {"b": 119, "k": "8A", "e": 6}),
                 ({"title": "Next"}, {"b": 122, "k": "9A", "e": 7})]
        with mock.patch.object(al, "deck_details_read", return_value={"am:1": {"bpm": 120, "key": "8A", "energy": 6}}):
            picked = al.deck_mix_pick(found, anchor, 3)
        self.assertEqual([s["title"] for s in picked], ["Fits", "Next", "Clash"])      # Far is out of tempo

    def test_building_energy_avoids_a_drop(self):
        anchor = {"service": "applemusic", "id": "1"}
        found = [({"title": "Calmer"}, {"b": 120, "k": "8A", "e": 4}), ({"title": "Lift"}, {"b": 121, "k": "8A", "e": 7})]
        with mock.patch.object(al, "deck_details_read", return_value={"am:1": {"bpm": 120, "key": "8A", "energy": 6}}):
            self.assertEqual(al.deck_mix_pick(found, anchor, 1, "energy")[0]["title"], "Lift")

    def test_ask_weights_the_newest_and_says_what_the_room_wants(self):
        now = time.time()
        played = [{"uid": f"p{i}", "title": f"Old {i}", "artist": f"A{i}", "playedAt": now - 3000 + i * 100} for i in range(8)]
        played.append({"uid": "old", "title": "Last week", "artist": "X", "playedAt": now - 86400 * 7})
        played.sort(key=lambda x: x["playedAt"])
        deck = {"played": played, "now": {"uid": "n", "title": "Now", "artist": "B", "rid": "r1"},
                "set": [{"uid": "s", "title": "Queued", "artist": "C", "from": "✦ Auto-DJ"}],
                "votes": {}, "skipped": [{"title": "Nope", "artist": "D"}], "direction": "energy"}
        with mock.patch.object(al, "deck_details_read", return_value={}):
            ask, anchor = al.deck_autodj_ask(deck)
        self.assertEqual(anchor["title"], "Queued")
        self.assertNotIn("Last week", ask)                       # only tonight
        self.assertIn("Earlier tonight: Old 0 by A0", ask)
        self.assertIn("Now by B [guest request]", ask)
        self.assertIn("follows «Queued by C [Auto-DJ's pick]»", ask)
        self.assertIn("Nope by D", ask)
        self.assertIn("Build the energy", ask)


class DuckTest(unittest.TestCase):
    def test_overlapping_clips_never_stack_the_dip(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        level = {"v": 1.0}
        def volume(song, value=None):
            was = level["v"]
            if value is not None:
                level["v"] = value
            return was
        with mock.patch.object(al, "DECK_DUCK", Path(tmp.name) / "duck.json"), \
             mock.patch.object(al, "deck_app_volume", side_effect=volume), \
             mock.patch.object(al, "deck_update"), mock.patch.object(al.time, "sleep"), \
             mock.patch.object(al.subprocess, "run"):
            first = al.deck_duck({}, True)
            level["v"] = 0.3                                   # dipped by the first clip
            self.assertEqual(al.deck_duck({}, True), first)    # the second sees the real level, not the dip
            self.assertFalse(al.deck_duck({}, False))          # not the last out
            self.assertTrue(al.deck_duck({}, False))
            level["v"] = 1.0
            al.deck_laptop_clip({"service": "applemusic"}, "x.wav", 1)
        self.assertEqual(level["v"], 1.0)


class UnplayableTest(unittest.TestCase):
    def deck(self):
        song = lambda uid: {"uid": uid, "title": uid, "artist": "A", "service": "applemusic", "id": "1"}
        return {"now": song("was"), "playing": True, "played": [], "set": [song("bad"), song("good"), song("last")]}

    def start(self, deck, refuses):
        with mock.patch.object(al, "deck_where_room", return_value=None), \
             mock.patch.object(al, "deck_play_laptop", side_effect=lambda s, at=0: s["uid"] not in refuses), \
             mock.patch.object(al, "toast") as toast, mock.patch.object(al, "deck_watch"):
            return al.deck_start(deck), toast

    def test_a_song_that_wont_play_is_passed_over(self):
        deck = self.deck()
        ok, toast = self.start(deck, {"bad"})
        self.assertTrue(ok)
        self.assertEqual(deck["now"]["uid"], "good")
        self.assertEqual([x["uid"] for x in deck["played"]], ["was"])     # the bad one isn't history
        self.assertEqual([x["uid"] for x in deck["set"]], ["last"])
        self.assertIn("Skipped bad", toast.call_args_list[0].args[0])
        self.assertEqual(deck["unplayable"]["title"], "bad")                # crossed out under the set

    def test_the_deck_stops_after_a_few_in_a_row(self):
        deck = self.deck()
        ok, toast = self.start(deck, {"bad", "good", "last"})
        self.assertFalse(ok)
        self.assertFalse(deck["playing"])
        self.assertIsNone(deck["now"])
        self.assertIn("has stopped", toast.call_args.args[1])

    def test_apple_music_refusing_a_song_gives_up_quickly(self):
        with mock.patch.object(al, "am_bridge", return_value={"ok": False}) as bridge, \
             mock.patch.object(al, "deck_apple_id", return_value=""), \
             mock.patch.object(al.time, "sleep"), mock.patch("builtins.open", mock.mock_open()):
            self.assertFalse(al.deck_play_laptop({"service": "applemusic", "id": "1", "title": "x"}))
        self.assertEqual(bridge.call_count, 3)

    def test_another_countrys_song_is_found_again_in_yours(self):
        song = {"service": "applemusic", "id": "1", "title": "Adorn", "artist": "Miguel"}
        replies = lambda op, timeout=0: {"ok": op.get("id") == "2"}
        with mock.patch.object(al, "am_bridge", side_effect=replies), \
             mock.patch.object(al, "deck_apple_id", return_value="2") as find, mock.patch.object(al.time, "sleep"):
            self.assertTrue(al.deck_play_laptop(song))
        find.assert_called_once_with({"title": "Adorn", "artist": "Miguel"})
        self.assertEqual(song["id"], "2")


class SoftSkipTest(unittest.TestCase):
    def test_next_fades_down_then_brings_the_next_up(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        song = lambda uid: {"uid": uid, "title": uid, "artist": "A", "service": "applemusic", "id": "1"}
        state = {"now": song("a"), "playing": True, "played": [], "set": [song("b")]}
        levels = []
        def volume(s, level=None):
            if level is not None:
                levels.append(level)
            return 0.8
        with mock.patch.object(al, "DECK", Path(tmp.name) / "deck.json"), \
             mock.patch.object(al, "DECK_DUCK", Path(tmp.name) / "duck.json"), \
             mock.patch.object(al, "deck_where_room", return_value=None), \
             mock.patch.object(al, "deck_app_volume", side_effect=volume), \
             mock.patch.object(al, "deck_update", side_effect=lambda f: f(state)), \
             mock.patch.object(al, "deck_read", side_effect=lambda: state), \
             mock.patch.object(al, "deck_play_laptop", return_value=True), \
             mock.patch.object(al, "deck_watch"), mock.patch.object(al.time, "sleep"):
            al.deck_soft_next(copy.deepcopy(state))
        self.assertEqual(state["now"]["uid"], "b")
        low = levels.index(min(levels))
        self.assertTrue(all(x >= y for x, y in zip(levels[:low], levels[1:low + 1])))   # down...
        self.assertLess(min(levels), 0.1)
        self.assertEqual(levels[-1], 0.8)                                               # ...and back up

    def test_pause_fades_out_and_play_brings_it_back_up(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        state = {"now": {"uid": "a", "service": "ytmusic"}, "playing": True, "paused": False}
        levels = []
        def volume(s, level=None):
            if level is not None:
                levels.append(level)
            return 0.6
        with mock.patch.object(al, "DECK", Path(tmp.name) / "deck.json"), \
             mock.patch.object(al, "DECK_DUCK", Path(tmp.name) / "duck.json"), \
             mock.patch.object(al, "deck_where_room", return_value=None), \
             mock.patch.object(al, "deck_app_volume", side_effect=volume), \
             mock.patch.object(al, "deck_update", side_effect=lambda f: f(state)), \
             mock.patch.object(al, "deck_read", side_effect=lambda: state), \
             mock.patch.object(al, "media_command"), mock.patch.object(al.time, "sleep"):
            al.deck_soft(dict(state), al.deck_pause, rise=False)
            self.assertFalse(state["playing"])
            self.assertLess(min(levels), 0.05)
            self.assertEqual(levels[-1], 0.6)                    # put back while paused
            levels.clear()
            al.deck_soft_resume(dict(state), lambda d: d.update(playing=True, paused=False))
        self.assertTrue(state["playing"])
        self.assertLess(levels[0], 0.05)                         # starts quiet...
        self.assertEqual(levels[-1], 0.6)                        # ...and comes up

    def test_a_sonos_room_skips_straight_on(self):
        state = {"now": {"uid": "a", "service": "applemusic"}, "playing": True}
        with mock.patch.object(al, "DECK", Path(tempfile.mkdtemp()) / "deck.json"), \
             mock.patch.object(al, "deck_where_room", return_value={"ip": "x"}), \
             mock.patch.object(al, "deck_app_volume") as volume, mock.patch.object(al, "deck_update") as update:
            al.deck_soft_next(state)
        volume.assert_not_called()
        update.assert_called_once()


class LaptopVolumeTest(unittest.TestCase):
    def test_the_deck_sets_the_laptops_own_output(self):
        with mock.patch.object(al, "quiet_out") as out:
            al.deck_laptop_volume("30")
            al.deck_laptop_volume("-5")
            al.deck_room_volume("laptop", "140")
        calls = [c.args for c in out.call_args_list]
        self.assertIn(("wpctl", "set-volume", "-l", "1.0", "@DEFAULT_AUDIO_SINK@", "30%"), calls)
        self.assertIn(("wpctl", "set-volume", "-l", "1.0", "@DEFAULT_AUDIO_SINK@", "5%-"), calls)
        self.assertIn(("wpctl", "set-volume", "-l", "1.0", "@DEFAULT_AUDIO_SINK@", "100%"), calls)
        self.assertEqual(sum(c[1] == "set-mute" for c in calls), 2)       # turning it down doesn't unmute

    def test_state_says_what_the_laptop_plays_through(self):
        outs = {"outputs": [{"name": "a", "label": "Speaker", "kind": "speaker", "default": False, "volume": 50, "muted": False},
                            {"name": "b", "label": "Headphones", "kind": "headphones", "default": True, "volume": 35, "muted": False}]}
        with mock.patch.object(al, "audio_outputs", return_value=outs):
            self.assertEqual(al.deck_laptop_out(), {"kind": "headphones", "label": "Headphones", "volume": 35, "muted": False})


class PartySafetyTest(unittest.TestCase):
    def setUp(self):
        al.DECK_STALL.clear()
        al.DECK_OUT.clear()

    def deck(self):
        return {"now": {"uid": "a", "service": "applemusic", "title": "Song", "id": "1"}, "playing": True,
                "expect": {"uid": "a", "since": 5}}

    def test_a_song_that_stops_moving_is_started_again_then_given_up_on(self):
        state = self.deck()
        clock = {"t": 1000.0}
        frozen = {"time": 60, "length": 200, "playing": True, "reach": True}
        with mock.patch.object(al.time, "time", side_effect=lambda: clock["t"]), \
             mock.patch.object(al, "deck_play_laptop", return_value=True) as play, \
             mock.patch.object(al, "deck_update", side_effect=lambda f: f(state)), mock.patch.object(al, "toast") as toast:
            self.assertEqual(al.deck_stalled(state, frozen, frozen), frozen)        # noticed
            clock["t"] += 11
            al.deck_stalled(state, frozen, frozen)                                  # tried again, where it was
            play.assert_called_once_with(state["now"], start_at=60)
            clock["t"] += 20
            self.assertFalse(al.deck_stalled(state, frozen, frozen))               # gave up
        self.assertFalse(state["playing"])
        self.assertIn("stopped moving", state["silent"]["why"])
        self.assertIn("Press Play", toast.call_args.args[1])

    def test_moving_music_is_left_alone(self):
        state = self.deck()
        self.assertIsNone(al.deck_stalled(state, {"time": 61, "length": 200, "playing": True}, {"time": 60}))

    def test_paused_in_the_app_the_deck_steps_back(self):
        state = self.deck()
        clock = {"t": 1000.0}
        held = {"time": 60, "length": 200, "playing": False, "reach": True}
        with mock.patch.object(al.time, "time", side_effect=lambda: clock["t"]), \
             mock.patch.object(al, "deck_play_laptop") as play, \
             mock.patch.object(al, "deck_update", side_effect=lambda f: f(state)):
            al.deck_stalled(state, held, held)
            clock["t"] += 11
            al.deck_stalled(state, held, held)
        play.assert_not_called()
        self.assertEqual((state["playing"], state["paused"]), (False, True))
        self.assertNotIn("silent", state)

    def test_a_cut_off_fade_puts_the_volume_back(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        fade = Path(tmp.name) / "fade.json"
        fade.write_text(json.dumps({"service": "ytmusic", "level": 0.7, "at": time.time() - 60}))
        with mock.patch.object(al, "DECK_FADE", fade), mock.patch.object(al, "DECK_DUCK", Path(tmp.name) / "duck.json"), \
             mock.patch.object(al, "deck_app_volume", return_value=0.05) as volume:
            al.deck_fade_heal()
        volume.assert_called_once_with({"service": "ytmusic"}, 0.7)
        self.assertFalse(fade.exists())

    def test_a_fade_in_progress_is_left_alone(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        fade = Path(tmp.name) / "fade.json"
        fade.write_text(json.dumps({"service": "ytmusic", "level": 0.7, "at": time.time()}))
        with mock.patch.object(al, "DECK_FADE", fade), mock.patch.object(al, "DECK_DUCK", Path(tmp.name) / "duck.json"), \
             mock.patch.object(al, "deck_app_volume") as volume:
            al.deck_fade_heal()
        volume.assert_not_called()

    def test_headphones_out_pauses(self):
        state = self.deck()
        outs = iter([{"kind": "headphones"}, {"kind": "speaker"}])
        with mock.patch.object(al, "deck_where_room", return_value=None), \
             mock.patch.object(al, "deck_laptop_out", side_effect=lambda: next(outs)), \
             mock.patch.object(al, "deck_soft") as soft, mock.patch.object(al, "toast"):
            self.assertFalse(al.deck_unplugged(state))
            self.assertTrue(al.deck_unplugged(state))
        self.assertIs(soft.call_args.args[1], al.deck_pause)

    def test_battery_warns_at_twenty_then_ten_once_each(self):
        state = {"playing": True, "batteryWarned": 0}
        level = {"v": 19}
        with mock.patch.object(al, "deck_battery", side_effect=lambda: {"level": level["v"], "charging": False}), \
             mock.patch.object(al, "deck_update", side_effect=lambda f: f(state)), mock.patch.object(al, "toast") as toast:
            al.deck_battery_watch(state)
            al.deck_battery_watch(state)
            level["v"] = 9
            al.deck_battery_watch(state)
            al.deck_battery_watch(state)
        self.assertEqual(toast.call_count, 2)
        self.assertEqual(state["batteryWarned"], 10)


class PolishTest(unittest.TestCase):
    def test_apple_music_opens_without_taking_you_there(self):
        clients = {"n": 0}
        def out(*argv, timeout=4):
            if argv[1] == "activeworkspace":
                return json.dumps({"id": 6 if clients["n"] > 1 else 7})
            if argv[1] == "clients":
                clients["n"] += 1
                return json.dumps([{"class": al.AM_CLASS}] if clients["n"] > 1 else [])
            return ""
        with mock.patch.object(al, "quiet_out", side_effect=out) as q, mock.patch.object(al.subprocess, "Popen"), \
             mock.patch.object(al.time, "sleep"):
            self.assertTrue(al.am_open_quietly())
        self.assertIn(("hyprctl", "dispatch", 'hl.dsp.focus({ workspace = "7" })'), [c.args for c in q.call_args_list])

    def test_warm_only_with_apple_music_to_come_and_nothing_playing(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        am = {"service": "applemusic"}
        with mock.patch.object(al, "DECK_WARM", Path(tmp.name) / "warm"), \
             mock.patch.object(al, "deck_where_room", return_value=None), mock.patch.object(al.subprocess, "Popen") as run:
            al.deck_warm_soon({"playing": True, "now": am, "set": []})
            al.deck_warm_soon({"playing": False, "now": None, "set": [{"service": "ytmusic"}]})
            self.assertFalse(run.called)
            al.deck_warm_soon({"playing": False, "now": None, "set": [am]})
            al.deck_warm_soon({"playing": False, "now": None, "set": [am]})      # not again so soon
        self.assertEqual(run.call_count, 1)

    def test_a_song_without_a_cover_shows_apples(self):
        song = {"uid": "a", "title": "T", "artist": "A", "service": "ytmusic", "video": "v", "thumb": ""}
        key = al.deck_song_key(song)
        with mock.patch.object(al, "deck_details_read", return_value={key: {"art": "https://x/art.jpg"}}):
            deck = al.deck_with_details({"now": song, "set": [], "played": []})
        self.assertEqual(deck["now"]["thumb"], "https://x/art.jpg")


class AutoDJTowardTest(unittest.TestCase):
    def test_ask_bridges_to_the_destination_then_stays(self):
        deck = {"played": [], "now": {"uid": "n", "title": "Now", "artist": "B"}, "set": [], "votes": {}, "skipped": [],
                "toward": {"brief": "deep house", "steps": 6, "done": 2}}
        with mock.patch.object(al, "deck_details_read", return_value={}):
            ask, _ = al.deck_autodj_ask(deck)
            self.assertIn("towards «deep house»", ask)
            self.assertIn("We're 2 songs into getting there", ask)
            self.assertIn("over the next 4 songs", ask)
            self.assertNotIn("carrying on its sound", ask)
            deck["toward"]["done"] = 6
            ask, _ = al.deck_autodj_ask(deck)
            self.assertIn("arrived at «deep house»", ask)

    def test_heading_somewhere_clears_autodjs_queue_but_keeps_yours(self):
        state = {"set": [{"uid": "a", "from": "✦ Auto-DJ"}, {"uid": "b", "from": "✦ Auto-DJ"},
                         {"uid": "c", "from": "Friday"}, {"uid": "d", "from": "✦ Auto-DJ", "rid": ""}],
                 "pinned": ["d"]}
        with mock.patch.object(al, "deck_edit", side_effect=lambda f: f(state)), \
             mock.patch.object(al, "deck_after_edit"), mock.patch.object(al, "toast"), \
             mock.patch.object(al, "deck_read", return_value={"now": None}), \
             mock.patch.object(al, "deck_fill") as fill, mock.patch.object(al, "deck_watch"):
            al.deck_toward({}, "deep house")
        self.assertEqual([x["uid"] for x in state["set"]], ["a", "c", "d"])       # next stays, yours and pinned stay
        self.assertEqual(state["toward"]["brief"], "deep house")
        self.assertTrue(state["autodj"])
        self.assertEqual(fill.call_args.kwargs, {"count": 6, "auto": True})


class AutoDJTidyTest(unittest.TestCase):
    def test_only_autodjs_songs_move_and_the_next_stays(self):
        song = lambda uid, bpm: {"uid": uid, "title": uid, "artist": uid, "bpm": bpm, "key": "8A", "service": "x"}
        d = {"now": song("now", 124), "pinned": [], "played": [],
             "set": [song("next", 124), song("mine", 122), song("a1", 98), song("a2", 123), song("a3", 100)]}
        with mock.patch.object(al, "deck_with_details", side_effect=lambda x: x):
            al.deck_tidy(d, {"a1", "a2", "a3"})
        order = [s["uid"] for s in d["set"]]
        self.assertEqual(order[:2], ["next", "mine"])                  # next and yours stay put
        self.assertEqual(order[2], "a2")                               # the near-tempo one comes first
        self.assertEqual(sorted(order[3:]), ["a1", "a3"])              # the slow pair sit together

    def test_settle_waits_for_tempos_then_goes(self):
        deck = {"autoTidy": True, "autodjSettle": {"uids": ["a"], "at": time.time()},
                "set": [{"uid": "a", "service": "applemusic", "id": "9"}]}
        with mock.patch.object(al, "deck_details_read", return_value={}):
            self.assertFalse(al.deck_settle_due(deck))
            deck["autodjSettle"]["at"] -= al.DECK_TIDY_WAIT + 1
            self.assertTrue(al.deck_settle_due(deck))                  # waited long enough
        deck["autodjSettle"]["at"] = time.time()
        with mock.patch.object(al, "deck_details_read", return_value={"am:9": {"bpm": 120}}):
            self.assertTrue(al.deck_settle_due(deck))
            deck["autoTidy"] = False
            self.assertFalse(al.deck_settle_due(deck))
