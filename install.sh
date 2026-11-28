#!/bin/bash
# Baseline: set up the whole system on an Omarchy machine, or bring one up to date.
#
# On a new machine:
#   bash <(curl -fsSL https://raw.githubusercontent.com/mortalfish-studio/baseline/main/install.sh)
#
# From a checkout:  ./install.sh [--no-omarelay] [--no-apps] [--look=<id>] [--dotfiles=<owner/repo>]
#
# Before it changes anything it takes a snapshot, so `afterlight uninstall`
# can put your system back as it was. Safe to run again any time: it fetches
# the latest and puts back whatever is missing.

set -uo pipefail

OWNER=mortalfish-studio
BASELINE_DIR=${BASELINE_DIR:-$HOME/Projects/baseline}
OMARELAY_DIR=${OMARELAY_DIR:-$HOME/Projects/omarelay}
DOTFILES_DIR=${DOTFILES_DIR:-$HOME/Projects/dotfiles}
DOTFILES_REPO=
LOOK=
use_dotfiles=0
use_omarelay=1
use_apps=1
for arg in "$@"; do
  case $arg in
    --dotfiles=*) DOTFILES_REPO=${arg#*=}; use_dotfiles=1 ;;
    --no-dotfiles) use_dotfiles=0 ;;
    --no-omarelay) use_omarelay=0 ;;
    --no-apps) use_apps=0 ;;
    --look=*) LOOK=${arg#*=} ;;
    -h | --help)
      cat <<'HELP'
Baseline installer. Options:
  --no-apps                don't install T3 Code, Grok Bot, Superwhisper or Chrome
  --no-omarelay            skip OmaRelay (voice control)
  --look=<id>              start on this look
  --dotfiles=<owner/repo>  restore your settings from your own dotfiles repo
It takes a snapshot first: `afterlight uninstall` puts everything back.
HELP
      exit 0 ;;
    *) echo "Unknown option: $arg (see --help)"; exit 1 ;;
  esac
done

C=$HOME/.config
BACKUP=$C/baseline-backup-$(date +%Y%m%d-%H%M%S)
problems=()

step() { printf '\n\033[1;36m◇ %s\033[0m\n' "$*"; }
note() { printf '  %s\n' "$*"; }
warn() { printf '  \033[1;33m◆ %s\033[0m\n' "$*"; problems+=("$*"); }

# ---------------------------------------------------------------- checks

step "Checking this machine"
if ! command -v omarchy >/dev/null; then
  echo "Baseline runs on Omarchy (https://omarchy.org); install that first."
  exit 1
fi
note "Omarchy $(omarchy version 2>/dev/null | head -1), $(uname -m)"

