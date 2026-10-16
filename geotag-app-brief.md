# Geotag and Upload Mac App - Brief for Claude Code

## Goal
A native Mac app (SwiftUI) that matches photos from an SD card to the user's Garmin track (via Strava), writes location into copies of the photos, saves them on the Mac, and uploads them to a NAS through a resilient background queue. Built for an Antarctica trip with intermittent connectivity. Shared with family members, not a commercial product.

## Working rules
- GUI only: buttons, progress bars, clear status. No scripts or terminal steps for the user.
- No emoji anywhere in the app UI.
- Before building each stage, describe the design for that stage and wait for approval.
- Nothing is hardcoded. All credentials, addresses and thresholds are settings.

## Settings (app-wide)
- Strava API: Client ID, Client Secret, and connect/disconnect button. One connection only (the owner's). Stored in the macOS Keychain, never in code or files. Token refresh automatic.
- People list: each person has a name, a local save folder and a NAS destination folder. Add, edit, remove.
- Cameras (belong to a person): identified by model; each has its own clock offset. Owner has a Canon EOS R5 Mark II and a Canon EOS R7.
- NAS: primary SMB address and a fallback address (both editable), and a Test Connection button.
- Matching: maximum time gap allowed between a photo and the nearest track point.

## Track source
The owner's watch (Garmin fenix 9 via Strava) is the single source of truth for everyone. It is exact for the owner and approximate for other people. Fallback: import a GPX or FIT file exported from Garmin Connect. Cache tracks locally so matching works offline.

## Import flow
1. Insert a card or choose a folder. The app asks which person it belongs to, from the people list.
2. The app lists the photos and skips those already imported for that person (match on file name, size and capture time against that person's History). Show the skipped count; allow overriding per photo.
3. Clock offset: asked per card, defaulting to the last one used for that camera or person. Used for matching only.
4. Matching: interpolate position between the two nearest track points. Photos with no track within the maximum gap go to a review list, never guessed. A photo from a camera model with no offset set also goes to the review list.
5. Writing: use bundled ExifTool to write GPS into the Mac copies, including RAW (CR3) directly, no sidecar files. Explicitly write latitude, longitude, altitude, and GPS date and time stamps, since CR3 files from cameras without a GPS accessory may lack some of them. Never modify the SD card. Never change any dates or file names. Verify each file still opens and the GPS tags are present; failures go to the review list.
6. Save copies to that person's local folder, then add to the upload queue for that person's NAS folder.
7. History is kept per person.

## Upload queue
Persistent across app restarts. Uploads over SMB to the NAS, pauses when the connection drops, resumes by itself, verifies each file with a checksum, shows per-file progress and failures, with retry.

## Stages
1. Project shell: main window with sections Tracks, Photos, Queue, History, Settings.
2. Early test: write GPS into real files from both the R5 Mark II and the R7 (CR3, and any HEIF or JPEG the user shoots), and confirm the location shows in Finder and the user's photo software.
3. Tracks (Strava settings, fetch, cache, GPX fallback).
4. People and cameras setup.
5. Photo import with skip history.
6. Matching and review list.
7. Location writing.
8. Upload queue and NAS connection test.
9. Visual polish (sidebar, tables, dark mode) and app icon.

## Packaging
Single app file in a disk image with ExifTool bundled. No Apple Developer account, so use ad-hoc signing; each person approves the first launch under Privacy and Security. No setup guide is needed, the owner sets up family members' Macs.

## Known context
- NAS reached through a Tailscale tunnel. Candidate addresses: smb://nas.home.arpa, smb://10.0.10.10, or the NAS's Tailscale address. The subnet route may be needed for the first two away from home. Test from a hotspot before relying on any of them.
- Watch: Garmin fenix 9, recording Every Second, Satellites on Max Accuracy, activity profile Antarctique (Hike-based, so Strava labels these as hikes).
- Existing site antarctique.xyz already fetches Strava tracks; reuse its approach where sensible.

## Open items
- NAS connection test result from outside the home network.
