#!/bin/bash
# Sends the signed app and command-line tool in ./build to Apple's notary service, then staples the
# ticket to the app so it opens without a warning, even offline. Run scripts/build-app.sh with a
# Developer ID SIGN_IDENTITY first.
#
# Credentials, one of:
#   NOTARY_PROFILE=icloudphotos scripts/notarize.sh
#       a profile saved once with: xcrun notarytool store-credentials icloudphotos
#   NOTARY_KEY_PATH=AuthKey_ABC123.p8 NOTARY_KEY_ID=ABC123 NOTARY_ISSUER_ID=<uuid> scripts/notarize.sh
#       an App Store Connect API key (what the release workflow uses)
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/iCloud Photos Downloader.app"
CLI="build/icloudpd-swift"

if [ -n "${NOTARY_PROFILE:-}" ]; then
  AUTH=(--keychain-profile "$NOTARY_PROFILE")
elif [ -n "${NOTARY_KEY_PATH:-}" ]; then
  AUTH=(--key "$NOTARY_KEY_PATH" --key-id "${NOTARY_KEY_ID:?}" --issuer "${NOTARY_ISSUER_ID:?}")
else
  echo "error: set NOTARY_PROFILE, or NOTARY_KEY_PATH, NOTARY_KEY_ID and NOTARY_ISSUER_ID." >&2
  exit 1
fi

# Catch what Apple would reject anyway, before waiting on the upload.
for item in "$APP" "$CLI"; do
  info="$(codesign -dvv "$item" 2>&1)"
  if ! grep -q '^Authority=Developer ID Application' <<<"$info"; then
    echo "error: $item isn't signed with a Developer ID Application certificate." >&2
    exit 1
  fi
  if ! grep -q 'flags=.*runtime' <<<"$info"; then
    echo "error: $item isn't signed with the hardened runtime." >&2
    exit 1
  fi
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/upload"
ditto "$APP" "$WORK/upload/$(basename "$APP")"
cp "$CLI" "$WORK/upload/"
ditto -c -k --keepParent "$WORK/upload" "$WORK/upload.zip"

echo "Sending to Apple's notary service. This usually takes a few minutes."
RESULT="$(xcrun notarytool submit "$WORK/upload.zip" "${AUTH[@]}" --wait --timeout 1h --output-format json)"
echo "$RESULT"
ID="$(plutil -extract id raw -o - - <<<"$RESULT")"
STATUS="$(plutil -extract status raw -o - - <<<"$RESULT")"
if [ "$STATUS" != "Accepted" ]; then
  echo "error: Apple's notary service answered \"$STATUS\". Its log:" >&2
  xcrun notarytool log "$ID" "${AUTH[@]}" >&2 || true
  exit 1
fi

# A bare command-line tool can't carry a ticket; Gatekeeper looks it up online instead.
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"
echo "Notarized: $APP and $CLI"
