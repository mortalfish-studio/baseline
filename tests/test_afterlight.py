"""Tests for bin/afterlight: the parts that can break a system or let bad
data in. Every path the script writes to is pointed into a temporary folder,
and nothing here touches the network or runs hyprctl, systemctl or omarchy.

Run from the repo root: python3 -m unittest discover -s tests -q
"""

import copy
import importlib.machinery
import importlib.util
import json
import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent.parent
_loader = importlib.machinery.SourceFileLoader("afterlight_under_test", str(ROOT / "bin/afterlight"))
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


class TempCase(unittest.TestCase):
    """A fresh temporary folder per test, removed afterwards."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.addCleanup(self._tmp.cleanup)

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
