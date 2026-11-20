# Rebuilding, for the repo

Not for David. He never needs a command.

```
./build.sh            # writes build/Squeaky.app
./build.sh install    # and copies it to /Applications
```

Only the command line developer tools are needed (Command Line Tools for
Xcode 26.6, Swift 6.3, builds it on both Macs). On a Mac updated from old
tools, `softwareupdate` can leave the 2023
`PackageDescription.swiftmodule/*.private.swiftinterface` files behind, and
every manifest then fails to link (`Package.__allocating_init` undefined).
Move those two files out (done on the second Mac, 1 November 2026; they sit
in `/Library/Developer/CLT-old-2023`). There is no Xcode project:
`build.sh` compiles with Swift Package Manager, assembles the bundle by hand,
writes `Info.plist` and signs the bundle ad hoc.

ExifTool is kept unpacked in `Vendor/ExifTool` (the script, `lib` and its
README, version 13.59, checked against exiftool.org's SHA-256).

The stage 2 location test, which only reads the samples folder:

```
Tools/gps-test.sh <samples folder> <output folder>
```

The self-test, with its files in a scratch folder, Garmin's sample FIT
files in another, and a local copy of the track service holding the test
keys (see `../tracks/CLAUDE.md`):

```
SQUEAKY_SCRATCH=<scratch> swift run -c release SelfTest <fit folder> http://127.0.0.1:8790
```

Raise `appVersion` in `Sources/SqueakyCore/Version.swift` with every push. The
build script reads that line for the bundle version, and the number shows in
the corner of the sidebar.
