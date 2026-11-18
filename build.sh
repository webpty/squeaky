#!/bin/zsh
# Builds Geotag into build/ and, with "install", copies it to /Applications.
# With "dmg", also puts it in a disk image for the family's Macs:
# build/Geotag <version>.dmg. Built for both Apple chips and Intel (David,
# 6 November 2026, bringing Intel back); the app's Download page makes a
# disk image for one kind of Mac only.
# Needs only the command line developer tools, no Xcode.
#
#   ./build.sh [install | dmg]
set -e
cd "$(dirname "$0")"

name="Geotag"; display="Geotag"; bundle="com.webpty.geotag"
version=$(grep 'let appVersion' Sources/GeotagCore/Version.swift | sed 's/.*"\(.*\)".*/\1/')
mkdir -p build

echo "Building $display $version"
# Each chip's build copied out as soon as it is made: newer Swift puts both in
# the same place (.build/out/Products/Release), and the old per-chip folders
# kept a copy from 17 November 2026 that was shipped as 0.31.5 (18 November).
for arch in arm64 x86_64; do
  swift build -c release --product "$name" --triple $arch-apple-macosx14.0
  bin=$(swift build -c release --product "$name" --triple $arch-apple-macosx14.0 --show-bin-path)
  cp "$bin/$name" "build/$name-$arch"
done
binary="build/$name-universal"
lipo -create "build/$name-arm64" "build/$name-x86_64" -output "$binary"


app="build/$display.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/$name"

echo "Adding ExifTool"
cp -R Vendor/ExifTool "$app/Contents/Resources/ExifTool"
# The pictures for "Set time and date in camera", from the cameras' manuals.
cp -R Resources/CameraClock "$app/Contents/Resources/CameraClock"

echo "Drawing the icon"
mkdir -p build
swiftc -O Tools/makeicon.swift -o build/makeicon
./build/makeicon Resources/AppIcon.svg build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$app/Contents/Resources/AppIcon.icns"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleDisplayName</key><string>$display</string>
  <key>CFBundleExecutable</key><string>$name</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
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
elif [[ "$1" == "dmg" ]]; then
  # The app beside a shortcut to Applications, to drag it onto.
  stage="build/dmg"
  rm -rf "$stage"
  mkdir -p "$stage"
  cp -R "$app" "$stage/"
  ln -s /Applications "$stage/Applications"
  image="build/$display $version.dmg"
  hdiutil create -quiet -volname "$display" -srcfolder "$stage" -ov -format UDZO "$image"
  echo "Built $image"
else
  echo "Built $app"
fi
