#!/bin/zsh
# Builds Geotag into build/ and, with "install", copies it to /Applications.
# Needs only the command line developer tools, no Xcode.
#
#   ./build.sh [install]
set -e
cd "$(dirname "$0")"

name="Geotag"; display="Geotag"; bundle="com.webpty.geotag"
version=$(grep 'let appVersion' Sources/GeotagCore/Version.swift | sed 's/.*"\(.*\)".*/\1/')

echo "Building $display $version"
swift build -c release --product "$name"

app="build/$display.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp ".build/release/$name" "$app/Contents/MacOS/$name"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleDisplayName</key><string>$display</string>
  <key>CFBundleExecutable</key><string>$name</string>
  <key>CFBundleIdentifier</key><string>$bundle</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$display</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$version</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.photography</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSSupportsSuddenTermination</key><false/>
</dict>
</plist>
PLIST

printf 'APPL????' > "$app/Contents/PkgInfo"

echo "Signing"
codesign --force --sign - --identifier "$bundle" "$app" >/dev/null 2>&1

if [[ "$1" == "install" ]]; then
  rm -rf "/Applications/$display.app"
  cp -R "$app" "/Applications/$display.app"
  echo "Installed /Applications/$display.app"
else
  echo "Built $app"
fi
