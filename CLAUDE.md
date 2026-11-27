# Squeaky

An iPhone app for David and his family (David's and Amanda's phones). It reads
an SD card through a USB-C reader, matches the photos to David's watch tracks,
writes the location into copies, adds them to the phone's Photos library and
sends them to his NAS (or bufr.cc away from home). Shared with family members
now and meant to be shared with others later, never sold: it works the same
for everyone, with no code for one person (David, 27 November 2026); who
someone is comes from settings only. The full brief is `squeaky-app-brief.md`, given on 16 October 2026,
for what was then a Mac app.

- David's instructions override the brief wherever they clash (16 October
  2026). Follow them and record them here; the brief is only the start.
- The Mac app is dropped (0.34.13, David, 25 November 2026: "let's drop the
  mac app entirely"; the photos reach the computer through Photos or the
  server). Its code, ExifTool, the Mac build, its installer and the iCloud sync
  between Macs are removed; only the commit history has them. Its files on
  David's Mac went to the Bin. Squeaky is the iPhone app alone: every feature
  is the phone's, and nothing is to be built for the Mac again unless he asks.

## Stack

- SwiftUI for iPhone, built with Xcode (`Phone/Squeaky.xcodeproj`, scheme
  `SqueakyPhone`) from the Swift package's `SqueakyCore` and `SqueakyUI`.
  Not his usual React, HeroUI Pro and Cloudflare stack: the job needs SD
  cards, the Photos library and the NAS.
- Signed with David's free Apple ID, installed over the cable with
  `Phone/install_phone.sh`.
- Third-party code: Garmin's Connect IQ companion kit only.
- Repo: github.com/webpty/squeaky, private. Commits as webpty with the GitHub
  no-reply address.

## Tracks come from the track service, never from Strava directly

