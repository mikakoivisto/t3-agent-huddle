#!/usr/bin/env bash
# Regenerates demo/ from two fake T3 machines ("Mika’s MacBook Pro" = this Mac, "Mika’s Mac mini" = a linked one).
# Loopback only; touches nothing under ~/.t3, no Keychain, no real T3. All data is synthetic.
# Needs: swift, ffmpeg. No Screen Recording permission required (the app renders its own views to bitmaps).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build >/dev/null
BIN=.build/debug/AgentHuddle
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

rm -rf demo/stills demo/compare demo/agent-huddle-demo.mp4
mkdir -p demo/stills

# 1. Offscreen stills of every UI state (the SwiftUI views through ImageRenderer).
"$BIN" --snapshot demo/stills >/dev/null 2>&1

# 2. Scripted run of the real NSPanel against the fake machines -> frames (+ stills that need the real window) -> mp4.
"$BIN" --record "$WORK/rec" >/dev/null 2>&1
ffmpeg -loglevel error -y -framerate 10 -i "$WORK/rec/frames/f%04d.png" \
  -c:v libx264 -preset slow -pix_fmt yuv420p -crf 22 -movflags +faststart demo/agent-huddle-demo.mp4
# The inline preview in README.md: the first 30 s as a small looping GIF (GitHub does not play a repo mp4 inline).
ffmpeg -loglevel error -y -t 30 -i demo/agent-huddle-demo.mp4 \
  -vf "fps=10,scale=720:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=96[p];[b][p]paletteuse=dither=bayer:bayer_scale=4" demo/agent-huddle-preview.gif
cp "$WORK"/rec/stills/*.png demo/stills/

# 3. The app icon, 512 px.
"$BIN" --icon "$WORK/icon-1024.png" >/dev/null 2>&1
ffmpeg -loglevel error -y -i "$WORK/icon-1024.png" -vf scale=512:512 demo/stills/29-app-icon.png
echo "demo/ regenerated: $(ls demo/stills | wc -l | tr -d ' ') stills, $(ffprobe -v error -show_entries format=duration -of csv=p=0 demo/agent-huddle-demo.mp4) s video"
