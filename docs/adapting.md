# Adapting Baseline to your own apps

Baseline is wired to **T3 Code** (coding), **Grok Bot** (chat), **Superwhisper** (dictation) and **Chrome**. Each of these is referenced in a handful of places, so swapping one for another app is a contained change.

Coding apps that Omarchy installs include:
- [Herdr](https://herdr.dev): `omarchy install ai herdr`
- the Claude and ChatGPT desktop apps: `omarchy install ai claude|chatgpt`
- terminal agents: `omarchy default agent <name>`

## Where each app is wired in

| What | T3 Code / Grok Bot today | Where to change it |
|---|---|---|
| Which app owns workspace 3 (coding) and 4 (chat), and starts at login | `com.t3tools.T3Code` → 3, `grok-bot` → 4 | **Setup → Apps**, or `afterlight apps set coding\|chat <id>`. For any other app: `afterlight apps custom coding\|chat <name> <window class regex> <command>`, e.g. `afterlight apps custom coding Herdr '^herdr$' herdr`. Find an app's class with `hyprctl clients`. Written to `~/.config/hypr/baseline_apps.lua`. The other workspaces are in `system/hypr/home.lua`. |
| Workspace names on the bar | term · web · code · chat · video · music | the `mortalfish.workspaces` plugin copy (`system/plugin-patches/`) |
| Which apps' notifications pop up | Grok Bot, T3 Code, Baseline | `Delivery.js` in the `mortalfish.notifications` copy; also `shownApps` in `plugin/…/ui/StatusTab.qml` |
| Voice: questions | sent into Grok Bot | OmaRelay: `bin/omarelay_settings.py` (`FEATURES`, `ASSISTANTS`) and `bin/omarelay_grok.py` |
| Voice: code tasks | start a T3 Code thread | OmaRelay: `bin/omarelay_t3.py` |
| Sonos in the Player tab | your speakers on the local network (UPnP); the volume keys follow the picked room | `bin/afterlight`: the `sonos_*` functions; `system/bin/baseline-volume`; `ui/OutputSwitch.qml` |
| Send to Sonos | the laptop's song carries on in a room, found on Apple Music there | `bin/afterlight`: `sonos_send` (`SONOS_SERVICE` names the service Grok plays from; the brief is `sonos_send_brief`) |
| Apple Music | searched with Apple's public catalogue, played in the Apple Music web app (class `chrome-music.apple.com__-Default`, workspace 6) | `bin/afterlight`: the `am_*` functions (`am_country` picks the storefront from your locale); `chrome/beatport-baseline/background.js`: `appleMusic()` |
| Suggestions | when "play …" has no clear match, Grok's fast model suggests songs | `bin/afterlight`: `confident()` decides what counts as a match; `grok_ideas()` (`GROK_FAST` names the model; swap in another headless agent); `ui/PlayerTab.qml` shows them |
| Voice: Sonos | anything with "Sonos" in it goes to the Grok agent (`grok -p`), which uses the Sonos MCP | OmaRelay: `bin/omarelay_sonos.py` (`command()`: swap in another agent's headless command, such as `claude -p`, with the same Sonos MCP added to it) |
| Agent threads in Baseline | read from T3 Code's database | `bin/afterlight`: `agents_from_db` / `agents_from_cli` |
| Agent usage limits | `omarchy agent account list` (Claude, Codex, Grok) | `bin/afterlight` (morning check) and `ui/BarWidget.qml` |
| The neon theme layer | T3 Code's theme file | `bin/afterlight`: `t3_neon` |
| Dictation | `superwhisper start/stop/record` | `MOUSE_ACTIONS` in `bin/afterlight` (mouse buttons), and Setup → Dictation |
| Browser | Chrome, the Beatport add-on | [chrome-extension.md](chrome-extension.md); Chrome's colour comes from Omarchy's browser policy |

After editing:
- `home.lua` reloads with `hyprctl reload`
- panel QML needs `omarchy restart shell`
- OmaRelay changes need `python3 install.py` in its checkout
- plugin-copy changes are recorded with `afterlight plugins save`

## A different mouse

The mouse features were written against one mouse, the **Razer Basilisk V3** (wired), and read it at a low level. Expect another mouse to need real changes, not just settings. Everything is in `bin/afterlight`:

| What | How it works on the Basilisk V3 | Where |
|---|---|---|
| Finding the mouse | its `/dev/input/by-id/usb-Razer_Razer_Basilisk_V3*` devices | `MOUSE_GLOB`, `mouse_hidraw()` |
| Lighting | OpenRGB, device name `Basilisk`, three zones in this order: logo, wheel, strip; Direct mode | `MOUSE_ZONES`, `mouse_light()`, `mouse_colours()` |
| Side buttons | ordinary mouse buttons 275 (rear) and 276 (front), bound in Hyprland | `MOUSE_KEYS`, `write_mouse()` → `~/.config/hypr/mouse.lua` |
| Slow-down ("sniper") button | sends no click at all: while held, the mouse reports a lower DPI (e.g. 1600 → 400) on its second HID interface (`05 02 <dpi>`), and the daemon treats that drop as press and release | `mouse_daemon()` |
| Wheel tilt | read from the main HID report's third byte (AC Pan), not bound in Hyprland, because a Hyprland tilt binding also catches touchpad sideways scrolling | `mouse_daemon()` |

To adapt:
1. Run `openrgb --list-devices` to see whether OpenRGB supports your mouse and what its zones are called. Set the device name and `MOUSE_ZONES` to match.
2. Run `hyprctl devices`, or `wev` while you press buttons, to find your side buttons' codes for `MOUSE_KEYS`.
3. Buttons that send no event (like the sniper button) need your mouse's HID reports. Read `/dev/hidraw*` while pressing them and change `mouse_daemon()` to match.
4. Then run `systemctl --user restart afterlight-mouse` and `afterlight mouse bind`.

Or skip it: with no Basilisk connected, the mouse section in Setup and its service stay idle, and nothing else depends on them.

## A different laptop

Battery care reads `/sys/class/power_supply/qcom-battmgr-bat` (the Surface Laptop 7's driver); change `BATTERY` in `bin/afterlight` to your battery's folder if it offers `charge_control_end_threshold`, and the rule in `system/udev/` to match.

## Not using something at all

- **No Razer Basilisk V3**: the mouse section and its service stay idle (see [A different mouse](#a-different-mouse)).
- **No music sites**: the Player tab still controls whatever's playing through the media keys.
- **No dictation**: leave the slow-down button on "Default" in Setup.
- **No voice control**: install with `--no-omarelay`.

Setup → Apps moves the workspaces and autostart today. OmaRelay's hand-offs and the Status tab still talk to T3 Code and Grok Bot directly (rows above); point those at your apps in code.
