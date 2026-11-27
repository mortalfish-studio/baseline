"""Nothing personal or copyrighted goes into the public repo."""
import re
import subprocess
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
ALLOWED_IMAGES = {"unlock.png", "preview-unlock.png"}
PICTURE = re.compile(r"\.(png|jpe?g|webp|gif|avif|mp4|webm)$", re.I)


def tracked():
    out = subprocess.run(["git", "-C", str(REPO), "ls-files"], capture_output=True, text=True)
    if out.returncode:
        raise unittest.SkipTest("not a git checkout")
    return [line for line in out.stdout.splitlines() if line]


class Privacy(unittest.TestCase):
    def test_no_pictures_tracked(self):
        pictures = [f for f in tracked() if PICTURE.search(f) and f not in ALLOWED_IMAGES and not f.startswith("docs/")]
        self.assertEqual(pictures, [], "pictures are linked from pictures.json, never committed")

    def test_no_home_paths(self):
        found = []
        for name in tracked():
            path = REPO / name
            if PICTURE.search(name) or not path.is_file() or path.is_symlink():
                continue
            try:
                text = path.read_text()
            except (UnicodeDecodeError, OSError):
                continue
            for n, line in enumerate(text.splitlines(), 1):
                if re.search(r"/home/[a-z_][a-z0-9_-]*/", line) and "/home/<" not in line:
                    found.append(f"{name}:{n}")
        self.assertEqual(found, [], "use ~ or $HOME instead of a real home folder")


if __name__ == "__main__":
    unittest.main()
