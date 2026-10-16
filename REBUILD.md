# Rebuilding, for the repo

Not for David. He never needs a command.

```
./build.sh            # writes build/Geotag.app
./build.sh install    # and copies it to /Applications
```

Only the command line developer tools are needed. There is no Xcode project:
`build.sh` compiles with Swift Package Manager, assembles the bundle by hand,
writes `Info.plist` and signs the bundle ad hoc.

ExifTool is kept unpacked in `Vendor/ExifTool` (the script, `lib` and its
README, version 13.59, checked against exiftool.org's SHA-256).

The stage 2 location test, which only reads the samples folder:

```
Tools/gps-test.sh <samples folder> <output folder>
```

Raise `appVersion` in `Sources/GeotagCore/Version.swift` with every push. The
build script reads that line for the bundle version, and the number shows in
the corner of the sidebar.
