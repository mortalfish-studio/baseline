# Baseline

One person's Omarchy system, after *Blade Runner 2049* and rain-soaked neon noir: a set of **looks** (themes), the **Baseline** bar panel that drives everything, **Baseline Studio** for pictures and making looks, and voice control through **[OmaRelay](https://github.com/mortalfish-studio/omarelay)** (its own repo). Afterlight, sodium amber over smog-steel slate with a teal counterpoint, is the original look. More looks are shared in the **[catalog](https://github.com/mortalfish-studio/baseline-looks)**.

Open source under the MIT licence ([LICENSE](LICENSE)): take it, change it, make it yours.

**New here?** It was built on a Surface Laptop 7 (Snapdragon X Elite, ARM64) with a Razer Basilisk V3 mouse ([details](docs/install.md#built-on)); the mouse features won't work on other mice without changes. Start with [docs/install.md](docs/install.md) (prerequisites, with links to each app), read [what it changes on your system](docs/system-changes.md), set up the [Chrome add-on](docs/chrome-extension.md) for the music controls, and see [adapting it to your own coding and chat apps](docs/adapting.md). It's built for one person's day-to-day work and shared for fun: no support, plenty to tinker with. Changed your mind? `afterlight uninstall` puts your system back as it was before (see [Taking it off](docs/install.md#taking-it-off)).

This repo is the single source: everything it puts into the system is a link back here, and `afterlight repair` puts it back if an update knocks anything out (see Health below). The command and folder are still called `afterlight` for history's sake.

- `bin/afterlight`: the command behind it all (`afterlight --help`); linked into `~/.local/bin`
- `plugin/mortalfish.baseline/`: the Baseline bar widget, panel (System, Player, Status, Wallpapers, Look, Setup) and Studio; linked into `~/.config/omarchy/plugins`
- `colors.toml`, `hyprland.lua`, `night/`, `saver/`: the Afterlight look (Day, Night, Saver). Its pictures aren't published; add your own.
- `looks/<id>/`: the other built-in looks (Ultraviolet, Cobalt Rain, Neon Rose), each with `pictures.json`: links to its pictures, fetched by `afterlight pictures`
- `atmosphere.lua`: window atmosphere shared by every look and mode (dimming, blur, terminal transparency, slow "drift" animations), with the panel's tweaks laid over it
- `btop.theme`, `unlock.png`, `preview-unlock.png`: btop colours and the boot/unlock logo
- `system/`: everything installed outside the repo, each as a link: `bin/` (helpers), `hooks/` (boot, theme-set, post-update), `hypr/home.lua` (home workspaces, window rules, mouse buttons), `branding/screensaver.txt` (BASELINE / CELLS INTERLINKED), `shell/baseline.json` (the bar layout repair restores), `systemd/`, `wireplumber/`, `udev/` and `plugin-patches/`

## Install on a new machine

On a fresh Omarchy install (no GitHub account needed):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/mortalfish-studio/baseline/main/install.sh)
```

`install.sh` fetches Baseline into `~/Projects/baseline` and OmaRelay into `~/Projects/omarelay`, then:

- takes a **snapshot** of everything it's about to change (`~/.local/share/baseline-before/`), so `afterlight uninstall` can put it all back
- installs the packages Baseline needs (python, imagemagick, starship, openrgb, …) and the apps it's built around, through Omarchy's own installers: T3 Code, Grok Bot, Superwhisper and Chrome (`--no-apps` to skip)
- with `--dotfiles=<owner/repo>`, restores your desktop settings from your own dotfiles backup: key bindings, input, window look, autostart, night light, menus, foot, default apps, Baseline's settings, liked music and your own pictures (never `hyprland.lua` or `monitors.lua`, which belong to each machine)
- installs Baseline's prompt (`system/starship.toml`)
- runs `afterlight repair`, which builds the rest from this repo: every link and hook, the bar (at the bottom, with Baseline and the plugin copies; copies are made afresh from Omarchy's originals plus the saved patches), Hyprland's home workspaces and mouse buttons, and the services
- sets the look (the one in your settings, else Afterlight, or `--look=<id>`), downloads the built-in looks' pictures from their original sites, installs OmaRelay, and adds the charge-limit rule with sudo
- finishes with the health check

Run it again any time to bring a machine up to date; options are `--no-omarelay`, `--no-apps`, `--look=<id>` and `--dotfiles=<owner/repo>`.

## Taking it off

`afterlight uninstall` shows what it will do and asks first (`--dry-run` only shows it). It stops Baseline's services, removes its links, puts every file it replaced back from the snapshot, switches to the theme you had, and removes the charge-limit rule (asks for your password). Nothing is deleted: whatever it removes or replaces, your looks and settings included, is moved to `~/.local/share/baseline-removed-<time>/`. Packages it added stay unless you pass `--packages`; apps it installed are listed with the Omarchy command that removes them. Without a snapshot (a machine set up before snapshots existed) it falls back to Omarchy's own defaults for the bar, prompt and screensaver.

## Health: check and repair

`afterlight check` lists every part Baseline puts into the system; `afterlight repair` puts back whatever is missing or changed. Baseline > Setup > Health shows the same, with Repair and Check again buttons.

- **Links & hooks**: the command and helpers, the plugin, `home.lua`, the three hooks, the systemd units, the WirePlumber rule, the screensaver text, and every look's themes in `~/.config/omarchy/themes/`. A real file found where a link should be is kept as `.bak-<time>`.
- **Desktop**: `hyprland.lua` still requires `hypr.home`, the coding and chat apps' workspace rules (`~/.config/hypr/baseline_apps.lua`) match Setup → Apps, the mouse bindings exist, and Hyprland reports no config errors.
- **Bar & plugin copies**: `shell.json`'s bar layout, plugins and disabled plugins match `system/shell/baseline.json` (a backup is taken before it's put back). The plugin copies get their changes re-applied to Omarchy's new versions. Changed the bar on purpose? **Keep this bar** (`afterlight repair --keep-bar`) saves it as the new reference.
- **Services**: the mouse daemon, the morning check and the day/night timer.
- **Look in other apps**: the starship prompt palette, T3 Code's neon layer and Chrome's colour match the current look.
- **OmaRelay** (under services): its installed copy matches its checkout (`install.py --check`); repair reinstalls it. **Looks from the catalog** (under look): any you've added are present; repair fetches them again. **Pictures for the built-in looks**: repair downloads any that are missing.
- **System (password)**: the charge-limit udev rule and OpenRGB. These need sudo, so **Repair system parts** (`afterlight repair --system`) runs them in a terminal where sudo can ask.

The Status tab's **Baseline** card shows new changes on GitHub (checked at most every six hours; **Update** runs `afterlight update`: pull Baseline and OmaRelay, reinstall OmaRelay, repair, restart the shell) or parts needing repair.

`system/hooks/baseline-repair` runs `afterlight repair --quiet` after every `omarchy update`; it sends a Baseline notification only when something was put back or still needs you. Results land in `~/.local/state/afterlight/health.json`.

## Modes

- **Day**, **Night** and **Saver** are three themes. `afterlight mode day|night|saver|toggle|auto` switches; the menu has Night Mode and Saver Mode entries.
- `afterlight-mode.timer` runs `afterlight mode auto` at the schedule's times (07:00 and 20:00 by default). A Saver picked by hand stays until it's left by hand.
- Saver turns the screen down, warms it, picks the power-saver profile and a solid bar, and puts all four back when it ends.

## Settings

Everything the panel changes is in `~/.config/omarchy/afterlight/settings.json`. Night wallpapers are darkened copies made from the originals into `~/.config/omarchy/backgrounds/afterlight-2049-night/` (Saver's into `-saver/`); added wallpapers go in `~/.config/omarchy/backgrounds/afterlight-2049/`.

Live copy: `~/.config/omarchy/themes/afterlight-2049` is a link to this repo, so edits here apply on the next `omarchy theme set "Afterlight 2049"`. Keep it a symlink: Omarchy strips `*.lua` from a theme folder that holds `.git` directly.

No pictures are kept in this repo. The built-in looks link to theirs (Wallhaven pages, with the uploader's credit) and `afterlight pictures` downloads them for your own desktop; their rights stay with their creators.

## Copies of Omarchy plugins

Some built-in plugins are copied into `~/.config/omarchy/plugins/` and changed: `mortalfish.osd` (popups near the top), `mortalfish.notifications` (which apps may pop up) and `mortalfish.workspaces` (workspace names). Each copy's changes are kept as a patch in `system/plugin-patches/`.

- `afterlight plugins status`: has Omarchy changed any of the originals?
- `afterlight plugins save`: record the copies' current changes (the daily dotfiles sync does this).
- `afterlight plugins restore`: after an update, take Omarchy's new version, re-apply our changes, and make sure the shell uses our copies. If a patch no longer fits, the old copy stays in use and Baseline sends a notification.

The repair (above) runs the restore after every `omarchy update`.

## Looks

A look is a whole colour scheme with its own wallpapers, in Day, Night and Saver alike: Afterlight (the original, at the top of this repo), Ultraviolet, Cobalt Rain and Neon Rose (`looks/<id>/`). Pick one in Baseline > Look, or `afterlight look set <id>` / `next` / `previous`.

A look's folder holds `look.json` (name, tagline, order), `colors.toml` (its Day palette), and `backgrounds/` (its own pictures, not tracked by git; anything dropped in there joins that look's library). The built-in looks are part of Baseline and read-only; looks you make in the Studio are yours, in `~/.local/share/baseline/mine/<id>/`. `afterlight look build <id>` writes its Night and Saver palettes and each mode's `hyprland.lua` from the Day palette, and links the three themes into `~/.config/omarchy/themes/` as `afterlight-<id>`, `-night` and `-saver`. Each look remembers which pictures you've ticked for Day and Night; wallpapers you add yourself are shared by all looks.

### Backing up and sharing looks

- **Your looks** live in `~/.local/share/baseline/mine/`, outside this repo. To back them up, set a backup command (`afterlight set backup.command '"~/Projects/dotfiles/sync.sh"'`, for example): saving or deleting a look runs it in the background, with the reason in `BASELINE_BACKUP_REASON`. `afterlight looks backup` runs it by hand.
- **Where pictures came from**: adding a picture from a link records its page and direct image link (`~/.config/omarchy/afterlight/sources.json`, synced with the dotfiles); a Wallhaven page link (`wallhaven.cc/w/<id>`) fetches its picture and keeps the uploader's credit and original source. The built-in looks list theirs in `looks/<id>/pictures.json`.
- **The public catalog**: [mortalfish-studio/baseline-looks](https://github.com/mortalfish-studio/baseline-looks) holds shared looks as data only: `look.json`, the palette, and picture *links* with credit (never the images). Studio → Browse lists it; **Add** checks each look (known colour keys and `#rrggbb` values only, plain short text, https links to Wallhaven, Unsplash or Wikimedia, no stock photos, at most eight pictures), writes its palette and window files locally, and can fetch its pictures from their sites (size-capped, no redirects, kept only if they really are images). Added looks live in `~/.local/share/baseline/looks/` as `c-<id>`, are remembered in settings, and come back on a new machine through repair.
- **Sharing**: Studio → Looks → **Share…** shows exactly what would go out, then opens a pull request on the catalog (`afterlight share <look> --preview`, then `--author=<handle> --include=<picture ids>`). Commits use your GitHub no-reply address. The catalog's own check (`tools/validate.py`) runs on every pull request, and nothing appears until it's merged.

### Chrome and T3 Code

Each look's theme folders carry a `chromium.theme` with the mode's accent (written by `afterlight look install`), so Omarchy seeds Chrome's frame, tabs and highlights from the look's own colour instead of its background; light or dark still follows the system. `system/hooks/baseline-theme` (a theme-set hook) runs `afterlight t3-neon`, which adds a small neon layer in the look's colours to the T3 Code theme Omarchy writes: a gradient under the chat header, a glow round the composer while typing, accent edges on your messages and the selected thread.

### Terminal prompt

The theme-set hook also runs `afterlight prompt`, which writes a `[palettes.baseline]` block (accent, highlight, alert, dim) into `~/.config/starship.toml` from the current theme. The prompt's folder and `◇` use the accent, git uses the highlight, and a failed command's `◆` uses red. Omarchy retints foot's own 16 colours.

## Apps on workspaces 3 and 4

Setup → Apps picks the coding app (workspace 3) and chat app (workspace 4): T3 Code and Grok Bot by default, or none. Any other app: `afterlight apps custom coding|chat <name> <window class> <command>` (find a window's class with `hyprctl clients`), then pick it in Setup. Baseline writes the choice to `~/.config/hypr/baseline_apps.lua`. More in [docs/adapting.md](docs/adapting.md).

## Baseline Studio

`omarchy-shell mortalfish.baseline studio library|looks`, or the Studio buttons in Baseline's Wallpapers and Look tabs: every picture and which looks use it by day and night, adding pictures, and the look maker (live preview, colour picker, palettes suggested from a picture, new looks and copies).
