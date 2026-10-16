# Rebuilding, for the repo

Not for David. He never needs a command.

```
./build.sh            # writes build/Geotag.app
./build.sh install    # and copies it to /Applications
```

Only the command line developer tools are needed. There is no Xcode project:
`build.sh` compiles with Swift Package Manager, assembles the bundle by hand,
writes `Info.plist` and signs the bundle ad hoc.

Raise `appVersion` in `Sources/GeotagCore/Version.swift` with every push. The
build script reads that line for the bundle version, and the number shows in
the corner of the sidebar.
