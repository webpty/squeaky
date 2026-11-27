#!/bin/zsh
# Builds Squeaky for App Store Connect and uploads it for TestFlight (0.34.22).
# The version comes from Sources/SqueakyCore/Version.swift; the build number is
# the number of commits, so it rises with every upload. Signing and the upload
# go through the Apple ID signed in to Xcode: no key or token.
#   Phone/upload_testflight.sh          archive and upload
#   ARCHIVE_ONLY=1 Phone/upload_testflight.sh   archive only
set -e
cd "${0:A:h}/.."
version=$(sed -nE 's/.*appVersion = "([^"]+)".*/\1/p' Sources/SqueakyCore/Version.swift)
build=$(git rev-list --count HEAD)
archive="build/testflight/Squeaky-$version-$build.xcarchive"
echo "Squeaky $version, build $build"
xcodebuild -project Phone/Squeaky.xcodeproj -scheme SqueakyPhone -configuration Release \
  -destination "generic/platform=iOS" -archivePath "$archive" -allowProvisioningUpdates \
  DEVELOPMENT_TEAM=KMB36MW5KY CODE_SIGN_STYLE=Automatic PRODUCT_BUNDLE_IDENTIFIER=geotrac.squeaky \
  MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build" archive | grep -E "error:|ARCHIVE (SUCCEEDED|FAILED)"
[[ -n "$ARCHIVE_ONLY" ]] && exit 0
options=build/testflight/ExportOptions.plist
cat > "$options" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>app-store-connect</string>
<key>destination</key><string>upload</string>
<key>teamID</key><string>KMB36MW5KY</string>
<key>signingStyle</key><string>automatic</string>
<key>manageAppVersionAndBuildNumber</key><false/>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist "$options" \
  -exportPath build/testflight/export -allowProvisioningUpdates 2>&1 | grep -E "error|Upload|EXPORT (SUCCEEDED|FAILED)|uploaded"
