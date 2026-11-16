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
- The sidebar is a photo from the last card inserted (0.23.0, David,
  5 November 2026; orange with white words, his request of 16 October 2026,
  only until a card has had a JPEG). One per card, chosen once it is read
  (`SidebarPhoto.choose`): the newest upright JPEG, the camera's turn
  counted, else the newest JPEG; no JPEG leaves the last. A small copy,
  `Sidebar.jpg` beside people.json, keeps it through restarts and through
  the Mac copies being removed. Centred, cropped evenly. A band of the
  window's colour, 90% opaque so the photo shows faintly through it
  (0.25.3, David, 6 November 2026), sits behind the menu and the title area and fades out
  over 160 points below it; a short one behind the version line. The words
  follow light and dark. The icon is his `Resources/AppIcon.svg`,
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
- The map of photos (`AlignmentView`, a sheet) shows the list's photos
  (`mappable`) on a map you drag and zoom (`SlippyMap`, CARTO tiles, six
  fetched at a time, kept while Geotag runs): each at its own location, or
  where its time falls along the tracks by its camera's offset. Only to
  look at from 0.26.0 (David, 6 November 2026: "only the QR offsets it
  now"): the slider, the Track choice and "Use this offset" are gone. It
  works with the card out while the list shows (pictures from the Mac
  copies) and never opens by itself. A camera's offset comes from the
  offset code, or typed by hand in Settings, Cameras, as a fallback.
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
- A card in an SD slot built into a Mac (MacBook Pro, Mac Studio) is taken
  too (0.14.4, David, 18 October 2026). Such a slot calls itself internal,
  so an internal FAT or exFAT disk counts when it is removable or ejectable
  or its protocol is Secure Digital; the Mac's own disks never are. Not tried
  on a real slot: David's Mac mini has none. His second Mac is a MacBook Air
  (1 November 2026), on which he uses a card in an adapter. The self-test asks the Mac about
  each of its own disks and checks none is taken.
- Eject forces the whole disk closed (`kDADiskUnmountOptionForce |
  kDADiskUnmountOptionWhole`, on the whole disk, never a partition) and
  ejects it; under a second, open files or not. While it ejects, the Photos line spins and
  Eject is dimmed (0.27.2, David, 13 November 2026).
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

## One window (0.25.0, David, 6 November 2026)

- Geotag has one window. "Avoid other windows as much as possible. and if
  you need them, have them inside the main window. i despise apps that have
  many windows." Anything new is a page, a sheet or a panel laid over the
  main window, never a `Window` or `WindowGroup` of its own, and never an
  alert window (say it on the page instead).
- Tracks is a page (the tracks as a grid of map cards, Refresh and Import
  GPX or FIT at the top), the track viewer laid over it. Geotag opens on
  Photos. David's instructions: "when tracks are working I don't need to
  see them", "they should be a grid", never Geotag's own toolbar. It was a
  menu in the Mac's menu bar until 0.24.0, then its own window.

## The sidebar's second group (0.24.0, pages from 0.25.0)

- The menus at the top of the screen moved to the sidebar ("the top is
  getting really crowded"): under the pages, after a thin line, Tracks,
  Clock drift, Camera clocks and Download (`Screen.tools`), pages of the
  window like the others. Settings and Set Up This Mac stay in the Geotag
  menu.
- Command and a number for every sidebar item in order, Settings keeping
  Command-comma: Photos 1, Queue 2, History 3, Tracks 4, Clock drift 5,
  Camera clocks 6, Download 7 (`Shortcuts`, `GoMenu`, listed in the View
  menu).
- Escape closes whatever is laid over the window: every sheet by its
  Cancel or Later button, the track viewer and the offset code by Close.

## Ordering the tables (0.24.0, David, 6 November 2026)

- Every column with something in it sorts, on Photos, Queue and History
  (`SortColumns`): a click ascending, the next descending, the Mac's arrow
  at the right of the heading; the column ordering it has its heading in
  the accent colour and a faint tint down its cells. The Photos picture
  column has nothing to order by. The saved tick ascending puts photos
  still to save first.
- Photos opens newest first; its choice is kept (`photoSort`,
  `photoSortAscending`). Queue and History start in their usual order.
- "Hide photos saved before" (`hideSavedBefore`, kept) hides photos saved
  from an earlier card; those saved this time and those not saved stay.
- Ejecting a card, or taking it out, leaves the Photos list: "Clear photos"
  (shown once the card is out) or the next card empties it. With the card
  out, pictures come from the Mac copies (`pictureURL`), and Save and the
  map say the card is out. The list is kept through a restart too (0.26.1,
  David, 6 November 2026: an update had emptied it): `photos.json` beside
  `queue.json` (`PhotoListFile`), written a second after any change and
  as Geotag quits, holds the rows, their outcomes and whose they are; it
  opens with the card out. Clear photos or the next card removes it.

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

## Folders by day and place (18 October 2026)

- Every photo goes into a folder named by its day and the place it was
  taken: "2026.12.03 Ushuaia", "2026.12.03 Puerto Williams" (David: "place
  the day, then location, each a folder"). A photo with no location, or whose
  place cannot be named, goes into the day's own folder, "2026.12.03". The
  NAS gets the same folders. A photo placed later stays where it was saved;
  folders made before 0.13.4 keep their names.
- The place is OpenStreetMap's reverse lookup (`PlaceNames`, zoom 14), the
  first of town, village, city, hamlet, municipality, suburb, county,
  state_district, state, else the country. Checked on the trip's places on
  18 October 2026: Buenos Aires, Ushuaia, Puerto Williams, El Calafate, El
  Chalten, Puerto Natales, Torres del Paine, Stanley, Grytviken; the open sea
  and the Antarctic landings have no answer, so their folders are the day
  alone. Zoom 12 named South Georgia after Argentina's province; the city
  before the town named Puerto Williams "Cape Horn"; the hamlet before the
  city named Puerto Natales "Huertos Endesa".
- No internet: the first unanswered lookup ends the lookups for that save
  (`PlaceLookup.unreachable`), and the rest go by their day alone instead of
  each waiting ten seconds. Tests never go online (`FakePlaces`).

## Wrong camera clocks (0.14.0, 18 October 2026)

- Until 0.26.0 the map had a Track choice laying a camera's photos along a
  chosen track whatever its clock said, and a slider to set the offset;
  both went with "Use this offset". A clock far out is now set from the
  offset code.
- A camera whose offset is an hour or more (the Matching card's "Correct the
  dates when a clock is out by", `clockFixMinutes`) gets corrected dates in
  its copies: the EXIF, XMP and QuickTime dates (`Saver.shiftArguments`) and
  the file dates move by the offset, and the day folder follows. The time
  zone fields stay as the camera wrote them. The copy check wants
  DateTimeOriginal moved by exactly that much and every other tag but the
  dates unchanged. A copy placed later is moved by what was not moved yet
  (`UnplacedEntry.shifted`). Canon's CTMD TimeStamp cannot be written and
  stays. The card is never changed.
- The Photos page names each camera whose clock is out, by how much, and
  points to the menu below (`PhotoText.clockNote`).
- The map never opens by itself after a card is read (0.26.0; it used to
  when a track ran within a day of the photos, with nothing left to line
  up there now). "See photos on the map" opens it.
- "Camera clocks", in the sidebar (the menu "Set time and date in camera"
  until 0.24.0), opens on the first camera and has a page per family
  camera (`CameraGuide.all`): steps in the camera's own menu words from the
  maker's manual, with pictures of the camera's screens in
  `Resources/CameraClock/<camera>` (Canon's manual pictures for the R5
  Mark II and R7, Nikon's drawings for the P950 drawn to PNG and trimmed,
  crops of page 34 of the T3i manual). The T3i has no time zone setting:
  its page says to give it a fixed zone in Geotag.

## Firmware (0.14.0, 18 October 2026)

- Each camera keeps the newest firmware version its photos have shown, with
  the day of that photo (`Camera.firmware`, `firmwareSeen`); a card of older
  photos never takes it back. Settings, Cameras shows "Firmware 1.7.1,
  2025.09.08" and a "Latest firmware" button to the maker's page for the
  model (`Firmware.page`). No maker publishes the latest version in a form
  Geotag can read; the page shows it.
- Canon writes the version in its maker notes, which the fast read
  (`-fast2`) skips, and reading them for every photo doubled the time a card
  takes. So only the newest photo of each model is asked
  (`PhotoScanner.readFirmware`). Nikon writes it as Software ("COOLPIX
  P950   V1.0").
- Photos name the lens and its serial number but never its firmware; the
  camera shows that only in its own Firmware menu.

## Lenses (0.14.1, 18 October 2026)

- Every card read notes the lenses its photos name (`LensModel` and
  `LensSerialNumber`, in the fast read at no extra cost): one entry per lens,
  model and serial, kept in `people.json` with whose card and which camera
  its latest photo came from and that photo's day (`Lenses.noting`). A later
  photo moves it to that camera; an older card never takes it back. A serial
  of zeros (some makers' lenses) counts as none.
- An extender is not a lens: whatever follows a "+" in the lens name is left
  off, so a lens used with and without one is one entry. David has the
  extenders (18 October 2026). How the cameras write an extender into the
  name is not proven on one of his photos yet.
- Settings has a Lenses card once a card has named one, each person's lenses
  together, with a "Latest firmware" button to Canon U.S.A.'s page for the
  lens (`Lenses.page`). The page's name follows the lens as the camera writes
  it, checked on eight Canon pages (RF, RF-S, EF, EF-S); other makers' lenses
  get no button. The P950 names no lens.
- Each lens row has a pencil for its firmware version, typed in by hand from
  the camera's Firmware menu (0.14.2, David, 18 October 2026). Kept with the
  day it was typed ("Firmware 1.0.6, 2026.10.18") and never touched by later
  cards; Save stays greyed out until the version changes, and an empty one
  removes it.

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
- Each photo's send says its step (`SendStep`, 0.17.2, David, 2 November
  2026: "short and sweet"): "Looking" (already there? which name?),
  "Sending 42%", "Checking 60%" (read back and compared), "Naming", then
  "On the NAS". Shown beside the bar on the Queue page, in its Status
  column, in the Photos page's Status and in the menu bar. The write is
  uncached and pushed out every 2 MB, so the share is what reached the NAS:
  before, the bar hit 100% as the Mac took the photo in, then sat for half
  a minute while it really went, about 0.3 s a round trip away from home.
- Several photos go up at once (0.18.0, David, 2 November 2026):
  `sendAtOnce`, 1 to 6, in Settings, NAS, "Photos at once"; default 1
  since 0.18.2, 3 gaining nothing over Tailscale (David, 2 November 2026).
  `sendWaiting` keeps that many sends running in a task group, the next
  waiting photo starting as one finishes. `SendMeter` keeps each photo's
  step by queue entry; the bar shows them together, the menu bar a line
  each. Two photos of the same name into the same folder never go at once
  (`nextToSend` skips the second), and the naming step takes a lock, so no
  two pick a name at the same moment. A connection that fails or a full
  NAS stops new ones; those already going finish.
  A photo gets the Mac copy's dates only once it has its final name: with
  its old date on the hidden working file, another photo starting in the
  same folder cleared it as a leftover (0.18.1). Measured on 2 November 2026
  away from home through Tailscale: no faster at 3 than at 1, the link
  already full (about 0.1 MB a second).
- In the Status columns (Queue and Photos pages) a photo going up shows
  `SendingCell`: the step on the left, how far the whole photo has got at
  the far right, and a bar of that filling the cell behind them (0.18.1).
  The same share shows in the menu bar and above the list.
- That share weights each step by its real time (0.18.2, David: "reflect
  reality more"). `StepClock` times every step of each photo that went
  through all four; `StepTimes` keeps the last 20 per NAS address (home and
  Tailscale differ), saved in defaults as `stepTimes`; each step's weight is
  its share of their time. Until an address has 3 timed, `StepWeights.guess`:
  2/60/36/2. Looking and Naming can't tell how far they are, so they show
  where they start.
- Time left for sending (0.22.0, David, 5 November 2026: it "easily loses
  the estimation"): `SendSpeeds`, each whole photo's bytes and seconds per
  NAS address, 200 kept, saved in defaults as `sendSpeeds`. Time left is
  the bytes still to go (the waiting copies' sizes, plus what is left of
  those going up) over the pace of the address's latest 20 photos, so it
  shows from the first photo and survives breaks, pauses and restarts.
  Before 0.22.0 it went by photos since the last break and needed three.
  The line ends "Slow.", "Average." or "Fast.": the latest photo's speed
  among every photo timed, home and Tailscale together (thirds), once 10
  are timed. The line is said again at every step and queue change
  (`sayGoing`); it used to be said only as a photo started, and read "1
  more waiting" while a card added 243. It no longer counts what is waiting: the
  Waiting box above has it (David, 5 November 2026); the menu bar keeps
  "12 of 200". While photos go up, the NAS box
  names the address they go through (`sendingThrough`).
- Copies on this Mac are removed once on the NAS (0.19.0, David, 5 November
  2026: saving locally does not scale). `sent.jsonl` beside `queue.json`
  (`SentLogFile`) records every photo that passed the check on arrival, for
  good: where it landed, when, and the Mac copy's size and date as sent.
  `MacTidy.plan` decides by that record alone. Geotag never looks at the NAS
  again: its job ends with the send and its first check, and the photos
  there will be sorted, renamed or deleted later. Settings, NAS, "Keep
  photos on this Mac": 30 days after reaching the NAS (default, as the
  Mac's Trash: time to use them while fresh), until on the NAS, or always.
  Never removed: a copy with a queue entry not yet sent (held ones
  included) or one changed since it went. A copy without a location goes
  after 30 days like the rest and leaves `unplaced.json` (0.27.0, David,
  12 November 2026: "that's not scalable"; a photo without a location is no
  big deal). An emptied day folder goes too, never the person's save folder. Runs every ten minutes
  from the send timer. The first run puts what the queue still lists as
  sent into the record; copies sent before that have none and stay.
  The Queue page's "Freed on this Mac" adds up `freed`.
- iCloud (0.20.0 copied up only; 0.21.0 both ways, David, 5 November 2026):
  `CloudSync.sync` at launch, before the setup decision, and every minute.
  Shared: `CloudCopy.sharedKeys` from defaults (`settings.plist`),
  `people.json` without save folders, `temperatures.json`, and History,
  combined both ways so a photo read on any of David's Macs counts on all.
  For the rest, whichever side changed since they last agreed
  (`CloudSync.Seen`, defaults `cloudSeen`) goes to the other; both changed,
  the newer file wins, this Mac's settings win. A file iCloud has not
  brought down (`.name.icloud`) is asked for and left alone that time.
  Stays on each Mac: secrets (keychain), save folders, whose Mac it is,
  photos at once, keep on this Mac, pause, step times, setup.
  `Macs/<host uuid>.json` holds each Mac's name and last sync (written on
  a change, at least every ten minutes), shown in the header (`CloudMacs`).
  A new install starts with nobody (`PeopleBook()`; the setup's first step
  adds people); one that takes everyone from iCloud opens the setup for
  its own password, key and save folders. iCloud only links Macs on the
  same Apple account, so David's brother's never see his. A test's iCloud
  is "iCloud" beside its people file; tests use `familyFile` for the four
  people they expect. David's other Mac gets a fresh install from iCloud;
  its old data is dropped: never raise it.
- Notifications come in kinds, one of each showing at a time (identifier
  `geotag-<kind>`): `nas`, `card`, `power`, `nas-away`.
- A Mac notification per finished batch (`MacNotifier`, one at a time under
  the identifier `geotag-nas`): "19 photos are on the NAS." or "17 photos are
  on the NAS. 2 were not sent." Never per photo: not while a card is being
  saved or photos placed, not while waiting for the NAS or paused. Clicking
  it opens the Queue page. It posts only from the app itself; the self-test
  records the words instead (`RecordingNotifier`).

## Checking for tracks before saving (0.27.0, David, 12 November 2026)

- He often inserts a card before the latest tracks have loaded. When a card
  would save itself (every camera set) and any photo has no track within
  the gap, `checkTracksBeforeSave` lays `TrackCheckPanel` over the window:
  "Checking for matching tracks" with loader dots while the tracks are
  loaded again (Strava pulled too); all matched, it closes and the card
  saves. Else "Not all photos have a track. Make sure this is correct."
  (David, 13 November 2026; with "The track service
  isn't answering." above when it could not be reached) and Don't save,
  Check tracks again (the default button, blue, Return), Save anyway;
  Escape is Don't save. Nothing is saved until one is clicked. Taking the
  card out closes it. Save photos clicked by hand never asks.
- Save anyway with the service away holds the photos without a track
  (`QueueEntry.held`): on this Mac, not sent. Asked every minute; once the
  service answers, they are tried once against the tracks
  (`releaseHeld`), then let go to the NAS, placed or not.
- Photos saved earlier are no longer placed by themselves when tracks,
  cameras or the gap change (until 0.26.2 every rematch tried all of
  `unplaced.json`). Once on the NAS without a location, a photo stays so
  unless "Recheck photos for this track" on its track card (cards at least
  230 points wide so it fits) places those taken during that track: the
  copy on this Mac gets its location, is checked, and replaces the NAS
  copy. Copies already removed from this Mac stay without one; never fetch
  them back from the NAS.

## Visual polish and the disk image (stage 9, 17 October 2026)

- `GEOTAG_GALLERY=1` (with `GEOTAG_MAP_KEY` for maps) draws every screen,
  window and sheet off-screen in light and dark into the run's scratch
  folder under `gallery/`. Off-screen, the window's sidebar draws blank, so
  the sidebar is drawn on its own (`SheetProbe(.sidebar)`); switches draw
  grey because the window is not active.
- A spinner or bar beside a status line is part of it (`StatusLine(busy:
  progress:)`), level with the words' first line; elsewhere `levelWithText()`
  in a row lined up on the baseline. Placed beside a two-line status line
  from outside, it sat half a line low (David, 18 October 2026).
- Labels beside fields share `Style.labelWidth`, so fields line up from card
  to card; the person and camera editors are one row per field with one
  right edge. Tile figures and labels shrink before they are cut short.
- Photos: Status sits right after Name, so it shows even in the smallest
  window. Once saved, it says where the copy stands with the NAS and, for a
  photo saved without a location, why ("On the NAS · Camera time offset not
  set"); the Without location count and filter keep counting those photos.
- History shows dates in the format chosen in Settings, under "Date and
  time".
- The disk image for another Mac comes from the Download page (a menu in
  the Mac's menu bar until 0.24.0): "Download for Apple silicon" or
  "Download for Intel" makes it there and then from the running Geotag
  (`Installer`, `hdiutil`), with only that kind of Mac's part of the
  program (`Installer.only`, which keeps the part as signed), puts "Geotag
  <version> <kind>.dmg" in Downloads over one of the same name, and shows it in
  Finder (David, 17 October 2026: in the app, made on demand so it works on
  every Mac, replacing the copy already there). `./build.sh dmg` still makes
  one in `build/` for development. Each Mac approves the first launch once
  under Privacy & Security. Intel is back from 0.25.0 (David, 6 November
  2026: "yes whole new dev"), after he removed it on 17 October: `build.sh`
  builds both and joins them. No Intel Mac to try it on for a while; the
  self-test built for Intel passes under Rosetta
  (`arch -x86_64 .build/x86_64-apple-macosx/release/SelfTest`).
- Builds name their chip (`--triple arm64-apple-macosx14.0`); run the
  self-test from `.build/arm64-apple-macosx/release/SelfTest`.

## Big cards (0.14.3, 18 October 2026)

- His CFexpress card (3,630 photos, an R5 card in a USB reader that calls
  itself a fixed disk) was taken, held hidden and read-only, and read; then
  Geotag crashed drawing the Photos list. On cards of a few hundred photos
  or more the Mac's own table warns "Application performed a reentrant
  operation in its NSTableView delegate" (a bare SwiftUI Table of numbers
  does it too, on macOS 26.6.2), and during that pass a cell view's
  `@EnvironmentObject` is not found: a fatal error. Views drawn inside a
  Table cell never use `@EnvironmentObject`; hand them the model
  (`PhotoStatus(model:row:)`). Closures in `TableColumn` may read the
  screen's own `model`.
- `GEOTAG_TABLE_STRESS=<count>` runs only the big-card test: a scratch card
  of that many photos, read while the Photos page shows, scrolled end to
  end. It reproduced the crash with the old cell and passes with the new.
- The list of a card is changed in one step (`rematch`, after saving), not
  row by row: row by row copies the whole list for every photo.

## The menu bar icon (0.14.8, 18 October 2026)

- While Geotag reads a card, saves photos or sends them to the NAS, a pin in
  a ring shows on the right of the menu bar (`MenuBarIcon`, an
  `NSStatusItem`, started from the window's task in the app only, never in
  the self-test, which must not put icons on David's menu bar). The ring
  fills with the first job's progress, in fortieths; the icon is a template,
  so it takes the menu bar's own colour.
- Its menu: one line per job, the Photos page's own line while reading or
  saving ("Saving 340 of 3,630"), "Sending to the NAS: 12 of 200" while
  photos go up, then Open Geotag. Nothing going on, no icon; photos only
  waiting for the NAS show nothing (David's plan).
- `AppModel.refreshWork()` builds it from the reading, saving and sending
  state into `WorkStatus`; saving ends before its closing line is said, so
  the menu never shows "5 saved."
- Closing the window leaves Geotag working, as before.

## Quitting (0.14.7, 18 October 2026; asks first from 0.16.0)

- Command-Q and the menu's Quit ask first while photos are being saved or
  are on their way to the NAS (`Quitting.asked()`, the words from
  `AppModel.quitCutOff()`): "Are you sure?", what would be cut off and that
  reopening resumes it, with Cancel (Return) and "Yes, Quit anyway". David,
  1 November 2026: a Command-Q meant for another app stopped a save of
  Amanda's card. With nothing going on, Command-Q quits at once, whatever is
  open. Quit events (the Dock, a log-out) never ask.
- `Quitting.now()` is the one way out: the key watch in `AppDelegate`, the
  menu's Quit (after asking) and quit events all go through it.
- The Mac refuses to quit while a sheet is open ("App termination blocked
  by modal sheet" in its log), and SwiftUI shows a sheet again within a
  twentieth of a second of it being closed from outside, because its
  binding still says shown. So the sheets are closed and `NSApp.terminate`
  is called in the same moment; quitting on the next turn, as before 0.14.7,
  was refused every time. A running file chooser is stopped first. If
  anything still refuses, Geotag exits a second later: every record is
  written as it changes.
- The self-test runs a copy of itself with a sheet open and checks it quits
  the Mac's own way (`GEOTAG_QUIT_CHILD`).
- The run's last check, that his records are as they were, also fails when
  his own Geotag saves or sends while the test runs: look at what changed
  before blaming a test (1 November 2026).

## Setting up a Mac (0.15.0, 1 November 2026)

- `SetupView`, a sheet over the window, in five steps: whose Mac this is,
  each person's save folder, the track service, the NAS with each person's
  NAS folder, and opening when a card is inserted (the switch, with one line
  on why it means starting at login). "Later" closes it; Done marks it done
  (`setupDone`). "Set Up This Mac…" in the Geotag menu opens it again.
- It shows by itself only when `needsSetup`: not done, no track service
  address and nobody with a save folder. A Mac set up before 0.15.0 is
  marked done at launch and never sees it unasked.
- Whose Mac (`macOwner`) only puts that person first: first in "Whose is
  this card?" (and Return picks them when the card is new) and in History.
  Every card still asks whose it is, and the Person tile's pencil still
  changes it (David: it is no substitute for choosing per card).
- Save folders: several people on one Mac, any left empty.
- Track service: the address is filled in with https://geotrac.cc when
  empty and stays editable. Each Mac has its own key, made by hand in the
  track service (`../tracks`); Geotag cannot make one.
- One NAS per Mac.

## Buttons that can't be used are dimmed (0.26.0, David, 6 November 2026)

- "Disable any button that cannot be used. they should be dimmed." This
  replaces the 1 November rule that such a button says why when clicked.
- Save photos (`canSave`): a card in, whose it is known, a save folder
  there (`saveBlock`), photos not saved yet, nothing busy. See photos on the
  map (`canMap`): photos to show and tracks (or photos with their own
  location). Name place… needs a selection and the card in. Add camera
  needs somebody; Save in the person and camera editors a name or a model;
  Connect Strava the track service (`hasService`); Test connection a NAS
  folder and address (`canTestNAS`). Eject shows only with a card.
- Lines Geotag says on its own keep their fix (`PhotosFix`) as a button
  beside them: choose whose card, Choose folder… (keeps the folder for that
  person, then saves), Open Settings, Edit camera (`cameraToEdit`). A save
  folder missing or not found is said as soon as a card is read, since Save
  photos is dimmed for it. Any new line clears the fix.

## Tracks loading (0.15.0, 1 November 2026)

- The Tracks line says "Loading tracks" the moment a refresh starts, then
  "Loading tracks: 12 of 51" as each new track's points come in
  (`TrackLibrary.refresh(loading:)`). Before 0.15.0 the line from before
  the refresh stayed up, and read "not set up in Settings" on a Mac that
  had just saved its key (David, 1 November 2026).

## The card comes out as soon as it can (0.16.0, 1 November 2026)

- Sending to the NAS goes from the Mac's copies, so the card is needed only
  while photos are copied off it. When a save ends with every photo saved
  (not stopped, none failed), Geotag ejects the card itself and says
  "EOS_DIGITAL can come out. 340 photos are on this Mac; the NAS copies go
  from there.", with a `card` notification. Stopped, or with photos not
  saved, the card stays and the line says why, as before. Not tried on a
  real card by the self-test: scratch cards have no disk to eject.
- Saving says the time left at the pace so far ("Saving 340 of 3,630, about
  12 min left", `Remaining`, from the third photo and five seconds on), as
  does sending, on the Queue page and in the menu bar ("Sending to the NAS:
  12 of 200, about 30 min left"). A NAS break restarts the pace.
- On battery (`PowerPort`, the Mac's own estimate through IOKit), when the
  save would outlast the battery the line adds "Connect to power: about 25
  min of saving left, the battery has about 15 min." and one `power`
  notification per save. Recomputed every photo, so it goes once plugged in.
  A Mac on power or with no battery never sees it.

## NAS away on opening (0.16.0, 1 November 2026)

- As Geotag opens, with photos waiting and no answer from the NAS at either
  address (`announceNASAway`), it says "The NAS isn't answering. If you're
  away from home, turn on Tailscale; otherwise check the connection." on
  the Photos page (with Open Tailscale), on the Queue page and as a
  `nas-away` notification. It goes by itself once the NAS answers.
- Tailscale is found by its bundle id (`io.tailscale.ipn.macos` from the
  App Store, `io.tailscale.ipn.macsys` from Tailscale's site); no button
  without it.

## Offset code and clock drift (0.17.0, 1 November 2026)

- "Show offset code", in Settings, Cameras, next to Add camera, lays the
  code over the whole window and puts the window in full screen, back as
  it was on Close or Escape (`OffsetCodeView`, `showingOffsetCode`; its own
  window until 0.25.0): the true time to the
  hundredth, UTC, and a QR code holding it in milliseconds
  (`OffsetCode.payload`, "geotag-clock:<ms>"), redrawn every frame. The
  Mac's clock is checked with `sntp` against the server in /etc/ntp.conf
  (else time.apple.com) and the shown time corrected; offline it says the
  Mac's clock is shown as it is. The code is drawn 16 pixels to a square:
  scaled up afterwards it blurred.
- 0.17.1: the window goes full screen once it is in a window (`FullScreen`
  watches for it; asked earlier it stayed small), the code and time sit side
  by side on a wide window and stacked on a narrow one, and the time shrinks
  to fit (at 0.17.0 it was cut short). Under the time: "Shutter 1/500 s or
  faster, mechanical shutter." (David asked for it to be said): the code
  changes 60 times a second, and a slower or fully electronic shutter
  catches two codes at once. 1/320 s was still too slow on his camera
  (1 November 2026). Then "Camera facing the screen straight on.": at 1/500 s
  with the screen tilted, the reading was still ambiguous.
- When a card is read, the first and last five photos of each camera are
  looked at for a code (Vision, on the Mac's own picture of raw files). A
  code sets the camera's offset to the hundredth: `ClockReading` added to
  `Camera.readings`, `offsetSeconds` the rounded value.
- Drift (`Drift`): fitted through all readings. A photo between two readings
  gets the offset in proportion; after the last, the last plus the drift
  since. Only while `followsReadings` (the offset is the last reading's): an
  offset typed or slid by hand since takes over.
- Every camera on the card set (zone and offset): the map never opens and
  the photos are saved at once, then the card ejected (David: "just grab all
  the photos"). So on such a card Name place… comes too late to name the
  folders. `saveWhenReady` is off only in the self-test.
- A week after a camera's last reading, and each week after, one
  notification ("Time to photograph the offset code with Amanda's Canon EOS
  R5m2."), kind `clock-<camera id>`, checked at launch and every ten minutes.
- Camera temperature: Canon's `CameraTemperature`, in the maker notes the
  fast read skips, so read afterwards for one photo per camera per quarter
  hour, with its position, into `temperatures.json` beside people.json.
- "Clock drift", a page from the sidebar, shows per camera, each stretch
  between two readings with its drift, the camera's temperature (average,
  lowest, highest), the outside temperature and up to three places, and a
  chart of drift against temperature. The outside temperature is to come
  from the track service, which does not keep weather yet (brief in memory,
  `tracks-weather-wanted`); until then that column is empty.
- Untried on a real camera: reading the code off a photo of the screen,
  raw files included, and whether the P950 and T3i record a temperature.

## Tests never touch David's own records

- A scratch folder is made a card with `scratchCard`, never
  `CardWatcher.card(at:)`: folders on one disk share its id, so every test
  card was the same card, and choosing a second one started a read of its
  own beside the test's (found 18 October 2026; some tests had passed
  without reading at all).

- Every `AppModel` in the self-test gets scratch stores for history, queue,
  unplaced and people, and a `FakeNAS`. The defaults are his real files: on
  17 October 2026 a test without its own `unplaced:` added 15 rows to his
  `unplaced.json` (taken out the same day). The run ends by checking his
  `people.json`, `queue.json`, `unplaced.json`, `temperatures.json` and History
  are as they were.

## The iPhone (0.28.0, David, 14 November 2026)

- Same approach as Countries: built on this Mac with Xcode, signed with
  David's free Apple ID, installed over the cable with
  `Phone/install_phone.sh`; it runs for 7 days, then is installed again.
  His phone only. No iCloud entitlement.
- CR3 and JPG only, never HEIC (David: "the app never handles heic"). CR3
  first. A .HIF on a card is left there. The Mac is unchanged.
- ExifTool cannot run on the phone: `NativeMetadata` reads and writes CR3
  and JPG itself. Canon leaves fixed room for the location (a JPG's GPS block
  is followed by zeros up to the thumbnail; a CR3's CMT4 box is padded), so
  the location is written into that room and nothing else moves: the copy
  has the card's size, and the check proves every other byte is the card's.
  A file without that room (one ExifTool already rewrote) is refused. The
  dates, when corrected, are rewritten in place too (EXIF and the CR3's
  container dates).
- Proved on the Mac against ExifTool and `Saver.check` with
  `GEOTAG_ORIGINALS=<folder of camera originals>` (the Savoie R5 Mark II
  CR3 and JPG): it reads what ExifTool reads on every file, finds room in
  every one, and every copy passes the Mac's own check. In the simulator,
  `--write-test` and `--flow-test` (debug builds only) run the phone's own
  writer and the whole flow: card, track, save, NAS.
- `GeotagCore` and `GeotagUI` build for both. Mac-only files are wrapped in
  `#if os(macOS)`; the app model is shared, so the track check, held
  photos and the queue behave as on the Mac. The phone's
  screens are its own (`Phone/Geotag`), four tabs: Photos, Tracks, Queue,
  Settings. No map pictures on the phone.
- The card: opened once in the Files list (a USB-C card reader), with
  Open card; the phone allows no app into a card before that. Each card
  opened is remembered (`CardWatch`, David, 16 November 2026): plugged in
  while Geotag is open, or when it opens, it is read by itself, looked for
  every 3 s while Geotag is in front. No eject: the card is let go of once
  saved, and not read again until it has been taken out. Copies go in Geotag's folder on the phone
  (On My iPhone, Geotag, one folder per person). Paths kept in the queue and
  records, and the Photos list's copies (0.29.14), are moved to the new
  install's folder after each reinstall; matched on
  "/Containers/Data/Application/<id>", the phone's and the simulator's alike.
  A saved photo whose copy has left the phone (a raw on the server) shows no
  square once the card is out.
- The NAS: its shared folder, connected in the Files app and chosen once in
  Settings (`NASThroughFiles`), matched by the name the Files app shows (a
  shared folder's own name is internal, "Nm3Lvwhomes" for homes). Sending
  runs only while Geotag is open; the screen stays on while saving or
  sending.
- Each person manages their own photos (David, 15 November 2026), in the
  Photos library since 0.29.15; Geotag's own working copies leave the phone
  once on the server.
- One person per phone (David, 15 November 2026), kept as `macOwner`.
  Choose card is dimmed until the person is saved.
- Not every card is the phone's person's (David, 15 November 2026: his
  partner copies his photos from his card). The first time a card is
  chosen, Geotag asks "Whose card is this?", Mine or Someone else's,
  remembered per card; the Card row on the Photos tab changes it. Someone
  else's photos are tagged as usual and saved under the person "Others"
  (`PhoneFolders.othersId`, folder Others), never put on the queue, never
  sent. Their cameras are kept apart, under Other cameras in Settings.
- Settings on the phone has one checkmark at the top right that saves
  everything typed (name, track service, camera offsets) and closes the
  keyboard; no Save buttons in the sections (David, 16 November 2026).
  Dragging the page also closes the keyboard.
- Tracks on the phone show a map as the Mac does (0.29.4): CARTO's wordless
  tiles through the service's map source, the route on top in blue (David:
  nothing in Geotag is orange; blue on the phone), kept in Geotag/Maps as
  `<id>-phone-<light|dark>.png`; the bare line until a map can be made. Map
  on the left, words on the right; the map credit under the list.
- The Photos tab's squares are exact, one size, edge to edge (0.29.4).
- On the Mac's Photos page the sync line follows the title and the buttons
  sit at the right edge (0.29.4).
- The server (David, 15 November 2026): "NAS" is "server" on the phone,
  and the server is any folder the Files app reaches (a file server such as
  the NAS, a USB drive, a storage app). The day folders go straight into the
  chosen folder; the person has no NAS folder of their own on the phone
  (`NASThroughFiles.share`). With a storage app the read-back check reads
  the app's own copy on the phone. Settings, Server has the steps to
  connect a file server.
- Five languages on the phone (David, 15 November 2026), as Countries:
  English, Spanish, French, Simplified and Traditional Chinese, following
  the phone's language. Every text goes through `Words.t("template {0}",
  ...)`; the phone loads `Phone/Geotag/Words/words-<language>.json` at
  launch. The Mac loads nothing and shows the templates, so it stays in
  English and keeps "NAS". The phone's English list turns NAS into server
  and this Mac into this iPhone. Every new text needs all five lists.
- Each phone is on its own (David, 15 November 2026): no iCloud, nothing
  shared with the Macs or other phones except the track service. Settings
  holds its one person (anyone else on the phone is removed), the cameras, added by themselves from the first card (zone from
  the photo; offset from the offset code or typed in seconds), the track
  service (address filled with https://geotrac.cc, key typed) and the NAS.
  Until a camera has an offset its photos are not saved by themselves.

## The list of photos saved, on the server (0.29.0, David, 16 November 2026)

- Each person's server folder (their NAS folder on the Mac, the chosen
  folder on the phone) holds a hidden `.geotag` folder with one list per
  device, `saved-<device>.json` (the Mac's id, or a phone's own), of the
  photos it saved from cards: name, size, time taken (`ServerList`). Each
  device writes its own whole list as it opens and after each save; a card
  being read is checked against all of them, once per card, so a card one
  Mac or phone handled reads as saved before on every other.
- Written as Geotag opens, whenever the server answers and they were not
  written since it opened, and after each batch sent (0.29.2). The Photos
  page says so, in David's words (0.29.3): "Sync file saved on NAS. Last
  save: Mac app @ 20:03" ("on server" on the phone), whichever device wrote
  last; "Sync file not saved yet."; or "Sync file not saved:" and why. On
  the Mac it sits on the title row, after the buttons; on the phone, first
  in the top section. Geotag's own openings of
  the NAS are not closed while the lists are written.
- A server known not to answer is not waited for; then only the device's
  own list counts. Someone else's card on a phone is never checked.
- This is Geotag's own record on the server, read only to know what was
  saved; it never decides anything about the photos there.

## Offsets shared, the offset code and squares on the phone (0.29.1, David, 16 November 2026)

- Camera offsets go through the same `.geotag` folder: each device writes
  `cameras-<device>.json` with the person's cameras that have an offset;
  for each model the offset set most recently on any device wins
  (`Camera.offsetSet`; before 0.29.1, the last offset code reading's date).
  Read as Geotag opens and before a card is read; written whenever an
  offset changes. Others' cameras on a phone are never shared.
- The phone shows the offset code full screen (Settings, Cameras, Show
  offset code), at full brightness, its clock checked against
  time.apple.com by one NTP question, as the Mac does with sntp.
- The Photos tab on the phone shows the photos still to be saved as square
  pictures, three to a row; already saved ones are left out. Why photos
  wait is one line per reason, with how many.
- Version numbers: small changes raise the last digit (David, 16 November
  2026).

## Raws, the panel before saving, track names, the background (0.29.5, David, 16 November 2026)

- Raws on the server, not on the phone: CR3 copies from the person's own
  card are removed from the phone as soon as they are on the server and
  checked (tidy with "until on the server" for raws only); JPGs stay. A raw
  saved without a location cannot be placed later once it has left.
- Someone else's card on a phone: JPGs only; its raws are left on the card.
- The phone shows a panel before every save (`TrackCheck.ready`): tracks
  checked first, then "Latest track: <name>, starts <date>", "Not all
  photos have a track" when it applies, and Save photos, Check tracks
  again, Don't save. The Mac keeps its panel for missing tracks only.
- Tracks are named by where they are (`TrackPlaces`, Mac and phone): start,
  middle and end looked up on OpenStreetMap in English at zoom 10; one town
  for all three gives "Ronda, Andalusia", else the region it starts in. Kept
  in trackplaces.json beside people.json; never looked up in the self-test.
  The map data has regions, not landscapes ("Aragon", not "Pyrénées").
- The phone's background is the newest JPG of the last card (the Mac's
  sidebar photo), filling the screen behind every tab, under a dark layer in
  dark mode and a light one in light mode.
- Settings shows the server folder's whole path, as the Files app names it,
  saved when the folder is chosen (0.29.8): opening Settings never asks the
  NAS, which froze the tab while it answered. Nothing on the main thread
  opens the server folder.
- The Photos tab's squares show only while the card is in.
- Saving on the phone reads the card once (0.29.9): the copy is made with
  the location and dates written on the way and fingerprinted
  (`NativeMetadata.copyPatched`), then the copy alone is read and checked
  against that fingerprint (`checkCopy`). The Mac's saving is unchanged.
- Squares (0.29.9): one per frame (the JPG of a RAW+JPG pair), 3-point
  gaps, 4-point corners, filled to their edges. Made from the JPG itself:
  the preview inside a JPG is 160x120 with black bands. A raw's own preview
  has none. Made one after another in the photos' order.

## Bursts (0.29.6, David, 16 November 2026)

- Each burst goes into its own folder inside its day folder: "burst_01",
  "burst_02", numbered on from the burst folders already in that day folder
  on the device. Mac and phone alike, so the NAS gets the same folders.
- A burst is two or more frames shot in one of Canon's continuous drive
  modes (ContinuousDrive 1, 3, 4, 5, 8, 10: Continuous, Speed Priority,
  Low, High, High+, Silent), each within 2 s of the last. Single shots never
  are, however quick: David's photos up to 16 November 2026 are all
  "Single", some under a second apart. A camera with no drive mode: three
  or more frames each under a second apart. RAW and JPG of a frame together.
- The drive mode is read natively on the phone (maker notes, CameraSettings
  value 6); on the Mac by ExifTool only for photos within 2 s of another,
  since the fast card read skips the maker notes.
- No real burst has been tried yet: the stand-in was a copy with its drive
  mode and times changed.

## Saying what it is doing (0.29.10, David, 16 November 2026: "i like transparency")

- After the card is read, each step has its line: "Checking the server for
  camera offsets", "Checking the server for photos already saved", "Looking
  for offset codes: 3 of 10 photos", "Loading tracks", "Matching photos to
  tracks". Any new slow step gets its own line.
- Offset codes are looked for in one file per frame, the JPG of a RAW+JPG
  pair; a raw alone in its own large preview, not decoded.
- The sync line's last save is remembered between launches and noted
  whenever Geotag reads the server folder, not only when it writes.

## No silent failures (0.29.11, David, 16 November 2026: "dont fail silently")

- Every way of not reaching the server folder says why: in Settings under
  Folder, on the sync line ("Sync file not saved:" and why), and on the step
  lines while a card is read ("...: <why> Going on with this phone's own
  list."). Reasons: no folder chosen; the folder chosen can't be found any
  more (the bookmark no longer resolves); the server isn't answering (the
  Files app's connection is down), with the phone's own words; no answer
  within 15 seconds; a sync file that couldn't be written or read.

## The sync files kept here; saved photos keep their square (0.29.12, David, 16 November 2026)

- Each device keeps what the sync files held when last read
  (`servercopy-<person id>.json` beside people.json): every device's photos
  saved and each camera's newest offset. Reading a card uses that copy and
  never waits on the server (David: one card and one reader, moved between
  devices; "whats the point of having it locally if it's going to check the
  server everytime"). The copy is refreshed, both files in one visit, with
  each sharing: as Geotag opens, when the server answers again after being
  away, after each save and each batch sent.
- On the phone, photos saved from the card keep their square with a green
  check in the bottom right corner, from the copy on the phone once the card
  is out.

## A card gone mid-save; reasons on the phone (0.29.13, David, 16 November 2026)

- A card that goes during a save (David pulled the reader to install by
  cable: 68 saved, then 427 marked "not saved: see the Status column") stops
  the save at the first photo it can't give: "The card stopped answering
  after N photos: <why>. N saved; the rest are still to save..." The rest
  are not marked failed; the phone lets go of the card, so it is read again
  and carries on when back. Noted when Geotag was in the background
  meanwhile.
- The phone has no Status column: its line gives each reason with how many.
  A failed square has a red mark; the count of saved photos updates after
  each photo.

## The Photos library and the background (0.29.15, David, 16 November 2026)

- Photos saved on the phone go into its Photos library, not Files (David:
  "they should show in the library"): every JPG saved from a card is added
  with its location and date (`PhoneLibrary`, add-only permission). Raws
  never go into the library. Geotag's working copies live hidden in
  Application Support/Geotag/Copies, out of the phone's backup, and each
  leaves once it is on the server. Someone else's JPGs go into the library
  and their copy is removed at once. Geotag no longer shows in Files.
- On the first launch of 0.29.15, what was in Files (Documents) is moved to
  the hidden copies with every path kept, and every JPG added to Photos;
  done again each launch until all are in; nothing deleted on the way.
- A save, and the sending after it, ask the phone to keep running in the
  background (`BackgroundWork`, BGContinuedProcessingTask, iOS 26 and
  later): progress on the Lock Screen; cancelling there is Stop. The screen
  stays on only when the phone will not take it on. Not yet seen on a real
  phone, nor whether the card stays readable meanwhile.

## Every step on screen (0.29.16, David, 16 November 2026: "it's really exhausting to have to ask for basic things like this")

- Anything that takes more than a moment says what it is doing, with a
  count, and every failure says why. Check each new step against this
  before calling a build done. Lines so far: moving out of Files ("Waiting
  for permission to add to Photos", "Adding photos from Files to Photos: 9
  of 40"), "<saving line>, adding to Photos", "Naming tracks by place: 3 of
  40" (and "Tracks not named by place: OpenStreetMap isn't answering"),
  "Making maps: 3 of 40" (phone), "Reading the sync files" and "Saving the
  sync file" in place of the sync line, and the card-reading steps.

## The list of saved photos read before a card (0.29.17, David, 16 November 2026)

- 0.29.12 made card reading use the device's copy of the sync files only,
  and nothing filled that copy after the update: the phone found it empty
  and saved photos the Mac had saved long ago again. Now a missing or empty
  copy is read from the server first ("Reading the list of photos already
  saved, from the server"); if that fails, the panel before saving says why
  and that photos saved on the Mac may be saved again, and its button reads
  Save anyway.

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
- Raise `appVersion` in `Sources/GeotagCore/Version.swift` with every change
  that is committed or installed, the phone's included, and start the
  commit subject with that number (David, 16 November 2026: six phone
  changes went out as 0.28.0 and he could not tell he had the latest).
- Commit locally as often as it is worth, and push to GitHub without asking
  (David, 6 November 2026: a push here only saves versions; nothing goes
  live from it). Installing a new build on his Mac still needs his yes.
- British spelling. No em dashes.

## Notes

### Geotag scope: send and check once

Geotag's job on the NAS ends with the send and its first check (read back and compared on arrival). David, 5 Nov 2026: "we're not building a continued integrity tool". No later look at the NAS to decide anything, e.g. before removing Mac copies.

**Why:** the NAS has RAID plus a nightly remote Hyper Backup, and David plans to sort the photos later, deleting or renaming files and folders, so later checks would misfire.

**How to apply:** decisions about photos already sent rest on Geotag's own record of the send, never on what the NAS holds now. Mac copies are removed 30 days after reaching the NAS (matches the Mac Trash's 30 days; time to use the photos while fresh). Related: [[geotag-state]].

### Geotag other Mac: fresh install

Geotag on David's other Mac will be a fresh install that takes everything from iCloud; its old settings and its list of photos read are dropped on purpose (David, 5 Nov 2026). Only this MacBook Air copies its settings to iCloud.

**Why:** he said "do not mention the other mac again ... we lose all the old stuff. capiche?"

**How to apply:** never raise the other Mac's old data, merging, or what is lost with it. Plan the iCloud work from this Mac's data only. Related: [[geotag-scope-send-and-check-once]].

### Geotag: push without asking

On Geotag, push without asking (David, 6 Nov 2026: "since push does nothing
more than save versions on this project, dont ask me for push on this
project only").

**Why:** Geotag is a Mac app; GitHub holds its versions and nothing goes
live from a push, unlike his Cloudflare sites where a push to main is a
release.

**How to apply:** after a Geotag commit is built and tested, push it
without a question. Still ask before installing a new build on his Mac
(it quits his running Geotag). Every other project keeps the push
question. Claude Code's own safety check treats a push as a release, so
`.claude/settings.json` here allows `git push`, and the Sites folder's
local settings allow `git -C /Users/david/Sites/geotag push` (12 November
2026, his yes). Exception to [[david-plan-then-ask-to-push]] and
[[keep-wine-no-push-without-word]].

### Notes only in cross-project changes

Said 26 Oct 2026: in changes made across all projects, only Geotag's notes are aligned, nothing else, unless David names it.
