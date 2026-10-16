# Geotag

A Mac app for David and his family. It matches photos from an SD card to
David's watch track, writes the location into copies of the photos, saves them
on the Mac per person and uploads them to his NAS through a queue that survives
lost connections. Built for an Antarctica trip with patchy internet. Shared with
family members, never sold. The full brief is `geotag-app-brief.md`, given on
16 October 2026; it is built in nine stages.

## Stack

- SwiftUI, built as a plain `.app` with `./build.sh`, like Photo Flatten and
  Photo Dedupe. Not his usual React, HeroUI Pro and Cloudflare stack: the job
  needs SD cards, local files and the NAS. He accepted the plain Mac look on
  16 October 2026 rather than putting a HeroUI Pro interface in the window.
- No Xcode on this Mac. Swift Package Manager and the command line tools only.
- Ad hoc signing, no Apple Developer account. Each family member approves the
  first launch under Privacy & Security.
- The only third-party code is ExifTool, bundled in the app (from stage 2).
- Minimum macOS 14.
- Repo: github.com/webpty/geotag, private. Commits as webpty with the GitHub
  no-reply address.

## Tracks come from the track service, never from Strava directly

- There is exactly one Strava connection, and it belongs to a separate track
  service on Cloudflare (its own repo, Cloudflare's free address, decided
  16 October 2026). This app and antarctique.xyz both read tracks from it.
- The brief's Strava Client ID and Secret settings are replaced by the
  service's address and key. Connect and Disconnect stay in Settings and work
  through the service.
- Never change antarctique.xyz from this project. At most write a report for
  its own session. Changeover order: antarctique.xyz stops its own Strava sync
  before the service connects.

## Rules the app lives by

- Never modify the SD card. Never change a date or a file name.
- Nothing is hardcoded: credentials, addresses and thresholds are settings.
  Credentials live in the Keychain only.
- A photo with no track point within the maximum gap, or from a camera with no
  offset set, goes to the review list. Never guess a position.
- No emoji anywhere in the interface.

## Writing the location (proved in stage 2, 16 October 2026)

- ExifTool 13.59 lives in `Vendor/ExifTool` and runs on the Mac's own
  `/usr/bin/perl`. `Tools/gps-test.sh` holds the exact arguments.
- Name the group on every tag: `-GPS:GPSLatitude=` and so on. Left to choose,
  ExifTool also writes XMP into a CR3 with no S or W, which other software
  reads as north and east.
- Clear the old location first (`-GPS:all= -XMP-exif:GPS*=`), so nothing of an
  old position stays mixed with the new one.
- Write with `-P`, then copy `FileCreateDate` and `FileModifyDate` back from
  the original: ExifTool's rewrite gives the copy a new creation date.
- GPS date and time are UTC: the capture time less `OffsetTimeOriginal`.
- Prove each copy: `ImageDataHash` equals the original's, every other tag is
  unchanged, and ImageIO opens it and reads the position.

## Architecture

- `GeotagCore` is the domain and knows nothing about the interface.
- `GeotagUI` holds the model and the screens. `GeotagApp` is the entry point
  and nothing else.

## Working on it

- Each stage: describe its design, wait for his approval, then build it.
- Never open the app, or anything else, on his screen without asking first.
- Raise `appVersion` in `Sources/GeotagCore/Version.swift` with every push, and
  start the commit subject with that number.
- Commit locally as often as it is worth. Push only when he says so, each time.
- British spelling. No em dashes.
