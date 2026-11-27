"""Snapshot, install, uninstall: the home folder ends up exactly as it began.

Runs against a temporary home; system commands (systemctl, omarchy, hyprctl,
sudo) are stubbed, and the repo itself is never written to."""

import hashlib
import importlib.machinery
import importlib.util
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent.parent


def load_module(home):
    env = {k: v for k, v in os.environ.items() if not k.startswith("XDG_")}
    env["HOME"] = str(home)
    with mock.patch.dict(os.environ, env, clear=True):
        loader = importlib.machinery.SourceFileLoader(f"afterlight_uninstall_{id(home)}", str(ROOT / "bin/afterlight.py"))
        module = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
        loader.exec_module(module)
    return module


def tree(home):
    """Every path under home: its kind, and its contents or link target."""
    found = {}
    for path in sorted(home.rglob("*")):
        rel = str(path.relative_to(home))
        if path.is_symlink():
            found[rel] = "link:" + os.readlink(path)
        elif path.is_file():
            found[rel] = hashlib.sha256(path.read_bytes()).hexdigest()
        elif path.is_dir():
            found[rel] = "dir"
    return found


class Done:
    returncode = 0
    stdout = ""
    stderr = ""


class UninstallTests(unittest.TestCase):

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.home = Path(self._tmp.name)
        self.al = load_module(self.home)
        # A machine before Baseline: some settings of its own.
        c = self.home / ".config"
        (c / "hypr").mkdir(parents=True)
        (c / "hypr/hyprland.lua").write_text('require("hypr.looknfeel")\n')
        (c / "hypr/bindings.lua").write_text("-- my keys\n")
        (c / "omarchy/branding").mkdir(parents=True)
        (c / "omarchy/branding/screensaver.txt").write_text("MY SCREENSAVER\n")
        (c / "omarchy/shell.json").write_text('{"bar": {"position": "top"}}\n')
        (c / "starship.toml").write_text("format = '$all'\n")
        (c / "foot").mkdir()
        (c / "foot/foot.ini").write_text("[main]\n")
        (c / "omarchy/themes").mkdir(parents=True)
        (c / "omarchy/themes/my-theme").mkdir()
        (self.home / ".local/state/omarchy/current").mkdir(parents=True)
        (self.home / ".local/state/omarchy/current/theme.name").write_text("my-theme\n")
        stub = mock.patch.object(self.al, "run", return_value=Done())
        stub.start()
        self.addCleanup(stub.stop)

    def install(self):
        """What the installer and repair do to the home folder."""
        al = self.al
        for link, target, _ in al.repo_links():
            al.relink(link, target)
        al.append_text(al.CONFIG / "hypr/hyprland.lua", 'require("hypr.home")\n')
        al.write_atomic(al.SHELL_JSON, '{"bar": {"position": "bottom"}}\n')
        al.write_atomic(al.CONFIG / "starship.toml", 'palette = "baseline"\n')
        al.write_atomic(al.CONFIG / "hypr/bindings.lua", "-- keys from the dotfiles\n")
        al.write_atomic(al.APPS_LUA, "-- apps\n")
        al.write_atomic(al.CHROME_HOST, "{}\n")
        al.write_atomic(al.SETTINGS, "{}\n")
        (al.PLUGINS_DIR / "mortalfish.osd").mkdir(parents=True)
        (al.PLUGINS_DIR / "mortalfish.osd/manifest.json").write_text("{}")
        (al.HOME / ".local/share/baseline/mine/x").mkdir(parents=True)
        (al.THEMES / "afterlight-2049").symlink_to(al.REPO)
        (al.USER_BG / "afterlight-2049").mkdir(parents=True)

    def test_round_trip_leaves_home_as_it_was(self):
        before = tree(self.home)
        self.assertEqual(self.al.snapshot(), "taken")
        self.install()
        self.assertNotEqual(tree(self.home), before)
        with mock.patch.object(sys.stdin, "isatty", return_value=False), mock.patch("builtins.print"):
            self.al.uninstall()
        after = {k: v for k, v in tree(self.home).items() if not k.startswith(".local/share/baseline-removed-")}
        # Empty folders Baseline made along the way may stay; nothing else differs.
        extra = {k for k in after.keys() - before.keys() if after[k] != "dir"}
        self.assertEqual(extra, set())
        self.assertEqual({k: after.get(k) for k in before}, before)

    def test_replaced_files_are_kept_not_deleted(self):
        self.al.snapshot()
        self.install()
        with mock.patch.object(sys.stdin, "isatty", return_value=False), mock.patch("builtins.print"):
            self.al.uninstall()
        removed = next(self.home.glob(".local/share/baseline-removed-*"))
        self.assertEqual((removed / str(self.home / ".config/hypr/bindings.lua").lstrip("/")).read_text(),
                         "-- keys from the dotfiles\n")
        self.assertTrue((removed / str(self.home / ".local/share/baseline/mine/x").lstrip("/")).is_dir())

    def test_no_snapshot_once_installed(self):
        self.install()
        self.assertEqual(self.al.snapshot(), "installed")
        self.assertFalse((self.al.BEFORE / "manifest.json").exists())

    def test_first_snapshot_wins(self):
        self.assertEqual(self.al.snapshot(), "taken")
        self.assertEqual(self.al.snapshot(), "kept")

    def test_uninstall_never_touches_the_repo(self):
        listing = sorted(str(p) for p in ROOT.rglob("*") if ".git" not in p.parts and "__pycache__" not in p.parts)
        self.al.snapshot()
        self.install()
        with mock.patch.object(sys.stdin, "isatty", return_value=False), mock.patch("builtins.print"):
            self.al.uninstall()
        self.assertEqual(sorted(str(p) for p in ROOT.rglob("*") if ".git" not in p.parts and "__pycache__" not in p.parts),
                         listing)


if __name__ == "__main__":
    unittest.main()
