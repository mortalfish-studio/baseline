"""The docs keep up with the code: everything Baseline puts into the system
is listed in docs/system-changes.md, and the guides link up."""
import importlib.machinery
import importlib.util
import re
import sys
import unittest
from pathlib import Path

sys.dont_write_bytecode = True
REPO = Path(__file__).resolve().parent.parent
_loader = importlib.machinery.SourceFileLoader("afterlight_docs", str(REPO / "bin/afterlight.py"))
al = importlib.util.module_from_spec(importlib.util.spec_from_loader("afterlight_docs", _loader))
_loader.exec_module(al)
CHANGES = (REPO / "docs/system-changes.md").read_text()


def home_path(path):
    return "~/" + str(Path(path).relative_to(al.HOME))


class SystemChangesListed(unittest.TestCase):
    def test_every_link_is_listed(self):
        for link, _target, label in al.repo_links():
            shown = home_path(link)
            # The units are listed together as "<name>.service + .timer".
            stem = shown.rsplit(".", 1)[0] if shown.endswith((".service", ".timer")) else shown
            with self.subTest(label=label):
                self.assertIn(stem, CHANGES, f"{shown} ({label}) is missing from docs/system-changes.md")

    def test_written_files_are_listed(self):
        for path in (al.SHELL_JSON, al.MOUSE_LUA, al.CHROME_HOST, al.SOURCES_FILE, al.TIMER,
                     al.CONFIG / "starship.toml", al.CONFIG / "hypr/hyprland.lua"):
            with self.subTest(path=path):
                self.assertIn(home_path(path).replace("~/.config/omarchy/afterlight/", "").split("/")[-1], CHANGES)

    def test_system_files_are_listed(self):
        self.assertIn(str(al.UDEV_RULE), CHANGES)

    def test_plugin_copies_are_listed(self):
        for record in sorted(al.PATCHES.glob("*.json")):
            with self.subTest(copy=record.stem):
                self.assertIn(record.stem.split(".", 1)[1], CHANGES)

    def test_health_groups_are_described(self):
        readme = (REPO / "README.md").read_text()
        for group in ("Links & hooks", "Desktop", "Bar & plugin copies", "Services", "Look in other apps", "System"):
            with self.subTest(group=group):
                self.assertIn(group, readme)


class GuidesLinkUp(unittest.TestCase):
    def test_relative_links_resolve(self):
        for page in [REPO / "README.md", *sorted((REPO / "docs").glob("*.md"))]:
            for target in re.findall(r"\]\(([^)#:]+\.md)\)", page.read_text()):
                with self.subTest(page=page.name, link=target):
                    self.assertTrue((page.parent / target).is_file())

    def test_install_command_matches_the_repo(self):
        install = (REPO / "install.sh").read_text()
        guide = (REPO / "docs/install.md").read_text()
        command = re.search(r"bash <\(curl [^\n]+\)", install).group(0)
        self.assertIn(command, guide)
        self.assertIn(command, (REPO / "README.md").read_text())
        # It fetches the repo that the command downloads it from.
        self.assertIn("mortalfish-studio/baseline/main/install.sh", command)
        self.assertIn('/$OWNER/baseline.git"', install)

    def test_uninstall_is_documented(self):
        for name in ("README.md", "docs/install.md", "docs/system-changes.md"):
            self.assertIn("afterlight uninstall", (REPO / name).read_text(), name)


if __name__ == "__main__":
    unittest.main()
