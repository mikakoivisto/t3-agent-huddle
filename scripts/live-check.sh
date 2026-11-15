#!/usr/bin/env bash
# Live check against the LOCAL T3 (127.0.0.1) using a throwaway pairing code, then clean up everything it created.
#   scripts/live-check.sh [huddle-probe args…]      e.g.  scripts/live-check.sh --huddle
# - mints one pairing credential (read+operate, 10 min) and revokes it on exit;
# - the probe signs in through the advertised OAuth flow (approval = pairing code) and makes read-only calls, except
#   `--send-check STEER_ID QUESTION_ID`, which SENDS a steer, a queued message and a written answer to those two threads
#   (make throwaway ones for it); `--send-raw THREAD queue|steer` sends one message; `--remote-mcp ADDRESS` signs in to
#   that address's T3 over https (the pairing code is minted HERE, so use this Mac's own address) and `--remote-send STEER QUESTION`
#   then sends a steer, a queued message and a written answer there;
# - revokes the OAuth session(s) it created (diff of `t3 auth session list` before/after);
# - the pairing secret lives in a 0600 temp file and an env var, never argv or a log.
set -euo pipefail
cd "$(dirname "$0")/.."
T3="${T3_BIN:-$HOME/.t3/bin/t3}"
swift build --product huddle-probe >/dev/null
umask 077   # every file this script creates is private to you
WORK="$(mktemp -d)"; chmod 700 "$WORK"
# Only sessions labelled "huddle…" count as ours (the pairing labels below and the OAuth client name), so a login of yours that
# happens while a check runs is never revoked.
sessions() { "$T3" auth session list --json 2>/dev/null | jq -r '.[] | select((.client.label // "") | test("huddle"; "i")) | .sessionId' | sort; }
sessions > "$WORK/before"
PID=""
cleanup() {
  trap - EXIT INT TERM
  set +e   # keep going whatever fails: every credential gets its own revoke attempt
  [ -n "$PID" ] && "$T3" auth pairing revoke "$PID" >/dev/null 2>&1 && echo "revoked pairing credential ${PID:0:8}"
  sessions > "$WORK/after"
  for id in $(comm -13 "$WORK/before" "$WORK/after"); do
    "$T3" auth session revoke "$id" >/dev/null 2>&1 && echo "revoked session ${id:0:8}"
  done
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
"$T3" auth pairing create --scope orchestration:read --scope orchestration:operate \
  --label "huddle-live-check" --ttl 10m --json > "$WORK/pair.json" 2>/dev/null
PID="$(jq -r .id "$WORK/pair.json")"
HUDDLE_PAIRING_TOKEN="$(jq -r .credential "$WORK/pair.json")" .build/debug/huddle-probe "$@"