# fetch <url> <dir>: clone it, or bring an existing checkout up to date.
fetch() {
  local name=${1##*/}
  if [[ -d $2/.git ]]; then
    if git -C "$2" pull --ff-only -q 2>/dev/null; then
      note "${name%.git}: up to date"
    else
      warn "${name%.git} at $2 has its own changes, so it wasn't updated"
    fi
  else
    mkdir -p "$(dirname "$2")"
    git clone -q "$1" "$2" && note "${name%.git}: fetched into $2" || { warn "couldn't fetch $1"; return 1; }
  fi
}

step "Fetching Baseline"
fetch "https://github.com/$OWNER/baseline.git" "$BASELINE_DIR" || exit 1
(( use_omarelay )) && { fetch "https://github.com/$OWNER/omarelay.git" "$OMARELAY_DIR" || use_omarelay=0; }
if (( use_dotfiles )); then
  # Your own settings backup, usually a private repo: needs a GitHub sign-in.
  if ! gh auth status >/dev/null 2>&1; then
    note "Sign in to GitHub so $DOTFILES_REPO can be fetched."
    gh auth login --git-protocol https --web || use_dotfiles=0
  fi
  gh auth setup-git >/dev/null 2>&1 || true
  (( use_dotfiles )) && { fetch "https://github.com/$DOTFILES_REPO.git" "$DOTFILES_DIR" || use_dotfiles=0; }
fi

# ---------------------------------------------------------------- snapshot

step "Snapshot of your system as it is"
added=
command -v python3 >/dev/null || { omarchy pkg add python >/dev/null 2>&1 && added=python; }
note "$(python3 "$BASELINE_DIR/bin/afterlight" snapshot --added=$added)"

# ---------------------------------------------------------------- packages

step "Packages"
omarchy pkg add python imagemagick rsync patch diffutils starship openrgb cava aubio libkeyfinder >/dev/null 2>&1 \
  && note "python, imagemagick, starship, openrgb and friends are in" \
  || warn "some packages didn't install; run: omarchy pkg add python imagemagick rsync patch starship openrgb cava aubio libkeyfinder"

# ---------------------------------------------------------------- the apps Baseline works with

# Baseline is built around these: the home workspaces open them, OmaRelay
# hands off to them, and the Status tab reads them. Each comes from Omarchy's
# own installers. Swap in your own coding and chat apps afterwards if you like.
if (( use_apps )); then
  step "Apps (T3 Code, Grok Bot, Superwhisper, Chrome)"
  [[ -x $HOME/.local/share/t3code/T3-Code.AppImage ]] \
    || omarchy install ai t3 code stable --no-launch || warn "T3 Code didn't install: omarchy install ai t3 code"
  command -v grok-bot >/dev/null || omarchy pkg add grok-bot >/dev/null || warn "Grok Bot didn't install: omarchy pkg add grok-bot"
  command -v superwhisper >/dev/null \
    || omarchy install dictation superwhisper --background || warn "Superwhisper didn't install: omarchy install dictation superwhisper"
  command -v google-chrome-stable >/dev/null \
    || omarchy install browser chrome || warn "Chrome didn't install: omarchy install browser chrome"
  note "all four in place (sign in to each the first time you open it)"
fi

# ---------------------------------------------------------------- your settings

# keep <file-in-home>: back it up before it's replaced.
keep() {
  [[ -e $1 || -L $1 ]] || return 0
  local rel=${1#"$HOME"/}
  mkdir -p "$BACKUP/$(dirname "$rel")"
  cp -a "$1" "$BACKUP/$rel"
}
# restore <path-in-dotfiles> <destination>
restore() {
  local src=$DOTFILES_DIR/$1 dst=$2
  [[ -e $src ]] || return 0
  keep "$dst"
  mkdir -p "$(dirname "$dst")"
  if [[ -d $src ]]; then rsync -a "$src/" "$dst/"; else cp -a "$src" "$dst"; fi
}

if (( use_dotfiles )); then
  step "Your desktop settings (from the dotfiles backup)"
  # Key bindings, input, window look, autostart and night light. Not
  # hyprland.lua or monitors.lua: those belong to each machine's screen.
  for f in bindings.lua input.lua looknfeel.lua autostart.lua hyprsunset.conf; do
    restore "config/hypr/$f" "$C/hypr/$f"
  done
  restore config/omarchy/shell.toml "$C/omarchy/shell.toml"
  restore config/omarchy/extensions "$C/omarchy/extensions"
  restore config/omarchy/afterlight/settings.json "$C/omarchy/afterlight/settings.json"
  restore config/omarchy/afterlight/sources.json "$C/omarchy/afterlight/sources.json"
  restore config/omarchy/backgrounds/afterlight-2049 "$C/omarchy/backgrounds/afterlight-2049"
  restore baseline/mine "$HOME/.local/share/baseline/mine"                 # looks you made
  restore baseline/afterlight-backgrounds "$BASELINE_DIR/backgrounds"      # Afterlight's own pictures
  for p in mortalfish.calendar mortalfish.focus; do
    restore "config/omarchy/plugins/$p" "$C/omarchy/plugins/$p"
  done
  restore config/foot "$C/foot"
  restore config/mimeapps.list "$C/mimeapps.list"
  restore config/chrome-flags.conf "$C/chrome-flags.conf"
  restore state/afterlight "$HOME/.local/state/afterlight"
  note "key bindings, input, menus, foot, default apps, Baseline settings, liked music and your pictures"
fi

step "Terminal prompt"
if ! grep -q '^palette = "baseline"' "$C/starship.toml" 2>/dev/null; then
  keep "$C/starship.toml"
  cp "$BASELINE_DIR/system/starship.toml" "$C/starship.toml"
  note "Baseline's prompt installed"
else
  note "already Baseline's"
fi

# ---------------------------------------------------------------- Baseline

step "Baseline"
mkdir -p "$HOME/.local/bin"
ln -sfn "$BASELINE_DIR/bin/afterlight" "$HOME/.local/bin/afterlight"
afterlight=$HOME/.local/bin/afterlight
# Repair builds everything from the repo: links, hooks, the bar (at the
# bottom, with Baseline on it), plugin copies, Hyprland rules, services.
"$afterlight" repair | sed -n 's/^put back: /  put in: /p'
"$afterlight" look install >/dev/null 2>&1
# The look you had (from settings), or Afterlight on a brand-new machine.
[[ -n $LOOK ]] || LOOK=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("look","afterlight"))' \
  "$C/omarchy/afterlight/settings.json" 2>/dev/null || echo afterlight)
note "setting the look: $LOOK"
"$afterlight" look set "$LOOK" >/dev/null 2>&1 || warn "couldn't set the look $LOOK"
"$afterlight" sync >/dev/null 2>&1 || true
"$afterlight" mode auto >/dev/null 2>&1 || true
note "$("$afterlight" pictures 2>/dev/null) pictures for the built-in looks, from their original sites"

if (( use_omarelay )); then
  step "OmaRelay (voice control)"
  python3 "$OMARELAY_DIR/install.py" >/dev/null && note "installed" || warn "OmaRelay's installer failed: python3 $OMARELAY_DIR/install.py"
fi

# ---------------------------------------------------------------- password parts

step "System parts (asks for your password)"
rule=$BASELINE_DIR/system/udev/99-afterlight-charge-limit.rules
if cmp -s "$rule" /etc/udev/rules.d/99-afterlight-charge-limit.rules; then
  note "charge-limit rule already in place"
elif sudo install -m 0644 "$rule" /etc/udev/rules.d/99-afterlight-charge-limit.rules; then
  sudo udevadm control --reload && sudo udevadm trigger --subsystem-match=power_supply
  note "charge-limit rule installed"
else
  warn "charge-limit rule not installed (needs sudo)"
fi
policy=$BASELINE_DIR/system/chrome/baseline-autoplay.json
if cmp -s "$policy" /etc/opt/chrome/policies/managed/baseline-autoplay.json; then
  note "Chrome autoplay policy already in place"
elif sudo install -D -m 0644 "$policy" /etc/opt/chrome/policies/managed/baseline-autoplay.json; then
  note "Chrome autoplay policy installed (the Deck's mixes start on their own)"
else
  warn "Chrome autoplay policy not installed (needs sudo); the Deck won't mix Beatport songs"
fi

# ---------------------------------------------------------------- finish

step "Self-test"
if python3 -m unittest discover -s "$BASELINE_DIR/tests" -q >/dev/null 2>&1; then
  note "all tests pass"
else
  warn "some of Baseline's tests failed: python3 -m unittest discover -s $BASELINE_DIR/tests"
fi
find "$BASELINE_DIR" -name __pycache__ -type d -prune -exec rm -rf {} + 2>/dev/null

step "Finishing"
hyprctl reload >/dev/null 2>&1 || true
omarchy restart shell >/dev/null 2>&1 || true
"$afterlight" repair >/dev/null 2>&1   # once more, now the shell has restarted
"$afterlight" check | grep -v '^ok' | sed 's/^XX /  ◆ /'
note "$("$afterlight" check --json | python3 -c 'import json,sys; d=json.load(sys.stdin); print(f"{len(d["checks"]) - d["failing"]} of {len(d["checks"])} parts in place")')"

# Anything the apps step couldn't put in place.
missing=()
[[ -x $HOME/.local/share/t3code/T3-Code.AppImage ]] || missing+=("T3 Code (~/.local/share/t3code/T3-Code.AppImage)")
command -v grok-bot >/dev/null || missing+=("Grok Bot")
command -v superwhisper >/dev/null || missing+=("Superwhisper (omarchy default dictation)")
command -v google-chrome-stable >/dev/null || missing+=("Google Chrome (omarchy install browser chrome)")
if (( ${#missing[@]} )); then
  step "Still to install yourself"
  for m in "${missing[@]}"; do note "$m"; done
fi
[[ -d $BACKUP ]] && { step "Backups"; note "files replaced were kept in $BACKUP"; }
if (( ${#problems[@]} )); then
  step "Needs a look"
  for p in "${problems[@]}"; do note "$p"; done
fi
printf '\n\033[1;36m◇ Within baseline.\033[0m Log out and back in to start the home workspaces.\n'
printf '  Changed your mind? afterlight uninstall puts everything back as it was.\n'