- There is exactly one Strava connection, and it belongs to a separate track
  service on Cloudflare (its own repo, `~/Sites/tracks`, at https://geotrac.cc,
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

## Tracks (stage 3, 16 October 2026)

- The track service is `~/Sites/tracks` (its own CLAUDE.md). Settings holds its
  address (UserDefaults) and key (login keychain, account
  `track-service-key`, service `com.webpty.squeaky`).
- The key's role decides: an owner key connects Strava, syncs and uploads;
  a reading key reads, and its Mac's imports stay on that Mac.
- `TrackLibrary` keeps every track and its points in
  `~/Library/Application Support/Squeaky/Tracks` (`index.json`,
  `points/<id>.json`). Files are replaced whole, never removed. An uploaded
  import stays in the index as `uploaded` and is hidden; the service's copy
  is the one shown.
- A file starting within 60 s of a track already here is the same track.
- Map pictures are OpenStreetMap tiles with no words from CARTO, whose
  addresses, credit and key come from the service (`GET /v1/maps`), with
  the line drawn in orange; drawn once per appearance and kept in
  `Squeaky/Maps` as `<id>-osm-<light|dark>.png`. Offline or without a key,
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
  follow light and dark. The icon is his `Resources/AppIcon.png`,
  drawn into the Mac's rounded square by `Tools/makeicon.swift`.
- FIT reading is our own (`FITReader`), checked against Garmin's own
  decoder on its sample files. A real fenix 9 file has not been tried yet.

## People and cameras (stage 4, 16 October 2026)

- `PeopleBook` in `~/Library/Application Support/Squeaky/people.json`, per Mac,
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
  fetched at a time, kept while Squeaky runs): each at its own location, or
  where its time falls along the tracks by its camera's offset. Only to
  look at from 0.26.0 (David, 6 November 2026: "only the QR offsets it
  now"): the slider, the Track choice and "Use this offset" are gone. It
  works with the card out while the list shows (pictures from the Mac
  copies) and never opens by itself. A camera's offset comes from the
  offset code, or typed by hand in Settings, Cameras, as a fallback.
- Off-screen pictures of the screens: `SQUEAKY_VIEWER=1` and `SQUEAKY_ALIGN=1`
  with `SQUEAKY_MAP_KEY` (the CARTO key from `~/Sites/tracks/.keys/carto.key`).
  A probe view needs a background of its own or it draws black.

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
  its page says to give it a fixed zone in Squeaky.

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
- Lines Squeaky says on its own keep their fix (`PhotosFix`) as a button
  beside them: choose whose card, Choose folder… (keeps the folder for that
  person, then saves), Open Settings, Edit camera (`cameraToEdit`). A save
  folder missing or not found is said as soon as a card is read, since Save
  photos is dimmed for it. Any new line clears the fix.

## Offset code and clock drift (0.17.0, 1 November 2026)

- "Show offset code", in Settings, Cameras, next to Add camera, lays the
  code over the whole window and puts the window in full screen, back as
  it was on Close or Escape (`OffsetCodeView`, `showingOffsetCode`; its own
  window until 0.25.0): the true time to the
  hundredth, UTC, and a QR code holding it in milliseconds
  (`OffsetCode.payload`, "squeaky-clock:<ms>"), redrawn every frame. The
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

## Tests

- `SelfTest` (a Mac command-line program, `SqueakyCore` only) checks the
  core: matching, bursts, videos, GPX and FIT, the track library, the card
  memory. Run `SQUEAKY_SCRATCH=<scratch folder> $(swift build -c release
  --triple arm64-apple-macosx14.0 --show-bin-path)/SelfTest` after
  `swift build -c release --triple arm64-apple-macosx14.0 --product SelfTest`
  (a plain `swift build` also tries `SqueakyUI`, which is phone-only now).
  The tests of the Mac app (its screens, ExifTool saving, the app model on
  the Mac) went with it in 0.34.13.
- The app model is checked in the simulator: `--write-test` and `--flow-test`
  (debug builds only), with real camera originals.
- Tests work in their scratch folder only, never in David's records.

## The iPhone (0.28.0, David, 14 November 2026)

- Same approach as Countries: built on this Mac with Xcode, signed with
  David's free Apple ID, installed over the cable with
  `Phone/install_phone.sh`; it runs for 7 days, then is installed again.
  Always on both phones, David's and Amanda's (David, 24 November
  2026). No iCloud entitlement.
  With ProtonVPN connected on the Mac, a phone on the cable cannot be reached
  ("The tunnel connection failed", 26 November 2026): David disconnects it
  for the install. One Release build (`generic/platform=iOS`) goes on both
  phones; the install only copies it (`devicectl device install app`).
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
  `SQUEAKY_ORIGINALS=<folder of camera originals>` (the Savoie R5 Mark II
  CR3 and JPG): it reads what ExifTool reads on every file, finds room in
  every one, and every copy passes the Mac's own check. In the simulator,
  `--write-test` and `--flow-test` (debug builds only) run the phone's own
  writer and the whole flow: card, track, save, NAS.
- `SqueakyCore` builds for the phone and for the Mac self-test; `SqueakyUI`
  for the phone only (0.34.13). The phone's
  screens are its own (`Phone/Squeaky`), four tabs: Photos, Tracks, Queue,
  Settings. No map pictures on the phone.
- The card: opened once in the Files list (a USB-C card reader), with
  Open card; the phone allows no app into a card before that. Each card
  opened is remembered (`CardWatch`, David, 16 November 2026): plugged in
  while Squeaky is open, or when it opens, it is read by itself, looked for
  every 3 s while Squeaky is in front. No eject: the card is let go of once
  every photo on it is saved (0.32.1, David: copying some photos must leave
  the card open to choose more), or with Done with this card, and not read
  again until it has been taken out. "Copy done. Remove the card." only when
  every photo on it is saved.
- Save all (0.32.1) selects every photo on the card and saves; photos copied
  before are left out unless the "Include previously saved" switch is on
  (`includeSaved`, off again as each save starts). With it on, a copy still
  in its folder counts as saved and goes on the queue again if missing. Copies go in Squeaky's folder on the phone
  (On My iPhone, Squeaky, one folder per person). Paths kept in the queue and
  records, and the Photos list's copies (0.29.14), are moved to the new
  install's folder after each reinstall; matched on
  "/Containers/Data/Application/<id>", the phone's and the simulator's alike.
  A saved photo whose copy has left the phone (a raw on the server) shows no
  square once the card is out.
- The NAS: its shared folder, connected in the Files app and chosen once in
  Settings (`NASThroughFiles`), matched by the name the Files app shows (a
  shared folder's own name is internal, "Nm3Lvwhomes" for homes). Sending
  runs only while Squeaky is open; the screen stays on while saving or
  sending.
- Each person manages their own photos (David, 15 November 2026), in the
  Photos library since 0.29.15; Squeaky's own working copies leave the phone
  once on the server.
- One person per phone (David, 15 November 2026), kept as `macOwner`.
  Choose card is dimmed until the person is saved.
- Not every card is the phone's person's (David, 15 November 2026: his
  partner copies his photos from his card). The first time a card is
  chosen, Squeaky asks "Whose card is this?", Mine or Someone else's,
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
  nothing in Squeaky is orange; blue on the phone), kept in Squeaky/Maps as
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
  ...)`; the phone loads `Phone/Squeaky/Words/words-<language>.json` at
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
  folder on the phone) holds a `~Squeaky` folder (`.squeaky` before 0.29.23) with one list per
  device, `saved-<device>.json` (the Mac's id, or a phone's own), of the
  photos it saved from cards: name, size, time taken (`ServerList`). Each
  device writes its own whole list as it opens and after each save; a card
  being read is checked against all of them, once per card, so a card one
  Mac or phone handled reads as saved before on every other.
- Written as Squeaky opens, whenever the server answers and they were not
  written since it opened, and after each batch sent (0.29.2). The Photos
  page says so, in David's words (0.29.3): "Sync file saved on NAS. Last
  save: Mac app @ 20:03" ("on server" on the phone), whichever device wrote
  last; "Sync file not saved yet."; or "Sync file not saved:" and why. On
  the Mac it sits on the title row, after the buttons; on the phone, first
  in the top section. Squeaky's own openings of
  the NAS are not closed while the lists are written.
- A server known not to answer is not waited for; then only the device's
  own list counts. Someone else's card on a phone is never checked.
- This is Squeaky's own record on the server, read only to know what was
  saved; it never decides anything about the photos there.

## Offsets shared, the offset code and squares on the phone (0.29.1, David, 16 November 2026)

- Camera offsets go through the same `.squeaky` folder: each device writes
  `cameras-<device>.json` with the person's cameras that have an offset;
  for each model the offset set most recently on any device wins
  (`Camera.offsetSet`; before 0.29.1, the last offset code reading's date).
  Read as Squeaky opens and before a card is read; written whenever an
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
- Since 0.29.20 the track service names its tracks (tracks 0.4.1, field
  `place`), so every site shows the same; Squeaky shows that name and names
  only tracks the service does not hold itself.
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
  whenever Squeaky reads the server folder, not only when it writes.

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
  each sharing: as Squeaky opens, when the server answers again after being
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
  and carries on when back. Noted when Squeaky was in the background
  meanwhile.
- The phone has no Status column: its line gives each reason with how many.
  A failed square has a red mark; the count of saved photos updates after
  each photo.

## The Photos library and the background (0.29.15, David, 16 November 2026)

- Photos saved on the phone go into its Photos library, not Files (David:
  "they should show in the library"): every JPG saved from a card is added
  with its location and date (`PhoneLibrary`, add-only permission). Raws
  never go into the library. Squeaky's working copies live hidden in
  Application Support/Squeaky/Copies, out of the phone's backup, and each
  leaves once it is on the server. Someone else's JPGs go into the library
  and their copy is removed at once. Squeaky no longer shows in Files.
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

## Who an SD card belongs to (0.29.19, David, 16 November 2026)

- The old Card row switched a card's owner on a tap and read it again;
  David tapped it to read the card again and his card became someone
  else's (JPGs only, never checked against his list). Now the Photos tab
  only says "SD card belongs to: David" (or "Someone else"); reading again
  is the round icon at the top right ("Check photos again"); the owner is
  changed only in Settings, SD cards, with Change and the question "Does
  this SD card belong to David?" (Yes, No), the same question asked the
  first time a card is read. 0.29.19 set cards marked someone else's back
  to the phone's person once.

## Sync files written safely (0.29.21, David, 17 November 2026)

- Sync files are written through a coordinated write (`ServerList.put`),
  as they are read, since a plain write could hang on the NAS through the
  Files app; only when something is new since the device's last write
  (a fingerprint of its list and offsets); in the background, never holding
  up a card; tried again each minute while it fails. The line then says
  "Not synced with the NAS yet: <why> Trying again each minute; your photos
  are not affected, you can carry on." ("server" on the phone).
- The one-off reset of SD cards marked someone else's runs as Squeaky starts,
  before any card is read.

## The sync folder made visible (0.29.23, David, 17 November 2026)

- The phone reaches the NAS through the Files app, which hides folders
  whose name starts with a dot: ".squeaky" looked absent, so the phone never
  saw the Mac's list and said "not saved yet". The sync files now live in
  "~Squeaky" in each person's server folder (0.29.24; the tilde keeps it at
  the top of the list, David's choice); each device moves the old
  hidden folder's files there the first time (`ServerList.moveFromHidden`).
  Finding no sync file at all is said ("No sync files found on the server."),
  never shown as "not saved yet".

## No name on the phone (0.29.25, David, 17 November 2026)

- The phone's person is set up by itself, tied to the ID the phone gives
  Squeaky (identifierForVendor; apps cannot read the IMEI), with no name: a
  name typed and never saved left the phone with no person, and the sync
  files were skipped without a word. The SD card question reads "Is this
  your card?"; the Photos tab says the card belongs to "you" or "someone
  else". The Name field is gone from Settings.
- Settings' checkmark turns blue when something typed is not saved yet;
  a tap outside the keyboard closes it.

## The wheel (0.29.26, David, 17 November 2026)

- Any wait longer than half a second shows the spinning wheel beside its
  line, in Squeaky (his rule for this project only): reaching the NAS on the
  sync line ("Reaching the NAS"), moving photos out of Files, naming tracks
  by place, working out the server folder's path in Settings, and every
  step that already had one.

## One synced list per person (0.29.27, David, 17 November 2026: "i want a synced list. everyone their own is not a sync")

- Each person's "~Squeaky" holds one `saved.json` (every photo saved by any
  device for that person) and one `cameras.json` (each camera's newest
  offset), each with when and by which kind of device it was last updated.
  A device reads them, adds what it saved, and writes them back only when
  something is new, once a card's save is done or a batch is sent, never
  per photo; entries are never removed, and anything lost to two writes at
  once is added again at the next. The Mac keeps one per person it saves
  for. The per-device files of 0.29.2 to 0.29.26 are merged in the first
  time, then removed from the NAS.
- The sync line: "Sync list: 4,230 photos, last updated by the Mac app @
  01:21".

## HIF photos, reasons, mobile data (0.29.28, David, 17 November 2026)

- HIF photos from the person's own card (his cameras save .HIF with HDR
  PQ on) go straight into the phone's Photos library with their location
  and date set in Photos, not written into the file: no copy, not sent to
  the server, not on the sync list; he will decide on that later. Noted on
  the phone only (`heifAdded`) so they show as saved. This replaces the
  phone's earlier "never HEIC" rule for his own HIF photos.
- "Show what wasn't saved" on the Photos tab, when anything failed, lists
  each file with its reason.
- The saving line is two fixed lines, "Saving X of Y" and "Z left" (a
  blank second line until known), the wheel beside the first; "adding to
  Photos" is no longer said.
- Settings, Server: "Allow backup over mobile data", off by default; while
  off and the phone is on mobile data only, sending waits for Wi-Fi and
  says so.

## Sending while locked, line breaks, titles (0.29.29, David, 17 November 2026)

- The phone stopped sending once locked (9 of 231 sent, none failed).
  The background work's progress now moves with each part of a photo, not
  once per photo; sending that starts without a save asks for background
  time too (while Squeaky is in front); when the phone ends it anyway, or the
  server stops answering for a minute, the Photos and Queue tabs say
  "Sending stopped while the phone was locked, after 9 of 231. Carrying on
  now." when Squeaky is back, until nothing is waiting. The cause is not
  proven; this is the best reading.
- Phone messages that do not fit on one line start each sentence on a new
  line (`Sentences`, `LineBreaks`); a soft break (`LineBreaks.soft`) is ", "
  on one line and a new line otherwise. A time never splits.
- The phone's Queue line: "DAVL4150.CR3 to Squeaky, ≈ 9 h 15 min left
  (speed: average)", no full stops, broken at the comma when long. The Mac
  keeps its own line.
- Page titles sit in the top row on the left, smaller, level with the round
  button (`PageTitle`). Clear photos is red. The line under a row with the
  wheel starts at the wheel. Queue: "Not sent" is "Failed".

## Settings and Tracks reworked (0.29.30, David, 17 November 2026)

- Cameras: one line each, the name and "Offset" with a small green check
  once set ("Not set" otherwise). No figure and no typing: the offset code
  is the only way to set it on the phone (David: the figure tells nothing,
  and it drifts).
- SD cards: Rename (a name kept by Squeaky, `cardNicknames`; the card's own
  name stays in `cardNames`; the card is never changed) and Change.
- "GPS tracks service" (the phone's English messages say so too), with an
  i in its heading opening `ServiceFormat`: what a service must answer, for
  anyone running their own. Once a key is saved: the address, a green check
  for the key, Change and Remove (red) side by side; Change opens the
  fields, saved with the top checkmark.
- Server: an i in its heading opens the steps to connect a file server
  (the separate line is gone); Change and Remove side by side, Remove red.
- Tracks: the status line has no box; an Import button at the top right
  takes GPX or FIT files from the Files list, as the Mac's import does.

## Unsaved photos tried again (0.29.31, David, 17 November 2026)

- "Show unsaved photos" (it was "Show what wasn't saved") opens "Unsaved
  photos": each file and its reason, and "Try again", which reads the card
  again (so a photo this version can now handle is read afresh) and saves
  as Save photos would. With the card out, the button's place reads
  "Insert the card to try again"; never a dimmed button there.

## One notification, paused not failed (0.29.32, David, 17 November 2026)

- He saw "Sending 3 of 205" and "Task failed" side by side. Squeaky now
  hands the phone one background request at a time (`asked`), and ends
  its work as finished with its last words: "Sending paused: 3 of 205
  sent. It carries on when Squeaky is open." or "Saving stopped: 40 of 300
  saved.", never as failed. An install that closes Squeaky mid-send still
  leaves the phone's own "failed" notice: say so before each install.

## Tracks, Queue and Settings tidied (0.29.33, David, 17 November 2026)

- Tracks: a one-sentence line has no full stop on the phone ("No new
  tracks"); the line sits close under the title; "Recheck photos"; the map
  credit is the last row of the list, not laid over it.
- Queue: "≈ 9 h 15 min left" in the top row, right of the title, while
  photos go up; a "Sending" section with each photo's name and the wheel at
  the right edge (the speed is no longer shown); the queue line shows only
  when nothing is going up.
- Every pair of buttons side by side is two `HalfButton`s, each half the
  width less the gap; a lone one keeps half (`HalfSpace`); Remove is red.
- SD cards: name and owner on one line; Rename only while that card is in.
- Settings' tap-to-close-the-keyboard is active only while a field is being
  typed in: always on, it swallowed taps on plain buttons (Show offset code
  did nothing).

## A track's large map (0.29.35, David, 17 November 2026)

- Tapping a track on the phone opens `TrackMapPage`: the same wordless map
  as the small pictures, drawn at the page's size (`MapThumbnails.large`,
  kept as `<id>-phone-large-<w>x<h>-<light|dark>.png`), the route framed to
  fit, no moving or zooming (David: "just a big image like the others is
  enough"); "Making the map" with the wheel until it is ready; the credit
  under it. Simulator: `--track-map --maps <file of GET /v1/maps>`.
- The panel before saving: "Latest track: Ronda, Andalusia" and "Starts 17
  Nov 2026, 15:57" on separate lines when they do not fit on one; a line
  begun at a soft break starts with a capital.

## Paste in every field (0.29.36, David, 17 November 2026)

- A tap outside a text field closes the keyboard through `KeyboardCloser`, a
  window-wide tap watcher that ignores touches inside a `UITextField` or
  `UITextView` and never cancels touches. The Settings tap gesture of 0.29.25
  and 0.29.33 is removed: it closed the keyboard on a tap inside the field
  itself, so Paste never appeared ("i can't paste it").

## Card out, and the language choice (0.29.37, David, 17 November 2026)

- The phone says nothing when a card is pulled out, so `CardWatch` checks the
  card in use every 3 s while nothing reads or saves it; gone, it calls
  `AppModel.cardTakenOut()`: the card let go of, the list and whose it is
  kept, "{0} was taken out." on the Photos page. Rename greys out and the
  unsaved photos say "Insert the card to try again" (David: "the sd card
  menu is still active while there is no card connected").
- `CFBundleLocalizations` in `Phone/Info.plist` lists en, es, fr, zh-Hant.
  The iPhone offers a Language row under Settings, Apps, Squeaky, only when
  the phone itself has more than one language in General, Language & Region.
  `Locale.preferredLanguages` then starts with the language chosen there.
- Simplified Chinese is removed (David: "only need traditional chinese. not
  simplified"): no `words-zh-Hans.json`, no `zh-Hans.lproj`; a phone in any
  Chinese gets Traditional.

## The iPhone's own settings, linked (0.29.38, David, 17 November 2026)

- Settings the iPhone keeps for Squeaky stay there (Apple's convention): the
  Settings page's last row before the version opens them
  (`UIApplication.openSettingsURLString`), "Language, access to Photos,
  notifications and mobile data" under it.
- "Allow backup over mobile data" is removed (David: "it's clearly a settings
  setting"); told that upload apps usually keep their own Wi-Fi-only switch,
  he still chose the iPhone's. `NetworkWatch` now only notices the iPhone
  keeping Squeaky off mobile data with no Wi-Fi (`unsatisfiedReason ==
  .cellularDenied`): sending waits and says "Waiting for Wi-Fi to back up to
  the server" instead of failing.
- Once on each phone (`mobileDataReminded`), an alert at launch: "Mobile
  data", how to stop sending over it, "Open iPhone Settings" and "Close".
  Not shown in the debug flow test.

## "Is this your card?" from its button (0.29.39, David, 17 November 2026)

- The question is attached to each SD card's Change button, so the iPhone
  opens it from that button; attached to the page, it opened near the top
  ("appears too high, not tied with the actual location of the launching
  button"). Simulator: `--tab settings --ask-card` asks about the first card.

## Copy done, remove the card (0.29.40, David, 17 November 2026)

- After saving, with every photo saved and the card still plugged in
  (`AppModel.cardStillIn`, set by `letGo` and kept by `CardWatch` while a
  let-go card is still there), the Photos page shows "Copy done. Remove the
  card." where "Open card" was (David: "makes no sense. we've just
  finished"). Once the card is out, "Open card" is back. Photos not saved:
  unchanged.

## The Queue page reworked, and a record of background runs (0.29.41, David, 17 November 2026)

- The photo going up is first on the page, its name on a blue bar that fills
  with `SendStep`'s share (`ProgressFill`); no wheel. Pause is a round button
  top right (play while paused). "Retry failed uploads" is a round refresh
  button beside the Failed count, from one failed up. The server row is
  removed ("we've only enabled one in this setup").
- A box at the bottom while sending: "Estimated time" (`Remaining.approx`,
  no ≈ any more), "Average time per photo" (that time over the photos left,
  `Remaining.each`), "Speed": `SendSpeeds.Rating`, now with Very slow for
  the slowest tenth of every photo timed.
- `RunLog` writes `Library/Application Support/Squeaky/background-runs.log`
  (newest 3000 lines): Squeaky opening, background, lock and unlock, closing;
  each background request, start, a line every 30 s with counts and how the
  phone stands, and how it ended (by the iPhone, or closed by Squeaky). Read
  it over the cable with `xcrun devicectl device copy from ... --source
  "Library/Application Support/Squeaky/background-runs.log"` to find the
  cause of "Task failed".

## Each photo's share on the right (0.29.42, David, 17 November 2026)

- The Sending rows show `Going.percent` ("42%") on the right, over the blue bar.
- Greyed out when they cannot be used (David: "all buttons should be greyed
  out if they are in a situation where they cannot be used"): Pause with
  nothing waiting or going; the Settings tick with nothing to save; Import
  with no service or a reading key; Refresh with no service; Rename's Save
  with an empty name.

## The wheel back in front of the name (0.29.43, David, 17 November 2026)

- Each Sending row: the wheel, the name, the percentage on the right, over
  the blue bar ("the blue progress is too slow to feel it's doing something").

## Card names: removed (0.29.44, David, 17 November 2026)

- "Rename" for SD cards is removed, with its window and the names kept in
  Squeaky (`cardNicknames`, cleared at launch): the iPhone gives no app a way
  to rename a card, so a name only Squeaky showed was a pretend rename ("the
  name was not applied to the card ... remove all that mambo jumbo"). Each
  card shows its own name, as in Files.

## Each photo timed in the record (0.29.45, David, 17 November 2026)

- `AppModel.onPhotoTimed` hands each photo sent through every step to the
  phone, which adds a line to `background-runs.log`: name, size, total, and
  the time spent looking, sending, reading back and naming, with the sending
  speed. Nothing on screen ("no need to report on the app. at least not yet").

## The buffer server, bufr.cc (0.30.0, David, 17 November 2026)

- Away from home, photos go to bufr.cc (its own project, ~/Sites/bufr.cc), and a
  container on the NAS fetches them home; at home they go straight to the
  NAS as before. Why: the home is behind CGNAT, so Tailscale only reaches the
  NAS through the Miami relay, about 0.5 MB/s; Cloudflare took 2 MB/s.
- At home or not: `GET /v1/status` says `atHome` when this device's address
  is the one the NAS last fetched from. Asked at most once a minute
  (`useBuffer`); the buffer server not answering means the NAS route.
- `sendThroughBuffer` hands up to 30 photos at a time to `BufferUploads`: on
  the iPhone a background URLSession (`.buffer` identifier), which carries on
  while Squeaky is closed or the phone locked, with no notification; on the
  Mac an ordinary session. Each upload carries its fingerprint, which R2
  checks: no reading back. When all are done the phone wakes Squeaky
  (`PhoneAppDelegate`, `PhoneModel.shared`) to hand over the next 30.
  BackgroundWork asks for no continued-processing task on this route.
- The path sent: the Mac's `nasFolder` ("homes/david/Squeaky") plus the
  photo's relative path; on the phone the Files folder's path
  (`nasBookmarkPath`, "home/Squeaky"), which bufr.cc turns into
  "homes/<user>/Squeaky" from the key.
- The keychain item on the iPhone is readable after first unlock, so a
  relaunch with the phone locked still has the key.
- A NAS batch already going asks `useBuffer` before each next photo, so a
  key saved mid-batch, or leaving home, hands over without reopening (0.30.1).
- Each buffer upload is timed from its first bytes going up, not from being
  handed over: 30 are handed over and two go at a time, so the time spent
  waiting its turn made 40 s read as 2 min 18 s (0.30.2).
- Over HTTP/2 every handed-over upload goes at once on one connection, so a
  photo's own time is its share of the line: "8 min per photo", "36 h
  left". `BufferUploads.pace()` counts the bytes of all of them over three
  minutes; `sendingSeconds` and the speeds recorded use it (0.30.3).
- A phone with no server folder chosen yet sends through the buffer server,
  as "home/Squeaky/...", wherever it is: Amanda's phone until her folder is
  chosen at home in Panama, over the home network with no Tailscale (0.30.4).
  Once a folder is chosen, home goes straight to the NAS again.
- A photo counts as sent once at bufr.cc. "Waiting on the buffer server"
  (Queue) is what the NAS has not fetched yet; "Connected to server" or
  "Connected to buffer server" says the route (David's words).
- Settings: a "Buffer server" section (phone) and card (Mac), address and
  key, default address https://bufr.cc.
- Simulator: `--flow-test ... --buffer <address> <sender key>` sends through
  a local `wrangler dev` of bufr.cc; then `nas/fetch.py` with `BUFR_ONCE=1`
  fetches into a scratch folder. A fetch from the same address within ten
  minutes makes it "at home" and the NAS route is taken: use a fresh store.

## Photos by day, chosen by hand (0.31.0, David, 18 November 2026)

- While the card is in, the Photos page shows every photo on it (one square
  per frame, the JPG of a pair), in a section per day: newest day first,
  earliest photo first within it (`PhotoDays`). The title is the phone's
  own full date form ("Monday 20 June 2026"; David first asked for "20th",
  then dropped it), on its own line so it is never cut; the count and
  "Select all"/"Deselect all" under it.
- A blue tick top left on each square is `ImportRow.ticked`, for every file
  of the frame (`AppModel.setTicked`). "Save selected photos" saves the
  ticked ones, photos copied before included (copied again). New photos
  start ticked, ones copied before not.
- A slide that starts sideways on a square selects (or deselects, when it
  starts on a selected one) everything from where it began to the square
  under the finger, in the page's order; moving back restores the rest.
  Scrolling is off during it; in the top or bottom tenth the page moves
  three squares at a time. Up or down at the start scrolls, as in Photos.
- Days fold on a tap of the title, remembered in `photoDaysOpen`; days
  whose photos were all copied before start folded, and their pictures are
  made only when opened. Simulator: `--tab photos --show-card <folder>`.

## Queue rows that stay put (0.31.1, David, 18 November 2026)

- The Sending rows animate on `meter.order`: one done fades and the rest
  slide up; their separator starts at the row's left edge. Uploads picked
  up again after a reopen are listed in the queue's order, not a set's.

## HeroUI's blue (0.31.2, David, 18 November 2026)

- The phone app's accent is HeroUI's default blue, #0485F7
  (`Color.heroBlue`, and the AccentColor asset for what the system draws).
  The Sending bars are that blue, solid, with the words white where the bar
  lies under them (`SendingRow`).

## Day cards, nothing selected to start (0.31.3, David, 18 November 2026)

- On the phone every photo starts deselected; "Select all photos" above
  "Save selected photos" selects the card's every photo.
- Each day is a card: its title row ("17 Nov 2026", the template "dMMMy" in
  the phone's order, since the medium style can be all numbers) with one
  button, "Select 67" or "Deselect 67", then its photos.
- The slide works in screen coordinates for both the finger and the
  squares: a named coordinate space put it a row off.
- The flow tests select every photo before saving.

## Photos held when the camera has no offset: replaced (0.31.8)

- 0.31.4's hold is removed (David, 18 November 2026: "i always want the
  choice"; his card on Amanda's phone could never be saved). See below.

## Six at a time to the buffer (0.31.5, David, 18 November 2026)

- `sendThroughBuffer` hands over 6 photos at a time, not 30: over one HTTP/2
  connection all handed-over uploads go at once, and starved ones timed out
  and started again ("57% then back to 11%"). A stalled upload now waits
  600 s before the phone starts it again. Watch the record for slower
  sending while locked: each batch of 6 needs the phone to wake Squeaky.

## The buffer bar reaches 100% (0.31.7, David, 18 November 2026)

- A photo going to the buffer server fills its bar on `StepWeights.buffer`
  (sending is all of it): on the NAS weights it stopped at 62% ("62% is the
  maximum value I see before the image disappears"), the reading back and
  naming never happening on that route.

## The choice, no duplicates, lists at bufr.cc, the red line, locations in Photos (0.31.8, David, 18 November 2026)

- Save selected photos is on whenever photos are selected, whatever their
  camera's offset. The panel before saving says "12 photos have no camera
  time offset. They will be saved without a location."; the Photos page's
  reason line adds "Show the offset code in Settings and photograph it with
  that camera." while such photos are selected. Never hold a photo back
  from saving without giving the choice (David: "i always want the choice").
- No duplicates: just before copying, each selected photo is checked
  against this device's record, the sync lists kept here and the HIF list
  (`alreadyCopied`); those are left out and unticked: "8 photos already
  copied, not copied again." Photos copied before without a location
  included: Locations in Photos (below) is the way to place them.
- Sync lists at bufr.cc too (bufr.cc 0.2.1, `GET`/`PUT /v1/lists`, header
  `X-Path` = the person's base + "/~Squeaky/saved.json" or "cameras.json",
  the same path the NAS has; `bufferBase`). `syncThroughBuffer` reads both,
  adds them to the copy kept here (`keepServerCopy`: never replaced, only
  added to, the NAS read included), and writes back when something is new.
  Run first in `shareWithServer` (as Squeaky opens, after each save and
  batch) and before each card is read, at most 10 s ("Reading the sync list
  from the buffer server"). Reached, it clears the sync line's problem; the
  NAS write passes on what it added. Card reading itself stays local.
- The red line (`InternetState`, `InternetLine`): fixed at the very top,
  over every tab on the phone (`safeAreaInset` on the TabView) and above
  the page on the Mac. "No internet connection" from the device's network
  state; "The internet connection is unstable" from `NetHealth`: the track
  service, the buffer server (status, lists, uploads) and map tiles report
  each request; two network failures within a minute, until two requests
  in a row get through (David: "the app should tell us when the internet is
  unstable/not connected", "in red", "stays visible when scrolling").
- Locations in Photos (phone, `LibraryLocations`, David: "much cleaner"):
  photos in the Photos app with no location, taken from two days before the
  first track on, whose original is a JPG from a camera Squeaky knows with
  its offset set (the phone's person's, else Others'), get the location
  their time falls on, set on the photo already there
  (`PHAssetChangeRequest.location`, 100 a batch; the iPhone asks to allow
  each). Photos keeps it in its own record; the file inside is not
  rewritten. Each photo's clock reading is read once and kept in
  `libraryread.json` (originals in iCloud only are not fetched). Full
  access to Photos is asked only from the button "Add locations to photos
  in Photos"; once given it looks by itself whenever the tracks change,
  with the card out. Copies already on the server keep no location.

## Ticks, the panel's map, offset code photos, days in two (0.31.9, David, 18 November 2026)

- Every photo already copied, by any device known, shows the green tick as
  soon as the card is read (`isSaved`), not only those copied since: "there
  was nothing showing".
- The panel before saving shows the latest track's map (`TrackLargeMap`,
  shared with the large map page, made at its size) with the map credit.
- Photos of the offset code are left out of the list (`offsetCodeFrames`, by
  frame), on the phone and the Mac: never shown, copied or sent. A reading
  that changed the record adds "Offset updated for <model>" to
  `offsetNotices`, shown under the red line inside Squeaky (`NoticeLines`),
  never a system notification, until closed.
- A day with photos copied and not is two cards: "<day>" with every photo
  not copied yet, then "<day>-copied" with a green tick in its title, folded
  to start; every fully copied day has the tick; all copied, one card again
  (it keeps the copied card's fold state).
- `Phone/install_phone.sh` takes `PHONE=<id>` for the phone on the cable
  when another one is about over Wi-Fi.

## Squeaky in Chinese (0.31.10, David, 18 November 2026)

- On an iPhone set to Chinese the app is named Squeaky ("photos along the
  way", David's pick of three), under its icon, in Settings and in the
  Photos permission texts (`zh-Hant.lproj/InfoPlist.strings`). Everywhere
  else, and in the words inside the app, it stays Squeaky.

## Which photos got a location (0.31.11, David, 18 November 2026: "i've no idea which ones they were")

- "Add locations to N photos" opens `LibraryPhotosPage`: each photo with
  its date and time and the place it will get (OpenStreetMap, else the
  coordinates), and "Add locations" at the bottom. "Locations added to N
  photos in Photos" opens the same page for the photos the last batch
  changed, kept in defaults (`libraryAdded`) until the next batch.

## Architecture

- `SqueakyCore` is the domain and knows nothing about the interface.
- `SqueakyUI` holds the model, phone-only since 0.34.13. The phone's screens
  are in `Phone/Squeaky`.

## Working on it

- Each stage: describe its design, wait for his approval, then build it.
- Never open the app, or anything else, on his screen without asking first.
- Never delete anything on his computer, not even copies or scratch files
  made here (his rule, 16 October 2026). Ask in the chat first. The one
  exception he gave: each new build replaces the previous Squeaky in
  Applications and in `build/`.
- Raise `appVersion` in `Sources/SqueakyCore/Version.swift` with every change
  that is committed or installed, the phone's included, and start the
  commit subject with that number (David, 16 November 2026: six phone
  changes went out as 0.28.0 and he could not tell he had the latest).
- Commit locally as often as it is worth, and push to GitHub without asking
  (David, 6 November 2026: a push here only saves versions; nothing goes
  live from it). Installing a new build on the phones still needs his yes.
- British spelling. No em dashes.

## Notes

### Squeaky scope: send and check once

Squeaky's job on the NAS ends with the send and its first check (read back and compared on arrival). David, 5 Nov 2026: "we're not building a continued integrity tool". No later look at the NAS to decide anything, e.g. before removing Mac copies.

**Why:** the NAS has RAID plus a nightly remote Hyper Backup, and David plans to sort the photos later, deleting or renaming files and folders, so later checks would misfire.

**How to apply:** decisions about photos already sent rest on Squeaky's own record of the send, never on what the NAS holds now. Mac copies are removed 30 days after reaching the NAS (matches the Mac Trash's 30 days; time to use the photos while fresh). Related: [[squeaky-state]].

### Squeaky: push without asking

On Squeaky, push without asking (David, 6 Nov 2026: "since push does nothing
more than save versions on this project, dont ask me for push on this
project only").

**Why:** Squeaky is a Mac app; GitHub holds its versions and nothing goes
live from a push, unlike his Cloudflare sites where a push to main is a
release.

**How to apply:** after a Squeaky commit is built and tested, push it
without a question. Still ask before installing a new build on his Mac
(it quits his running Squeaky). Every other project keeps the push
question. Claude Code's own safety check treats a push as a release, so
`.claude/settings.json` here allows `git push` (12 November 2026, his
yes). The project lives in ~/Apps/squeaky since 24 November 2026. Exception to [[david-plan-then-ask-to-push]] and
[[keep-wine-no-push-without-word]].

### Notes only in cross-project changes

Said 26 Oct 2026: in changes made across all projects, only Squeaky's notes are aligned, nothing else, unless David names it.

## Receiving tracks from the Geotrac watch app (Watch 0.2.0, Squeaky 0.32.0, David, 19 November 2026)

- The watch app is Geotrac, in the tracks project (`~/Sites/tracks/Watch/Geotrac`, moved 21 November 2026); its rules are in that project's brief. Its app id `df38ae45-bb86-4899-9ea8-c45147dfc5ee` (the public store listing, 0.34.10; the beta and sideloaded one was `14bdff03-...`) is `WatchLink.appId` here: change both together or never.
- Phone: Garmin's kit, Swift package `connectiq-companion-app-sdk-ios` pinned at 1.8.0, `-ObjC` linker flag, URL scheme `squeaky-ciq`, `gcm-ciq` in queried schemes, Bluetooth background mode. It works with the free signing (no entitlement needed). Settings, Watch, Choose watch opens Garmin Connect once; the picked watch is kept in UserDefaults `watchDevices`.
- Parts are kept in `Application Support/Squeaky/Watch/<id>/<n>.bin` (`WatchInbox`) and acknowledged one by one; the track is added when whole, as `watch-<start seconds>`, named "From David's fēnix watch" (the phone's person and the watch model's first word). It is used for matching at once. On the owner's phone it waits to upload and goes up with the next refresh, tried every five minutes while any wait.
- Family phones: `TrackShare`, MultipeerConnectivity service `squeaky-trk`, only between phones whose track service address is the same (a hash of it in the discovery info and the invitation). Each sends the watch tracks the other lacks; the receiving phone shows "Track received from David: date, length" with OK.
- Duplicates: `sameStartSeconds` is 20 (was 60). Of listed tracks starting within 20 s, the longest stays listed, the others are set aside (`Track.setAside`). geotrac.cc still uses 60 s and keeps the first: changing it belongs to the tracks project.

## Videos (0.33.0, David, 20 November 2026)

- MP4, MOV and CRM (Canon RAW video) are listed, selected, matched and saved
  like photos, on the phone and the Mac alike (`PhotoKinds.videos`).
- Videos are read and written by `NativeMetadata` on both, never ExifTool:
  Canon keeps the CR3's CMT1 to CMT4 boxes in its videos, so the location goes
  into the padded CMT4 and every other byte stays the card's
  (`Layout.movie`, kept apart from `cr3`). A video with no such room is
  saved unchanged without a location, and the save line says how many.
  Without Canon's boxes the start time is the container's, in UTC.
- Untested on a real Canon video at 0.33.0 (none on the Mac): the self-test
  builds one (`SelfTest.videos`) with Canon's boxes appended. Check on the
  first real card.
- Squares and the Mac's preview show a frame (`MovieFrames.picture`), a play
  mark and the length bottom left ("10:07"). A CRM is purple with a broken
  video icon (0.33.1, David), never a picture. On the phone, videos go into
  Photos with the location given to Photos (it does not read CMT4); CRM never
  does.
- Holding a square on the phone opens a half-height panel (`Viewer`, 0.33.1,
  David): photos and videos larger, swiped sideways through every day in
  order, closed by swiping down. A video has a round black (90%) button with a
  white play icon in the middle and plays in the panel; a CRM shows purple.
  No context menu on the squares: in a List the menu lifted the whole day.
- A CRM and an MP4 of the same name and moment are one square, the MP4's.
- Someone else's card on the phone: its MP4 and MOV too, not its CRM.

## Geotag became Squeaky (0.34.0, David, 20 November 2026)

- Every name is Squeaky: the apps, bundle ids (`com.webpty.squeaky`), modules
  (`SqueakyCore`, `SqueakyUI`, `SqueakyApp`), the phone project and scheme
  (`Phone/Squeaky.xcodeproj`, `SqueakyPhone`), and
  the folders, the keychain service, the phones' link service
  (`squeaky-trk`) and Garmin Connect scheme (`squeaky-ciq`), the test settings
  (`SQUEAKY_*`), and the location note ("GPS coordinates added by
  Squeaky.app"). Only the commit history says Geotag. The repo is
  github.com/webpty/squeaky. The watch app id is unchanged (it carries no name).
- The icon is David's cat (`Resources/AppIcon.png`, 1024, no transparency); the
  watch app is Geotrac now, in the tracks project. Chinese uses "Squeaky" too.
- The name Geotag survives in code only to carry data over: `FromGeotag` on a
  Mac's first launch moves Application Support/Geotag, ~/Pictures/Geotag (and
  the paths in the records), iCloud Drive/Geotag, the settings, the track
  service key (the Mac asks for its password once) and opening on a card;
  `ServerList.oldFolderNames` moves "~Geotag" lists to "~Squeaky"; leftover
  ".geotag-" working copies are still cleared. The phones start empty: a new
  app; Geotag is deleted by hand once its queue is empty.
- bufr.cc only keeps lists under "~Geotag" until its own session accepts
  "~Squeaky": until then the phone cannot read the lists through it.
- The server photo folders (homes/david/Geotag, homes/amanda/Geotag) are
  David's to rename on the NAS; each device's Server setting then follows.

## Phone panel, delete and selecting (0.34.2, David, 20 November 2026)

- The panel is tall enough for a portrait photo across its width, with a round
  red bin button below while the card is in. "Are you sure?" with Cancel and
  Delete in the middle of the screen; Delete removes every file of the square
  from the card (`AppModel.deleteFromCard`), the only thing Squeaky writes to a
  card. Copies already saved stay. The panel moves on to the next square.
- No Delete on the Mac (David, 20 November 2026: "no"): it keeps opening cards read-only (`CardGuard`), never writable, not even for a delete. The one exception to every feature on both.
- A video starts behind its picture and shows once its first frame is there.
- Each square watches its own picture (`PictureBox`) and square positions sit
  in `SpotBox`: neither redraws the page, which shook while a card loaded.
- Select is blue, Deselect purple (each day and Select all photos); a folded
  day's button is greyed out, and folding never changes what is selected.
- The panel (0.34.3, David): the shown square, then the next and previous,
  made ready large (`LargePictures`, the last nine kept); until then the grid's
  picture, enlarged, never black. A 40-point strip above the photo keeps it
  clear of the corners (the iPhone's own rounding, 0.34.7: never change a default) and holds "Photo deleted" / "Video deleted"
  for two seconds. Delete sits in 64 points below. The height follows what is
  shown: a portrait photo (2:3) or a portrait video (9:16) across the width.

## Buttons, grey, hiding what is saved, Photos checked (0.34.4, David, 20 November 2026)

- Every action on the phone is a real button (`WideButton`: full width, 46
  high, radius 12): Select all blue / Deselect all purple; Save selected blue
  and Save all teal side by side (`ViewThatFits`: stacked where the words are
  too long, French and Spanish); Clear red; others grey. Each group its own
  card, no titles. "photos" is gone from the button words.
- No "Done with this card" on the phone: no eject there; the card is let go
  of once every photo is saved, or when taken out.
- Dark mode is dark grey, not black (`Palette`: page 0.12, cards 0.20, panel
  0.25); every list row takes `Palette.card` (`cardRows`). Light is unchanged.
- "Hide already saved" (`hideSaved`, on to start, kept) replaces "Include
  previously saved" on both: on, saved photos are hidden and cannot be
  selected or saved (`choosable`); off, they show, and saving them copies
  them again. The Mac's "Hide photos saved before" became the same switch.
- The phone looks in the Photos library before adding a photo or video
  (`PhoneLibrary.index`: assets taken within two days of the card's span, by
  original file name, jpeg as jpg, and moment within 2 s, or 14 h without a
  zone); one already there is not added again, AirDrops included, and the line
  says "3 already in Photos, not added again." It still goes to the server.
  Needs full access to Photos, asked once.
- 0.34.5 (David): buttons are Apple's own (`WideButton` is a
  PrimitiveButtonStyle around `.borderedProminent`, large, tinted; grey is
  `Palette.greyButton`), never an invented shape; the panel's delete is
  Apple's round button. Button rows have 16 points on every side. Switches are
  green (`SwitchToggleStyle(tint: .green)` at the root). Select all sits in the
  saving card. The panel before saving says "None of the photos have a
  track..." or "12 of 40 photos have no track...", and offers "Save only
  those with a track" (`saveOnlyTracked`: the rest stay selected).
- 0.34.6 (David): the panel before saving says "Cancel" in red, not "Don't save"; its text is body, as the Photos page; "Save selected" is dimmed with everything selected.

## Where this is heading (David, 21 November 2026)

- The goal is apps installed properly through Apple's store (TestFlight or a
  private listing, not public) once David has a paid developer account; until
  then, the free account and cable installs.
- With that account: a separate Geotrac phone app (receiving watch tracks,
  sharing them between phones, uploading to geotrac.cc), sharing tracks with
  Squeaky through a shared container, so offline matching keeps working.
  Until then Squeaky stays the phone side of geotrac.
- The watch app is a geotrac thing: to be named Geotrac, its code moved to
  the tracks project (in that project's own session).
- 0.34.9 (David, 21 November 2026): the card out (taken out, ejected, or let go of and then taken out), the Photos page empties on the phone and the Mac (`forgetCard`): photos, counts, owner, days; all read again when it is back. No Clear button on either. This replaces the 6 November rule that the Mac kept the list. The sync line moved from Photos to Settings on both.

## Cards read once, Save selected orange (0.34.12, David, 25 November 2026)

- What was read from each photo on a card is kept (`CardReadMemory`,
  `cardread/<card id>.json` beside people.json), by its place on the card,
  size and modification date. The next time the card is read only photos not
  seen before, or changed since, are opened ("since you know this card had
  1900 photos last time, only 20 are new"); the rest come from the memory, so
  "Reading 0 of 20" counts only those. Phone and Mac alike. "Try again" on
  unsaved photos reads every photo afresh (`read(fresh: true)`). Raise
  `CardReadMemory.reader` whenever what is read from a photo changes, so
  every card is read afresh once. The first read of each card after 0.34.12
  still opens every photo. Untried on a real card.
- "Save selected" is orange (`WideButton(.orange)`), apart from Select all's
  blue and Save all's teal.

## Offset codes looked for once, the server list behind the photos (0.34.13, David, 25 November 2026)

- What looking for an offset code found in each photo is kept
  (`OffsetCodeMemory`, `offsetcodes.json` beside people.json, by the photo's
  key): only photos not looked at before are looked at, so a card with no new
  photos skips the step. A code found before was added to its camera then;
  its photo is only left out of the list again.
- Reading a card never waits for the list of saved photos ("don't block the
  flow by reading it"). The list is the backup of what was saved: read and
  written in the background as Squeaky opens, after each save and each
  minute while it failed; the ticks follow when it brings anything new
  (`applySavedList`). Only a phone with no copy of it (a new install) reads it
  as a card is read, behind the photos (`restoreSavedList`).

## Only SD cards are opened (0.34.14, David, 26 November 2026)

- A folder chosen with Open card must be an SD card: one holding a DCIM
  folder, its DCIM folder, or a folder inside DCIM (`SDCard.looksLikeCard`).
  Any other folder is refused with "This doesn't appear to be a card"
  (David's words). Before, Amanda's phone opened a folder on the NAS as a
  card, read 509 of her photos, added a camera for each model in them, and,
  the folder never being "taken out", never let go of it for the real card.
- Clean-up of that bug, silent (David: "this was a bug, no need to
  specify"): a remembered folder that is not an SD card is forgotten as
  Squeaky opens or while it is open (`CardWatch.dropNotACard`,
  `forgetNotACard`), its photos off the page and its name off the SD cards
  list; once, every camera with no time offset is removed
  (`removeCamerasWithoutOffset`, defaults `offsetlessCamerasRemoved`); a real
  one comes back with the next card that has its photos.
- 0.34.15: 0.34.14 took a card being taken out for a folder that is not a
  card (an unreadable folder has no DCIM folder either) and forgot it and
  whose it was, on both phones. Only a folder that can be read and holds no
  DCIM folder is dropped now (`SDCard.surelyNotACard`); a card taken out is
  let go of as before.

## Mark as copied (0.34.16, David, 26 November 2026)

- "Mark as copied" (grey, under the save buttons) records the selected
  photos as copied on the phone (`markCopied`): nothing is copied or added to
  Photos, the green tick appears, "Hide already saved" hides them. For photos
  copied before Squeaky's record: Amanda's phone held only 77 of David's card
  (all from 25 November, 15:40), and saving the rest again would bring back
  photos she had deleted in Photos ("as soon as the photos are copied she
  manages them and deletes all the ones she doesn't like").
- It never writes over a record it cannot read; it says so instead. Saving
  still does: `save` starts from `(try? history.load(...)) ?? []`, so a record
  that fails to read once is replaced by that save's photos alone. Not proven
  to be how Amanda's record lost its older entries; worth fixing.

## Saving straight away; one track for overlapping copies (0.34.17, David, 26 November 2026)

- The panel before saving is removed ("since we can now add the gps
  coordinates post import"): Save selected and Save all copy at once
  (`saveSelected`). Photos without a track go without a location and are
  placed later with Add locations. Gone with it: the latest track's map, the
  counts without a track or a camera offset, "Save only those with a track",
  and the panel that came up by itself after a card was read. Nothing is
  saved until chosen by hand.
- Copies of the same track are one: starting within 20 s, or sharing at least
  80% of the shorter one's minutes (`TrackLibrary.sameTrack`), whatever their
  starts. Garmin and Strava trim and smooth the track Geotrac saved, so their
  copy starts elsewhere and its line differs slightly. The watch's own track
  stays listed (its points as recorded), else the longest; the rest are set
  aside, worked out afresh each time, and photos are matched against the
  listed one only. geotrac.cc's own list still holds both: the tracks
  project's to change.

## "This is a card", and removing a card (0.34.18, David, 27 November 2026)

- A folder with no DCIM folder, chosen with Open card, brings the alert
  "This doesn't appear to be a card" with Cancel and "This is a card"
  (Patrick's dashcam card may have none). "This is a card" opens it and keeps
  its id in `cardsByChoice` (`CardWatch.markAsCard`), so the clean-up of
  0.34.14 never drops it.
- Settings, SD cards: Remove (red) beside Change, for a folder taken as a
  card by mistake (`CardWatch.remove`, `AppModel.removeCard`): the folder is
  forgotten with its owner, name and card memory, and its photos leave the
  page. The record of copies is untouched, so photos copied stay copied.
  Dimmed while that card is being saved.

## Patrick and Gilbert (27 November 2026)

- Each has a reading key on the track service and a sender key on bufr.cc
  (homes/patrick, homes/gilbert), live and checked; the key files are in each
  project's `.keys/`. Patrick tries Squeaky for a week with his dashcam and
  his DJI Mini 4 Pro, away from David.
- A new phone joins the free signing only when it is on the cable while the
  phone build is made: his phone needs that build, which then serves the
  other two as well.
- Set aside for now (David): a time zone setting for cameras that write none
  (the T3i).
- Untried: a dashcam card, DJI files (DNG raws are left on the card; the
  drone's own GPS in its videos is not read), Nikon JPGs (the P950).

## Use Geotrac's tracks (0.34.19, David, 27 November 2026)

- Settings, GPS tracks service: "Use Geotrac's tracks", off by default
  (`useGeotracTracks`). Off, the phone asks the service for no tracks, takes
  none from the family's phones (`TrackShare`), and shows and matches only
  tracks imported on it (`source == .file`). The same on every phone, the
  owner key's included (0.34.20).
- Asked once, "Use Geotrac's tracks?" with No and Yes, as soon as Squeaky
  opens after the install, after the mobile data message
  (`geotracTracksAsked`). Until 0.34.20 both waited for a notification
  question Squeaky never asks at launch: two minutes on a new phone.
- Untried on a phone at 0.34.19.
- Where it is heading (David): Geotrac with many users, each with their own
  tracks, able to share them with others. That is the tracks project's work;
  this switch then becomes a choice of whose tracks.
