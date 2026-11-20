#!/bin/zsh
# Builds Squeaky for the iPhone, signed with the personal Apple ID team (no
# iCloud entitlement; runs for 7 days), and installs it on the iPhone
# connected by cable. Usage: Phone/install_phone.sh
set -e
cd "$(dirname "$0")"
TEAM=$(defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier 2>/dev/null | grep -m1 -E 'teamID' | sed -E 's/.*= "?([A-Z0-9]+)"?;/\1/')
[ -z "$TEAM" ] && TEAM=$(defaults read com.apple.dt.Xcode IDEProvisioningTeams 2>/dev/null | grep -m1 -E 'teamID' | sed -E 's/.*= "?([A-Z0-9]+)"?;/\1/')
[ -z "$TEAM" ] && TEAM=$(security find-certificate -a -c "Apple Development" -p 2>/dev/null | openssl x509 -noout -subject 2>/dev/null | grep -o -E 'OU ?= ?[A-Z0-9]{10}' | head -1 | grep -o -E '[A-Z0-9]{10}$')
[ -z "$TEAM" ] && { echo "NO_TEAM"; exit 2; }
# PHONE=<id> picks the phone on the cable when another is about over Wi-Fi.
PHONE=${PHONE:-$(xcrun devicectl list devices 2>/dev/null | awk '/iPhone/ && (/ connected / || /available \(paired\)/) && /physical/ {for(i=1;i<=NF;i++) if ($i ~ /^[0-9A-F-]{25,}$/) {print $i; exit}}')}
[ -z "$PHONE" ] && { echo "NO_PHONE"; exit 3; }
BUNDLE=${BUNDLE:-com.webpty.squeaky}
VERSION=$(sed -n 's/.*appVersion = "\(.*\)".*/\1/p' ../Sources/SqueakyCore/Version.swift)
xcodebuild -project Squeaky.xcodeproj -scheme SqueakyPhone -configuration Release \
  -destination "id=$PHONE" -derivedDataPath ../build/phone -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Automatic PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE" \
  MARKETING_VERSION="$VERSION" build 2>&1 | grep -E "error:|BUILD"
xcrun devicectl device install app --device "$PHONE" ../build/phone/Build/Products/Release-iphoneos/Squeaky.app
