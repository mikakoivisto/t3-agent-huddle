#!/usr/bin/env bash
# Live check of the "another machine" approvals path, using THIS Mac as the other machine (its T3 reached at its own https address).
#   scripts/live-check-remote.sh https://this-mac.tailnet.ts.net
#   HUDDLE_APPROVAL_THREAD=<id> HUDDLE_APPROVAL_ITEM=<turn-item:runtime-request:…> HUDDLE_APPROVAL_DECISION=accept|decline \
#     scripts/live-check-remote.sh https://this-mac.tailnet.ts.net        # also decides ONE throwaway request
# - mints two pairing credentials with `t3 auth pairing create` (10 min): read+operate (as the remote machine would make it) and
#   read+access:read (for discovery on this Mac); revokes both on exit;
# - revokes every session it created (diff of `t3 auth session list` before/after), even on failure;
# - secrets live in a 0700 temp dir and in env vars, never argv or a log. Run only when asked (AGENTS.md).
set -euo pipefail
cd "$(dirname "$0")/.."
ADDRESS="${1:?usage: live-check-remote.sh https://address}"
T3="${T3_BIN:-$HOME/.t3/bin/t3}"
swift build --product huddle-probe >/dev/null
umask 077   # every file this script creates is private to you
WORK="$(mktemp -d)"; chmod 700 "$WORK"
# Only sessions labelled "huddle…" count as ours (the pairing labels below and the OAuth client name), so a login of yours that
# happens while a check runs is never revoked.
sessions() { "$T3" auth session list --json 2>/dev/null | jq -r '.[] | select((.client.label // "") | test("huddle"; "i")) | .sessionId' | sort; }
sessions > "$WORK/before"
PIDS=()
cleanup() {
  trap - EXIT INT TERM
  set +e   # keep going whatever fails: every credential gets its own revoke attempt
  for p in "${PIDS[@]:-}"; do [ -n "$p" ] && "$T3" auth pairing revoke "$p" >/dev/null 2>&1 && echo "revoked pairing credential ${p:0:8}" || true; done
  sessions > "$WORK/after"
  for id in $(comm -13 "$WORK/before" "$WORK/after"); do
    "$T3" auth session revoke "$id" >/dev/null 2>&1 && echo "revoked session ${id:0:8}"
  done
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
ENV_ID="$(curl -s --max-time 5 http://127.0.0.1:3773/.well-known/t3/environment | jq -r .environmentId)"
"$T3" auth pairing create --scope orchestration:read --scope orchestration:operate --label "huddle-remote-check" --ttl 10m --json > "$WORK/remote.json" 2>/dev/null
PIDS+=("$(jq -r .id "$WORK/remote.json")")
"$T3" auth pairing create --scope orchestration:read --scope access:read --label "huddle-remote-check-discovery" --ttl 10m --json > "$WORK/disc.json" 2>/dev/null
PIDS+=("$(jq -r .id "$WORK/disc.json")")
HUDDLE_REMOTE_PAIRING="$(jq -r .credential "$WORK/remote.json")" HUDDLE_DISCOVERY_PAIRING="$(jq -r .credential "$WORK/disc.json")" \
  .build/debug/huddle-probe --remote "$ADDRESS" "$ENV_ID"
