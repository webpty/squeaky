# Geotag

A Mac app for David and his family. It matches photos from an SD card to
David's watch track, writes the location into copies of the photos, saves them
on the Mac per person and uploads them to his NAS through a queue that survives
lost connections. Built for an Antarctica trip with patchy internet. Shared with
family members, never sold. The full brief is `geotag-app-brief.md`, given on
16 October 2026; it is built in nine stages.

- David's instructions override the brief wherever they clash (16 October
  2026). Follow them and record them here; the brief is only the start.

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

## The keychain asks after every update (decided 16 October 2026)

- The service key stays in the login keychain, as the brief asks. Every new
  build is a stranger to the keychain (no Apple-issued signature, so its
  partition is the build's own hash), and the Mac asks for the password,
  twice, on the first launch of each new version. David chose to live with
  it over a key file or Xcode with his Apple ID. A home-made signing
  certificate would not help: only an Apple-issued one gives a stable
  partition. Do not propose it again.

## People and cameras (stage 4, 16 October 2026)

- `PeopleBook` in `~/Library/Application Support/Geotag/people.json`, per Mac,
  seeded on first launch with David, Amanda, Patrick and Gilbert and the five
  cameras David listed: his R5 Mark II and R7, Amanda's R5 Mark II (zone
  from the photo), Gilbert's COOLPIX P950 and Patrick's EOS REBEL T3i (zone
  not set; the T3i's model is a guess until one of his photos is read).
- A photo finds its camera by owner and model, the model as EXIF records it
  ("Canon EOS R5m2", not "R5 Mark II").
- A camera is ready for matching only with its zone (from the photo, or a
  fixed zone for cameras that write none) and its clock offset set.
  Offset is seconds the clock is ahead; negative is behind.
- The NAS folder is kept as share plus path ("homes/patrick/Antarctica"), not
  a /Volumes path, so it does not depend on where a Mac mounts the share.
- ExifTool is inside the app (`Contents/Resources/ExifTool`) from 0.5.0.
  Read camera details with it: ImageIO misses `OffsetTimeOriginal` in Canon
  CR3 files.
- Appearance is applied with `NSApp.appearance`; `preferredColorScheme` alone
  did not switch the window back and forth reliably.

## Importing a card (stage 5, 16 October 2026)

- A card is any mounted disk with a DCIM folder (`CardWatcher`). With "Open
  Geotag when a card is inserted" on (the default, `openOnCard`), Geotag is
  in Login Items (`SMAppService.mainApp`), starts with no window at login,
  and comes forward on a card: `Windows.bringForward` reopens the window by
  opening the running app again.
- `start()` runs once per launch; a reopened window must not start a second
  card watcher or timer.
- `PhotoScanner` lists photo files (hidden folders left out) and reads time,
  sub-seconds, zone and model through ExifTool, 100 files at a time. It only
  reads; the self-test checks the card's files are unchanged.
- A card Geotag has seen is read straight away for last time's person
  (`cardPeople` in UserDefaults, keyed by the card's volume id); only a new
  card asks whose it is. The Person tile's pencil changes it (David,
  16 October 2026).
- A photo counts as imported before when name, size and time taken (with
  sub-seconds) match the person's history (`History/<person id>.json`).
- The self-test can attach a disk image with `-nobrowse` to prove a card
  arriving and leaving (`GEOTAG_MOUNT_TEST=1`); nothing shows in Finder.

## Matching and alignment (stage 6, 16 October 2026)

- The real moment: the camera clock's reading (with sub-seconds), less its
  zone (from the photo, or the camera's fixed zone at that date), less the
  camera's offset (seconds ahead). `Moments` in `Matching.swift`.
- `TrackTimeline` holds every track's points; a moment between two points
  both within the maximum gap is shared out in proportion to the time,
  altitude too; otherwise the nearest point within the gap; otherwise
  review. The gap is a setting (Matching card), 2 minutes to start.
- A photo with a location of its own keeps it ("Own location"); the watch is
  for photos without one (David's decision in the stage 6 plan).
- Review reasons: no track within the gap, offset not set, zone not set, no
  zone in the photo, no time, camera not on the list. A photo in review is
  imported only when "Without location" is ticked for it.
- The alignment window (`AlignmentView`) slides one camera's photos up to
  15 minutes either way along the track on a map you drag and zoom
  (`SlippyMap`, CARTO tiles, six fetched at a time, kept while Geotag runs);
  "Use this offset" saves it as the camera's offset, and everything is
  matched again.
- Off-screen pictures of the screens: `GEOTAG_VIEWER=1` and `GEOTAG_ALIGN=1`
  with `GEOTAG_MAP_KEY` (the CARTO key from `../tracks/.keys/carto.key`).
  A probe view needs a background of its own or it draws black.

## Cards held, dates, tiles (0.9.0, 16 October 2026)

- `CardGuard` (DiskArbitration) refuses the Mac's own opening of every
  external, removable or ejectable FAT/exFAT disk, opens it itself with
  `rdonly,nobrowse`, and keeps it only if it has a DCIM folder; any other
  disk is closed and opened again as usual. Cards open before Geotag starts
  are taken over the same way unless another app holds them. There is no
  Release button (David's decision): to see a card in Finder, quit Geotag.
- The Mac may answer "busy" to Geotag's own opening and open the card all
  the same; check whether it is open before calling it a failure.
- Eject forces the whole disk closed (`kDADiskUnmountOptionForce |
  kDADiskUnmountOptionWhole`, on the whole disk, never a partition) and
  ejects it; under a second, open files or not.
- Test the guard only on a disk image named GTTEST with a GEOTAG_TEST
  folder (`GEOTAG_GUARD_TEST=1`), never with a DCIM folder: Geotag on
  David's Mac would take a DCIM test disk for a real card.
- Photos come only from cards: Choose folder is gone (David, 16 October).
- Dates and times follow Settings (`When`): date order and 24-hour clock,
  else the Mac's own. A chosen format uses the language without the Mac's
  "24-hour time" override, or a 12-hour choice would be ignored.
- Copies of JPEG photos are saved ending ".jpg" (`CopyName`), raw and HEIF
  names untouched (David, 16 October 2026).
- The map window is titled by place: OpenStreetMap's Nominatim lookup, one
  question a second, identified as Geotag; else the track's name; else the
  day.

## Tracks out of the way (0.10.0, 16 October 2026)

- Tracks is not in the sidebar. It is a "Tracks" menu in the Mac's menu bar
  (Show Tracks, Refresh, Import GPX or FIT…); Show Tracks opens a window of
  its own (`Window` id "tracks") with the tracks as a grid of map cards, and
  the track viewer opens over that window. Geotag opens on Photos. David's
  instructions: "when tracks are working I don't need to see them", "they
  should be a grid", "in the Apple top bar", never Geotag's own toolbar.

## Saving (stage 7, 16 October 2026)

- `Saver` copies a card photo to a hidden working file in the person's day
  folder (`2027.01.12`, the camera clock's day; "Undated" without one), named
  `.<stem>.geotag-<8 hex>.<ext>`: the real extension must stay last, or the
  Mac reads a Nikon NRW as plain TIFF and the check fails.
- It writes the GPS block (named group tags only, old location cleared,
  hundredths of a second cut, never rounded to a 60th second), gives the copy
  the card file's creation and modification dates, then checks it: it opens
  in ImageIO, `ImageDataHash` equals the card's, every tag but GPS, file
  system and offsets is unchanged, the position and altitude read back. A
  copy unchanged on purpose (own location, without location) must match the
  card byte for byte.
- Only then is it moved to its final name; a move never replaces. Same name
  and same photo: "already there"; same photo saved before with another
  location: reported, the earlier copy kept; another photo: `_2`, `_3`.
- A failed copy is removed (Geotag's own); leftovers from a crash are cleared
  at the next save, matched by that exact pattern only.
- History and `queue.json` are written after every photo. A missing save
  folder or a full disk stops the save with one line.
- Tested on R5 Mark II CR3 and JPEG, R7 JPEG, Canon EOS 600D and REBEL T3i
  CR2, and COOLPIX P950 NRW (published samples from raw.pixls.us); HEIF not
  yet, nobody has supplied one.

## Dump, tag and save (17 October 2026)

- Geotag is not a sorting app (David: "it's dump, tag and save; triage can
  happen later"). No tick boxes or choices per photo: every new photo on a
  card is saved, with its location when it can be placed and without one
  otherwise (the reason shows in Status, the count in the Without location
  tile). A checkmark icon marks saved photos; never a checkbox for status.

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
