#!/usr/bin/env bash
# Notarizes dist/Agent Huddle.app, staples it, re-zips it, then builds, signs, notarizes and staples dist/AgentHuddle.dmg.
# Run after scripts/build-app.sh signed the app with a Developer ID. Needs:
#   SIGN_IDENTITY     "Developer ID Application: …" (signs the DMG)
#   NOTARY_KEY_PATH   path to the App Store Connect API key (.p8)
#   NOTARY_KEY_ID, NOTARY_ISSUER_ID
# Prints submission ids and statuses only; never the key.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${SIGN_IDENTITY:?}" "${NOTARY_KEY_PATH:?}" "${NOTARY_KEY_ID:?}" "${NOTARY_ISSUER_ID:?}"
APP="dist/Agent Huddle.app"
ZIP="dist/AgentHuddle.zip"
DMG="dist/AgentHuddle.dmg"

notarize() {   # $1: a .zip or .dmg
  local out id status
  out="$(xcrun notarytool submit "$1" --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" \
          --wait --timeout 30m --output-format json)"
  id="$(jq -r '.id' <<<"$out")"; status="$(jq -r '.status' <<<"$out")"
  echo "notarization of $(basename "$1"): $status (submission $id)"
  if [[ "$status" != "Accepted" ]]; then
    xcrun notarytool log "$id" --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" || true
    exit 1
  fi
}

codesign --verify --strict "$APP"
SIG="$(codesign -dv "$APP" 2>&1)"   # read it whole: a grep -q on a pipe would cut codesign off (and pipefail would fail)
[[ "$SIG" == *"Authority=Developer ID Application"* ]] || { echo "notarize.sh: the app is not signed with a Developer ID" >&2; exit 1; }
if [[ -n "${APPLE_TEAM_ID:-}" ]]; then   # the certificate must belong to this team
  [[ "$(sed -n 's/^TeamIdentifier=//p' <<<"$SIG")" == "$APPLE_TEAM_ID" ]] || { echo "notarize.sh: the signing team is not APPLE_TEAM_ID" >&2; exit 1; }
fi

# 1. The app: submit the zip, staple the ticket to the app, zip it again so the download carries the ticket.
rm -f "$ZIP"; (cd dist && ditto -c -k --keepParent "Agent Huddle.app" AgentHuddle.zip)
notarize "$ZIP"
xcrun stapler staple "$APP"
rm -f "$ZIP"; (cd dist && ditto -c -k --keepParent "Agent Huddle.app" AgentHuddle.zip)
spctl --assess --type execute --verbose=2 "$APP"

# 2. The DMG: the app and a link to /Applications to drag it onto.
STAGE="$(mktemp -d)/Agent Huddle"; mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Agent Huddle.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Agent Huddle" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
notarize "$DMG"
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
echo "notarized: $ZIP and $DMG"
