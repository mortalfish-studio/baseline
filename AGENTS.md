# Working on Baseline

Baseline is an Omarchy desktop system: looks (themes), the bar panel (`plugin/mortalfish.baseline/`), Baseline Studio, the `afterlight` command (`bin/afterlight`), and the install/health tooling. Read `README.md` first.

## Every change keeps the docs current

Other people install this from GitHub, so the docs are part of the change, not an afterthought. Before committing, update whichever of these the change touches:

| If you change… | Update |
|---|---|
| anything Baseline links, writes or replaces outside the repo, needs sudo for, runs in the background, or fetches from the network | `docs/system-changes.md`, and `managed_paths()` in `bin/afterlight` so the snapshot and `afterlight uninstall` cover it |
| `install.sh`, prerequisites, apps it installs, the install command | `docs/install.md` and the README's install section |
| the Chrome add-on (`chrome/`) or its native host | `docs/chrome-extension.md`, and bump `version` in its `manifest.json` |
| where an app (T3 Code, Grok Bot, Superwhisper, Chrome) is wired in | `docs/adapting.md` |
| health checks, repair, looks, the catalog, sharing | the matching README section |
| the catalog format or its rules | also `tools/validate.py` and `README.md` in `mortalfish-studio/baseline-looks` (Baseline's `validate_shared` and the catalog's validator must agree) |

`tests/test_docs.py` fails when something the health check manages is missing from `docs/system-changes.md`, or a guide's link is broken. Keep it passing; extend it when you add a new kind of system change.

## Checks before committing

```bash
python3 -m unittest discover -s tests -q   # must pass
afterlight check                            # every part in place
```

Panel QML changes need `omarchy restart shell`; check `journalctl --user --since -2min | grep -i qml` for errors and look at the result (screenshot) before calling it done.

## Rules

- Never edit `/usr/share/omarchy/`. Customise in `~/.config/`; plugin changes go in the copies, recorded with `afterlight plugins save`.
- Everything installed outside the repo is a **link into the repo** (see `repo_links()`), so the repo stays the single source and `afterlight repair` can rebuild it. `relink()` must never replace a path whose folder already leads into the repo.
- Shared looks are **data only**: validate, then write palettes and theme files locally. Nothing from the catalog is ever executed, and no pictures are hosted, only links.
- Keep personal details out of anything shared or public: commits use the GitHub no-reply address, and no real home path (`/home/<name>/`) goes in a tracked file. `tests/test_privacy.py` checks.
- No pictures in the repo: built-in looks link to theirs in `pictures.json`; `backgrounds/` folders are gitignored.
- Screenshots for docs or the catalog show the app alone: crop to the panel or window, with no desktop, other windows, notifications, names or paths in view.
- Uninstall must keep working: the round trip in `tests/test_uninstall.py` (snapshot → install → uninstall leaves home unchanged) has to pass, and uninstall moves things aside, never deletes them.
- Commit messages end with the agent's attribution line if your tool adds one.
