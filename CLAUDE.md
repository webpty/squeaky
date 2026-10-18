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
- Every location Geotag writes carries `GPSProcessingMethod` = "GPS
  coordinates added by Geotag.app" (David, 17 October 2026), in the GPS block
  so nothing else in the photo changes; the copy check requires it. Photos
  with their own location, and copies saved without one, get no note. The
  app's arguments are `Saver.gpsArguments`; `Tools/gps-test.sh` is the
  stage 2 proof and predates the note.
- On the NAS, the same photo at the same place but written differently (a
  copy from before the note) counts as already there.
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

- From 0.12.0 the one keychain item (account `track-service-key`) holds the
  service key and the NAS password together, as JSON; an item holding the
  bare key (before 0.12.0) is still read. One item, so the NAS password adds
  no prompts.
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
  CR2, and COOLPIX P950 NRW (published samples from raw.pixls.us). HEIF
  (17 October 2026): `.HEIC` and Canon-style `.HIF` files made by the Mac's
  own converter (`sips`) from an R5 Mark II JPEG are read, saved with their
  location and checked; a HIF shot by the camera itself is still untried.
- HEIF stays (David, 17 October 2026). He first asked for it to be blocked,
  then kept it: his R5 Mark II and R7 save .HIF when HDR PQ is on, he does
  not edit photos, and a block would leave such photos unsaved on a card.

## Dump, tag and save (17 October 2026)

- Geotag is not a sorting app (David: "it's dump, tag and save; triage can
  happen later"). No tick boxes or choices per photo: every new photo on a
  card is saved, with its location when it can be placed and without one
  otherwise (the reason shows in Status, the count in the Without location
  tile). A checkmark icon marks saved photos; never a checkbox for status.

## Sending to the NAS (stage 8, 17 October 2026)

- Settings, NAS: address (`smb://10.0.10.10` on David's Mac), backup address
  (`smb://100.99.144.35`, the NAS on Tailscale), user name, password. Each
  person's NAS folder in People is a shared folder and a path
  (`homes/david`); photos go into day folders under it, as on the Mac.
- `NASOverSMB` uses a shared folder already open on this Mac when it answers
  within 5 s (Finder's `/Volumes/homes`), else opens it itself with NetFS:
  no password window, hidden from Finder, soft (a lost connection fails
  instead of hanging), 30 s to answer. Its own openings are closed again
  when nothing is waiting. The main address first, then the backup.
- `NASSender` copies one photo: a hidden `.<stem>.geotag-up-<id>.<ext>` on the
  NAS, read back from the NAS itself (no cache) and compared by SHA-256 with
  the Mac's copy, the Mac copy's dates, then its name. Never overwrites: the
  same file is "already there", another photo gets `_2`, the same photo with
  other bytes is refused ("Already on the NAS with another location") unless
  the entry is an update. Only its own unfinished uploads older than an hour
  are cleared.
- The queue (`queue.json`) is held by the app model and written after every
  change; saving and sending never keep their own copies of it. Oldest first,
  one at a time, every 3 s from launch. NAS away: everything waits, tried
  again each minute. NAS full: tried again in 5 minutes. A send that breaks
  off rests 1 to 10 minutes so the others go first. A photo that cannot go
  (copy gone, refused) is "Not sent" with the reason until Retry failed.
  Sent entries leave the list after a week; History keeps every photo.
- A copy given its location later goes again as an update and replaces
  Geotag's earlier copy on the NAS; still waiting, it simply goes as it is now.
- Sending runs on GCD threads, never Swift's own pool: a hung connection
  must not stall the app. A shared folder that hangs is asked once at a time.
- The Mac asks once whether Geotag may use files on a network volume.
- First real send, 17 October 2026: his 19 photos into homes/david through
  the share Finder already had open, in 20 seconds. The Tailscale address is
  still untried. Tests use `FakeNAS` (a scratch folder); never write test
  files to his NAS.
- Save on the NAS and Track service cards says "Saved." at once, then the
  answer ("Saved. Checking the NAS", then "Saved. Connected through
  10.0.10.10."), and is greyed out until a field changes (David, 17 October
  2026: "no indication of the state"). Test connection tries the fields on
  screen; sending uses the saved settings. Messages name the NAS by its
  number, without "smb://".
- The Queue page's NAS box says whether the NAS answers now (`checkNAS`):
  asked as Geotag opens and whenever the Queue page is shown, and with every
  photo sent. "Checking", the address that answered, "Not reachable", or
  "Not set up" (no address, or nobody with a NAS folder). It used to wait for
  something to send, and read "Not tried yet" while everything was on the
  NAS (David, 18 October 2026).
- A Mac notification per finished batch (`MacNotifier`, one at a time under
  the identifier `geotag-nas`): "19 photos are on the NAS." or "17 photos are
  on the NAS. 2 were not sent." Never per photo: not while a card is being
  saved or photos placed, not while waiting for the NAS or paused. Clicking
  it opens the Queue page. It posts only from the app itself; the self-test
  records the words instead (`RecordingNotifier`).

## Visual polish and the disk image (stage 9, 17 October 2026)

- `GEOTAG_GALLERY=1` (with `GEOTAG_MAP_KEY` for maps) draws every screen,
  window and sheet off-screen in light and dark into the run's scratch
  folder under `gallery/`. Off-screen, the window's sidebar draws blank, so
  the sidebar is drawn on its own (`SheetProbe(.sidebar)`); switches draw
  grey because the window is not active.
- Labels beside fields share `Style.labelWidth`, so fields line up from card
  to card; the person and camera editors are one row per field with one
  right edge. Tile figures and labels shrink before they are cut short.
- Photos: Status sits right after Name, so it shows even in the smallest
  window. Once saved, it says where the copy stands with the NAS and, for a
  photo saved without a location, why ("On the NAS · Camera time offset not
  set"); the Without location count and filter keep counting those photos.
- History shows dates in the format chosen in Settings, under "Date and
  time".
- The disk image for another Mac comes from the Download menu, next to
  Tracks in the Mac's menu bar: "Save to Downloads" makes it there and then
  from the running Geotag (`Installer`, `hdiutil`), puts "Geotag
  <version>.dmg" in Downloads over one of the same name, and shows it in
  Finder (David, 17 October 2026: in the app, made on demand so it works on
  every Mac, replacing the copy already there). `./build.sh dmg` still makes
  one in `build/` for development. Each Mac approves the first launch once
  under Privacy & Security. Apple chips only: David removed the Intel version
  on 17 October 2026 ("don't need it"); do not bring it back.
- Builds name their chip (`--triple arm64-apple-macosx14.0`); run the
  self-test from `.build/arm64-apple-macosx/release/SelfTest`.

## Tests never touch David's own records

- Every `AppModel` in the self-test gets scratch stores for history, queue,
  unplaced and people, and a `FakeNAS`. The defaults are his real files: on
  17 October 2026 a test without its own `unplaced:` added 15 rows to his
  `unplaced.json` (taken out the same day). The run ends by checking his
  `people.json`, `queue.json`, `unplaced.json` and History are as they were.

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
