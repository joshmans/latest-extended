#!/bin/bash
#
# Builds a Release copy of Latest into dist/Latest.app.
#
#   scripts/build-release.sh
#       Ad-hoc signed. No privileged helper; MacPorts changes ask for the password every time.
#
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" scripts/build-release.sh
#       Signed with your certificate and with the privileged helper embedded, so MacPorts changes
#       can run without a password prompt once the user enables the helper in Latest.
#       "Apple Development: ..." certificates work for local use as well.
#
#   NOTARY_PROFILE=name scripts/build-release.sh
#       Additionally notarizes and staples (needs a Developer ID identity and a profile created with
#       `xcrun notarytool store-credentials name`).
#
# Environment:
#   SIGN_IDENTITY   Code signing identity (name or SHA-1). Default: ad-hoc ("-").
#   TEAM_ID         Overrides the team identifier read from the certificate.
#   EMBED_HELPER=1  Embeds the helper even when ad-hoc signed (only useful for testing the build).
#
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${SIGN_IDENTITY:--}"
OUT="dist"
APP="$OUT/Latest.app"
HELPER_ID="com.max-langer.Latest.helper"

echo "==> Building Latest (Release)"
xcodebuild -project Latest.xcodeproj -scheme Latest -configuration Release -derivedDataPath build \
	CODE_SIGNING_ALLOWED=NO clean build | tail -n 3

# Only replace the app: dist/ may hold other things, such as backups of a previously installed copy.
mkdir -p "$OUT" && rm -rf "$APP"
ditto build/Build/Products/Release/Latest.app "$APP"

# The team identifier decides who may talk to the helper.
TEAM="${TEAM_ID:-}"
if [ -z "$TEAM" ] && [ "$IDENTITY" != "-" ]; then
	TEAM="$(security find-certificate -c "$IDENTITY" -p 2>/dev/null | openssl x509 -noout -subject -nameopt multiline 2>/dev/null | awk -F'= ' '/organizationalUnitName/ {print $2; exit}')"
fi

EMBED=0
if [ -n "$TEAM" ]; then EMBED=1; fi
if [ "${EMBED_HELPER:-0}" = "1" ]; then EMBED=1; fi

if [ "$EMBED" = "1" ]; then
	echo "==> Building privileged helper (team: ${TEAM:-none})"
	GEN="build/helper"
	mkdir -p "$GEN"
	cat > "$GEN/HelperBuildSettings.swift" <<SWIFT
enum HelperBuildSettings { static let teamIdentifier = "${TEAM}" }
SWIFT
	SOURCES=(Latest/Helper/main.swift Latest/Model/Packages/PortAction.swift Latest/Model/Packages/HelperProtocol.swift "$GEN/HelperBuildSettings.swift")
	for ARCH in x86_64 arm64; do
		xcrun swiftc -O -target "$ARCH-apple-macos13.0" -o "$GEN/helper-$ARCH" "${SOURCES[@]}"
	done
	lipo -create "$GEN/helper-x86_64" "$GEN/helper-arm64" -output "$GEN/$HELPER_ID"
	cp "$GEN/$HELPER_ID" "$APP/Contents/MacOS/$HELPER_ID"
	mkdir -p "$APP/Contents/Library/LaunchDaemons"
	cp Latest/Helper/com.max-langer.Latest.helper.plist "$APP/Contents/Library/LaunchDaemons/"
fi

echo "==> Signing with: $IDENTITY"
OPTIONS=()
if [ "$IDENTITY" != "-" ]; then OPTIONS=(--options runtime --timestamp); fi

# Inside out: Sparkle's nested code, the helper, then the app.
find "$APP/Contents/Frameworks" -name "*.xpc" -o -name "*.app" 2>/dev/null | while read -r nested; do
	codesign --force ${OPTIONS[@]+"${OPTIONS[@]}"} --sign "$IDENTITY" "$nested"
done
if [ -d "$APP/Contents/Frameworks/Sparkle.framework" ]; then
	codesign --force ${OPTIONS[@]+"${OPTIONS[@]}"} --sign "$IDENTITY" "$APP/Contents/Frameworks/Sparkle.framework"
fi
if [ "$EMBED" = "1" ]; then
	codesign --force ${OPTIONS[@]+"${OPTIONS[@]}"} --sign "$IDENTITY" --identifier "$HELPER_ID" "$APP/Contents/MacOS/$HELPER_ID"
fi
codesign --force ${OPTIONS[@]+"${OPTIONS[@]}"} --sign "$IDENTITY" --entitlements Latest/Resources/Latest.entitlements "$APP"

echo "==> Verifying"
codesign --verify --deep --strict "$APP"
codesign -dr - "$APP" 2>&1 | grep -E "designated" || true

if [ -n "${NOTARY_PROFILE:-}" ]; then
	echo "==> Notarizing"
	ditto -c -k --keepParent "$APP" "$OUT/Latest.zip"
	xcrun notarytool submit "$OUT/Latest.zip" --keychain-profile "$NOTARY_PROFILE" --wait
	xcrun stapler staple "$APP"
	rm "$OUT/Latest.zip"
fi

echo "==> Done: $APP (helper embedded: $([ "$EMBED" = "1" ] && echo yes || echo no))"
