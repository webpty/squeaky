import AppKit
import Foundation
import GeotagCore
import GeotagUI
import SwiftUI
import DiskArbitration

// Checks the rules without the interface. Everything happens in a temporary
// folder; the real library in Application Support is never touched.
//
//   GEOTAG_SCRATCH=<folder> swift run -c release SelfTest [fit folder] [service address]
//
// Its files go in a new folder inside GEOTAG_SCRATCH; set it to a scratch
// folder, since nothing on David's Mac is ever deleted.
// With a fit folder, Garmin's sample files in it are read. With a service
// address (a local copy of the track service holding the test keys
// test-owner-key and test-reader-key), the library is run against it.

@main
struct SelfTest {
    static var failures = 0

    static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        print("\(ok ? "pass" : "FAIL")  \(name)\(detail.isEmpty ? "" : "  \(detail)")")
        if !ok { failures += 1 }
    }

    static func main() async {
        let args = CommandLine.arguments
        let root = ProcessInfo.processInfo.environment["GEOTAG_SCRATCH"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        let scratch = root.appendingPathComponent("geotag-selftest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

        people(scratch)
        if let samples = ProcessInfo.processInfo.environment["GEOTAG_SAMPLES"] {
            saving(scratch, samples: URL(fileURLWithPath: samples),
                   raws: ProcessInfo.processInfo.environment["GEOTAG_RAWS"].map { URL(fileURLWithPath: $0) })
            await savingEdges(scratch, samples: URL(fileURLWithPath: samples))
            await placingLater(scratch, samples: URL(fileURLWithPath: samples))
        }
        cardKinds()
        cards(scratch)
        matching(scratch)
        names()
        if ProcessInfo.processInfo.environment["GEOTAG_MOUNT_TEST"] != nil { await cardArrives(scratch) }
        if ProcessInfo.processInfo.environment["GEOTAG_GUARD_TEST"] != nil { await guardTest(scratch) }
        if ProcessInfo.processInfo.environment["GEOTAG_VIEWER"] != nil { await photosPicture(scratch) }
        if let key = ProcessInfo.processInfo.environment["GEOTAG_MAP_KEY"], ProcessInfo.processInfo.environment["GEOTAG_ALIGN"] != nil {
            await alignmentPicture(scratch, key: key)
        }
        gpx(scratch)
        if args.count > 1, !args[1].isEmpty { fit(URL(fileURLWithPath: args[1])) }
        if args.count > 2 { await library(scratch, address: args[2]) }
        await thumbnail(scratch)
        if let key = ProcessInfo.processInfo.environment["GEOTAG_MAP_KEY"] {
            await mapStress(scratch, key: key)
        }
        if let key = ProcessInfo.processInfo.environment["GEOTAG_MAP_KEY"], ProcessInfo.processInfo.environment["GEOTAG_VIEWER"] != nil {
            await viewerPicture(scratch, key: key)
        }

        print(failures == 0 ? "all passed" : "\(failures) failed")
        print("scratch: \(scratch.path)")
        exit(failures == 0 ? 0 : 1)
    }

    /// A small JPEG with the camera details a photo carries.
    static func writePhoto(_ url: URL, model: String, zone: String?, taken: String = "2026:10:16 12:00:00", gps: (Double, Double)? = nil) {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 3,
                                   hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        guard let image = rep.cgImage,
              let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else { return }
        var exif: [CFString: Any] = [kCGImagePropertyExifDateTimeOriginal: taken]
        if let zone { exif[kCGImagePropertyExifOffsetTimeOriginal] = zone }
        var props: [CFString: Any] = [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: model, kCGImagePropertyTIFFMake: "Test"],
            kCGImagePropertyExifDictionary: exif,
        ]
        if let gps {
            props[kCGImagePropertyGPSDictionary] = [kCGImagePropertyGPSLatitude: abs(gps.0), kCGImagePropertyGPSLatitudeRef: gps.0 < 0 ? "S" : "N",
                                                    kCGImagePropertyGPSLongitude: abs(gps.1), kCGImagePropertyGPSLongitudeRef: gps.1 < 0 ? "W" : "E"]
        }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        CGImageDestinationFinalize(dest)
    }

    static func people(_ scratch: URL) {
        let store = PeopleStoreFile(url: scratch.appendingPathComponent("people.json"))
        check("people: nothing saved yet", (try? store.load()) == nil)
        var book = PeopleBook.family()
        check("people: the four", book.people.map(\.name) == ["David", "Amanda", "Patrick", "Gilbert"])
        check("cameras: the five, none ready", book.cameras.count == 5 && book.cameras.allSatisfy { !$0.isReady })
        try? store.save(book)
        check("people: saved and read back", (try? store.load()) == book)

        let david = book.people[0].id, amanda = book.people[1].id
        check("cameras: found by owner and model", book.camera(personId: amanda, model: "canon eos r5m2 ")?.personId == amanda)
        check("cameras: not someone else's", book.camera(personId: amanda, model: "Canon EOS R7") == nil)

        var r7 = book.camera(personId: david, model: "Canon EOS R7")!
        r7.offsetSeconds = -42
        book.save(r7)
        check("cameras: ready once its offset is set", book.camera(personId: david, model: "Canon EOS R7")!.isReady)
        var nikon = book.cameras.first { $0.model == "COOLPIX P950" }!
        nikon.zone = .fixed("America/Panama")
        nikon.offsetSeconds = 0
        book.save(nikon)
        try? store.save(book)
        let back = try? store.load()
        check("cameras: zone and offset kept", back?.cameras.first { $0.id == nikon.id }?.zone == .fixed("America/Panama")
              && back?.cameras.first { $0.id == r7.id }?.offsetSeconds == -42)

        book.remove(person: david)
        check("people: removing takes their cameras off", book.person(david) == nil && book.cameras(of: david).isEmpty && book.cameras.count == 3)

        let withZone = scratch.appendingPathComponent("zone.jpg"), without = scratch.appendingPathComponent("nozone.jpg")
        writePhoto(withZone, model: "Canon EOS R5m2", zone: "-05:00")
        writePhoto(without, model: "Canon EOS REBEL T3i", zone: nil)
        check("camera read with its zone", CameraReader.read(withZone) == CameraReading(model: "Canon EOS R5m2", zone: "-05:00"))
        check("camera read, no zone", CameraReader.read(without) == CameraReading(model: "Canon EOS REBEL T3i", zone: nil))

        // The same through ExifTool, as the app reads them, run from the repo.
        let tool = ExifTool(script: URL(fileURLWithPath: "Vendor/ExifTool/exiftool"))
        check("exiftool: camera read with its zone", CameraReader.read(withZone, exifTool: tool) == CameraReading(model: "Canon EOS R5m2", zone: "-05:00"))
        check("exiftool: camera read, no zone", CameraReader.read(without, exifTool: tool) == CameraReading(model: "Canon EOS REBEL T3i", zone: nil))
        if let folder = ProcessInfo.processInfo.environment["GEOTAG_SAMPLES"] {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: folder))?.sorted() ?? []
            for name in files where !name.hasPrefix(".") {
                let r = CameraReader.read(URL(fileURLWithPath: folder).appendingPathComponent(name), exifTool: tool)
                print("photo  \(name): \(r?.model ?? "-") | zone \(r?.zone ?? "none")")
            }
        }
    }

    static func writeGPX(_ url: URL, start: Int, count: Int, name: String, lat: Double = -54.81, lon: Double = -68.29) {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var points = ""
        for i in 0..<count {
            let t = f.string(from: Date(timeIntervalSince1970: TimeInterval(start + i)))
            points += "<trkpt lat=\"\(lat + Double(i) * 1e-5)\" lon=\"\(lon + Double(i) * 2e-5)\"><ele>\(5.0 + Double(i) / 10)</ele><time>\(t)</time><extensions><ns3:TrackPointExtension><ns3:hr>90</ns3:hr></ns3:TrackPointExtension></extensions></trkpt>\n"
        }
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx creator="Garmin Connect" version="1.1" xmlns="http://www.topografix.com/GPX/1/1" xmlns:ns3="http://www.garmin.com/xmlschemas/TrackPointExtension/v1">
          <metadata><link href="connect.garmin.com"><text>Garmin Connect</text></link><time>2026-10-14T12:00:00.000Z</time></metadata>
          <trk><name>\(name)</name><type>hiking</type><trkseg>
        \(points)  </trkseg></trk>
        </gpx>
        """
        try? xml.write(to: url, atomically: true, encoding: .utf8)
    }

    static func gpx(_ scratch: URL) {
        let url = scratch.appendingPathComponent("Ushuaia walk.gpx")
        let start = 1_791_979_200 // 2026-10-14 12:00 UTC
        writeGPX(url, start: start, count: 900, name: "Antarctique")
        do {
            let t = try TrackFiles.read(url)
            check("gpx: name from the track", t.name == "Antarctique", t.name)
            check("gpx: every point", t.points.count == 900)
            check("gpx: times read", t.points.t.first == start && t.points.t.last == start + 899)
            check("gpx: south and west", t.points.lat[0] == -54.81 && t.points.lon[0] == -68.29)
            check("gpx: altitude", t.points.alt[10] == 6.0)
        } catch {
            check("gpx read", false, "\(error)")
        }
        let bad = scratch.appendingPathComponent("notes.txt")
        try? "hello".write(to: bad, atomically: true, encoding: .utf8)
        check("other files refused", (try? TrackFiles.read(bad)) == nil)
        let broken = scratch.appendingPathComponent("broken.gpx")
        try? "<gpx><trk><trkseg><trkpt lat=".write(to: broken, atomically: true, encoding: .utf8)
        check("broken gpx refused", (try? TrackFiles.read(broken)) == nil)
    }

    static func fit(_ folder: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for url in files.filter({ $0.pathExtension.lowercased() == "fit" }).sorted(by: { $0.path < $1.path }) {
            do {
                let t = try TrackFiles.read(url)
                let p = t.points
                func r(_ v: Double) -> String { String(format: "%.6f", v) }
                print("fit  \(url.lastPathComponent): \(p.count) points, first \(p.t[0]) \(r(p.lat[0])) \(r(p.lon[0])) alt \(p.alt[0].map { String(format: "%.1f", $0) } ?? "-"), last \(p.t[p.count - 1]) \(r(p.lat[p.count - 1])) \(r(p.lon[p.count - 1]))")
            } catch {
                print("fit  \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    final class DeadService: TrackServicePort {
        func status() async throws -> ServiceStatus { throw ServiceError.offline }
        func maps() async throws -> MapSource { throw ServiceError.offline }
        func tracks() async throws -> [ServiceTrack] { throw ServiceError.offline }
        func points(_ id: String) async throws -> TrackPoints { throw ServiceError.offline }
        func upload(name: String, fileName: String?, points: TrackPoints) async throws -> UploadAnswer { throw ServiceError.offline }
        func sync() async throws -> String { throw ServiceError.offline }
        func connectLink() async throws -> URL { throw ServiceError.offline }
        func disconnect() async throws -> String { throw ServiceError.offline }
    }

    static func library(_ scratch: URL, address: String) async {
        guard let owner = TrackServiceHTTP(address: address, key: "test-owner-key"),
              let reader = TrackServiceHTTP(address: address, key: "test-reader-key") else {
            check("service address", false)
            return
        }
        let onService = (try? await reader.tracks().count) ?? -1

        // A family Mac: reads, keeps its own imports to itself.
        let family = TrackLibrary(store: TrackStoreFolder(folder: scratch.appendingPathComponent("family")))
        var report = await family.refresh(service: reader, role: .reader)
        let familyCount = await family.listed().count
        check("family: gets the service's tracks", familyCount == onService && report.added == onService, report.line)
        let familyFile = scratch.appendingPathComponent("family walk.gpx")
        writeGPX(familyFile, start: 1_792_000_000, count: 120, name: "Family walk")
        if case .added(let t)? = try? await family.importFile(familyFile, role: .reader) {
            check("family: import stays on this Mac", t.status == .thisMacOnly)
        } else {
            check("family: import", false)
        }
        report = await family.refresh(service: reader, role: .reader)
        let afterFamily = (try? await reader.tracks().count) ?? -1
        check("family: nothing uploaded", afterFamily == onService && report.problems.isEmpty, report.line)

        // The owner's Mac: imports go up, and show once.
        let mine = TrackLibrary(store: TrackStoreFolder(folder: scratch.appendingPathComponent("owner")))
        _ = await mine.refresh(service: owner, role: .owner)
        let ownerFile = scratch.appendingPathComponent("Ushuaia walk.gpx")
        guard case .added(let local)? = try? await mine.importFile(ownerFile, role: .owner) else {
            check("owner: import", false)
            return
        }
        check("owner: waits to upload", local.status == .waitingToUpload)
        let again = try? await mine.importFile(ownerFile, role: .owner)
        if case .alreadyHere? = again { check("owner: same file twice is one track", true) } else { check("owner: same file twice is one track", false) }
        report = await mine.refresh(service: owner, role: .owner)
        let listed = await mine.listed()
        let afterOwner = (try? await reader.tracks().count) ?? -1
        check("owner: uploaded", report.uploaded == 1 && afterOwner == onService + 1, report.line)
        check("owner: shown once, as the service's", listed.filter { abs($0.start.timeIntervalSince(local.start)) < 60 }.count == 1
              && listed.first { abs($0.start.timeIntervalSince(local.start)) < 60 }?.status == .onService)
        check("owner: nothing left waiting", await mine.waitingCount == 0)

        // The family Mac picks the upload up on its next refresh.
        report = await family.refresh(service: reader, role: .reader)
        check("family: sees the owner's upload", report.added == 1, report.line)

        // No internet: the Mac keeps what it has and says so.
        let before = await mine.listed().count
        report = await mine.refresh(service: DeadService(), role: .owner)
        check("offline: said plainly", report.offline && report.line == "Offline. Showing the tracks on this Mac.")
        check("offline: tracks kept", await mine.listed().count == before)

        // A wrong key is refused in words.
        let wrong = TrackServiceHTTP(address: address, key: "nobody")!
        do {
            _ = try await wrong.status()
            check("wrong key refused", false)
        } catch {
            check("wrong key refused", error.localizedDescription == "This key is not known.", error.localizedDescription)
        }
        do {
            _ = try await reader.upload(name: "x", fileName: nil, points: TrackPoints(t: [1_792_000_000, 1_792_000_001], lat: [0, 0], lon: [0, 0], alt: [nil, nil]))
            check("reading key cannot upload", false)
        } catch {
            check("reading key cannot upload", error.localizedDescription == "This key can only read.", error.localizedDescription)
        }
    }

    @MainActor
    static func thumbnail(_ scratch: URL) async {
        // An L shape: east along the bottom, then north, so a flipped map shows.
        var p = TrackPoints(t: [], lat: [], lon: [], alt: [])
        for i in 0..<100 { p.t.append(i); p.lat.append(-54.82); p.lon.append(-68.32 + Double(i) * 0.0004); p.alt.append(nil) }
        for i in 0..<100 { p.t.append(100 + i); p.lat.append(-54.82 + Double(i) * 0.0002); p.lon.append(-68.28); p.alt.append(nil) }
        let bounds = Bounds(minLat: -54.82, maxLat: -54.80, minLon: -68.32, maxLon: -68.28)

        let centre = MapThumbnails.project(0, 0, 0)
        check("map: the middle of the world", abs(centre.x - 128) < 0.001 && abs(centre.y - 128) < 0.001)
        let north = MapThumbnails.project(-54.80, -68.30, 10), south = MapThumbnails.project(-54.82, -68.30, 10)
        check("map: north is up", north.y < south.y)
        let z = MapThumbnails.zoom(bounds, size: MapThumbnails.size)
        check("map: a walk gets a close zoom", (11...12).contains(z), "zoom \(z)")

        // Drawing needs a real key: GEOTAG_MAP_KEY, with the tile addresses the service hands out.
        guard let key = ProcessInfo.processInfo.environment["GEOTAG_MAP_KEY"], !key.isEmpty else {
            print("skip  map pictures: no GEOTAG_MAP_KEY")
            return
        }
        let templates = [
            "light": "https://basemaps.cartocdn.com/rastertiles/light_nolabels/{z}/{x}/{y}@2x.png",
            "dark": "https://basemaps.cartocdn.com/rastertiles/dark_nolabels/{z}/{x}/{y}@2x.png",
        ]
        for (name, template) in templates {
            let png = await MapThumbnails.render(points: p, bounds: bounds, template: template, key: key, size: MapThumbnails.size)
            check("map picture \(name)", png != nil)
            try? png?.write(to: scratch.appendingPathComponent("thumb-\(name).png"))
        }
    }
}

// MARK: - A picture of the track viewer, drawn off-screen with test tracks.

struct NoSecrets: SecretStorePort {
    func read(_ account: String) -> String? { nil }
    func write(_ account: String, _ value: String) throws {}
}

extension SelfTest {
    /// Lets the main run loop turn, so the views draw and their tasks run.
    static func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    @MainActor
    static func viewerPicture(_ scratch: URL, key: String) async {
        let lib = TrackLibrary(store: TrackStoreFolder(folder: scratch.appendingPathComponent("viewer-lib")))
        let spots: [(String, Double, Double)] = [("Ushuaia harbour", -54.81, -68.30), ("Panama old town", 8.952, -79.535), ("El Chaltén", -49.33, -72.89)]
        for (i, spot) in spots.enumerated() {
            let url = scratch.appendingPathComponent("viewer-\(i).gpx")
            writeGPX(url, start: 1_792_000_000 + i * 86_400, count: 1800, name: spot.0, lat: spot.1, lon: spot.2)
            _ = try? await lib.importFile(url, role: .reader)
        }
        let model = AppModel(library: lib, peopleStore: PeopleStoreFile(url: scratch.appendingPathComponent("viewer-people.json")),
                             secrets: NoSecrets(), thumbnails: MapThumbnails(folder: scratch.appendingPathComponent("viewer-maps")))
        model.useMaps(MapSource(light: "https://basemaps.cartocdn.com/rastertiles/light_nolabels/{z}/{x}/{y}@2x.png",
                                dark: "https://basemaps.cartocdn.com/rastertiles/dark_nolabels/{z}/{x}/{y}@2x.png",
                                credit: "© OpenStreetMap contributors, © CARTO", key: key))
        await model.showLibrary()
        model.viewing = model.tracks[1].id
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        for dark in [false, true] {
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 1100, height: 820), styleMask: [.titled], backing: .buffered, defer: false)
            let host = NSHostingView(rootView: TrackViewer(trackId: model.tracks[1].id).environmentObject(model))
            window.contentView = host
            window.orderBack(nil)
            for _ in 0..<150 {
                spin(0.04)
                try? await Task.sleep(for: .milliseconds(40))
            }
            host.layoutSubtreeIfNeeded()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: scratch.appendingPathComponent("viewer-\(dark ? "dark" : "light").png"))
            }
            window.orderOut(nil)
        }
        NSApp.appearance = NSAppearance(named: .aqua)
        let grid = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 900, height: 620), styleMask: [.titled], backing: .buffered, defer: false)
        let gridHost = NSHostingView(rootView: TracksScreenProbe().environmentObject(model))
        grid.contentView = gridHost
        grid.orderBack(nil)
        for _ in 0..<100 {
            spin(0.04)
            try? await Task.sleep(for: .milliseconds(40))
        }
        if let rep = gridHost.bitmapImageRepForCachingDisplay(in: gridHost.bounds) {
            gridHost.cacheDisplay(in: gridHost.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: scratch.appendingPathComponent("tracks.png"))
        }
        print("viewer pictures in \(scratch.path)")
    }
}

extension SelfTest {
    /// Forty maps asked for at once, half of them abandoned straight away as a
    /// scrolled-off row would; every one must still be drawn.
    @MainActor
    static func mapStress(_ scratch: URL, key: String) async {
        let maps = MapThumbnails(folder: scratch.appendingPathComponent("stress-maps"))
        maps.source = MapSource(light: "https://basemaps.cartocdn.com/rastertiles/light_nolabels/{z}/{x}/{y}@2x.png",
                                dark: "https://basemaps.cartocdn.com/rastertiles/dark_nolabels/{z}/{x}/{y}@2x.png",
                                credit: "", key: key)
        var tracks: [(Track, TrackPoints)] = []
        for i in 0..<20 {
            let lat = 8.95 + Double(i) * 0.01, lon = -79.53 + Double(i) * 0.013
            let p = TrackPoints(t: Array(0..<300), lat: (0..<300).map { lat + Double($0) * 2e-5 },
                                lon: (0..<300).map { lon + Double($0) * 3e-5 }, alt: Array(repeating: nil, count: 300))
            let t = Track(id: "stress-\(i)", source: .file, name: "Stress \(i)", sport: nil, fileName: nil,
                          start: Date(), end: Date(), timeZone: nil, pointCount: 300, distance: nil,
                          bounds: Geo.bounds(p), status: .thisMacOnly)
            tracks.append((t, p))
        }
        var abandoned: [Task<NSImage?, Never>] = []
        for (i, (t, p)) in tracks.enumerated() {
            for dark in [false, true] {
                let task = Task { await maps.make(t, points: p, dark: dark) }
                if i % 2 == 0 { abandoned.append(task) }
            }
        }
        abandoned.forEach { $0.cancel() }
        try? await Task.sleep(for: .seconds(1))
        var drawn = 0
        for (t, p) in tracks {
            for dark in [false, true] where await maps.make(t, points: p, dark: dark) != nil { drawn += 1 }
        }
        check("maps: forty asked at once, all drawn", drawn == 40, "\(drawn) of 40")
    }
}

extension SelfTest {
    static func cards(_ scratch: URL) {
        let fm = FileManager.default
        let card = scratch.appendingPathComponent("CARD")
        let dcim = card.appendingPathComponent("DCIM/100CANON")
        try? fm.createDirectory(at: dcim, withIntermediateDirectories: true)
        try? fm.createDirectory(at: card.appendingPathComponent(".Trashes"), withIntermediateDirectories: true)
        writePhoto(dcim.appendingPathComponent("IMG_0001.JPG"), model: "Canon EOS R5m2", zone: "-03:00")
        writePhoto(dcim.appendingPathComponent("IMG_0002.JPG"), model: "Canon EOS R5m2", zone: "-03:00")
        writePhoto(dcim.appendingPathComponent("IMG_0003.JPG"), model: "Canon PowerShot G7 X", zone: nil)
        writePhoto(card.appendingPathComponent(".Trashes/IMG_9999.JPG"), model: "Canon EOS R5m2", zone: nil)
        try? "notes".write(to: dcim.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)

        check("card: a disk with DCIM is a card", CardWatcher.card(at: card)?.isCard == true)
        check("card: any other folder is not", CardWatcher.card(at: scratch) == nil)
        let files = PhotoScanner.files(in: card)
        check("card: photos only, hidden folders left out", files.map(\.lastPathComponent) == ["IMG_0001.JPG", "IMG_0002.JPG", "IMG_0003.JPG"])

        let tool = ExifTool(script: URL(fileURLWithPath: "Vendor/ExifTool/exiftool"))
        final class Last: @unchecked Sendable { var value = 0 }
        let last = Last()
        let photos = (try? PhotoScanner(exifTool: tool).scan(files) { last.value = $0 }) ?? []
        check("card: every photo read", photos.count == 3 && last.value == 3)
        check("card: time, zone and camera read", photos.first?.taken == "2026:10:16 12:00:00" && photos.first?.zone == "-03:00"
              && photos.first?.model == "Canon EOS R5m2", "\(String(describing: photos.first))")
        let before = files.map { (try? fm.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date) ?? nil }

        var book = PeopleBook.family()
        let amanda = book.people[1].id
        let history = HistoryStoreFolder(folder: scratch.appendingPathComponent("history"))
        let entry = HistoryEntry(fileName: photos[0].fileName, size: photos[0].size, taken: photos[0].taken,
                                 subSeconds: photos[0].subSeconds, imported: Date())
        try? history.save(amanda, [entry])
        let past = (try? history.load(amanda)) ?? []
        check("history: saved and read back", past == [entry])
        let rows = ImportList.rows(photos, history: past, book: book, personId: amanda)
        check("import: imported before, unticked", rows[0].status == .alreadyImported && !rows[0].ticked)
        check("import: new, ticked", rows[1].status == .new && rows[1].ticked)
        check("import: camera not on the list, ticked", rows[2].status == .unknownCamera && rows[2].ticked)
        book.remove(person: amanda)
        let after = files.map { (try? fm.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date) ?? nil }
        check("card: nothing on it changed", before == after)

        if let folder = ProcessInfo.processInfo.environment["GEOTAG_SAMPLES"] {
            let real = (try? PhotoScanner(exifTool: tool).scan(PhotoScanner.files(in: URL(fileURLWithPath: folder))) { _ in }) ?? []
            for p in real { print("card   \(p.fileName): \(p.taken ?? "-").\(p.subSeconds ?? "") \(p.zone ?? "-") \(p.model ?? "-")") }
        }
    }

    /// A card arriving for real: a disk image with a DCIM folder, attached
    /// without showing in Finder, then detached.
    @MainActor
    static func cardArrives(_ scratch: URL) async {
        let src = scratch.appendingPathComponent("dmg-src")
        try? FileManager.default.createDirectory(at: src.appendingPathComponent("DCIM/100TEST"), withIntermediateDirectories: true)
        writePhoto(src.appendingPathComponent("DCIM/100TEST/IMG_0001.JPG"), model: "Canon EOS R7", zone: "-03:00")
        let image = scratch.appendingPathComponent("card.dmg")
        let mount = scratch.appendingPathComponent("mnt")
        try? FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        func hdiutil(_ args: [String]) -> Int32 {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            p.arguments = args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
            return p.terminationStatus
        }
        guard hdiutil(["create", "-quiet", "-srcfolder", src.path, "-volname", "TESTCARD", "-fs", "ExFAT", image.path]) == 0 else {
            check("card arrives: disk image made", false)
            return
        }
        let watcher = CardWatcher()
        var inserted: [String] = []
        var lists: [[String]] = []
        watcher.onInserted = { inserted.append($0.name) }
        watcher.onChange = { lists.append($0.map(\.name)) }
        watcher.start()
        let attached = hdiutil(["attach", "-nobrowse", "-mountpoint", mount.path, image.path]) == 0
        for _ in 0..<40 { spin(0.05); try? await Task.sleep(for: .milliseconds(50)) }
        check("card arrives: noticed", attached && inserted == ["TESTCARD"], "\(inserted)")
        _ = hdiutil(["detach", "-quiet", mount.path])
        for _ in 0..<40 { spin(0.05); try? await Task.sleep(for: .milliseconds(50)) }
        check("card leaves: noticed", lists.last?.contains("TESTCARD") == false, "\(lists)")
    }
}

extension SelfTest {
    /// A picture of the Photos screen after reading a test card, off-screen.
    @MainActor
    static func photosPicture(_ scratch: URL) async {
        let card = scratch.appendingPathComponent("CARD")
        let model = AppModel(library: TrackLibrary(store: TrackStoreFolder(folder: scratch.appendingPathComponent("pp-lib"))),
                             peopleStore: PeopleStoreFile(url: scratch.appendingPathComponent("pp-people.json")),
                             history: HistoryStoreFolder(folder: scratch.appendingPathComponent("history")),
                             secrets: NoSecrets(), thumbnails: MapThumbnails(folder: scratch.appendingPathComponent("pp-maps")),
                             exifTool: ExifTool(script: URL(fileURLWithPath: "Vendor/ExifTool/exiftool")))
        let source = CardWatcher.card(at: card)!
        model.choose(source)
        // A card seen before is read for last time's person without asking.
        if model.askingWhose == nil {
            for _ in 0..<40 where model.photosBusy || model.rows.isEmpty { spin(0.05); try? await Task.sleep(for: .milliseconds(50)) }
            check("card: remembered, read without asking", model.importPerson == model.book.people[1].id && !model.rows.isEmpty)
        } else {
            check("card: a new card asks whose it is", model.askingWhose?.id == source.id)
        }
        model.askingWhose = nil
        // Amanda's history was written by the card test, under her id from a fresh book; use the book's own Amanda.
        await model.read(source, for: model.book.people[1].id)
        // The same card again: no question, read for Amanda straight away.
        model.choose(source)
        check("card: a known card is not asked about again", model.askingWhose == nil)
        for _ in 0..<60 where model.rows.isEmpty || model.photosBusy { spin(0.05); try? await Task.sleep(for: .milliseconds(50)) }
        check("card: read for last time's person", model.importPerson == model.book.people[1].id && !model.rows.isEmpty)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        NSApp.appearance = NSAppearance(named: .aqua)
        let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 1000, height: 520), styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: PhotosScreenProbe().environmentObject(model))
        window.contentView = host
        window.orderBack(nil)
        for _ in 0..<60 { spin(0.05); try? await Task.sleep(for: .milliseconds(50)) }
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: scratch.appendingPathComponent("photos.png"))
        }
        print("photos picture: \(model.photosLine)")
    }
}

extension SelfTest {
    static func photo(_ taken: String?, zone: String?, model: String = "Canon EOS R5m2", sub: String? = nil, located: Bool = false) -> ScannedPhoto {
        ScannedPhoto(url: URL(fileURLWithPath: "/tmp/x.jpg"), fileName: "x.jpg", size: 1, taken: taken, subSeconds: sub,
                     zone: zone, model: model, hasLocation: located)
    }

    static func matching(_ scratch: URL) {
        let iso = ISO8601DateFormatter()
        let person = UUID()
        var cam = Camera(personId: person, model: "Canon EOS R5m2", zone: .fromPhoto, offsetSeconds: 0)

        func utc(_ r: Result<Date, ReviewReason>) -> String {
            switch r { case .success(let d): return iso.string(from: d); case .failure(let e): return "\(e)" }
        }
        let p = photo("2026:10:16 12:00:00", zone: "-03:00", sub: "50")
        check("moment: zone taken off", utc(Moments.moment(p, camera: cam)) == "2026-10-16T15:00:00Z", utc(Moments.moment(p, camera: cam)))
        check("moment: sub-seconds kept", Moments.moment(p, camera: cam).map { $0.timeIntervalSince1970.truncatingRemainder(dividingBy: 1) } == .success(0.5))
        cam.offsetSeconds = 30
        check("moment: a clock 30 s ahead", utc(Moments.moment(p, camera: cam)) == "2026-10-16T14:59:30Z")
        cam.offsetSeconds = -90
        check("moment: a clock 90 s behind", utc(Moments.moment(p, camera: cam)) == "2026-10-16T15:01:30Z")
        cam.offsetSeconds = 0
        cam.zone = .fixed("Europe/Paris")
        let summer = photo("2026:07:01 12:00:00", zone: nil)
        check("moment: a fixed zone in summer time", utc(Moments.moment(summer, camera: cam)) == "2026-07-01T10:00:00Z", utc(Moments.moment(summer, camera: cam)))
        let winter = photo("2026:01:15 12:00:00", zone: nil)
        check("moment: a fixed zone in winter", utc(Moments.moment(winter, camera: cam)) == "2026-01-15T11:00:00Z")
        cam.zone = .notSet
        check("moment: zone not set", utc(Moments.moment(p, camera: cam)) == "zoneNotSet")
        cam.zone = .fromPhoto
        check("moment: no zone in the photo", utc(Moments.moment(photo("2026:10:16 12:00:00", zone: nil), camera: cam)) == "noZoneInPhoto")
        check("moment: no time", utc(Moments.moment(photo(nil, zone: "-03:00"), camera: cam)) == "noTime")
        cam.offsetSeconds = nil
        check("moment: offset not set", utc(Moments.moment(p, camera: cam)) == "offsetNotSet")
        check("moment: no camera", utc(Moments.moment(p, camera: nil)) == "unknownCamera")

        // A track from 15:00 to 15:10 UTC, a point every 10 s heading north
        // and climbing, with a pause from 15:04 to 15:06.
        let start = Int(iso.date(from: "2026-10-16T15:00:00Z")!.timeIntervalSince1970)
        var t: [Int] = [], lat: [Double] = [], lon: [Double] = [], alt: [Double?] = []
        for i in 0...60 where !(25..<36).contains(i) {
            t.append(start + i * 10); lat.append(-54.80 + Double(i) * 0.0001); lon.append(-68.30); alt.append(Double(i))
        }
        let timeline = TrackTimeline([(id: "a", points: TrackPoints(t: t, lat: lat, lon: lon, alt: alt))])
        func at(_ s: Int) -> Position? { timeline.position(at: Date(timeIntervalSince1970: TimeInterval(start + s)), gap: 120) }
        let mid = at(15)
        check("match: halfway between two points", mid.map { abs($0.lat - (-54.80 + 0.00015)) < 1e-9 && $0.alt == 1.5 } == true, "\(String(describing: mid))")
        check("match: just before the start, the first point", at(-60)?.lat == -54.80 && at(-60)?.fromPoint == 60)
        check("match: further before the start, nothing", at(-121) == nil)
        check("match: just after the end, the last point", at(660)?.lat == -54.80 + 0.006)
        let pause = at(300)
        check("match: in a pause, the nearer side within the gap", pause != nil && pause!.fromPoint == 60, "\(String(describing: pause))")
        let wide = timeline.position(at: Date(timeIntervalSince1970: TimeInterval(start + 300)), gap: 30)
        check("match: in a pause wider than the gap, nothing", wide == nil)

        cam.offsetSeconds = 0
        check("place: matched", Matcher.place(photo("2026:10:16 12:00:15", zone: "-03:00"), camera: cam, timeline: timeline, gap: 120) != .review(.noTrack))
        check("place: own location kept", Matcher.place(photo("2026:10:16 12:00:15", zone: "-03:00", located: true), camera: cam, timeline: timeline, gap: 120) == .ownLocation)
        check("place: no track", Matcher.place(photo("2026:10:16 18:00:00", zone: "-03:00"), camera: cam, timeline: timeline, gap: 120) == .review(.noTrack))
        check("place: the slider's extra seconds", Matcher.place(photo("2026:10:16 12:00:15", zone: "-03:00"), camera: cam, timeline: timeline, gap: 120, extraOffset: 600) == .review(.noTrack))

        var row = ImportRow(photo: p, status: .new, ticked: true, placement: .review(.noTrack))
        check("import: a photo that can't be placed is still saved", row.willImport)
        row.ticked = false
        check("import: a photo imported before is not saved again", !row.willImport)

        // Existing GPS read from a photo.
        let located = scratch.appendingPathComponent("located.jpg"), bare = scratch.appendingPathComponent("bare.jpg")
        writePhoto(located, model: "Canon EOS R5m2", zone: "-03:00", gps: (-54.8, -68.3))
        writePhoto(bare, model: "Canon EOS R5m2", zone: "-03:00")
        let tool = ExifTool(script: URL(fileURLWithPath: "Vendor/ExifTool/exiftool"))
        let read = (try? PhotoScanner(exifTool: tool).scan([located, bare]) { _ in }) ?? []
        check("scan: a photo's own location noticed", read.map(\.hasLocation) == [true, false])
    }
}

extension SelfTest {
    /// The alignment window, drawn off-screen: a test walk in Ushuaia and a
    /// card of photos taken along it.
    @MainActor
    static func alignmentPicture(_ scratch: URL, key: String) async {
        let lib = TrackLibrary(store: TrackStoreFolder(folder: scratch.appendingPathComponent("al-lib")))
        let start = 1_792_162_800 // 2026-10-16 15:00 UTC, 12:00 in Ushuaia
        let gpx = scratch.appendingPathComponent("al-walk.gpx")
        writeGPX(gpx, start: start, count: 1800, name: "Ushuaia walk", lat: -54.812, lon: -68.33)
        _ = try? await lib.importFile(gpx, role: .reader)
        let card = scratch.appendingPathComponent("AL-CARD/DCIM/100CANON")
        try? FileManager.default.createDirectory(at: card, withIntermediateDirectories: true)
        for i in 0..<12 {
            let s = 120 + i * 130
            let taken = String(format: "2026:10:16 12:%02d:%02d", s / 60, s % 60)
            writePhoto(card.appendingPathComponent(String(format: "IMG_%04d.JPG", i + 1)), model: "Canon EOS R5m2", zone: "-03:00", taken: taken)
        }
        let model = AppModel(library: lib, peopleStore: PeopleStoreFile(url: scratch.appendingPathComponent("al-people.json")),
                             history: HistoryStoreFolder(folder: scratch.appendingPathComponent("al-history")),
                             secrets: NoSecrets(), thumbnails: MapThumbnails(folder: scratch.appendingPathComponent("al-maps")),
                             exifTool: ExifTool(script: URL(fileURLWithPath: "Vendor/ExifTool/exiftool")))
        model.useMaps(MapSource(light: "https://basemaps.cartocdn.com/rastertiles/light_nolabels/{z}/{x}/{y}@2x.png",
                                dark: "https://basemaps.cartocdn.com/rastertiles/dark_nolabels/{z}/{x}/{y}@2x.png",
                                credit: "© OpenStreetMap contributors, © CARTO", key: key))
        await model.showLibrary()
        let source = CardWatcher.card(at: scratch.appendingPathComponent("AL-CARD"))!
        model.choose(source)
        await model.read(source, for: model.book.people[0].id)
        print("alignment: \(model.photosLine) | aligning \(model.aligning) | alignable \(model.alignable.count)")
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        NSApp.appearance = NSAppearance(named: .aqua)
        let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 1100, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: AlignmentProbe().environmentObject(model))
        window.contentView = host
        window.orderBack(nil)
        for _ in 0..<120 { spin(0.05); try? await Task.sleep(for: .milliseconds(50)) }
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: scratch.appendingPathComponent("alignment.png"))
        }
    }
}

extension SelfTest {
    /// The card guard on a test disk only (volume GTTEST, marker folder
    /// GEOTAG_TEST, so nothing else on the Mac takes it for a camera card).
    /// It must open it hidden and read-only, then force it off and eject it.
    @MainActor
    static func guardTest(_ scratch: URL) async {
        await guardRun(scratch, refuse: true)
        await guardRun(scratch, refuse: false)
    }

    /// With `refuse` off, the Mac opens the test disk itself first and the
    /// guard must take it over.
    @MainActor
    static func guardRun(_ scratch: URL, refuse: Bool) async {
        let label = refuse ? "guard" : "guard, opened first"
        func run(_ tool: String, _ args: [String]) -> (Int32, String) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            let out = Pipe()
            p.standardOutput = out
            p.standardError = out
            try? p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        }
        let src = scratch.appendingPathComponent("guard-src")
        try? FileManager.default.createDirectory(at: src.appendingPathComponent("GEOTAG_TEST"), withIntermediateDirectories: true)
        try? "x".write(to: src.appendingPathComponent("GEOTAG_TEST/a.txt"), atomically: true, encoding: .utf8)
        // The Mac's own format, so a Geotag running on this Mac, which only
        // looks at FAT and exFAT cards, leaves the test disk alone.
        let image = scratch.appendingPathComponent("guard-\(refuse).dmg")
        guard run("/usr/bin/hdiutil", ["create", "-quiet", "-srcfolder", src.path, "-volname", "GTTEST", "-fs", "HFS+", image.path]).0 == 0 else {
            check("\(label): test disk made", false)
            return
        }
        let guardian = CardGuard(marker: "GEOTAG_TEST", refuseAtApproval: refuse) { d in d[kDADiskDescriptionVolumeNameKey as String] as? String == "GTTEST" }
        var heldCard: PhotoSource?
        var gone: [String] = []
        var problems: [String] = []
        guardian.onHeld = { heldCard = $0 }
        guardian.onGone = { gone.append($0) }
        guardian.onProblem = { problems.append($0) }
        guardian.start()
        _ = run("/usr/bin/hdiutil", ["attach", "-nobrowse", image.path])
        for _ in 0..<80 where heldCard == nil { spin(0.05); try? await Task.sleep(for: .milliseconds(50)) }
        check("\(label): the card is held", heldCard != nil, problems.joined(separator: " "))
        guard let card = heldCard, let bsd = card.bsd else { return }
        let line = run("/sbin/mount", []).1.split(separator: "\n").first { $0.contains(card.url.path) }.map(String.init) ?? ""
        check("\(label): opened read-only", line.contains("read-only"), line)
        check("\(label): hidden from Finder", line.contains("nobrowse"), line)
        let wrote = FileManager.default.createFile(atPath: card.url.appendingPathComponent("written.txt").path, contents: Data("x".utf8))
        check("\(label): nothing can be written to it", !wrote)
        check("\(label): still readable", (try? String(contentsOf: card.url.appendingPathComponent("GEOTAG_TEST/a.txt"), encoding: .utf8)) == "x")

        // Something holding a file open does not stop the eject.
        let handle = FileHandle(forReadingAtPath: card.url.appendingPathComponent("GEOTAG_TEST/a.txt").path)
        var answer: String?? = .none
        let started = Date()
        guardian.eject(bsd) { answer = .some($0) }
        for _ in 0..<100 where answer == nil { spin(0.05); try? await Task.sleep(for: .milliseconds(50)) }
        let took = Date().timeIntervalSince(started)
        check("\(label): ejected at once, a file open or not", answer == .some(nil), "\(String(describing: answer)) in \(String(format: "%.1f", took)) s")
        check("\(label): within two seconds", took < 2)
        for _ in 0..<40 where gone.isEmpty { spin(0.05); try? await Task.sleep(for: .milliseconds(50)) }
        check("\(label): told the card is gone", !gone.isEmpty && Set(gone) == [bsd], "\(gone)")
        check("\(label): no longer attached", !run("/usr/bin/hdiutil", ["info"]).1.contains(image.path))
        try? handle?.close()
    }
}

extension SelfTest {
    static func names() {
        check("copy name: JPG becomes jpg", CopyName.forCopy("IMG_0001.JPG") == "IMG_0001.jpg")
        check("copy name: JPEG becomes jpg", CopyName.forCopy("IMG_0002.JPEG") == "IMG_0002.jpg")
        check("copy name: jpeg becomes jpg", CopyName.forCopy("IMG_0003.jpeg") == "IMG_0003.jpg")
        check("copy name: jpg stays", CopyName.forCopy("IMG_0004.jpg") == "IMG_0004.jpg")
        check("copy name: raw untouched", CopyName.forCopy("DAVL0311.CR3") == "DAVL0311.CR3" && CopyName.forCopy("IMG.HIF") == "IMG.HIF")
        let d = ISO8601DateFormatter().date(from: "2026-10-16T14:05:09Z")!
        let utc = TimeZone(secondsFromGMT: 0)!
        check("dates: day month year", When(order: .dayMonthYear, clock24: true).day(d, zone: utc).hasPrefix("16 Oct"), When(order: .dayMonthYear).day(d, zone: utc))
        check("dates: year month day", When(order: .yearMonthDay).day(d, zone: utc) == "2026-10-16")
        check("dates: 24-hour clock", When(clock24: true).time(d, zone: utc, seconds: true) == "14:05:09")
        check("dates: 12-hour clock", When(clock24: false).time(d, zone: utc).hasPrefix("2:05"), When(clock24: false).time(d, zone: utc))
    }
}

extension SelfTest {
    /// Which disks the guard takes for cards.
    static func cardKinds() {
        func d(_ kind: String, name: String = "EOS_DIGITAL", inside: Bool = false, removable: Bool = true, ejectable: Bool = true,
               content: String = "Windows_NTFS", proto: String = "USB") -> [String: Any] {
            [(kDADiskDescriptionVolumeKindKey as String): kind, (kDADiskDescriptionVolumeNameKey as String): name,
             (kDADiskDescriptionDeviceInternalKey as String): inside, (kDADiskDescriptionMediaRemovableKey as String): removable,
             (kDADiskDescriptionMediaEjectableKey as String): ejectable, (kDADiskDescriptionMediaContentKey as String): content,
             (kDADiskDescriptionDeviceProtocolKey as String): proto, (kDADiskDescriptionVolumeMountableKey as String): true]
        }
        check("card kinds: an SD card", CardGuard.cardLike(d("exfat")))
        check("card kinds: a CFexpress card in a reader that calls itself fixed",
              CardGuard.cardLike(d("exfat", removable: false, ejectable: false, proto: "PCI-Express")))
        check("card kinds: a FAT card", CardGuard.cardLike(d("msdos", content: "DOS_FAT_32")))
        check("card kinds: not a drive's hidden start-up part",
              !CardGuard.cardLike(d("msdos", name: "EFI", removable: false, content: "C12A7328-F81F-11D2-BA4B-00A0C93EC93B")))
        check("card kinds: not the Mac's own disk", !CardGuard.cardLike(d("exfat", inside: true)))
        check("card kinds: not an APFS or HFS drive", !CardGuard.cardLike(d("apfs")) && !CardGuard.cardLike(d("hfs")))
    }
}

extension SelfTest {
    /// Saving, on copies only: a "card" folder made in the scratch folder from
    /// the sample photos and the published raw files, never the real card.
    static func saving(_ scratch: URL, samples: URL, raws: URL?) {
        let fm = FileManager.default
        let card = scratch.appendingPathComponent("SAVE-CARD/DCIM/100CANON")
        try? fm.createDirectory(at: card, withIntermediateDirectories: true)
        var files = ((try? fm.contentsOfDirectory(at: samples, includingPropertiesForKeys: nil)) ?? []).filter { PhotoKinds.isPhoto($0) }
        if let raws { files += ((try? fm.contentsOfDirectory(at: raws, includingPropertiesForKeys: nil)) ?? []).filter { PhotoKinds.isPhoto($0) } }
        for f in files {
            let copy = card.appendingPathComponent(f.lastPathComponent)
            try? fm.copyItem(at: f, to: copy)
            // A camera writes a file once: created and modified at the same moment.
            if let m = (try? fm.attributesOfItem(atPath: f.path))?[.modificationDate] as? Date {
                try? fm.setAttributes([.creationDate: m, .modificationDate: m], ofItemAtPath: copy.path)
            }
        }
        // A JPEG whose name ends in .JPEG, to be saved ending in .jpg.
        if let jpg = files.first(where: { $0.pathExtension.uppercased() == "JPG" }) {
            let copy = card.appendingPathComponent("RENAME_ME.JPEG")
            try? fm.copyItem(at: jpg, to: copy)
            if let m = (try? fm.attributesOfItem(atPath: jpg.path))?[.modificationDate] as? Date {
                try? fm.setAttributes([.creationDate: m, .modificationDate: m], ofItemAtPath: copy.path)
            }
        }
        let cardFiles = PhotoScanner.files(in: card)
        func fingerprints() -> [String: String] {
            var out: [String: String] = [:]
            for f in cardFiles { out[f.lastPathComponent] = Saver.sha256(f) ?? "" }
            return out
        }
        let before = fingerprints()
        let tool = ExifTool(script: URL(fileURLWithPath: "Vendor/ExifTool/exiftool"))
        let photos = (try? PhotoScanner(exifTool: tool).scan(cardFiles) { _ in }) ?? []
        check("save: the test card read", photos.count == cardFiles.count && !photos.isEmpty, "\(photos.count) of \(cardFiles.count)")

        let out = scratch.appendingPathComponent("SAVED")
        let saver = Saver(exifTool: tool, folder: out)
        let moment = ISO8601DateFormatter().date(from: "2027-01-12T15:00:00Z")!
        let here = Position(lat: -54.8091234, lon: -68.2971234, alt: 5.5, moment: moment, fromPoint: 3)
        var saved: [(ScannedPhoto, SaveResult, SaveItem)] = []
        for (i, p) in photos.enumerated() {
            let item: SaveItem
            if p.hasLocation {
                item = SaveItem(photo: p, placement: .ownLocation, withoutLocation: false)
            } else if i == 1 {
                item = SaveItem(photo: p, placement: .review(.noTrack), withoutLocation: true)
            } else {
                item = SaveItem(photo: p, placement: .matched(here), withoutLocation: false)
            }
            saved.append((p, saver.save(item), item))
        }
        for (p, r, item) in saved {
            guard case .saved(let url) = r else {
                check("save: \(p.fileName)", false, "\(r)")
                continue
            }
            let attrs = (try? fm.attributesOfItem(atPath: url.path)) ?? [:]
            let original = (try? fm.attributesOfItem(atPath: p.url.path)) ?? [:]
            let datesKept = (attrs[.modificationDate] as? Date) == (original[.modificationDate] as? Date)
                && (attrs[.creationDate] as? Date) == (original[.creationDate] as? Date)
            // Read back the way Finder and Photos read it.
            var where_ = "-"
            if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
               let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
               let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any] {
                where_ = "\(gps[kCGImagePropertyGPSLatitude] ?? "-")\(gps[kCGImagePropertyGPSLatitudeRef] ?? "") \(gps[kCGImagePropertyGPSLongitude] ?? "-")\(gps[kCGImagePropertyGPSLongitudeRef] ?? "")"
            }
            let expectsWritten = item.position != nil
            let ok = datesKept && (!expectsWritten || (where_.contains("S") && where_.contains("W") && where_.hasPrefix("54.809")))
            check("save: \(p.fileName) as \(url.deletingLastPathComponent().lastPathComponent)/\(url.lastPathComponent)", ok,
                  "\(expectsWritten ? "written" : "copied as is"), dates kept \(datesKept), system reads \(where_)")
        }
        check("save: JPEG ends .jpg", fm.fileExists(atPath: out.appendingPathComponent("2025.03.23/RENAME_ME.jpg").path)
              || saved.contains { $0.1.url?.lastPathComponent == "RENAME_ME.jpg" })
        let leftovers = (fm.enumerator(atPath: out.path)?.allObjects as? [String] ?? []).filter { $0.contains(".geotag-") || $0.contains("exiftool_tmp") }
        check("save: no working copies left behind", leftovers.isEmpty, "\(leftovers)")
        check("save: the card untouched", fingerprints() == before)

        // The same photos again: already there, nothing doubled.
        let again = saved.map { saver.save($0.2) }
        check("save: saving again finds them already there", again.allSatisfy { if case .alreadyThere = $0 { return true } else { return false } },
              "\(again.filter { if case .alreadyThere = $0 { return false } else { return true } })")
        // A different photo under a name already taken gets _2: two JPEGs.
        let jpegs = saved.filter { $0.0.fileName.uppercased().hasSuffix(".JPG") && $0.1.url != nil }
        if jpegs.count >= 2, let taken = jpegs[0].1.url {
            let other = jpegs[1].0
            let impostor = ScannedPhoto(url: other.url, fileName: jpegs[0].0.fileName, size: other.size,
                                        taken: jpegs[0].0.taken, subSeconds: other.subSeconds, zone: other.zone, model: other.model)
            let r = saver.save(SaveItem(photo: impostor, placement: .matched(here), withoutLocation: false))
            check("save: a different photo with a taken name gets _2", r.url?.lastPathComponent == Saver.numbered(taken.lastPathComponent, 2), "\(r)")
        }
        check("save: the card still untouched", fingerprints() == before)
    }
}

extension SelfTest {
    /// The edges of saving: the 60th second, leftovers, a photo saved before
    /// with another location, and the whole flow through the app model.
    @MainActor
    static func savingEdges(_ scratch: URL, samples: URL) async {
        let fm = FileManager.default
        // A moment 59.996 s into the minute is written as 59.99, never 60.00.
        let edge = Date(timeIntervalSince1970: 1_799_999_999.996)
        let args = Saver.gpsArguments(Position(lat: 1, lon: 1, alt: nil, moment: edge, fromPoint: 0))
        check("save: no 60th second", args.contains { $0 == "-GPS:GPSTimeStamp=07:59:59.99" }, args.first { $0.hasPrefix("-GPS:GPSTimeStamp") } ?? "")
        let plain = Saver.gpsArguments(Position(lat: 1, lon: 1, alt: -3, moment: ISO8601DateFormatter().date(from: "2027-01-12T15:04:05Z")!, fromPoint: 0))
        check("save: an ordinary time and day", plain.contains("-GPS:GPSTimeStamp=15:04:05.00") && plain.contains("-GPS:GPSDateStamp=2027:01:12"))
        check("save: below sea level", plain.contains("-GPS:GPSAltitude=3.00") && plain.contains("-GPS:GPSAltitudeRef=1"))

        // Leftovers: only Geotag's own working copies go.
        let out = scratch.appendingPathComponent("EDGES")
        let day = out.appendingPathComponent("2026.01.01")
        try? fm.createDirectory(at: day, withIntermediateDirectories: true)
        try? "x".write(to: day.appendingPathComponent(".IMG_1.geotag-ABCDEF12.JPG"), atomically: true, encoding: .utf8)
        try? "x".write(to: day.appendingPathComponent(".IMG_2.geotag-0123ABCD"), atomically: true, encoding: .utf8)
        try? "x".write(to: day.appendingPathComponent(".hidden-of-his"), atomically: true, encoding: .utf8)
        try? "x".write(to: day.appendingPathComponent("IMG_3.geotag-ABCDEF12.JPG"), atomically: true, encoding: .utf8)
        let tool = ExifTool(script: URL(fileURLWithPath: "Vendor/ExifTool/exiftool"))
        let saver = Saver(exifTool: tool, folder: out)
        saver.clearLeftovers()
        let left = Set((try? fm.contentsOfDirectory(atPath: day.path)) ?? [])
        check("save: only Geotag's own leftovers cleared", left == [".hidden-of-his", "IMG_3.geotag-ABCDEF12.JPG"], "\(left.sorted())")

        // Saved before with another location: the earlier copy is kept and it says so.
        guard let jpg = ((try? fm.contentsOfDirectory(at: samples, includingPropertiesForKeys: nil)) ?? [])
            .first(where: { $0.pathExtension.uppercased() == "JPG" }),
              let photo = (try? PhotoScanner(exifTool: tool).scan([jpg]) { _ in })?.first, !photo.hasLocation || true else { return }
        let moment = ISO8601DateFormatter().date(from: "2027-01-12T15:00:00Z")!
        let a = Position(lat: -54.80, lon: -68.30, alt: nil, moment: moment, fromPoint: 0)
        let b = Position(lat: -54.90, lon: -68.10, alt: nil, moment: moment, fromPoint: 0)
        let first = saver.save(SaveItem(photo: photo, placement: .matched(a), withoutLocation: false))
        let second = saver.save(SaveItem(photo: photo, placement: .matched(b), withoutLocation: false))
        let third = saver.save(SaveItem(photo: photo, placement: .matched(a), withoutLocation: false))
        if case .saved = first { check("save: first save", true) } else { check("save: first save", false, "\(first)") }
        check("save: saved before with another location says so", { if case .failed(let w) = second { return w == "Previously saved in another location" } else { return false } }(), "\(second)")
        check("save: the same location again is already there", { if case .alreadyThere = third { return true } else { return false } }(), "\(third)")

        // The whole flow through the app model, on a test card made of copies.
        let card = scratch.appendingPathComponent("FLOW-CARD")
        let dcim = card.appendingPathComponent("DCIM/100CANON")
        try? fm.createDirectory(at: dcim, withIntermediateDirectories: true)
        for f in ((try? fm.contentsOfDirectory(at: samples, includingPropertiesForKeys: nil)) ?? []).filter({ PhotoKinds.isPhoto($0) }) {
            try? fm.copyItem(at: f, to: dcim.appendingPathComponent(f.lastPathComponent))
        }
        let saveTo = scratch.appendingPathComponent("FLOW-SAVED")
        try? fm.createDirectory(at: saveTo, withIntermediateDirectories: true)
        let queueFile = QueueStoreFile(url: scratch.appendingPathComponent("flow-queue.json"))
        let historyFolder = HistoryStoreFolder(folder: scratch.appendingPathComponent("flow-history"))
        let model = AppModel(library: TrackLibrary(store: TrackStoreFolder(folder: scratch.appendingPathComponent("flow-lib"))),
                             peopleStore: PeopleStoreFile(url: scratch.appendingPathComponent("flow-people.json")),
                             history: historyFolder, queue: queueFile, secrets: NoSecrets(),
                             thumbnails: MapThumbnails(folder: scratch.appendingPathComponent("flow-maps")), exifTool: tool)
        var david = model.book.people[0]
        david.saveFolder = scratch.appendingPathComponent("NOT-THERE").path
        model.save(david)
        let source = CardWatcher.card(at: card)!
        model.choose(source)
        model.askingWhose = nil
        await model.read(source, for: david.id)
        // No track here: every photo without a location of its own is let through without one.
        for row in model.rows where row.needsReview { model.setWithoutLocation(row.id, true) }
        let ready = model.readyToSave.count
        await model.savePhotos()
        check("flow: a missing save folder is said once, nothing saved", model.photosLine.contains("can't be found") && model.results.isEmpty, model.photosLine)
        david.saveFolder = saveTo.path
        model.save(david)
        await model.savePhotos()
        let queued = (try? queueFile.load()) ?? []
        let remembered = (try? historyFolder.load(david.id)) ?? []
        check("flow: every ready photo saved", model.results.count == ready && model.results.values.allSatisfy { $0.url != nil }, "\(model.photosLine)")
        check("flow: History has them", remembered.count == ready, "\(remembered.count) of \(ready)")
        check("flow: the queue has them, by day folder", queued.count == ready && queued.allSatisfy { $0.relativePath.split(separator: "/").count == 2 }, "\(queued.map(\.relativePath))")
        check("flow: they now count as imported before", model.rows.allSatisfy { $0.status == .alreadyImported && !$0.ticked })
        await model.savePhotos()
        check("flow: nothing left to save", model.readyToSave.isEmpty && ((try? queueFile.load()) ?? []).count == ready)
    }
}

extension SelfTest {
    /// A photo saved without a location (its camera's offset not set) gets it
    /// written into the saved copy once the offset is set.
    @MainActor
    static func placingLater(_ scratch: URL, samples: URL) async {
        let fm = FileManager.default
        let photoFile = samples.appendingPathComponent("DAVL3660.JPG") // 2025:03:23 17:44:20 -05:00, no location
        guard fm.fileExists(atPath: photoFile.path) else { print("skip  later: no DAVL3660.JPG"); return }
        let tool = ExifTool(script: URL(fileURLWithPath: "Vendor/ExifTool/exiftool"))
        let lib = TrackLibrary(store: TrackStoreFolder(folder: scratch.appendingPathComponent("later-lib")))
        let gpx = scratch.appendingPathComponent("later-walk.gpx")
        let start = Int(ISO8601DateFormatter().date(from: "2025-03-23T22:30:00Z")!.timeIntervalSince1970)
        writeGPX(gpx, start: start, count: 1800, name: "Casco Viejo", lat: 8.952, lon: -79.535)
        _ = try? await lib.importFile(gpx, role: .reader)
        let card = scratch.appendingPathComponent("LATER-CARD/DCIM/100CANON")
        try? fm.createDirectory(at: card, withIntermediateDirectories: true)
        try? fm.copyItem(at: photoFile, to: card.appendingPathComponent(photoFile.lastPathComponent))
        let saveTo = scratch.appendingPathComponent("LATER-SAVED")
        try? fm.createDirectory(at: saveTo, withIntermediateDirectories: true)
        let unplacedFile = UnplacedStoreFile(url: scratch.appendingPathComponent("later-unplaced.json"))
        let queueFile = QueueStoreFile(url: scratch.appendingPathComponent("later-queue.json"))
        let model = AppModel(library: lib, peopleStore: PeopleStoreFile(url: scratch.appendingPathComponent("later-people.json")),
                             history: HistoryStoreFolder(folder: scratch.appendingPathComponent("later-history")),
                             queue: queueFile, unplaced: unplacedFile, secrets: NoSecrets(),
                             thumbnails: MapThumbnails(folder: scratch.appendingPathComponent("later-maps")), exifTool: tool)
        await model.showLibrary()
        var david = model.book.people[0]
        david.saveFolder = saveTo.path
        model.save(david)
        let source = CardWatcher.card(at: scratch.appendingPathComponent("LATER-CARD"))!
        model.choose(source)
        model.askingWhose = nil
        await model.read(source, for: david.id)
        check("later: the camera's offset is not set", model.rows.first?.placement == .review(.offsetNotSet), "\(String(describing: model.rows.first?.placement))")
        await model.savePhotos()
        let saved = model.results.values.compactMap(\.url).first
        check("later: saved without a location, and remembered", saved != nil && ((try? unplacedFile.load()) ?? []).count == 1)
        guard let saved else { return }
        let before = Saver.sha256(saved)
        let dates = (try? fm.attributesOfItem(atPath: saved.path)) ?? [:]

        // The offset is set: the photo saved earlier is placed.
        var camera = model.book.camera(personId: david.id, model: "Canon EOS R5m2")!
        camera.offsetSeconds = 0
        model.save(camera)
        for _ in 0..<200 {
            try? await Task.sleep(for: .milliseconds(50))
            if !model.placingLater, ((try? unplacedFile.load()) ?? []).isEmpty { break }
        }
        var where_ = "-"
        if let src = CGImageSourceCreateWithURL(saved as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any] {
            where_ = "\(gps[kCGImagePropertyGPSLatitude] ?? "-")\(gps[kCGImagePropertyGPSLatitudeRef] ?? "") \(gps[kCGImagePropertyGPSLongitude] ?? "-")\(gps[kCGImagePropertyGPSLongitudeRef] ?? "")"
        }
        let after = (try? fm.attributesOfItem(atPath: saved.path)) ?? [:]
        check("later: the location is now in the saved copy", where_.hasPrefix("8.9606") && where_.contains("N") && where_.contains("W"), where_)
        check("later: the copy changed only by that", Saver.sha256(saved) != before
              && (after[.modificationDate] as? Date) == (dates[.modificationDate] as? Date)
              && (after[.creationDate] as? Date) == (dates[.creationDate] as? Date))
        check("later: off the list, once on the queue", ((try? unplacedFile.load()) ?? []).isEmpty
              && ((try? queueFile.load()) ?? []).filter { $0.localPath == saved.path }.count == 1)
        let leftovers = (fm.enumerator(atPath: saveTo.path)?.allObjects as? [String] ?? []).filter { $0.contains(".geotag-") }
        check("later: no working copies left", leftovers.isEmpty, "\(leftovers)")
        check("later: said on the Photos page", model.photosLine.contains("now has its location"), model.photosLine)
    }
}
