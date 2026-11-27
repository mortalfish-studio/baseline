# The Chrome add-on: Beatport, YouTube Music and Apple Music

Baseline's Player tab and the mouse's media buttons drive music that plays in Chrome:
- **Beatport**: installed as a Chrome app, on workspace 6
- **YouTube Music**: a web app
- **Apple Music**: a web app (sign in with your Apple account)

A small add-on, **Baseline for Beatport**, lets Baseline work those pages. It can:
- switch Top 100 charts, playlists and artists in place, without a page reload
- start them playing
- list your Beatport playlists in the panel
- add tracks to your likes (♥)
- play Apple Music search results through Apple's own player in the page (MusicKit): a song within its album, an album, or an artist's top songs; and read what it's playing, where it is and how long it is (so the [Deck](../README.md#the-deck) knows when a song ends); find playlists (yours in your library, and Apple's), list all of yours, and read a playlist's songs, for the Deck. It only changes your library when you ask the Deck to *Save to Apple Music*, which makes one new playlist
- for the Deck's *Save to*, make a new private playlist of a set's songs in your YouTube Music or Beatport account (Beatport's own sign-in is used inside its page and never leaves it); only when you press it
- turn a page's volume down and back up, so the Deck can fade one app into the next
- keep only one thing playing at a time

None of this is required. Without the add-on, Baseline still opens these pages and the media keys still work. You just lose playing them in place and the playlist list.

## Install it

1. **Get the music apps** (if you use them):
   - **Beatport**: open [beatport.com](https://www.beatport.com) in Chrome, then choose **⋮ → Cast, save and share → Install page as app**. Sign in.
   - **YouTube Music**: run `omarchy webapp install "YouTube Music" https://music.youtube.com/ <icon-url>`, or install it from Chrome the same way as Beatport.
   - **Apple Music**: run `omarchy webapp install "Apple Music" https://music.apple.com/ <icon-url>`, then sign in there.
2. **Load the add-on**:
   - Open `chrome://extensions` and turn on **Developer mode** (top right).
   - Choose **Load unpacked** and pick the `chrome/beatport-baseline` folder in your Baseline checkout (for example `~/Projects/baseline/chrome/beatport-baseline`).
3. **Register its bridge**: run `afterlight repair`. The installer already does this.
   - It writes `~/.config/google-chrome/NativeMessagingHosts/com.mortalfish.baseline_beatport.json`, which points Chrome at `chrome/native/beatport-host.py`.
   - Chrome gives an unpacked add-on an ID that depends on its folder's path, so repair works the ID out for your checkout. If you move the checkout, run repair again, then in `chrome://extensions` remove the old add-on and **Load unpacked** from the new folder.
4. **Reload the Beatport, YouTube Music and Apple Music pages** once.

If the panel says *"Beatport add-on isn't running"*, reload the add-on in `chrome://extensions` and check that `afterlight check` shows **Chrome add-on bridge registered**.

## Keeping it up to date

Chrome never updates an unpacked add-on by itself. After you pull Baseline (`afterlight update`, or **Update** on the Status tab), open `chrome://extensions` and press the add-on's **↻ reload** button. The version number in its card should match `chrome/beatport-baseline/manifest.json`.

## How it fits together

```
Baseline panel / mouse ──► afterlight beatport … ──► socket ($XDG_RUNTIME_DIR/afterlight-beatport.sock)
                                                         │
                                  chrome/native/beatport-host.py (started by Chrome)
                                                         │  native messaging
                                  background.js (the add-on's worker) ──► the open Beatport / YouTube Music tab
                                                                           (bridge.js, autoplay.js, report.js)
```

| File | Job |
|---|---|
| `manifest.json` | permissions: native messaging, tabs, scripting; only `beatport.com`, `youtube.com`, `music.youtube.com` |
| `background.js` | connects to the native host and handles each request: `open`, `check`, `page`, `fetch`, `scratch`, `media`, `tabs`; passes playlists back |
| `bridge.js` | runs inside the page: finds and clicks things (`click`, with `first` for the page's own button rather than a recommendation's; `steps`), browses YouTube Music (`ytm-browse`), and quiets that page's audio and video (`pause-media`; `dry` only says whether it could, and how many players it found: Beatport's player isn't on the page, so the Deck presses its bar's Pause instead), so the Deck can start the next song before it stops the last |
| `background.js` → `appleMusic()` | one fixed function run in the Apple Music page's own world (Apple's player lives there): `now`, `queue` (checked catalogue ids only), `play`, `pause`, `toggle`, `next`, `previous`, `seek`, `volume` (the Deck's fade), and, reading only, `playlists` (a search of your library playlists and Apple's, or with `*` every playlist in your library) and `tracks` (a checked playlist id's songs) |
| `autoplay.js` | presses a Beatport page's own Play button when Baseline opens it with `#baseline-play` |
| `report.js` | reads your playlists from Beatport's sidebar |
| `../native/beatport-host.py` | Chrome starts it; it saves playlists to `~/.local/state/afterlight/beatport.json` and relays requests from the socket |

## Tweaking it

Sites change their pages, and you may want other music sites.

- **A button stopped working** (Beatport or YouTube changed their page): the selectors are in `bridge.js` and `autoplay.js`. Open the page and inspect the element in Chrome's DevTools (F12), update the match, then reload the add-on.
  - To test a single page action without the panel, run `afterlight beatport page '<json op>'`, e.g. `'{"type":"probe"}'`.
- **Another site**:
  1. Add it to `host_permissions` and to a `content_scripts` entry in `manifest.json`.
  2. Handle it in `bridge.js`, following the `music.youtube.com` branch.
  3. Add a command for it in `bin/afterlight` (see `beatport_bridge` and `media_command`).
- **After any change**: bump `version` in `manifest.json`, then reload the add-on.

The add-on can only reach the three music sites listed in its manifest, and the native host only accepts requests through a socket in your own runtime folder.
