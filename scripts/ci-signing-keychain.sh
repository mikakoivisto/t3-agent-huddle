#!/usr/bin/env bash
# CI only: puts the Developer ID certificate in a throwaway keychain and the notarization key in a temp file.
#   setup:   reads MACOS_CERT_P12 (base64), MACOS_CERT_PASSWORD, NOTARY_KEY_P8 (base64); writes SIGN_IDENTITY and
#            NOTARY_KEY_PATH to $GITHUB_ENV.
#   cleanup: deletes the keychain and the key file.
# The secrets go only to files under $RUNNER_TEMP and to `security`; nothing is echoed.
set -euo pipefail
KC="$RUNNER_TEMP/signing.keychain-db"
KEY="$RUNNER_TEMP/notary.p8"
case "${1:-}" in
  setup)
    : "${MACOS_CERT_P12:?}" "${MACOS_CERT_PASSWORD:?}" "${NOTARY_KEY_P8:?}"
    KC_PASS="$(openssl rand -hex 24)"
    P12="$RUNNER_TEMP/cert.p12"
    umask 077
    base64 --decode <<<"$MACOS_CERT_P12" > "$P12"
    base64 --decode <<<"$NOTARY_KEY_P8" > "$KEY"
    security create-keychain -p "$KC_PASS" "$KC"
    security set-keychain-settings -lut 3600 "$KC"
    security unlock-keychain -p "$KC_PASS" "$KC"
    security import "$P12" -k "$KC" -P "$MACOS_CERT_PASSWORD" -T /usr/bin/codesign -f pkcs12 >/dev/null
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KC_PASS" "$KC" >/dev/null
    security list-keychains -d user -s "$KC" $(security list-keychains -d user | tr -d '"')
    rm -f "$P12"
    ID="$(security find-identity -v -p codesigning "$KC" | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"
    [[ -n "$ID" ]] || { echo "ci-signing-keychain.sh: no Developer ID Application identity in the certificate" >&2; exit 1; }
    { echo "SIGN_IDENTITY=$ID"; echo "NOTARY_KEY_PATH=$KEY"; } >> "$GITHUB_ENV"
    echo "signing identity ready: ${ID%% (*}"
    ;;
  cleanup)
    security delete-keychain "$KC" 2>/dev/null || true
    rm -f "$KEY"
    ;;
  *) echo "usage: $0 setup|cleanup" >&2; exit 2 ;;
esac
