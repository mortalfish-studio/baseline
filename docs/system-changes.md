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
| [cava](https://github.com/karlstav/cava) | the Deck's equalizer: it reads the laptop's sound from PipeWire while the Deck is on screen and playing on the laptop |
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
| `~/.local/bin/baseline-volume` | the volume keys: the picked Sonos room, or else the laptop through Omarchy's own `omarchy-audio-output-volume` |
| `~/.local/bin/baseline-media` | the media keys: the Deck while it plays (or you paused it), or else Omarchy's own media control |
| `~/.config/omarchy/plugins/mortalfish.baseline` | the Baseline bar widget, panel and Studio |
| `~/.config/hypr/home.lua` | home workspaces, window rules, autostart, mouse buttons (below), the volume keys (rebound to `baseline-volume`) and the media keys (rebound to `baseline-media`) |
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
| `~/.config/omarchy/plugins/mortalfish.notifications`, `.osd`, `.workspaces` | copies of Omarchy's plugins with changes: **only Grok Bot, T3 Code and Baseline notifications pop up** (others go quietly to history), pop-ups near the top, workspaces named term/web/code/chat/video/music/deck. Rebuilt from Omarchy's originals after each update. |
| `~/.config/hypr/hyprland.lua` | one line added if missing: `require("hypr.home")` |
| `~/.config/hypr/baseline_apps.lua` | which apps open on workspaces 3 (coding) and 4 (chat) and start at login: T3 Code and Grok Bot unless changed in Setup → Apps (`afterlight apps`) |
| `~/.config/hypr/mouse.lua` | the mouse's side-button bindings (written by `afterlight mouse`) |
| `~/.config/starship.toml` | replaced by Baseline's prompt (backed up); a `[palettes.baseline]` block is rewritten on every theme switch |
| `~/.t3/userdata/themes/omarchy.json` | a marked CSS block appended to the T3 Code theme Omarchy writes (neon accents) |
| `~/.config/google-chrome/NativeMessagingHosts/com.mortalfish.baseline_beatport.json` | registers the bridge for the Chrome add-on (see [chrome-extension.md](chrome-extension.md)) |
| `~/.config/omarchy/afterlight/settings.json`, `sources.json` | Baseline's settings, and where each added picture came from |
| `~/.config/omarchy/backgrounds/afterlight-*` | pictures you add, and darkened Night/Saver copies made from them |
| `~/.config/systemd/user/afterlight-mode.timer` | the Day/Night schedule |
| `~/.local/state/afterlight/` | state: health report, liked tracks, Beatport playlists, the Sonos speakers and room names found (`sonos.json`, kept current: rewritten when they change and at least daily), the music popup's last message (`toast.json`), the last suggestions (`suggest.json`), the Deck's set (`deck.json`), where its song is (`deck-now.json`), its songs' details (`deck-details.json`), the last 30 changes to undo (`deck-undo.json`), a lock so one Sonos queue update runs at a time (`deck-sonos.lock`, `deck-sonos.again`) and the sets you saved (`deck-sets.json`), and, while Sonos has the volume keys, `sonos-target` |
| `~/.local/share/baseline/looks/` | looks added from the [catalog](https://github.com/mortalfish-studio/baseline-looks) |
| `~/.local/share/baseline/mine/` | looks you make in the Studio |
| `~/.local/share/baseline-before/` | the snapshot taken before installing (moved aside by `afterlight uninstall`) |
| `looks/*/backgrounds/` in the checkout | the built-in looks' pictures, downloaded from their links (not tracked by git) |
| `~/.cache/afterlight/`, `~/.cache/baseline/` | thumbnails, Sonos covers, Apple Music search results (kept a day), a copy of the catalog |

With `--dotfiles=<owner/repo>`, the installer also replaces key bindings, input, window look, autostart and night-light settings, menus, foot, default apps and Chrome flags from your backup. They're in the snapshot, so uninstalling puts your own versions back.

## What needs your password

| What | Why |
|---|---|
| `/etc/udev/rules.d/99-afterlight-charge-limit.rules` | lets Baseline set the battery charge limit (Surface Laptop 7; harmless elsewhere) |
| packages and apps | through `omarchy pkg` / `omarchy install` |
| letting phones reach the Deck's requests page (optional) | the firewall (ufw) blocks it until you allow it, once, for your home network only: `sudo ufw allow from 192.168.0.0/16 to any port 8765 proto tcp` (use your network's range). `sudo ufw delete allow from 192.168.0.0/16 to any port 8765 proto tcp` takes it back |

Chrome's colour follows the look through Omarchy's own browser policy (`/etc/opt/chrome/policies/managed/color.json`), which Omarchy writes with its own permission.

## The desktop, day to day

- **Home workspaces**: 1 terminal, 2 web (Chrome, Outlook), 3 code (T3 Code, or the coding app picked in Setup → Apps), 4 chat (Grok Bot, or your pick), 5 video (YouTube), 6 music (Beatport, YouTube Music, Apple Music), 7 deck (Baseline's [Deck](../README.md#the-deck), opened there by the shell at start unless `deck.home` is off). Each app always opens on its own workspace, and all of them start at login. The bar names the seven (the `mortalfish.workspaces` copy).
- **Day / Night / Saver**: switched by the clock (07:00 and 20:00 by default). Saver lowers the screen brightness, warms the colours, picks the power-saver profile and a solid bar, and puts all four back afterwards. Night and Saver also change the colour temperature.
- **Mouse** (Razer Basilisk V3 only; other mice need [adapting](adapting.md#a-different-mouse)): lights in the look's colours; slow-down button = hold to dictate, front side button = OmaRelay voice, rear side button = next track, wheel tilt = previous/next workspace. All changeable in Setup.
- **Superwhisper**: Setup can change its recording indicator style.
- **Volume keys**: Omarchy's volume up, down, mute (and Alt + up/down) are rebound to `baseline-volume`. With the laptop picked they do exactly what they did; with Sonos picked in the Player tab they change that room's volume.
- **Super+Alt+D** pops up the Deck over whatever you're doing (`omarchy-shell mortalfish.baseline deck`).
- **Media keys**: play/pause, next and previous (and their Alt forms) are rebound to `baseline-media`. While the Deck plays, or you paused it, they drive the Deck wherever it plays; otherwise they do exactly what they did.

## Background activity and network

| When | What |
|---|---|
| installing | clones Baseline and OmaRelay from GitHub; downloads the built-in looks' pictures from Wallhaven |
| at login | Day/Night by the clock, a wallpaper, a greeting once a day |
| 08:30 daily | morning check: Omarchy update, GitHub notifications (`gh`), coding-agent limits |
| opening the Status tab | GitHub (at most every 6 hours) for new Baseline and OmaRelay changes |
| while the Deck is on screen and playing on the laptop | `cava` reads the sound going out of the laptop (PipeWire), only to draw the equalizer; nothing is recorded or kept |
| while the Deck plays | a watcher (`afterlight deck run`) checks every couple of seconds where the song is, to start the next on the laptop or follow the Sonos room, and stops the music when a sleep timer runs out; on the laptop, in a song's last few seconds before the next starts in another app, it lowers the old app's volume (and puts it back after); it exits once nothing is playing |
| while the Deck's Auto-DJ is on and it plays | when the set gets down to three songs (at most every three minutes), `afterlight deck fill --auto` runs once in the background to add more (below), then exits |
| when songs in the Deck are missing details | `afterlight deck details` runs once in the background to look up their lengths, tempo, key and energy (below), then exits; a song isn't asked about again within the hour |
| after `omarchy update` | check and repair, notifying only if something needed fixing |
| saving or deleting a look | runs your backup command, if you set one (`backup.command`); nothing by default |
| Studio → Browse / Add | clones the public catalog; downloads pictures **only if you choose to**, from Wallhaven, Unsplash or Wikimedia |
| adding a Wallhaven link | asks Wallhaven's API for the picture and its credit |
| Share… | opens a public pull request on the catalog (only when you press it) |
| Player tab, while it's open | asks your Sonos speakers on the **local network** (port 1400) for rooms, volume and what's playing, every few seconds; finds them through Avahi (mDNS). Nothing leaves your network |
| saying "Sonos" to OmaRelay | the Grok agent (`grok -p`, Sonos tools only) talks to Sonos's cloud; only if you've added and signed in to the Sonos MCP yourself. OmaRelay gives it the room names Baseline last read |
| Send to Sonos (the Player tab's *Continue … in* button, or "send this to the kitchen") | the Grok agent, as above, starts the laptop's song (title, artist, album) on Apple Music in that room; then Baseline skips to the song and second over the local network and pauses the laptop |
| "play …" with no clear match, or *Ask Grok for ideas* | Grok's fast model (`grok -m grok-4.7-build-fast`, tools off) gets the words asked for and suggests songs; they're then searched on YouTube Music or Apple Music. Only if the Grok command line is installed and signed in |
| the Deck: *Build a set*, *Fill* and Auto-DJ | Grok's fast model, as above, gets your brief (or the titles and artists already in the set; for Auto-DJ, the last 24 played too; for a set grown from a song, that song's title, artist, tempo, key and energy) and the length; the songs it names are searched on the service the crate shows (YouTube Music, Apple Music or Beatport). A built set also gets each song's energy and chapter |
| the Chrome add-on's log | `~/.local/state/afterlight/addon.log`: the last 200 things the add-on did (requests, a save's steps and status), written by its native host, for working out what went wrong. No tokens, no song lists |
| the Deck: *Save to* a service | only when you press it: makes one new private playlist in your account on that service and adds the songs it has (looked up by title and artist first): Apple Music through Apple's player in its open window, YouTube Music through its open window, Beatport through the open Beatport app with its own sign-in, which stays in the page. Nothing else in your library is changed |
| the Deck's song details | lengths from Apple's public catalogue (`itunes.apple.com`, the songs' catalogue numbers) and YouTube Music (signed out, the video ids); tempo and key from Beatport's search, through the open Beatport window (each song's title and artist), only while that window is open, and for songs it doesn't have, Grok's fast model searching the web (the titles and artists, eight to a question, with web search and fetch only: no shell, files or other tools); energy from Grok's fast model (the titles and artists, all in one question). Kept in `deck-details.json` |
| Beatport in the Deck | Beatport's track search (the words you search) and each track's page, through the open Beatport app as you; your Beatport playlists by opening them in a background tab of that app and reading their tracks (nothing is changed, and the tab closes after) |
| the Deck's crate before you search | your own playlists: YouTube Music's through its open window, Apple Music's through its open window (read only) |
| the Deck's guests' requests | only while you've opened them (*Requests* → *Open requests*): a small web server (`afterlight deck guests serve`) on port 8765 of this laptop, on your home network. Its link has a random secret; it answers only the requests page, what's playing and next, an Apple Music search (Apple's public catalogue, the guest's words) and asking for a song from that search. It closes after 8 hours or when you close requests. The QR code of the link is `~/.local/state/afterlight/deck-guests.png`. Guests who say who they are are kept in `deck-guests.json` (a name, a random code their phone keeps) with their selfie, if they took one, in `deck-guests/` (a small JPEG, checked before it's kept, never sent anywhere); what each asked for (and any dedication) is in `deck-guests-asks.json`; 👍/👎 votes are kept in `deck.json` for the last 80 songs, and Auto-DJ's question to Grok includes the titles the room liked and didn't (so their phone can show it); `afterlight deck guests forget` removes them all. When dedications are read aloud in a Sonos room, the room fetches the spoken clip from this server (`/<secret>/voice/<id>.mp3`, nothing else under it) |
| dedications read aloud (optional) | only after `afterlight voice install`: [Piper](https://github.com/OHF-Voice/piper1-gpl) in its own Python (made with `uv`, from PyPI) and one English voice (`en_GB-cori-high`, downloaded from Hugging Face's `rhasspy/piper-voices`), about 175 MB, all in `~/.local/share/baseline/piper`. Speech is made on the laptop, offline; each clip is kept in `~/.local/state/afterlight/deck-voice/` (named by the request's random id). On the laptop it plays through PipeWire (`pw-play`) while the music app's volume dips; in a Sonos room the Deck points the room at the clip, then back at its queue. `afterlight deck voice off` stops it; removing the folder removes it |
| the Deck, playing in a Sonos room | writes the set into that room's queue (replacing what was queued there) and plays it, over the local network; YouTube Music songs are searched on Apple Music first |
| the Deck's rooms, while you can see it (on workspace 7 or popped up) | asks each Sonos speaker for its group, volume and whether it's playing, every 5 seconds, on the local network. Adding or taking out a room regroups the speakers (and may lower a joining room's volume); *Everywhere* never touches a room that's playing something else |
| searching for playlists in the Deck | YouTube Music's own search (signed out) and, for a playlist's songs, its web API; your private ones are read through the open YouTube Music window. Apple Music playlists and their songs through Apple's player in the Apple Music window, as you (your library playlists are only read, never changed) |
| searching Apple Music (Player tab, Deck, or "play … on Apple Music") | Apple's public catalogue search (`itunes.apple.com`), no account; the words searched and your region's storefront are sent |

Nothing is sent anywhere else, and nothing personal goes into shared looks: commits use your GitHub no-reply address and an author handle you choose.
