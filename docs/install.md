# Installing Baseline

Baseline started as one person's working setup on Omarchy and grew into a small system:
- **looks**: themes, each with Day, Night and Saver versions
- **a bar panel** that runs the desktop
- **Baseline Studio**, for pictures and making looks
- **OmaRelay**, for voice control

It's built to make day-to-day coding work simpler, and it's shared for fun: take it, pull it apart, make it yours. Expect to tinker, because there's no support.

Before you start, read **[what it changes on your system](system-changes.md)**. It moves the bar, filters notifications, pins apps to workspaces and starts them at login. The installer takes a snapshot first, so [`afterlight uninstall`](#taking-it-off) can put everything back.

## Built on

Baseline was built on, and is only tested on, one machine:

| | |
|---|---|
| **Laptop** | Microsoft Surface Laptop 7, Snapdragon X Elite (**ARM64 / aarch64**) |
| **Screen** | 2304×1536 at 1.5× scaling, 60 Hz, bar along the bottom |
| **System** | Omarchy (Arch Linux + Hyprland, Lua config) |
| **Mouse** | Razer Basilisk V3, wired |

Most of it is ordinary Omarchy configuration and should work on any machine, x86 included. These parts are tied to that hardware:
- **The mouse** (lighting and the extra buttons) is written for the Razer Basilisk V3 alone. It's unlikely to work with any other mouse, even another Razer, without changes; see [adapting.md](adapting.md#a-different-mouse). With no Basilisk plugged in, those features simply sit idle.
- **Battery care** (the 80% charge limit) uses the Surface's battery driver (`qcom-battmgr`). On other laptops the option doesn't appear, and its udev rule matches nothing.
- **Layout** sizes, such as the panel and the Studio window, were tuned for that screen. They scale, but may need nudging on very different displays.

## You'll need

- **[Omarchy](https://omarchy.org)**, installed and up to date. See [Built on](#built-on) for the hardware it was made on.
- Nothing else: Baseline and OmaRelay are public, so no GitHub account is needed (only for `--dotfiles`, below).
- The apps Baseline is built around. The installer adds any that are missing:
  - **[T3 Code](https://github.com/pingdotgg/t3code)**: the coding agent app, on workspace 3. Baseline shows its threads and sends it voice tasks.
  - **[Grok Bot](https://x.ai/bot)**: the chat app, on workspace 4. Voice questions go here.
  - **[Superwhisper](https://superwhisper.com)**: dictation (needs its own account).
  - **[Google Chrome](https://www.google.com/chrome/)**: the browser, plus the YouTube and Beatport apps.
- Optional:
  - a **Razer Basilisk V3** mouse for the lighting and extra buttons (other mice need tweaking; see [Built on](#built-on))
  - **[Beatport](https://www.beatport.com)** and/or **[YouTube Music](https://music.youtube.com)** with the [Chrome add-on](chrome-extension.md) for the Player tab
  - **Sonos**: the Player tab finds your rooms on the network, shows what's playing, and its volume slider, mute and the volume keys control the room you pick (leave **UPnP** on in the Sonos app: Account → Privacy & Security). With S2 you can also say "play … on Sonos in the kitchen" to OmaRelay and the Grok agent plays it, through [Sonos's MCP server](https://support.sonos.com/en/article/control-your-sonos-system-with-ai-using-sonos-27mcp). Set up in [OmaRelay's README](https://github.com/mortalfish-studio/omarelay#sonos-through-the-grok-agent)

Using a different coding or chat app, such as [Herdr](https://herdr.dev) (`omarchy install ai herdr`), Claude or ChatGPT? See [adapting.md](adapting.md).

## Install

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/mortalfish-studio/baseline/main/install.sh)
```

Prefer to read it first? `git clone https://github.com/mortalfish-studio/baseline.git ~/Projects/baseline`, look through `install.sh`, then run `~/Projects/baseline/install.sh`.

The installer:
1. fetches [Baseline](https://github.com/mortalfish-studio/baseline) into `~/Projects/baseline` and [OmaRelay](https://github.com/mortalfish-studio/omarelay) into `~/Projects/omarelay` (change with `BASELINE_DIR=` / `OMARELAY_DIR=`)
2. **takes a snapshot** of every file it's about to change, the theme you're on, and which packages and apps you already have (`~/.local/share/baseline-before/`)
3. installs packages and the apps above
4. with `--dotfiles`, restores your desktop settings from your own backup repo
5. installs the prompt
6. runs `afterlight repair`, which links everything in and sets up the bar, plugins, workspaces and services
7. sets a look, downloads the built-in looks' pictures from their original sites, and installs OmaRelay
8. asks for your password once, for the battery charge-limit rule
9. ends with a health check

Options:
- `--dotfiles=<owner/repo>`: restore key bindings, input, menus, foot, default apps, Baseline's settings, your looks (`baseline/mine/`) and pictures from your own dotfiles repo (laid out like `config/hypr/…`, `config/omarchy/…`; signs in to GitHub if it's private)
- `--no-apps`: don't install T3 Code, Grok Bot, Superwhisper or Chrome
- `--no-omarelay`: skip voice control
- `--look=<id>`: start on a particular look

Run it again any time: it updates and puts back anything missing.

## After installing

1. **Log out and back in.** The six home apps start on their workspaces. Using other coding or chat apps? Pick them in **Setup → Apps**.
2. **Sign in** to T3 Code, Grok Bot, Superwhisper, Chrome, and your music sites.
3. **Load the Chrome add-on** if you want the Player tab to drive Beatport or YouTube Music: [chrome-extension.md](chrome-extension.md).
4. Open the panel (click Baseline on the bar). **Setup → Health** should say every part is in place.
5. Pick a look in **Look**, or browse more in **Studio → Browse**.

## Staying up to date

- The **Status** tab shows when Baseline or OmaRelay has new changes on GitHub. **Update** pulls them, reinstalls, repairs and restarts the shell.
- After an **Omarchy** update, Baseline checks itself and quietly puts back anything the update knocked out. It only tells you if something needed fixing.
- After updating, reload the Chrome add-on in `chrome://extensions`.

## Taking it off

```bash
afterlight uninstall --dry-run   # see what it would do
afterlight uninstall             # do it (asks first)
```

It uses the snapshot the installer took:
- stops Baseline's services and removes its links, hooks and plugin copies
- puts back every file it replaced (bar, prompt, screensaver, any settings restored from dotfiles) exactly as they were, and takes its line out of `hyprland.lua`
- switches back to the theme you had and removes the looks from Omarchy's theme list
- removes the charge-limit rule (asks for your password)

Nothing is deleted: everything it removes or replaces, including your looks and Baseline's settings, goes to `~/.local/share/baseline-removed-<time>/`. Packages Baseline added stay unless you add `--packages`. Apps it installed are listed with the command that removes them (`omarchy remove ai t3 code`, for example), since that also deletes their data. Afterwards:
- delete the checkout (`~/Projects/baseline`) when you like
- remove the Chrome add-on in `chrome://extensions` if you loaded it
- OmaRelay: `python3 install.py --uninstall` in its checkout
- log out and back in

Set up before snapshots existed? It falls back to Omarchy's defaults (`omarchy refresh config`) for the bar, prompt and screensaver, and leaves your other settings as they are.
