#!/usr/bin/env bash
# Builds a DMG of an app: the app, a link to /Applications, and the branded background (rendered by the app itself,
# `--dmg-background`) with the window laid out to match it (DMGBackgroundView in Sources/AgentHuddle/DMGBackground.swift).
#   scripts/make-dmg.sh "dist/Agent Huddle.app" dist/AgentHuddle.dmg
# The window layout (.DS_Store) is written by dmgbuild (MIT), not by scripting Finder, so it works the same headless in CI.
# It is installed into a throwaway virtualenv from scripts/dmg-requirements.txt (wheels pinned by hash); set DMGBUILD to
# use one you already have.
set -euo pipefail
cd "$(dirname "$0")/.."
APP="${1:?usage: make-dmg.sh APP OUT.dmg}"; OUT="${2:?usage: make-dmg.sh APP OUT.dmg}"
[[ -d "$APP" ]] || { echo "make-dmg.sh: no app at $APP" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [[ -z "${DMGBUILD:-}" ]]; then
  python3 -m venv "$WORK/venv"
  "$WORK/venv/bin/pip" install --quiet --disable-pip-version-check --require-hashes --only-binary :all: \
    -r scripts/dmg-requirements.txt
  DMGBUILD="$WORK/venv/bin/dmgbuild"
fi

# The background at 1x and 2x, in one multi-resolution TIFF so Finder picks the sharp one on a Retina screen.
"$APP/Contents/MacOS/AgentHuddle" --dmg-background "$WORK"
tiffutil -cathidpicheck "$WORK/background.png" "$WORK/background@2x.png" -out "$WORK/background.tiff" >/dev/null 2>&1

# Window: 660×400 of content (the rect's height includes the 28 pt title bar); icon centres and sizes as in DMGBackgroundView.
cat > "$WORK/settings.py" <<'SETTINGS'
files = [(defines["app"], "Agent Huddle.app")]
symlinks = {"Applications": "/Applications"}
hide_extension = ["Agent Huddle.app"]
background = defines["background"]
format = "UDZO"
filesystem = "HFS+"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
default_view = "icon-view"
window_rect = ((200, 120), (660, 428))
arrange_by = None
icon_size = 128
text_size = 13
icon_locations = {"Agent Huddle.app": (170, 220), "Applications": (490, 220)}
SETTINGS

rm -f "$OUT"
"$DMGBUILD" -s "$WORK/settings.py" -D app="$APP" -D background="$WORK/background.tiff" "Agent Huddle" "$OUT" >/dev/null
echo "made $OUT"
