#!/bin/bash
# Assemble SessionsStats.app à partir des sources Swift, sans Xcode.
set -e
cd "$(dirname "$0")"
SRC="$(pwd)"

APP="SessionsStats.app"

# Le bundle est assemblé hors du dossier de travail : sur un Bureau synchronisé
# avec iCloud, le système repose sans cesse com.apple.FinderInfo, ce qui fait
# échouer la signature avec « resource fork […] not allowed ».
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
BUNDLE="$STAGE/$APP"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

swiftc -O Sources/*.swift -o "$BUNDLE/Contents/MacOS/SessionsStats" \
    -target arm64-apple-macos14.0 \
    -framework SwiftUI -framework EventKit -framework ServiceManagement

cp Info.plist "$BUNDLE/Contents/Info.plist"

# La signature est indispensable : sans elle, TCC refuse l'accès à Calendrier et
# Rappels, et SMAppService refuse l'ouverture au démarrage. Les droits déclarés
# dans SessionsStats.entitlements le sont tout autant — voir le README.
codesign -s - --force --options runtime \
    --entitlements SessionsStats.entitlements "$BUNDLE"
codesign --verify --strict "$BUNDLE"

INSTALLED="/Applications/$APP"
if [ -d "$INSTALLED" ]; then
    pkill -f "$INSTALLED/Contents/MacOS/SessionsStats" 2>/dev/null || true
    rm -rf "$INSTALLED"
    ditto "$BUNDLE" "$INSTALLED"
    echo "Installé : $INSTALLED  (relancez-la depuis le Finder)"
else
    ditto "$BUNDLE" "$SRC/$APP"
    echo "Construit : $SRC/$APP  (déplacez-la dans /Applications)"
fi
