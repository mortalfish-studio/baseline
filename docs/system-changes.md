# What Baseline changes on your system

Baseline reshapes an Omarchy desktop around one person's way of working, on one machine: a Surface Laptop 7 (Snapdragon X Elite, ARM64) with a Razer Basilisk V3 mouse ([built on](install.md#built-on)). Read this before installing: it covers every file it links, writes or replaces, what needs your password, what runs in the background, and what reaches the network.

Before changing anything, the installer takes a **snapshot** of every path below, the theme you're on, and which packages and apps you already have (`~/.local/share/baseline-before/`). **`afterlight uninstall`** uses it to put everything back as it was; see [Taking it off](install.md#taking-it-off). Omarchy can also restore any one file's defaults: `omarchy refresh config <file>`.

> This page is kept in step with the code: `tests/test_docs.py` fails if a part the health check manages isn't listed here.

## Packages and apps

Installed with Omarchy's own tools (`omarchy pkg add`, `omarchy install …`):

| What | Why |
|---|---|
| python, imagemagick, rsync, patch, diffutils | the `afterlight` command, picture handling, plugin copies |
| [starship](https://starship.rs/) | the prompt (Omarchy ships it already) |
| [OpenRGB](https://gitlab.com/CalcProgrammer1/OpenRGB) | the Razer mouse's lights; its package adds udev rules giving your user access to RGB devices |
| [T3 Code](https://github.com/pingdotgg/t3code) | the coding agent app (`omarchy install ai t3 code`) |
| [Grok Bot](https://x.ai/bot) | the chat app (`omarchy pkg add grok-bot`) |
| [Superwhisper](https://superwhisper.com) | dictation (`omarchy install dictation superwhisper`) |
| [Google Chrome](https://www.google.com/chrome/) | the browser (`omarchy install browser chrome`) |

Skip the apps with `--no-apps`.

## Links into the repo

These are symlinks back to your checkout, so the repo stays the single source. `afterlight check` lists them; `afterlight repair` recreates them. A real file found where a link belongs is renamed to `<name>.bak-<time>`, never deleted.

| Where | What it is |
|---|---|
| `~/.local/bin/afterlight` | the `afterlight` command |
| `~/.local/bin/afterlight-mode`, `~/.local/bin/afterlight-wallpaper` | small helpers used by the menu, timer and boot hook |
| `~/.config/omarchy/plugins/mortalfish.baseline` | the Baseline bar widget, panel and Studio |
| `~/.config/hypr/home.lua` | home workspaces, window rules, autostart, mouse buttons (below) |
| `~/.config/omarchy/hooks/post-boot.d/baseline-boot` | picks Day or Night and a wallpaper at login; a once-a-day greeting |
| `~/.config/omarchy/hooks/post-update.d/baseline-repair` | after `omarchy update`: check and repair everything, quietly |
| `~/.config/omarchy/hooks/theme-set.d/baseline-theme` | after a theme switch: T3 Code's neon layer and the prompt colours |
| `~/.config/systemd/user/afterlight-morning.service` + `.timer` | the morning check notification (08:30) |
| `~/.config/systemd/user/afterlight-mouse.service` | reads the mouse's slow-down button and wheel tilt |
| `~/.config/systemd/user/afterlight-mode.service` | switches Day/Night by the clock (with `afterlight-mode.timer`, written by the command) |
| `~/.config/wireplumber/wireplumber.conf.d/afterlight-honour-chosen-sink.conf` | audio: keep the output you picked even if its jack reads empty |
| `~/.local/share/wireplumber/scripts/afterlight` | the script that rule loads |
| `~/.config/omarchy/branding/screensaver.txt` | the screensaver text: BASELINE, and CELLS INTERLINKED beneath (your old one is kept as `.bak-<time>`) |
| `~/.config/omarchy/themes/afterlight-*` | every look's Day, Night and Saver themes |

## Files written or changed

| File | Change |
|---|---|
| `~/.config/omarchy/shell.json` | **the bar**: moved to the bottom, its layout set (menu and workspace names left, Baseline right), Omarchy's notifications and on-screen display swapped for Baseline's copies. Backed up as `shell.json.bak-baseline-<time>` before each change. |
| `~/.config/omarchy/plugins/mortalfish.notifications`, `.osd`, `.workspaces` | copies of Omarchy's plugins with changes: **only Grok Bot, T3 Code and Baseline notifications pop up** (others go quietly to history), pop-ups near the top, workspaces named term/web/code/chat/video/music. Rebuilt from Omarchy's originals after each update. |
| `~/.config/hypr/hyprland.lua` | one line added if missing: `require("hypr.home")` |
| `~/.config/hypr/baseline_apps.lua` | which apps open on workspaces 3 (coding) and 4 (chat) and start at login: T3 Code and Grok Bot unless changed in Setup → Apps (`afterlight apps`) |
| `~/.config/hypr/mouse.lua` | the mouse's side-button bindings (written by `afterlight mouse`) |
| `~/.config/starship.toml` | replaced by Baseline's prompt (backed up); a `[palettes.baseline]` block is rewritten on every theme switch |
| `~/.t3/userdata/themes/omarchy.json` | a marked CSS block appended to the T3 Code theme Omarchy writes (neon accents) |
| `~/.config/google-chrome/NativeMessagingHosts/com.mortalfish.baseline_beatport.json` | registers the bridge for the Chrome add-on (see [chrome-extension.md](chrome-extension.md)) |
| `~/.config/omarchy/afterlight/settings.json`, `sources.json` | Baseline's settings, and where each added picture came from |
| `~/.config/omarchy/backgrounds/afterlight-*` | pictures you add, and darkened Night/Saver copies made from them |
| `~/.config/systemd/user/afterlight-mode.timer` | the Day/Night schedule |
| `~/.local/state/afterlight/` | state: health report, liked tracks, Beatport playlists |
| `~/.local/share/baseline/looks/` | looks added from the [catalog](https://github.com/mortalfish-studio/baseline-looks) |
| `~/.local/share/baseline/mine/` | looks you make in the Studio |
| `~/.local/share/baseline-before/` | the snapshot taken before installing (moved aside by `afterlight uninstall`) |
| `looks/*/backgrounds/` in the checkout | the built-in looks' pictures, downloaded from their links (not tracked by git) |
| `~/.cache/afterlight/`, `~/.cache/baseline/` | thumbnails, a copy of the catalog |

With `--dotfiles=<owner/repo>`, the installer also replaces key bindings, input, window look, autostart and night-light settings, menus, foot, default apps and Chrome flags from your backup. They're in the snapshot, so uninstalling puts your own versions back.

## What needs your password

| What | Why |
|---|---|
| `/etc/udev/rules.d/99-afterlight-charge-limit.rules` | lets Baseline set the battery charge limit (Surface Laptop 7; harmless elsewhere) |
| packages and apps | through `omarchy pkg` / `omarchy install` |

Chrome's colour follows the look through Omarchy's own browser policy (`/etc/opt/chrome/policies/managed/color.json`), which Omarchy writes with its own permission.

## The desktop, day to day

- **Home workspaces**: 1 terminal, 2 web (Chrome, Outlook), 3 code (T3 Code, or the coding app picked in Setup → Apps), 4 chat (Grok Bot, or your pick), 5 video (YouTube), 6 music (Beatport). Each app always opens on its own workspace, and all six start at login.
- **Day / Night / Saver**: switched by the clock (07:00 and 20:00 by default). Saver lowers the screen brightness, warms the colours, picks the power-saver profile and a solid bar, and puts all four back afterwards. Night and Saver also change the colour temperature.
- **Mouse** (Razer Basilisk V3 only; other mice need [adapting](adapting.md#a-different-mouse)): lights in the look's colours; slow-down button = hold to dictate, front side button = OmaRelay voice, rear side button = next track, wheel tilt = previous/next workspace. All changeable in Setup.
- **Superwhisper**: Setup can change its recording indicator style.

## Background activity and network

| When | What |
|---|---|
| installing | clones Baseline and OmaRelay from GitHub; downloads the built-in looks' pictures from Wallhaven |
| at login | Day/Night by the clock, a wallpaper, a greeting once a day |
| 08:30 daily | morning check: Omarchy update, GitHub notifications (`gh`), coding-agent limits |
| opening the Status tab | GitHub (at most every 6 hours) for new Baseline and OmaRelay changes |
| after `omarchy update` | check and repair, notifying only if something needed fixing |
| saving or deleting a look | runs your backup command, if you set one (`backup.command`); nothing by default |
| Studio → Browse / Add | clones the public catalog; downloads pictures **only if you choose to**, from Wallhaven, Unsplash or Wikimedia |
| adding a Wallhaven link | asks Wallhaven's API for the picture and its credit |
| Share… | opens a public pull request on the catalog (only when you press it) |

Nothing is sent anywhere else, and nothing personal goes into shared looks: commits use your GitHub no-reply address and an author handle you choose.
