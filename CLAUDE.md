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
  service on Cloudflare (its own repo, `../tracks`, at https://geotrac.cc,
  decided 16 October 2026). This app and antarctique.xyz both read tracks from it.
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

## Tracks (stage 3, 16 October 2026)

- The track service is `../tracks` (its own CLAUDE.md). Settings holds its
  address (UserDefaults) and key (login keychain, account
  `track-service-key`, service `com.webpty.geotag`).
- The key's role decides: an owner key connects Strava, syncs and uploads;
  a reading key reads, and its Mac's imports stay on that Mac.
- `TrackLibrary` keeps every track and its points in
  `~/Library/Application Support/Geotag/Tracks` (`index.json`,
  `points/<id>.json`). Files are replaced whole, never removed. An uploaded
  import stays in the index as `uploaded` and is hidden; the service's copy
  is the one shown.
- A file starting within 60 s of a track already here is the same track.
- Map pictures are OpenStreetMap tiles with no words from CARTO, whose
  addresses, credit and key come from the service (`GET /v1/maps`), with
  the line drawn in orange; drawn once per appearance and kept in
  `Geotag/Maps` as `<id>-osm-<light|dark>.png`. Offline or without a key,
  the row shows the bare line. The credit line under the list is required.
- Never Apple Maps or MapKit: David ruled them out on 16 October 2026 (their
  words cannot be removed). He wants maps with no text.
- The sidebar is an orange gradient with white words, so the window stands
  out (his request, 16 October 2026). The icon is his `Resources/AppIcon.svg`,
  drawn into the Mac's rounded square by `Tools/makeicon.swift`.
- FIT reading is our own (`FITReader`), checked against Garmin's own
  decoder on its sample files. A real fenix 9 file has not been tried yet.

## Architecture

- `GeotagCore` is the domain and knows nothing about the interface.
- `GeotagUI` holds the model and the screens. `GeotagApp` is the entry point
  and nothing else.

## Working on it

- Each stage: describe its design, wait for his approval, then build it.
- Never open the app, or anything else, on his screen without asking first.
- Never delete anything on his computer, not even copies or scratch files
  made here (his rule, 16 October 2026). Ask in the chat first. The one
  exception he gave: each new build replaces the previous Geotag in
  Applications and in `build/`.
- Raise `appVersion` in `Sources/GeotagCore/Version.swift` with every push, and
  start the commit subject with that number.
- Commit locally as often as it is worth. Push only when he says so, each time.
- British spelling. No em dashes.
