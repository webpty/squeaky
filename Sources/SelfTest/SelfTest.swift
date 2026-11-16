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

    /// A scratch folder as a card of its own. Folders on one disk share the
    /// disk's id, so as cards they would all be the same card: choosing a
    /// second one would start reading it as one seen before, alongside the
    /// test's own reading (found 18 October 2026).
    static func scratchCard(_ root: URL) -> PhotoSource {
        PhotoSource(id: root.path, name: root.lastPathComponent, url: root, isCard: true)
    }

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
        if ProcessInfo.processInfo.environment["GEOTAG_QUIT_CHILD"] != nil {
            await quitChild()
        }
        let realBefore = realData()
        if ProcessInfo.processInfo.environment["GEOTAG_TABLE_STRESS"] != nil {
            await tableStress(scratch, count: Int(ProcessInfo.processInfo.environment["GEOTAG_TABLE_STRESS"] ?? "") ?? 3600)
            check("tests left David's own Geotag files alone", realData() == realBefore)
            print(failures == 0 ? "all passed" : "\(failures) failed")
            exit(failures == 0 ? 0 : 1)
        }

        if let originals = ProcessInfo.processInfo.environment["GEOTAG_ORIGINALS"] {
            nativeWriting(scratch, originals: URL(fileURLWithPath: originals))
            if ProcessInfo.processInfo.environment["GEOTAG_NATIVE_ONLY"] != nil {
                print(failures == 0 ? "all passed" : "\(failures) failed")
                exit(failures == 0 ? 0 : 1)
            }
        }
        people(scratch)
        if let samples = ProcessInfo.processInfo.environment["GEOTAG_SAMPLES"] {
            saving(scratch, samples: URL(fileURLWithPath: samples),
                   raws: ProcessInfo.processInfo.environment["GEOTAG_RAWS"].map { URL(fileURLWithPath: $0) })
            altitude(scratch, samples: URL(fileURLWithPath: samples))
            await savingEdges(scratch, samples: URL(fileURLWithPath: samples))
            await placingLater(scratch, samples: URL(fileURLWithPath: samples), sendFirst: false)
            await placingLater(scratch, samples: URL(fileURLWithPath: samples), sendFirst: true)
            nasSending(scratch, samples: URL(fileURLWithPath: samples))
            await nasQueue(scratch, samples: URL(fileURLWithPath: samples))
            await nasBatch(scratch, samples: URL(fileURLWithPath: samples))
            await menuBar(scratch, samples: URL(fileURLWithPath: samples))
            heif(scratch, samples: URL(fileURLWithPath: samples))
            await firmware(scratch, samples: URL(fileURLWithPath: samples),
                           raws: ProcessInfo.processInfo.environment["GEOTAG_RAWS"].map { URL(fileURLWithPath: $0) })
            await lenses(scratch, samples: URL(fileURLWithPath: samples),
                         raws: ProcessInfo.processInfo.environment["GEOTAG_RAWS"].map { URL(fileURLWithPath: $0) })
            await clocks(scratch, samples: URL(fileURLWithPath: samples),
                         raws: ProcessInfo.processInfo.environment["GEOTAG_RAWS"].map { URL(fileURLWithPath: $0) })
        }
        await serverList(scratch)
        await trackCheck(scratch)
        await settingsFeedback(scratch)
        await naming(scratch)
        await mapOpens(scratch)
        await buttonsSay(scratch)
        setupNeeded(scratch)
        await tracksLoading(scratch)
        timeLeft()
        await quitAndAway(scratch)
        drift()
        await offsetCodes(scratch)
        sendSteps(scratch)
        await sendTogether(scratch)
        macTidy(scratch)
        await cloudCopy(scratch)
        await sidebarPhoto(scratch)
        shortcuts()
        quitting()
        download(scratch)
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
        if ProcessInfo.processInfo.environment["GEOTAG_GALLERY"] != nil {
            await gallery(scratch, samples: ProcessInfo.processInfo.environment["GEOTAG_SAMPLES"].map { URL(fileURLWithPath: $0) },
                          key: ProcessInfo.processInfo.environment["GEOTAG_MAP_KEY"])
        }

        let realAfter = realData()
        let touched = Set(realBefore.keys).union(realAfter.keys).filter { realBefore[$0] != realAfter[$0] }.sorted()
        check("tests left David's own Geotag files alone", touched.isEmpty, "\(touched)")

        print(failures == 0 ? "all passed" : "\(failures) failed")
        print("scratch: \(scratch.path)")
        exit(failures == 0 ? 0 : 1)
    }

    /// Size and last change of Geotag's own records on this Mac. The tests
    /// must work only in their scratch folder, never in these.
    static func realData() -> [String: String] {
        let fm = FileManager.default
        let folder = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Geotag")
        var out: [String: String] = [:]
        var paths = ["people.json", "queue.json", "unplaced.json", "temperatures.json", "photos.json"]
        paths += ((try? fm.contentsOfDirectory(atPath: folder.appendingPathComponent("History").path)) ?? []).map { "History/\($0)" }
        for path in paths {
            let attributes = (try? fm.attributesOfItem(atPath: folder.appendingPathComponent(path).path)) ?? [:]
            let changed = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            out[path] = "\(attributes[.size] ?? "-") \(changed)"
        }
        return out
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
        let model = AppModel(library: lib, peopleStore: familyFile( scratch.appendingPathComponent("viewer-people.json")),
                             history: HistoryStoreFolder(folder: scratch.appendingPathComponent("viewer-history")),
                             queue: QueueStoreFile(url: scratch.appendingPathComponent("viewer-queue.json")),
                             unplaced: UnplacedStoreFile(url: scratch.appendingPathComponent("viewer-unplaced.json")),
                             secrets: NoSecrets(), thumbnails: MapThumbnails(folder: scratch.appendingPathComponent("viewer-maps")),
                             nas: FakeNAS(root: scratch.appendingPathComponent("viewer-nas")))
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
                             peopleStore: familyFile( scratch.appendingPathComponent("pp-people.json")),
                             history: HistoryStoreFolder(folder: scratch.appendingPathComponent("history")),
                             queue: QueueStoreFile(url: scratch.appendingPathComponent("pp-queue.json")),
                             unplaced: UnplacedStoreFile(url: scratch.appendingPathComponent("pp-unplaced.json")),
                             secrets: NoSecrets(), thumbnails: MapThumbnails(folder: scratch.appendingPathComponent("pp-maps")),
                             exifTool: ExifTool(script: URL(fileURLWithPath: "Vendor/ExifTool/exiftool")),
                             nas: FakeNAS(root: scratch.appendingPathComponent("pp-nas")))
        let source = scratchCard(card)
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
        let model = AppModel(library: lib, peopleStore: familyFile( scratch.appendingPathComponent("al-people.json")),
                             history: HistoryStoreFolder(folder: scratch.appendingPathComponent("al-history")),
                             queue: QueueStoreFile(url: scratch.appendingPathComponent("al-queue.json")),
                             unplaced: UnplacedStoreFile(url: scratch.appendingPathComponent("al-unplaced.json")),
                             secrets: NoSecrets(), thumbnails: MapThumbnails(folder: scratch.appendingPathComponent("al-maps")),
                             exifTool: ExifTool(script: URL(fileURLWithPath: "Vendor/ExifTool/exiftool")),
                             nas: FakeNAS(root: scratch.appendingPathComponent("al-nas")))
        model.useMaps(MapSource(light: "https://basemaps.cartocdn.com/rastertiles/light_nolabels/{z}/{x}/{y}@2x.png",
                                dark: "https://basemaps.cartocdn.com/rastertiles/dark_nolabels/{z}/{x}/{y}@2x.png",
                                credit: "© OpenStreetMap contributors, © CARTO", key: key))
        await model.showLibrary()
        let source = scratchCard(scratch.appendingPathComponent("AL-CARD"))
        model.choose(source)
        await model.read(source, for: model.book.people[0].id)
        print("map: \(model.photosLine) | \(model.mappable.count) to show")
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
        check("card kinds: not the Mac's own disk",
              !CardGuard.cardLike(d("exfat", inside: true, removable: false, ejectable: false, proto: "Apple Fabric")))
        check("card kinds: not a FAT part of the Mac's own disk", !CardGuard.cardLike(d("msdos", name: "SHARED", inside: true,
              removable: false, ejectable: false, content: "Microsoft Basic Data", proto: "Apple Fabric")))
        check("card kinds: a card in the Mac's own SD slot",
              CardGuard.cardLike(d("exfat", inside: true, removable: true, ejectable: true, proto: "Secure Digital")))
        check("card kinds: a card in the Mac's own SD slot, even when the slot calls it fixed",
              CardGuard.cardLike(d("exfat", inside: true, removable: false, ejectable: false, proto: "Secure Digital")))
        check("card kinds: not an APFS or HFS drive", !CardGuard.cardLike(d("apfs")) && !CardGuard.cardLike(d("hfs")))

        // This Mac's own disks, as the Mac itself describes them: none is a card.
        if let session = DASessionCreate(kCFAllocatorDefault) {
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? [])
                .filter { $0.range(of: #"^disk[0-9]+(s[0-9]+)?$"#, options: .regularExpression) != nil }
            let inside = names.compactMap { name -> (String, [String: Any])? in
                guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, name),
                      let d = DADiskCopyDescription(disk) as? [String: Any],
                      d[kDADiskDescriptionDeviceInternalKey as String] as? Bool == true else { return nil }
                return (name, d)
            }
            let taken = inside.filter { CardGuard.cardLike($0.1) }.map(\.0)
            check("card kinds: none of this Mac's own \(inside.count) disks and parts counts as a card", !inside.isEmpty && taken.isEmpty, "\(taken)")
        }
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
        let taken = ScannedPhoto(url: URL(fileURLWithPath: "/x.jpg"), fileName: "x.jpg", size: 1, taken: "2025:03:23 17:44:20",
                                 subSeconds: nil, zone: nil, model: nil)
        let undated = ScannedPhoto(url: URL(fileURLWithPath: "/y.jpg"), fileName: "y.jpg", size: 1, taken: nil, subSeconds: nil, zone: nil, model: nil)
        check("folders: day and place", Saver.folderName(taken, place: "Ushuaia") == "2025.03.23 Ushuaia")
        check("folders: the day alone with no place", Saver.folderName(taken, place: nil) == "2025.03.23" && Saver.folderName(taken, place: "  ") == "2025.03.23")
        check("folders: a place's slashes and colons made safe", Saver.folderName(taken, place: "Puerto Natales/Última: Esperanza") == "2025.03.23 Puerto Natales-Última- Esperanza",
              Saver.folderName(taken, place: "Puerto Natales/Última: Esperanza"))
        check("folders: no date, the place still", Saver.folderName(undated, place: "Ushuaia") == "Undated Ushuaia")
        let edge = Date(timeIntervalSince1970: 1_799_999_999.996)
        let args = Saver.gpsArguments(Position(lat: 1, lon: 1, alt: nil, moment: edge, fromPoint: 0))
        check("save: no 60th second", args.contains { $0 == "-GPS:GPSTimeStamp=07:59:59.99" }, args.first { $0.hasPrefix("-GPS:GPSTimeStamp") } ?? "")
        let plain = Saver.gpsArguments(Position(lat: 1, lon: 1, alt: -3, moment: ISO8601DateFormatter().date(from: "2027-01-12T15:04:05Z")!, fromPoint: 0))
        check("save: an ordinary time and day", plain.contains("-GPS:GPSTimeStamp=15:04:05.00") && plain.contains("-GPS:GPSDateStamp=2027:01:12"))
        check("save: below sea level", plain.contains("-GPS:GPSAltitude=3.00") && plain.contains("-GPS:GPSAltitudeRef#=1"))

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
        // The note that Geotag added the location: in the copy, and read by the Mac's own photo reading too.
        if case .saved(let url) = first {
            let note = (try? tool.read(["GPSProcessingMethod"], from: url))?["GPSProcessingMethod"]
            var mac = "-"
            if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
               let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
               let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any] {
                mac = "\(gps[kCGImagePropertyGPSProcessingMethod] ?? "-")"
            }
            check("save: the copy says Geotag added its location", note == "GPS coordinates added by Geotag.app"
                  && mac == "GPS coordinates added by Geotag.app", "ExifTool: \(note ?? "-"); the Mac: \(mac)")
            let card = (try? tool.read(["GPSProcessingMethod"], from: jpg))?["GPSProcessingMethod"]
            check("save: the card's photo has no such note", card != Saver.processingMethod, card ?? "")
        }

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
        let flowPlaces = FakePlaces()
        let model = AppModel(library: TrackLibrary(store: TrackStoreFolder(folder: scratch.appendingPathComponent("flow-lib"))),
                             peopleStore: familyFile( scratch.appendingPathComponent("flow-people.json")),
                             history: historyFolder, queue: queueFile,
                             unplaced: UnplacedStoreFile(url: scratch.appendingPathComponent("flow-unplaced.json")), secrets: NoSecrets(),
                             thumbnails: MapThumbnails(folder: scratch.appendingPathComponent("flow-maps")), exifTool: tool,
                             nas: FakeNAS(root: scratch.appendingPathComponent("flow-nas")), places: flowPlaces)
        var david = model.book.people[0]
        david.saveFolder = scratch.appendingPathComponent("NOT-THERE").path
        model.save(david)
        let source = scratchCard(card)
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
        let placed = queued.filter { $0.relativePath.contains(" Greenland/") }.map(\.relativePath).sorted()
        let dayOnly = queued.filter { !$0.relativePath.split(separator: "/")[0].contains(" ") }
        check("flow: photos with a location in a folder of their day and place", placed == ["2025.09.05 Greenland/DAVL2443.CR3", "2025.09.06 Greenland/DAVL2909.jpg"],
              "\(queued.map(\.relativePath))")
        check("flow: photos with none in their day's folder alone", dayOnly.count == ready - 2, "\(dayOnly.map(\.relativePath))")
        check("flow: they now count as imported before", model.rows.allSatisfy { $0.status == .alreadyImported && !$0.ticked })
        await model.savePhotos()
        check("flow: nothing left to save", model.readyToSave.isEmpty && ((try? queueFile.load()) ?? []).count == ready)
    }
}

extension SelfTest {
    /// A photo saved without a location (its camera's offset not set) gets it
    /// written into the saved copy once the offset is set. With `sendFirst`,
    /// the copy without it has already gone to the (stand-in) NAS, and the
    /// newer copy replaces it there.
    @MainActor
    static func placingLater(_ scratch: URL, samples: URL, sendFirst: Bool) async {
        let fm = FileManager.default
        let photoFile = samples.appendingPathComponent("DAVL3660.JPG") // 2025:03:23 17:44:20 -05:00, no location
        guard fm.fileExists(atPath: photoFile.path) else { print("skip  later: no DAVL3660.JPG"); return }
        let tag = sendFirst ? "later-sent" : "later"
        let tool = ExifTool(script: URL(fileURLWithPath: "Vendor/ExifTool/exiftool"))
        let lib = TrackLibrary(store: TrackStoreFolder(folder: scratch.appendingPathComponent("\(tag)-lib")))
        let gpx = scratch.appendingPathComponent("\(tag)-walk.gpx")
        let start = Int(ISO8601DateFormatter().date(from: "2025-03-23T22:30:00Z")!.timeIntervalSince1970)
        writeGPX(gpx, start: start, count: 1800, name: "Casco Viejo", lat: 8.952, lon: -79.535)
        _ = try? await lib.importFile(gpx, role: .reader)
        let cardRoot = scratch.appendingPathComponent("\(tag.uppercased())-CARD")
        let card = cardRoot.appendingPathComponent("DCIM/100CANON")
        try? fm.createDirectory(at: card, withIntermediateDirectories: true)
        try? fm.copyItem(at: photoFile, to: card.appendingPathComponent(photoFile.lastPathComponent))
        let saveTo = scratch.appendingPathComponent("\(tag.uppercased())-SAVED")
        try? fm.createDirectory(at: saveTo, withIntermediateDirectories: true)
        let unplacedFile = UnplacedStoreFile(url: scratch.appendingPathComponent("\(tag)-unplaced.json"))
        let queueFile = QueueStoreFile(url: scratch.appendingPathComponent("\(tag)-queue.json"))
        let nasRoot = scratch.appendingPathComponent("\(tag.uppercased())-NAS")
        let notes = RecordingNotifier()
        let model = AppModel(library: lib, peopleStore: familyFile( scratch.appendingPathComponent("\(tag)-people.json")),
                             history: HistoryStoreFolder(folder: scratch.appendingPathComponent("\(tag)-history")),
                             queue: queueFile, unplaced: unplacedFile, secrets: NoSecrets(),
                             thumbnails: MapThumbnails(folder: scratch.appendingPathComponent("\(tag)-maps")), exifTool: tool,
                             nas: FakeNAS(root: nasRoot), notifier: notes, places: FakePlaces())
        await model.showLibrary()
        var david = model.book.people[0]
        david.saveFolder = saveTo.path
        if sendFirst { david.nasFolder = "homes/david/Photos" }
        model.save(david)
        let source = scratchCard(cardRoot)
        model.choose(source)
        model.askingWhose = nil
        await model.read(source, for: david.id)
        check("\(tag): the camera's offset is not set", model.rows.first?.placement == .review(.offsetNotSet), "\(String(describing: model.rows.first?.placement))")
        await model.savePhotos()
        let saved = model.results.values.compactMap(\.url).first
        check("\(tag): saved without a location, and remembered", saved != nil && ((try? unplacedFile.load()) ?? []).count == 1)
        guard let saved else { return }
        let onNAS = nasRoot.appendingPathComponent("homes/david/Photos/2025.03.23/\(saved.lastPathComponent)")
        if sendFirst {
            await model.sendWaiting()
            check("\(tag): the copy without a location went to the NAS", model.queueEntry(for: saved.path)?.state == .sent
                  && Saver.sha256(onNAS) == Saver.sha256(saved), model.queueLine)
            check("\(tag): and a notification says so", notes.posted == ["1 photo is on the NAS."], "\(notes.posted)")
        }
        let before = Saver.sha256(saved)
        let dates = (try? fm.attributesOfItem(atPath: saved.path)) ?? [:]

        // The offset is set: nothing saved earlier is placed by itself (0.27.0).
        var camera = model.book.camera(personId: david.id, model: "Canon EOS R5m2")!
        camera.offsetSeconds = 0
        model.save(camera)
        try? await Task.sleep(for: .milliseconds(500))
        check("\(tag): not placed by itself", ((try? unplacedFile.load()) ?? []).count == 1 && Saver.sha256(saved) == before)
        // The track card's Recheck places it.
        if let track = model.tracks.first {
            await model.recheckPhotos(for: track)
            check("\(tag): the track card says how many it placed", model.tracksLine == "1 of 1 photos from \(track.name) now have their location.",
                  model.tracksLine)
        } else {
            check("\(tag): a track to recheck", false)
        }
        var where_ = "-"
        if let src = CGImageSourceCreateWithURL(saved as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any] {
            where_ = "\(gps[kCGImagePropertyGPSLatitude] ?? "-")\(gps[kCGImagePropertyGPSLatitudeRef] ?? "") \(gps[kCGImagePropertyGPSLongitude] ?? "-")\(gps[kCGImagePropertyGPSLongitudeRef] ?? "")"
        }
        let after = (try? fm.attributesOfItem(atPath: saved.path)) ?? [:]
        check("\(tag): the location is now in the saved copy", where_.hasPrefix("8.9606") && where_.contains("N") && where_.contains("W"), where_)
        check("\(tag): the copy changed only by that", Saver.sha256(saved) != before
              && (after[.modificationDate] as? Date) == (dates[.modificationDate] as? Date)
              && (after[.creationDate] as? Date) == (dates[.creationDate] as? Date))
        let queued = ((try? queueFile.load()) ?? []).filter { $0.localPath == saved.path }
        if sendFirst {
            check("\(tag): off the list, and on the queue again to replace the NAS copy", ((try? unplacedFile.load()) ?? []).isEmpty
                  && queued.count == 2 && queued[0].state == .sent && queued[1].state == .waiting && queued[1].update,
                  "\(queued.map { "\($0.state) \($0.update)" })")
            await model.sendWaiting()
            let names = (try? fm.contentsOfDirectory(atPath: onNAS.deletingLastPathComponent().path)) ?? []
            check("\(tag): the NAS copy replaced by the one with the location, nothing else left", Saver.sha256(onNAS) == Saver.sha256(saved)
                  && names == [saved.lastPathComponent] && model.queueEntry(for: saved.path)?.state == .sent, "\(names) \(model.queueLine)")
            check("\(tag): a notification for that batch too", notes.posted.count == 2, "\(notes.posted)")
        } else {
            check("\(tag): off the list, once on the queue", ((try? unplacedFile.load()) ?? []).isEmpty
                  && queued.count == 1 && !queued[0].update)
        }
        let leftovers = (fm.enumerator(atPath: saveTo.path)?.allObjects as? [String] ?? []).filter { $0.contains(".geotag-") }
        check("\(tag): no working copies left", leftovers.isEmpty, "\(leftovers)")
        check("\(tag): said on the Photos page", model.photosLine.contains("now has its location"), model.photosLine)
    }
}

extension SelfTest {
    /// A track service holding the given tracks, each with a point a minute.
    struct TracksService: TrackServicePort {
        let items: [ServiceTrack]
        init(_ spans: [(String, Int, Int)]) {
            items = spans.map { id, start, end in
                let json = #"{"id":"\#(id)","source":"strava","name":"\#(id)","start":\#(start),"end":\#(end),"pointCount":\#((end - start) / 60 + 1),"bounds":{"minLat":8.95,"maxLat":8.96,"minLon":-79.54,"maxLon":-79.53}}"#
                return try! JSONDecoder().decode(ServiceTrack.self, from: Data(json.utf8))
            }
        }
        func status() async throws -> ServiceStatus { throw ServiceError.offline }
        func maps() async throws -> MapSource { throw ServiceError.offline }
        func tracks() async throws -> [ServiceTrack] { items }
        func points(_ id: String) async throws -> TrackPoints {
            guard let item = items.first(where: { $0.id == id }) else { throw ServiceError.offline }
            let t = Array(stride(from: item.start, through: item.end, by: 60))
            return TrackPoints(t: t, lat: t.map { _ in 8.952 }, lon: t.map { _ in -79.535 }, alt: t.map { _ in -0.4 })
        }
        func upload(name: String, fileName: String?, points: TrackPoints) async throws -> UploadAnswer { throw ServiceError.offline }
        func sync() async throws -> String { "" }
        func connectLink() async throws -> URL { throw ServiceError.offline }
        func disconnect() async throws -> String { throw ServiceError.offline }
    }

    /// The check before a card saves itself, held photos, and a track card's
    /// Recheck (0.27.0, David, 12 November 2026).
    @MainActor
    static func trackCheck(_ scratch: URL) async {
        let fm = FileManager.default
        let tool = ExifTool(script: URL(fileURLWithPath: "Vendor/ExifTool/exiftool"))
        let saveTo = scratch.appendingPathComponent("TC-SAVED")
        try? fm.createDirectory(at: saveTo, withIntermediateDirectories: true)
        let unplacedFile = UnplacedStoreFile(url: scratch.appendingPathComponent("tc-unplaced.json"))
        let nasRoot = scratch.appendingPathComponent("TC-NAS")
        let model = AppModel(library: TrackLibrary(store: TrackStoreFolder(folder: scratch.appendingPathComponent("tc-lib"))),
                             peopleStore: familyFile(scratch.appendingPathComponent("tc-people.json")),
                             history: HistoryStoreFolder(folder: scratch.appendingPathComponent("tc-history")),
                             queue: QueueStoreFile(url: scratch.appendingPathComponent("tc-queue.json")), unplaced: unplacedFile,
                             secrets: NoSecrets(), thumbnails: MapThumbnails(folder: scratch.appendingPathComponent("tc-maps")),
                             exifTool: tool, nas: FakeNAS(root: nasRoot), notifier: RecordingNotifier(), places: FakePlaces())
        model.saveWhenReady = true
        var david = model.book.people[0]
        david.saveFolder = saveTo.path
        david.nasFolder = "homes/david/Photos"
        model.save(david)
        var camera = model.book.camera(personId: david.id, model: "Canon EOS R5m2")!
        camera.offsetSeconds = 0
        model.save(camera)
        let day = 86_400, noon = 1_792_162_800 // 2026-10-16 15:00 UTC, 12:00 at -03:00
        func track(_ id: String, _ d: Int) -> (String, Int, Int) { (id, noon + d * day - 600, noon + d * day + 600) }
        func card(_ name: String, _ d: Int) async -> (URL, PhotoSource) {
            let root = scratch.appendingPathComponent("TC-\(name)")
            let folder = root.appendingPathComponent("DCIM/100CANON")
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let photo = folder.appendingPathComponent("\(name).JPG")
            writePhoto(photo, model: "Canon EOS R5m2", zone: "-03:00", taken: "2026:10:\(16 + d) 12:00:00")
            let source = scratchCard(root)
            model.choose(source)
            model.askingWhose = nil
            return (photo, source)
        }
        func waitWhile(_ busy: () -> Bool) async {
            for _ in 0..<200 where busy() { try? await Task.sleep(for: .milliseconds(50)) }
        }
        func gps(_ url: URL?) -> String? { url.flatMap { try? tool.read(["GPSLatitude"], from: $0)["GPSLatitude"] } }

        // A track on the service but not yet on this Mac: found, and the card saves itself.
        model.useServiceForTest(TracksService([track("Day one", 0)]), role: .reader)
        var (photo, source) = await card("ONE", 0)
        let cardBytes = Saver.sha256(photo)
        await model.read(source, for: david.id)
        var saved = model.results.values.compactMap(\.url).first
        check("track check: a track found on refreshing, the card saved at once with the location",
              model.trackCheck == nil && saved != nil && gps(saved) != nil, "\(String(describing: model.trackCheck)) \(model.photosLine)")
        check("track check: the card's photo unchanged", Saver.sha256(photo) == cardBytes)

        // No track anywhere: nothing saved until a button is clicked.
        (photo, source) = await card("TWO", 1)
        await model.read(source, for: david.id)
        check("track check: no track, the choice waits", model.trackCheck == .noTrack(1) && model.results.isEmpty,
              "\(String(describing: model.trackCheck))")
        model.dontSave()
        check("track check: Don't save saves nothing", model.trackCheck == nil && model.results.isEmpty && !model.saving)
        await model.checkTracksBeforeSave()
        check("track check: checked again, still none", model.trackCheck == .noTrack(1))
        model.saveAnyway()
        await waitWhile { model.results.isEmpty || model.saving }
        saved = model.results.values.compactMap(\.url).first
        let two = saved
        check("track check: Save anyway saves it without a location, for the NAS straight away",
              saved != nil && gps(saved) == nil && model.queueEntry(for: saved?.path ?? "")?.held == false)

        // Nothing saved earlier is placed by itself when its track arrives.
        model.useServiceForTest(TracksService([track("Day one", 0), track("Day two", 1)]), role: .reader)
        await model.refresh()
        try? await Task.sleep(for: .milliseconds(300))
        check("track check: a later track places nothing by itself", gps(two) == nil && ((try? unplacedFile.load()) ?? []).count == 1)
        // The track card's Recheck does.
        let tracks = model.tracks
        if let dayOne = tracks.first(where: { $0.name == "Day one" }), let dayTwo = tracks.first(where: { $0.name == "Day two" }) {
            await model.recheckPhotos(for: dayOne)
            check("track check: Recheck on another day's track finds nothing to place",
                  model.tracksLine == "No photos without a location from Day one." && gps(two) == nil, model.tracksLine)
            await model.recheckPhotos(for: dayTwo)
            check("track check: Recheck on its track places it and sends it again",
                  model.tracksLine == "1 of 1 photos from Day two now have their location." && gps(two) != nil
                  && ((try? unplacedFile.load()) ?? []).isEmpty, model.tracksLine)
        } else {
            check("track check: the two tracks are listed", false, "\(tracks.map(\.name))")
        }

        // The track service away: Save anyway keeps it on this Mac until the tracks are checked.
        model.useServiceForTest(DeadService(), role: .reader)
        (photo, source) = await card("THREE", 2)
        await model.read(source, for: david.id)
        check("track check: the service away is said", model.trackCheck == .offline(1), "\(String(describing: model.trackCheck))")
        model.saveAnyway()
        await waitWhile { model.results.isEmpty || model.saving }
        saved = model.results.values.compactMap(\.url).first
        check("track check: saved and held back from the NAS", saved != nil && model.queueEntry(for: saved?.path ?? "")?.held == true)
        await model.sendWaiting()
        let three = saved.map { nasRoot.appendingPathComponent("homes/david/Photos/\($0.deletingLastPathComponent().lastPathComponent)/\($0.lastPathComponent)") }
        check("track check: a held photo is not sent", model.queueEntry(for: saved?.path ?? "")?.state == .waiting
              && !(three.map { fm.fileExists(atPath: $0.path) } ?? true))
        // Back online with its track: placed, then let go.
        model.useServiceForTest(TracksService([track("Day three", 2)]), role: .reader)
        await model.refresh()
        await waitWhile { model.queueEntries.contains(where: \.held) || model.placingLater }
        await model.sendWaiting()
        check("track check: once the service answers, placed and sent", gps(saved) != nil
              && model.queueEntry(for: saved?.path ?? "")?.state == .sent && three.map { Saver.sha256($0) == Saver.sha256(saved!) } == true,
              model.queueLine)

        // An eject that fails (a disk that is not there) stops the spinner and lets Eject be clicked again.
        let ghost = PhotoSource(id: "tc-ghost", name: "GHOST", url: scratch.appendingPathComponent("TC-GHOST"), isCard: true, bsd: "disk987s1")
        model.choose(ghost)
        model.askingWhose = nil
        model.eject()
        for _ in 0..<100 where model.ejecting != nil { try? await Task.sleep(for: .milliseconds(50)) }
        check("eject: a failed eject ends the busy state and says so", model.ejecting == nil && model.photosLine.hasPrefix("GHOST was not ejected."),
              model.photosLine)

        // Taking the card out closes the choice.
        model.useServiceForTest(DeadService(), role: .reader)
        (photo, source) = await card("FOUR", 3)
        await model.read(source, for: david.id)
        model.cardOutForTest()
        check("track check: the card out closes the choice", model.trackCheck == nil)
    }
}

/// Places named without going online: Greenland in the far north, Ushuaia in
/// the far south, nothing in between, or no answer at all.
@MainActor
final class FakePlaces: PlaceNaming {
    let answer: (Double, Double) -> PlaceLookup
    private(set) var asked = 0

    init(_ answer: @escaping (Double, Double) -> PlaceLookup = { lat, _ in
        lat > 60 ? .found("Greenland") : lat < -40 ? .found("Ushuaia") : .nothing
    }) {
        self.answer = answer
    }

    func place(lat: Double, lon: Double) async -> PlaceLookup {
        asked += 1
        return answer(lat, lon)
    }
}

/// Notifications kept for the tests to read, instead of shown on the Mac.
final class RecordingNotifier: NotifierPort, @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [String] = []

    var posted: [String] { lock.withLock { texts } }

    func post(_ text: String) {
        lock.withLock { texts.append(text) }
    }
}

/// A folder standing in for the NAS: the tests never touch David's real one.
/// A people file holding the four people tests use, unless one is there
/// already: a new install starts with nobody (0.21.0).
func familyFile(_ url: URL) -> PeopleStoreFile {
    let file = PeopleStoreFile(url: url)
    if !FileManager.default.fileExists(atPath: url.path) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? file.save(.family())
    }
    return file
}

extension SelfTest {
    /// The list of photos saved, on the server (0.29.0): what one Mac saved
    /// from a card counts as saved on another reading the same card.
    @MainActor
    static func serverList(_ scratch: URL) async {
        let fm = FileManager.default
        let nas = FakeNAS(root: scratch.appendingPathComponent("SL-NAS"))
        let root = scratch.appendingPathComponent("SL-CARD")
        let folder = root.appendingPathComponent("DCIM/100CANON")
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for i in 0..<4 {
            writePhoto(folder.appendingPathComponent(String(format: "IMG_%04d.JPG", i + 1)), model: "Canon EOS R5m2", zone: "-03:00",
                       taken: String(format: "2026:10:16 18:%02d:00", i * 5))
        }
        let tool = ExifTool(script: URL(fileURLWithPath: "Vendor/ExifTool/exiftool"))
        func model(_ tag: String) -> AppModel {
            let people = familyFile(scratch.appendingPathComponent("sl-\(tag)-people.json"))
            if var book = try? people.load() {
                for i in book.people.indices { book.people[i].nasFolder = "homes/\(book.people[i].name.lowercased())/Geotag" }
                try? people.save(book)
            }
            return AppModel(library: TrackLibrary(store: TrackStoreFolder(folder: scratch.appendingPathComponent("sl-\(tag)-tracks"))),
                            peopleStore: people, history: HistoryStoreFolder(folder: scratch.appendingPathComponent("sl-\(tag)-history")),
                            queue: QueueStoreFile(url: scratch.appendingPathComponent("sl-\(tag)-queue.json")),
                            unplaced: UnplacedStoreFile(url: scratch.appendingPathComponent("sl-\(tag)-unplaced.json")),
                            secrets: NoSecrets(), thumbnails: MapThumbnails(folder: scratch.appendingPathComponent("sl-\(tag)-maps")),
                            exifTool: tool, nas: nas, notifier: RecordingNotifier(), places: FakePlaces())
        }
        let first = model("a"), second = model("b")
        guard let davidA = first.book.people.first(where: { $0.name == "David" })?.id,
              let davidB = second.book.people.first(where: { $0.name == "David" })?.id else {
            check("server list: people", false)
            return
        }
        // The first Mac has saved the card's photos before.
        let photos = (try? PhotoScanner(exifTool: tool).scan(PhotoScanner.files(in: root)) { _ in }) ?? []
        let saved = photos.map { HistoryEntry(fileName: $0.fileName, size: $0.size, taken: $0.taken, subSeconds: $0.subSeconds, imported: Date()) }
        try? HistoryStoreFolder(folder: scratch.appendingPathComponent("sl-a-history")).save(davidA, saved)
        await first.publishHistory(davidA)
        let listed = fm.fileExists(atPath: scratch.appendingPathComponent("SL-NAS/homes/david/Geotag/.geotag").path)
        let onServer = await second.serverHistory(davidB)
        check("server list: one Mac's photos saved are listed on the server for the other", listed && onServer.count == 4,
              "\(onServer.count) listed")
        // The second Mac reads the same card: nothing new on it.
        let card = scratchCard(root)
        second.saveWhenReady = false
        second.choose(card)
        second.askingWhose = nil
        await second.read(card, for: davidB)
        for _ in 0..<100 where second.rows.isEmpty || second.photosBusy { try? await Task.sleep(for: .milliseconds(100)) }
        check("server list: the other Mac counts them as saved before", second.rows.count == 4
              && second.rows.allSatisfy { $0.status == .alreadyImported }, "\(second.rows.map(\.status))")
        // An offset set on one device reaches the other; the newest wins.
        if var camera = first.book.camera(personId: davidA, model: "Canon EOS R5m2") {
            camera.offsetSeconds = 7
            first.save(camera)
            await first.publishCameras(davidA)
            await second.pullCameras(davidB)
            let got = second.book.camera(personId: davidB, model: "Canon EOS R5m2")?.offsetSeconds
            check("server list: a camera offset set on one Mac reaches the other", got == 7, "\(String(describing: got))")
            if var theirs = second.book.camera(personId: davidB, model: "Canon EOS R5m2") {
                try? await Task.sleep(for: .milliseconds(20))
                theirs.offsetSeconds = -3
                second.save(theirs)
                await second.publishCameras(davidB)
                await first.pullCameras(davidA)
                let back = first.book.camera(personId: davidA, model: "Canon EOS R5m2")?.offsetSeconds
                check("server list: a newer offset from the other comes back", back == -3, "\(String(describing: back))")
            }
        } else {
            check("server list: a camera to set", false)
        }
        // Shared when asked, and the time it happened shown.
        await second.shareWithServer()
        check("server list: sharing says when it happened", second.sharedAt != nil && second.sharedProblem == nil
              && QueueText.shared(at: second.sharedAt, problem: nil).hasPrefix("Shared with the NAS: "))
        // Server away: no wait, and the card reads as new.
        nas.online = false
        await second.checkNAS()
        await second.shareWithServer()
        check("server list: sharing with the server away says why", second.sharedProblem != nil,
              QueueText.shared(at: second.sharedAt, problem: second.sharedProblem))
        let started = Date()
        let none = await second.serverHistory(davidB)
        check("server list: a server that does not answer is not waited for", none.isEmpty && Date().timeIntervalSince(started) < 2)
    }
}

final class FakeNAS: NASPort, @unchecked Sendable {
    let root: URL
    private let lock = NSLock()
    private var reachable = true
    private var wait = 0.0

    init(root: URL) {
        self.root = root
    }

    var online: Bool {
        get { lock.withLock { reachable } }
        set { lock.withLock { reachable = newValue } }
    }

    /// Seconds it takes to answer.
    var delay: Double {
        get { lock.withLock { wait } }
        set { lock.withLock { wait = newValue } }
    }

    func connect(share: String) async throws -> NASConnection {
        if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
        guard online else { throw NASError.offline("The NAS can't be reached at smb://test.") }
        let folder = root.appendingPathComponent(share, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return NASConnection(folder: folder, address: "smb://test", ours: false)
    }

    func disconnect(_ connection: NASConnection) async {}
}

extension SelfTest {
    /// Sending one photo: checked on arrival, never overwriting, `_2` for
    /// another photo, Geotag's own earlier copy replaced only as an update,
    /// and only Geotag's own old leftovers cleared.
    static func nasSending(_ scratch: URL, samples: URL) {
        let fm = FileManager.default
        let tool = ExifTool(script: URL(fileURLWithPath: "Vendor/ExifTool/exiftool"))
        let jpgs = ((try? fm.contentsOfDirectory(at: samples, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.uppercased() == "JPG" }.sorted { $0.path < $1.path }
        guard let photoFile = jpgs.first(where: { $0.lastPathComponent == "DAVL3660.JPG" }),
              let otherFile = jpgs.first(where: { $0 != photoFile }) else { print("skip  nas: samples missing"); return }
        let mac = scratch.appendingPathComponent("SEND-MAC")
        try? fm.createDirectory(at: mac.appendingPathComponent("other"), withIntermediateDirectories: true)
        let copy = mac.appendingPathComponent("DAVL3660.jpg")
        try? fm.copyItem(at: photoFile, to: copy)
        let day = scratch.appendingPathComponent("SEND-NAS/homes/david/Photos/2025.03.23")
        let there = day.appendingPathComponent("DAVL3660.jpg")
        func send(_ file: URL, update: Bool = false) -> Result<SendOutcome, NASError> {
            do {
                return .success(try NASSender.send(file, as: "DAVL3660.jpg", into: day, update: update, clean: true, exifTool: tool) { _ in })
            } catch {
                return .failure(error as? NASError ?? .failed("\(error)"))
            }
        }
        func hidden() -> [String] { ((try? fm.contentsOfDirectory(atPath: day.path)) ?? []).filter { $0.hasPrefix(".") } }

        let first = send(copy)
        let a = (try? fm.attributesOfItem(atPath: copy.path)) ?? [:], b = (try? fm.attributesOfItem(atPath: there.path)) ?? [:]
        check("nas: sent, the day folder made", first == .success(.sent(there)), "\(first)")
        check("nas: identical on the NAS", Saver.sha256(there) == Saver.sha256(copy))
        check("nas: the Mac copy's dates", (a[.modificationDate] as? Date) == (b[.modificationDate] as? Date)
              && (a[.creationDate] as? Date) == (b[.creationDate] as? Date))
        check("nas: no working copy left", hidden().isEmpty, "\(hidden())")
        check("nas: the same file again is already there", send(copy) == .success(.alreadyThere(there)))

        let other = mac.appendingPathComponent("other/DAVL3660.jpg")
        try? fm.copyItem(at: otherFile, to: other)
        let second = send(other)
        check("nas: another photo with that name becomes _2", second == .success(.sent(day.appendingPathComponent("DAVL3660_2.jpg")))
              && Saver.sha256(day.appendingPathComponent("DAVL3660_2.jpg")) == Saver.sha256(other), "\(second)")

        // The same photo with its location written in later.
        let placed = mac.appendingPathComponent("placed.jpg")
        try? fm.copyItem(at: copy, to: placed)
        let moment = ISO8601DateFormatter().date(from: "2025-03-23T22:44:20Z")!
        let problem = Saver(exifTool: tool, folder: mac).addLocation(to: placed, Position(lat: 8.95, lon: -79.53, alt: nil, moment: moment, fromPoint: 0))
        check("nas: a location written into a second copy", problem == nil, problem ?? "")
        let firstHash = Saver.sha256(there)
        let refused = send(placed)
        check("nas: not an update, the NAS copy is kept and it says so", refused == .failure(.failed("Already on the NAS with another location"))
              && Saver.sha256(there) == firstHash, "\(refused)")
        let replaced = send(placed, update: true)
        check("nas: as an update, Geotag's earlier copy is replaced", replaced == .success(.replaced(there))
              && Saver.sha256(there) == Saver.sha256(placed) && hidden().isEmpty, "\(replaced) \(hidden())")

        // The same photo at the same place, written by a Geotag without the note: it is there already.
        let older = mac.appendingPathComponent("older.jpg")
        try? fm.copyItem(at: placed, to: older)
        _ = try? tool.run(["-q", "-q", "-overwrite_original", "-P", "-GPS:GPSProcessingMethod=", older.path])
        let noteGone = (try? tool.read(["GPSProcessingMethod"], from: older))?["GPSProcessingMethod"] == nil
        let current = Saver.sha256(there)
        let same = send(older)
        check("nas: the same photo and place, written a little differently, is already there", noteGone
              && same == .success(.alreadyThere(there)) && Saver.sha256(there) == current, "\(same)")

        // Leftovers: only Geotag's own unfinished uploads, an hour old.
        let old = Date().addingTimeInterval(-7200)
        for (name, date) in [(".A.geotag-up-ABCDEF12.jpg", old), (".B.geotag-up-12345678.jpg", Date()),
                             (".his-hidden", old), ("C.geotag-up-ABCDEF12.jpg", old), (".D.geotag-old-ABCDEF12.jpg", old)] {
            let url = day.appendingPathComponent(name)
            try? "x".write(to: url, atomically: true, encoding: .utf8)
            try? fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
        NASSender.clearLeftovers(in: day)
        let left = Set((try? fm.contentsOfDirectory(atPath: day.path)) ?? [])
        check("nas: only Geotag's own old unfinished uploads cleared", !left.contains(".A.geotag-up-ABCDEF12.jpg")
              && left.isSuperset(of: [".B.geotag-up-12345678.jpg", ".his-hidden", "C.geotag-up-ABCDEF12.jpg", ".D.geotag-old-ABCDEF12.jpg",
                                      "DAVL3660.jpg", "DAVL3660_2.jpg"]), "\(left.sorted())")

        let gone = send(mac.appendingPathComponent("not-there.jpg"))
        check("nas: a copy gone from the Mac is said so", gone == .failure(.failed("The copy on this Mac is no longer there.")), "\(gone)")

        // Where people's NAS folders point.
        let folder = NASFolder(" homes / david/Photos/ ")
        check("nas: a NAS folder is its shared folder and the path in it", folder?.share == "homes" && folder?.path == "david/Photos"
              && NASFolder("") == nil && NASFolder("homes")?.path == "")
        check("nas: addresses", NASOverSMB.host("smb://10.0.10.10") == "10.0.10.10" && NASOverSMB.host("100.99.144.35/") == "100.99.144.35"
              && NASOverSMB.host("smb://nas.home.arpa/") == "nas.home.arpa" && NASOverSMB.host("  ") == nil)
    }

    /// The queue through the app model: the NAS away, paused, back; someone
    /// without a NAS folder; a send cut off by a crash; a copy gone.
    @MainActor
    static func nasQueue(_ scratch: URL, samples: URL) async {
        let fm = FileManager.default
        let tool = ExifTool(script: URL(fileURLWithPath: "Vendor/ExifTool/exiftool"))
        let jpgs = ((try? fm.contentsOfDirectory(at: samples, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.uppercased() == "JPG" }.sorted { $0.path < $1.path }
        guard jpgs.count >= 3 else { print("skip  queue: fewer than three JPEG samples"); return }

        // People, and copies on the Mac as a save leaves them, already on the queue.
        var book = PeopleBook.family()
        book.people[0].nasFolder = "homes/david/Photos"
        let peopleFile = PeopleStoreFile(url: scratch.appendingPathComponent("queue-people.json"))
        try? peopleFile.save(book)
        let david = book.people[0].id, amanda = book.people[1].id
        let mac = scratch.appendingPathComponent("QUEUE-MAC")
        func copied(_ file: URL, _ day: String, as name: String? = nil) -> (URL, String) {
            let folder = mac.appendingPathComponent(day)
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(name ?? file.lastPathComponent)
            try? fm.copyItem(at: file, to: url)
            return (url, "\(day)/\(url.lastPathComponent)")
        }
        var entries: [QueueEntry] = []
        for (i, jpg) in jpgs.prefix(3).enumerated() {
            let (url, relative) = copied(jpg, "2025.03.2\(i)")
            entries.append(QueueEntry(personId: david, localPath: url.path, relativePath: relative, added: Date().addingTimeInterval(Double(i - 10))))
        }
        let (forAmanda, amandasPlace) = copied(jpgs[0], "amanda")
        entries.append(QueueEntry(personId: amanda, localPath: forAmanda.path, relativePath: amandasPlace))
        // The first photo again, as a send a crash cut off left it.
        let (again, _) = copied(jpgs[0], "again")
        var cut = QueueEntry(personId: david, localPath: again.path, relativePath: entries[0].relativePath)
        cut.state = .sending
        entries.append(cut)
        let missing = QueueEntry(personId: david, localPath: mac.appendingPathComponent("gone.jpg").path, relativePath: "2025.03.20/gone.jpg")
        entries.append(missing)
        let stranger = QueueEntry(personId: UUID(), localPath: entries[1].localPath, relativePath: entries[1].relativePath)
        entries.append(stranger)
        let queueFile = QueueStoreFile(url: scratch.appendingPathComponent("queue-queue.json"))
        try? queueFile.save(entries)

        let fake = FakeNAS(root: scratch.appendingPathComponent("QUEUE-NAS"))
        fake.online = false
        let notes = RecordingNotifier()
        let model = AppModel(library: TrackLibrary(store: TrackStoreFolder(folder: scratch.appendingPathComponent("queue-lib"))),
                             peopleStore: peopleFile, history: HistoryStoreFolder(folder: scratch.appendingPathComponent("queue-history")),
                             queue: queueFile, unplaced: UnplacedStoreFile(url: scratch.appendingPathComponent("queue-unplaced.json")),
                             secrets: NoSecrets(), thumbnails: MapThumbnails(folder: scratch.appendingPathComponent("queue-maps")),
                             exifTool: tool, nas: fake, notifier: notes)
        func state(_ id: UUID) -> QueueState? { model.queueEntries.first { $0.id == id }?.state }
        check("queue: a send cut off is waiting again", state(cut.id) == .waiting)

        await model.sendWaiting()
        check("queue: the NAS away, nothing sent, and it says so", model.queueEntries.allSatisfy { $0.state != .sent }
              && model.queueLine.contains("can't be reached") && model.nasReach == .unreachable, model.queueLine)
        check("queue: someone off the list, their photo not sent and why", state(stranger.id) == .failed
              && model.queueEntries.first { $0.id == stranger.id }?.reason == "Their person was removed from People")
        check("queue: no notification while it waits for the NAS", notes.posted.isEmpty, "\(notes.posted)")

        fake.online = true
        model.setSendPaused(true)
        await model.sendWaiting()
        check("queue: paused, nothing sent", model.queueEntries.allSatisfy { $0.state != .sent } && model.queueLine == "Paused.", model.queueLine)
        check("queue: no notification while paused", notes.posted.isEmpty, "\(notes.posted)")

        model.setSendPaused(false)
        await model.sendWaiting()
        let nas = scratch.appendingPathComponent("QUEUE-NAS/homes/david/Photos")
        let davids = entries.prefix(3)
        check("queue: David's photos sent, each into its day folder", davids.allSatisfy { e in
            state(e.id) == .sent && Saver.sha256(nas.appendingPathComponent(e.relativePath)) == Saver.sha256(URL(fileURLWithPath: e.localPath))
        })
        check("queue: the cut-off one found already there", state(cut.id) == .sent
              && model.queueEntries.first { $0.id == cut.id }?.sentAs == nil)
        check("queue: a copy gone from the Mac is not sent, and why", state(missing.id) == .failed
              && model.queueEntries.first { $0.id == missing.id }?.reason == "The copy on this Mac is no longer there.")
        check("queue: Amanda's waits for her NAS folder, and it says so", state(entries[3].id) == .waiting
              && model.queueLine.contains("Amanda has no NAS folder"), model.queueLine)
        check("queue: the Photos page can tell", model.queueEntry(for: entries[0].localPath)?.state == .sent
              && model.nasReach == .through("smb://test"))
        let onDisk = (try? queueFile.load()) ?? []
        check("queue: written to disk as it went", onDisk.filter { $0.state == .sent }.count == 4 && onDisk.count == entries.count,
              "\(onDisk.map(\.state))")
        check("queue: one notification for the whole batch", notes.posted == ["4 photos are on the NAS. 2 were not sent."], "\(notes.posted)")
        await model.sendWaiting()
        check("queue: none again with nothing new", notes.posted.count == 1, "\(notes.posted)")

        model.retryFailed()
        check("queue: Retry failed puts them back in line", state(missing.id) == .waiting && state(stranger.id) == .waiting)
        await model.sendWaiting()
        check("queue: and they fail again for the same reasons", state(missing.id) == .failed && state(stranger.id) == .failed)
        check("queue: and a notification says so", notes.posted.last == "2 photos were not sent.", "\(notes.posted)")

        // Restarted: the list as it was left.
        let again2 = AppModel(library: TrackLibrary(store: TrackStoreFolder(folder: scratch.appendingPathComponent("queue-lib"))),
                              peopleStore: peopleFile, history: HistoryStoreFolder(folder: scratch.appendingPathComponent("queue-history")),
                              queue: queueFile, unplaced: UnplacedStoreFile(url: scratch.appendingPathComponent("queue-unplaced.json")),
                              secrets: NoSecrets(), thumbnails: MapThumbnails(folder: scratch.appendingPathComponent("queue-maps")),
                              exifTool: tool, nas: fake)
        check("queue: after a restart, the same list", again2.queueEntries.map(\.state) == model.queueEntries.map(\.state))

        // Pictures of the Queue page and the NAS card, off-screen.
        guard ProcessInfo.processInfo.environment["GEOTAG_VIEWER"] != nil else { return }
        model.nasAddress = "smb://10.0.10.10"
        model.nasBackupAddress = "smb://100.99.144.35"
        model.nasUser = "david"
        model.nasPassword = "not-a-real-one"
        // The longest line the card shows, to see it wrap.
        model.nasLine = "Saved. The NAS can't be reached at 10.0.10.10 or 100.99.144.35."
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        NSApp.appearance = NSAppearance(named: .aqua)
        let pictures: [(String, AnyView, NSSize)] = [
            ("queue.png", AnyView(QueueScreenProbe().environmentObject(model)), NSSize(width: 1000, height: 520)),
            ("nas-card.png", AnyView(NASCardProbe().environmentObject(model)), NSSize(width: 720, height: 300)),
        ]
        for (file, view, size) in pictures {
            let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -6000, y: -6000), size: size), styleMask: [.titled],
                                  backing: .buffered, defer: false)
            let host = NSHostingView(rootView: view)
            window.contentView = host
            window.orderBack(nil)
            for _ in 0..<30 { spin(0.05); try? await Task.sleep(for: .milliseconds(50)) }
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: scratch.appendingPathComponent(file))
            }
        }
        print("queue pictures: \(scratch.path)")
    }

    /// A card being saved while the photos already saved go up: one
    /// notification once it is all done, never one per photo.
    @MainActor
    static func nasBatch(_ scratch: URL, samples: URL) async {
        let fm = FileManager.default
        let tool = ExifTool(script: URL(fileURLWithPath: "Vendor/ExifTool/exiftool"))
        let card = scratch.appendingPathComponent("BATCH-CARD")
        let dcim = card.appendingPathComponent("DCIM/100CANON")
        try? fm.createDirectory(at: dcim, withIntermediateDirectories: true)
        for f in ((try? fm.contentsOfDirectory(at: samples, includingPropertiesForKeys: nil)) ?? []).filter({ PhotoKinds.isPhoto($0) }) {
            try? fm.copyItem(at: f, to: dcim.appendingPathComponent(f.lastPathComponent))
        }
        let saveTo = scratch.appendingPathComponent("BATCH-SAVED")
        try? fm.createDirectory(at: saveTo, withIntermediateDirectories: true)
        let notes = RecordingNotifier()
        // No internet: OpenStreetMap does not answer.
        let offline = FakePlaces { _, _ in .unreachable }
        let model = AppModel(library: TrackLibrary(store: TrackStoreFolder(folder: scratch.appendingPathComponent("batch-lib"))),
                             peopleStore: familyFile( scratch.appendingPathComponent("batch-people.json")),
                             history: HistoryStoreFolder(folder: scratch.appendingPathComponent("batch-history")),
                             queue: QueueStoreFile(url: scratch.appendingPathComponent("batch-queue.json")),
                             unplaced: UnplacedStoreFile(url: scratch.appendingPathComponent("batch-unplaced.json")),
                             secrets: NoSecrets(), thumbnails: MapThumbnails(folder: scratch.appendingPathComponent("batch-maps")),
                             exifTool: tool, nas: FakeNAS(root: scratch.appendingPathComponent("BATCH-NAS")), notifier: notes,
                             places: offline)
        var david = model.book.people[0]
        david.saveFolder = saveTo.path
        david.nasFolder = "homes/david"
        model.save(david)
        let source = scratchCard(card)
        model.choose(source)
        model.askingWhose = nil
        await model.read(source, for: david.id)
        let photos = model.readyToSave.count
        // Sending keeps up with saving, as on the home network.
        let saving = Task { await model.savePhotos() }
        var started = false, sentWhileSaving = 0, notifiedWhileSaving = false
        for _ in 0..<2000 {
            try? await Task.sleep(for: .milliseconds(30))
            if model.saving { started = true }
            await model.sendWaiting()
            if model.saving {
                sentWhileSaving = max(sentWhileSaving, model.queueEntries.filter { $0.state == .sent }.count)
                if !notes.posted.isEmpty { notifiedWhileSaving = true }
            }
            if (started && !model.saving) || model.saveDone == photos { break }
        }
        await saving.value
        check("batch: photos went up while the card was still being saved", sentWhileSaving > 0, "\(sentWhileSaving) sent")
        check("batch: no notification until the card was all saved", !notifiedWhileSaving, "\(notes.posted)")
        await model.sendWaiting()
        let sent = model.queueEntries.filter { $0.state == .sent }.count
        check("batch: every saved photo on the NAS", sent == photos && photos > 0, "\(sent) of \(photos)")
        check("batch: one notification, once all were saved and sent", notes.posted == [AppModel.batchText(sent: photos, failed: 0)],
              "\(notes.posted)")
        check("batch: no internet, asked once, every folder by its day alone", offline.asked == 1
              && model.queueEntries.allSatisfy { !$0.relativePath.split(separator: "/")[0].contains(" ") },
              "asked \(offline.asked): \(model.queueEntries.map(\.relativePath))")
    }

    /// Save says so at once, then what the NAS or the service answers, and is
    /// only there when something changed. The notification's words.
    @MainActor
    static func settingsFeedback(_ scratch: URL) async {
        check("words: one photo", AppModel.batchText(sent: 1, failed: 0) == "1 photo is on the NAS.")
        check("words: a batch", AppModel.batchText(sent: 19, failed: 0) == "19 photos are on the NAS.")
        check("words: some not sent", AppModel.batchText(sent: 17, failed: 2) == "17 photos are on the NAS. 2 were not sent.")
        check("words: one not sent", AppModel.batchText(sent: 3, failed: 1) == "3 photos are on the NAS. 1 was not sent.")
        check("words: none sent", AppModel.batchText(sent: 0, failed: 1) == "1 photo was not sent."
              && AppModel.batchText(sent: 0, failed: 2) == "2 photos were not sent.")

        var book = PeopleBook.family()
        book.people[0].nasFolder = "homes/david"
        let peopleFile = PeopleStoreFile(url: scratch.appendingPathComponent("feedback-people.json"))
        try? peopleFile.save(book)
        let fake = FakeNAS(root: scratch.appendingPathComponent("FEEDBACK-NAS"))
        let model = AppModel(library: TrackLibrary(store: TrackStoreFolder(folder: scratch.appendingPathComponent("feedback-lib"))),
                             peopleStore: peopleFile, history: HistoryStoreFolder(folder: scratch.appendingPathComponent("feedback-history")),
                             queue: QueueStoreFile(url: scratch.appendingPathComponent("feedback-queue.json")),
                             unplaced: UnplacedStoreFile(url: scratch.appendingPathComponent("feedback-unplaced.json")),
                             secrets: NoSecrets(), thumbnails: MapThumbnails(folder: scratch.appendingPathComponent("feedback-maps")),
                             nas: fake, notifier: RecordingNotifier())
        check("save: nothing to save at first", !model.nasUnsaved && !model.serviceUnsaved)
        let before = model.nasUser
        model.nasUser = before + "x"
        check("save: a changed field makes Save available", model.nasUnsaved)
        model.nasUser = before
        check("save: changed back, nothing to save", !model.nasUnsaved)
        model.nasUser = before + "x"
        fake.delay = 0.4
        let saving = Task { await model.saveNAS() }
        try? await Task.sleep(for: .milliseconds(150))
        check("save: says saved, and that it is checking", model.nasLine == "Saved. Checking the NAS" && model.nasBusy, model.nasLine)
        await saving.value
        check("save: then what the NAS answered", model.nasLine == "Saved. Connected through test.", model.nasLine)
        check("save: nothing left to save", !model.nasUnsaved && !model.nasBusy)
        fake.delay = 0
        await model.testNAS()
        check("save: Test connection says what the NAS answered", model.nasLine == "Connected through test.", model.nasLine)
        fake.online = false
        await model.testNAS()
        check("save: or that it can't be reached", model.nasLine == "The NAS can't be reached at smb://test.", model.nasLine)
        model.nasUser = before
        await model.saveNAS()
        check("save: saved even when the NAS is away, and says both", model.nasLine == "Saved. The NAS can't be reached at smb://test.", model.nasLine)

        let key = model.serviceKey
        model.serviceKey = key + "x"
        check("save: a changed key makes the service's Save available", model.serviceUnsaved)
        await model.saveService()
        check("save: the service's Save says saved first", model.settingsLine.hasPrefix("Saved. ") && !model.serviceUnsaved, model.settingsLine)
        model.serviceKey = key
        await model.saveService()

        // The Queue page's NAS box: asked, not left at its last need.
        fake.online = true
        await model.checkNAS()
        check("nas box: where the NAS answers", model.nasReach == .through("smb://test"), "\(model.nasReach)")
        fake.online = false
        await model.checkNAS()
        check("nas box: or that it can't be reached", model.nasReach == .unreachable, "\(model.nasReach)")
        let bare = AppModel(library: TrackLibrary(store: TrackStoreFolder(folder: scratch.appendingPathComponent("bare-lib"))),
                            peopleStore: familyFile( scratch.appendingPathComponent("bare-people.json")),
                            history: HistoryStoreFolder(folder: scratch.appendingPathComponent("bare-history")),
                            queue: QueueStoreFile(url: scratch.appendingPathComponent("bare-queue.json")),
                            unplaced: UnplacedStoreFile(url: scratch.appendingPathComponent("bare-unplaced.json")),
                            secrets: NoSecrets(), thumbnails: MapThumbnails(folder: scratch.appendingPathComponent("bare-maps")),
                            nas: fake, notifier: RecordingNotifier())
        await bare.checkNAS()
        check("nas box: nobody with a NAS folder, not set up", bare.nasReach == .notSetUp, "\(bare.nasReach)")
    }
}

extension SelfTest {
    /// Every screen, window and sheet drawn off-screen in light and in dark,
    /// with test tracks, a test card and a stand-in NAS (GEOTAG_GALLERY=1).
    /// The pictures land in the run's scratch folder, under "gallery".
    @MainActor
    static func gallery(_ scratch: URL, samples: URL?, key: String?) async {
        let fm = FileManager.default
        let out = scratch.appendingPathComponent("gallery")
        try? fm.createDirectory(at: out, withIntermediateDirectories: true)
        let tool = ExifTool(script: URL(fileURLWithPath: "Vendor/ExifTool/exiftool"))

        // Tracks: a walk the card's photos were taken along, and three others.
        let lib = TrackLibrary(store: TrackStoreFolder(folder: scratch.appendingPathComponent("gal-lib")))
        let start = 1_792_162_800 // 2026-10-16 15:00 UTC, 12:00 in Ushuaia
        writeGPX(scratch.appendingPathComponent("gal-walk.gpx"), start: start, count: 1800, name: "Ushuaia walk", lat: -54.812, lon: -68.33)
        _ = try? await lib.importFile(scratch.appendingPathComponent("gal-walk.gpx"), role: .reader)
        let spots: [(String, Double, Double)] = [("Panama old town", 8.952, -79.535), ("El Chaltén", -49.33, -72.89), ("Puerto Natales", -51.73, -72.50)]
        for (i, spot) in spots.enumerated() {
            let url = scratch.appendingPathComponent("gal-\(i).gpx")
            writeGPX(url, start: start - (i + 1) * 86_400 * 3, count: 1800, name: spot.0, lat: spot.1, lon: spot.2)
            _ = try? await lib.importFile(url, role: .reader)
        }

        // A card: photos along the walk, one from a camera not on the list, and David's samples.
        let cardRoot = scratch.appendingPathComponent("GAL-CARD")
        let card = cardRoot.appendingPathComponent("DCIM/100CANON")
        try? fm.createDirectory(at: card, withIntermediateDirectories: true)
        for i in 0..<8 {
            let s = 120 + i * 190
            writePhoto(card.appendingPathComponent(String(format: "IMG_%04d.JPG", i + 1)), model: "Canon EOS R5m2", zone: "-03:00",
                       taken: String(format: "2026:10:16 12:%02d:%02d", s / 60, s % 60))
        }
        writePhoto(card.appendingPathComponent("IMG_0009.JPG"), model: "Canon EOS 5D Mark IV", zone: "-03:00", taken: "2026:10:16 12:40:00")
        if let samples {
            for f in ((try? fm.contentsOfDirectory(at: samples, includingPropertiesForKeys: nil)) ?? []) where f.pathExtension.uppercased() == "JPG" {
                try? fm.copyItem(at: f, to: card.appendingPathComponent(f.lastPathComponent))
            }
        }

        // People, and the queue as a few days of use leave it: Amanda's photos
        // wait for her NAS folder, one of David's could not go.
        var book = PeopleBook.family()
        book.people[0].saveFolder = scratch.appendingPathComponent("GAL-SAVED").path
        book.people[0].nasFolder = "homes/david"
        book.people[1].saveFolder = scratch.appendingPathComponent("GAL-SAVED-AMANDA").path
        try? fm.createDirectory(at: scratch.appendingPathComponent("GAL-SAVED"), withIntermediateDirectories: true)
        for i in 0..<book.cameras.count where book.cameras[i].model == "Canon EOS R5m2" { book.cameras[i].offsetSeconds = 0 }
        let peopleFile = PeopleStoreFile(url: scratch.appendingPathComponent("gal-people.json"))
        try? peopleFile.save(book)
        let queueFile = QueueStoreFile(url: scratch.appendingPathComponent("gal-queue.json"))
        let earlier = Date().addingTimeInterval(-86_400)
        var gone = QueueEntry(personId: book.people[0].id, localPath: "/nowhere/DAVL0001.CR3", relativePath: "2026.10.15/DAVL0001.CR3", added: earlier)
        gone.state = .failed
        gone.reason = "The copy on this Mac is no longer there."
        try? queueFile.save([
            QueueEntry(personId: book.people[1].id, localPath: "/nowhere/AMA_0001.JPG", relativePath: "2026.10.15/AMA_0001.JPG", added: earlier),
            QueueEntry(personId: book.people[1].id, localPath: "/nowhere/AMA_0002.JPG", relativePath: "2026.10.15/AMA_0002.JPG", added: earlier),
            gone,
        ])
        let model = AppModel(library: lib, peopleStore: peopleFile,
                             history: HistoryStoreFolder(folder: scratch.appendingPathComponent("gal-history")),
                             queue: queueFile, unplaced: UnplacedStoreFile(url: scratch.appendingPathComponent("gal-unplaced.json")),
                             secrets: NoSecrets(), thumbnails: MapThumbnails(folder: scratch.appendingPathComponent("gal-maps")),
                             exifTool: tool, nas: FakeNAS(root: scratch.appendingPathComponent("GAL-NAS")), notifier: RecordingNotifier(),
                             places: FakePlaces())
        if let key {
            model.useMaps(MapSource(light: "https://basemaps.cartocdn.com/rastertiles/light_nolabels/{z}/{x}/{y}@2x.png",
                                    dark: "https://basemaps.cartocdn.com/rastertiles/dark_nolabels/{z}/{x}/{y}@2x.png",
                                    credit: "© OpenStreetMap contributors, © CARTO", key: key))
        }
        await model.showLibrary()
        let david = model.book.people[0].id
        let source = scratchCard(cardRoot)
        model.choose(source)
        model.askingWhose = nil
        await model.read(source, for: david)
        model.aligning = false

        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        func draw<V: View>(_ name: String, _ view: V, _ width: CGFloat, _ height: CGFloat, wait: Int = 40) async {
            for dark in [false, true] {
                let look = NSAppearance(named: dark ? .darkAqua : .aqua)
                NSApp.appearance = look
                let window = NSWindow(contentRect: NSRect(x: -9000, y: -9000, width: width, height: height), styleMask: [.titled],
                                      backing: .buffered, defer: false)
                window.appearance = look
                let host = NSHostingView(rootView: view.environmentObject(model))
                window.contentView = host
                window.orderBack(nil)
                for _ in 0..<wait {
                    spin(0.04)
                    try? await Task.sleep(for: .milliseconds(40))
                }
                host.layoutSubtreeIfNeeded()
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
                }
                window.orderOut(nil)
            }
        }

        // Before saving: the card as read, and the map to line its photos up on.
        model.screen = .photos
        await draw("01-photos-read", RootView(), 1100, 720)
        await draw("02-alignment", AlignmentProbe(), 1100, 760, wait: key == nil ? 40 : 120)
        await draw("03-whose-card", SheetProbe(.whose), 520, 170)
        await draw("03b-name-place", SheetProbe(.namePlace), 460, 150)

        // Saved and sent.
        await model.savePhotos()
        await model.sendWaiting()
        await draw("04-photos-saved", RootView(), 1100, 720)
        await draw("04b-photos-smallest", RootView(), 940, 620)
        await draw("04c-photos-wide", RootView(), 1440, 860)
        await draw("04d-sidebar", SheetProbe(.sidebar), 210, 620)
        model.screen = .queue
        await draw("05-queue", RootView(), 1100, 720)
        await draw("05b-sending-cells", SendingCellsProbe(), 260, 140)
        model.screen = .history
        model.showHistory(david)
        await draw("06-history", RootView(), 1100, 720)

        // Settings, as filled in on David's Mac.
        model.nasAddress = "smb://10.0.10.10"
        model.nasBackupAddress = "smb://100.99.144.35"
        model.nasUser = "david"
        model.nasPassword = "not-a-real-one"
        model.nasLine = "Saved. Connected through 10.0.10.10."
        if let first = model.book.lenses.first { model.setFirmware("1.0.6", lens: first.id) }
        model.screen = .settings
        await draw("07-settings-top", RootView(), 1100, 720)
        await draw("08-settings-all", SheetProbe(.settings), 760, 2200)
        await draw("09-person", SheetProbe(.person), 560, 230)
        await draw("10-camera", SheetProbe(.camera), 600, 320)
        await draw("10b-lens", SheetProbe(.lens), 460, 150)
        await draw("12-offset-code", OffsetCodeView(), 1280, 800)
        await draw("12b-offset-code-small", OffsetCodeView(), 1000, 760)
        await draw("12c-offset-code-narrow", OffsetCodeView(), 700, 900)
        for (i, kind) in [SheetProbe.Kind.setupOwner, .setupFolders, .setupService, .setupNAS, .setupCards].enumerated() {
            await draw("11-setup-\(i + 1)", SheetProbe(kind), 680, 460)
        }

        // The Tracks window and the track viewer.
        await draw("11-tracks", TracksScreenProbe(), 900, 620, wait: key == nil ? 40 : 100)
        model.viewing = model.tracks.first?.id
        if let first = model.tracks.first?.id {
            await draw("12-viewer", TrackViewer(trackId: first), 1100, 820, wait: key == nil ? 40 : 150)
        }

        // Set time and date in camera: each camera's page, drawn tall enough to show it whole.
        CameraGuide.pictures = URL(fileURLWithPath: "Resources/CameraClock")
        for guide in CameraGuide.all {
            model.cameraGuide = guide.id
            await draw("13-clock-\(guide.id)", CameraClockProbe(), 720, 3400)
        }
        await draw("13-clock-window", CameraClockProbe(), 720, 620)
        await draw("14-status-busy", StatusProbe(), 560, 300)
        await draw("15-menu-bar-icon", WorkIconProbe(), 560, 300)
        NSApp.appearance = NSAppearance(named: .aqua)
        print("gallery: \(out.path)")
    }
}

extension SelfTest {
    /// The Download menu's disk image, made from a small stand-in app into a
    /// scratch folder, never David's Downloads: the app beside a shortcut to
    /// Applications, and a second one made over the first.
    static func download(_ scratch: URL) {
        let fm = FileManager.default
        let bundle = scratch.appendingPathComponent("Stand-in.app")
        let program = bundle.appendingPathComponent("Contents/MacOS/Geotag")
        try? fm.createDirectory(at: program.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "first".write(to: program, atomically: true, encoding: .utf8)
        let folder = scratch.appendingPathComponent("DOWNLOADS")
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)

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
        /// What the disk image holds: its top level, where the shortcut points, and the app's program.
        func look(_ image: URL) -> (inside: Set<String>, link: String?, program: String?)? {
            let mount = scratch.appendingPathComponent("download-look-\(UUID().uuidString.prefix(8))")
            try? fm.createDirectory(at: mount, withIntermediateDirectories: true)
            guard hdiutil(["attach", "-readonly", "-nobrowse", "-mountpoint", mount.path, image.path]) == 0 else { return nil }
            defer { _ = hdiutil(["detach", "-quiet", mount.path]) }
            return (Set((try? fm.contentsOfDirectory(atPath: mount.path)) ?? []),
                    try? fm.destinationOfSymbolicLink(atPath: mount.appendingPathComponent("Applications").path),
                    try? String(contentsOf: mount.appendingPathComponent("Geotag.app/Contents/MacOS/Geotag"), encoding: .utf8))
        }

        let first: URL?
        do { first = try Installer.save(app: bundle, version: "9.9.9", into: folder) } catch {
            check("download: made", false, error.localizedDescription)
            return
        }
        check("download: made, named by version and kind of Mac", first?.lastPathComponent == "Geotag 9.9.9 Apple silicon.dmg", "\(String(describing: first))")
        let a = first.flatMap(look)
        check("download: Geotag beside a shortcut to Applications", a?.inside == ["Geotag.app", "Applications"]
              && a?.link == "/Applications" && a?.program == "first", "\(String(describing: a))")

        try? "second".write(to: program, atomically: true, encoding: .utf8)
        let second = try? Installer.save(app: bundle, version: "9.9.9", into: folder)
        let names = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
        let b = second.flatMap(look)
        check("download: made again over the one already there", second == first && names == ["Geotag 9.9.9 Apple silicon.dmg"]
              && b?.program == "second", "\(names) \(String(describing: b?.program))")
        let left = ((try? fm.contentsOfDirectory(atPath: fm.temporaryDirectory.path)) ?? []).filter { $0.hasPrefix("geotag-download-") }
        check("download: no working folder left behind", left.isEmpty, "\(left)")

        // A program built for both kinds of Mac keeps only the one asked for,
        // still signed: the Mac's own ls is built for both.
        func cpu(_ url: URL) -> (magic: UInt32, cpu: UInt32)? {
            guard let d = try? Data(contentsOf: url), d.count >= 8 else { return nil }
            return (d[0..<4].reversed().reduce(0) { $0 << 8 | UInt32($1) }, d[4..<8].reversed().reduce(0) { $0 << 8 | UInt32($1) })
        }
        func verified(_ url: URL) -> Bool {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            p.arguments = ["--verify", "--strict", url.path]
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
            return p.terminationStatus == 0
        }
        for (chip, wanted) in [(Installer.Chip.intel, UInt32(0x0100_0007)), (.appleSilicon, 0x0100_000C)] {
            let both = folder.appendingPathComponent("both-\(chip.rawValue)")
            try? fm.removeItem(at: both)
            try? fm.copyItem(at: URL(fileURLWithPath: "/bin/ls"), to: both)
            let thrown = (try? Installer.only(chip, in: both)) == nil
            let after = cpu(both)
            check("download: \(chip.title) keeps only its own part, signed and runnable",
                  !thrown && after?.magic == 0xFEED_FACF && after?.cpu == wanted && verified(both)
                  && fm.isExecutableFile(atPath: both.path), "\(String(describing: after))")
        }
        let armOnly = folder.appendingPathComponent("arm-only")
        try? fm.removeItem(at: armOnly)
        try? fm.copyItem(at: URL(fileURLWithPath: "/bin/ls"), to: armOnly)
        try? Installer.only(.appleSilicon, in: armOnly)
        var refused = ""
        do { try Installer.only(.intel, in: armOnly) } catch { refused = error.localizedDescription }
        check("download: no Intel part, no Intel disk image", refused == "This Geotag has no Intel version.", refused)

        // The real thing: the installed Geotag packed exactly as the menu packs
        // it, into the scratch folder, and the copy inside checked.
        guard let real = ProcessInfo.processInfo.environment["GEOTAG_REAL_APP"] else { return }
        let realFolder = scratch.appendingPathComponent("REAL-DOWNLOAD")
        try? fm.createDirectory(at: realFolder, withIntermediateDirectories: true)
        for chip in Installer.Chip.allCases {
        guard let image = try? Installer.save(app: URL(fileURLWithPath: real), version: appVersion, chip: chip, into: realFolder) else {
            check("download: the installed Geotag packed for \(chip.title)", false)
            continue
        }
        let mount = scratch.appendingPathComponent("real-look-\(chip.rawValue)")
        try? fm.createDirectory(at: mount, withIntermediateDirectories: true)
        guard hdiutil(["attach", "-readonly", "-nobrowse", "-mountpoint", mount.path, image.path]) == 0 else {
            check("download: the installed Geotag's disk image opens", false)
            return
        }
        defer { _ = hdiutil(["detach", "-quiet", mount.path]) }
        let copy = mount.appendingPathComponent("Geotag.app")
        let version = NSDictionary(contentsOf: copy.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--verify", "--deep", "--strict", copy.path]
        sign.standardError = FileHandle.nullDevice
        try? sign.run()
        sign.waitUntilExit()
        let exiftool = fm.fileExists(atPath: copy.appendingPathComponent("Contents/Resources/ExifTool/exiftool").path)
        let size = ((try? fm.attributesOfItem(atPath: image.path))?[.size] as? NSNumber)?.intValue ?? 0
        let kind = cpu(copy.appendingPathComponent("Contents/MacOS/Geotag"))
        check("download: the installed Geotag packed whole for \(chip.title), and for it alone",
              version == appVersion && sign.terminationStatus == 0 && exiftool && kind?.magic == 0xFEED_FACF
              && kind?.cpu == (chip == .intel ? 0x0100_0007 : 0x0100_000C),
              "\(image.lastPathComponent), \(size / 1_000_000) MB, version \(version ?? "-"), signature \(sign.terminationStatus == 0 ? "valid" : "broken"), ExifTool \(exiftool)")
        }
    }
}

extension SelfTest {
    /// HEIF photos, as the R5 Mark II can shoot them (".HIF") and as the Mac
    /// writes them (".HEIC"), made from one of David's samples with the Mac's
    /// own converter, then read and saved with a location like any card photo.
    static func heif(_ scratch: URL, samples: URL) {
        let fm = FileManager.default
        let source = samples.appendingPathComponent("DAVL3660.JPG")
        guard fm.fileExists(atPath: source.path) else { print("skip  heif: no DAVL3660.JPG"); return }
        let card = scratch.appendingPathComponent("HEIF-CARD/DCIM/100CANON")
        try? fm.createDirectory(at: card, withIntermediateDirectories: true)
        var made: [URL] = []
        for name in ["DAVL9001.HEIC", "DAVL9002.HIF"] {
            let heic = card.appendingPathComponent(name.replacingOccurrences(of: ".HIF", with: ".HEIC") == name ? name : "converting.HEIC")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
            p.arguments = ["-s", "format", "heic", source.path, "--out", heic.path]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
            let target = card.appendingPathComponent(name)
            if heic != target { try? fm.moveItem(at: heic, to: target) }
            if fm.fileExists(atPath: target.path) { made.append(target) }
        }
        check("heif: two HEIF photos made from a sample", made.count == 2, "\(made.map(\.lastPathComponent))")
        let tool = ExifTool(script: URL(fileURLWithPath: "Vendor/ExifTool/exiftool"))
        let photos = (try? PhotoScanner(exifTool: tool).scan(made) { _ in }) ?? []
        check("heif: read like any photo, time, zone and camera", photos.count == 2
              && photos.allSatisfy { $0.taken == "2025:03:23 17:44:20" && $0.zone == "-05:00" && $0.model == "Canon EOS R5m2" },
              "\(photos.map { "\($0.fileName) \($0.taken ?? "-") \($0.zone ?? "-") \($0.model ?? "-")" })")
        let saver = Saver(exifTool: tool, folder: scratch.appendingPathComponent("HEIF-SAVED"))
        let moment = ISO8601DateFormatter().date(from: "2025-03-23T22:44:20Z")!
        for photo in photos {
            let result = saver.save(SaveItem(photo: photo, placement: .matched(Position(lat: -54.8091, lon: -68.2971, alt: 3, moment: moment, fromPoint: 0)),
                                             withoutLocation: false))
            var seen = "-"
            if let url = result.url, let src = CGImageSourceCreateWithURL(url as CFURL, nil),
               let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
               let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any] {
                seen = "\(gps[kCGImagePropertyGPSLatitude] ?? "-")\(gps[kCGImagePropertyGPSLatitudeRef] ?? "") \(gps[kCGImagePropertyGPSLongitude] ?? "-")\(gps[kCGImagePropertyGPSLongitudeRef] ?? "") \(gps[kCGImagePropertyGPSProcessingMethod] ?? "-")"
            }
            let ok: Bool
            if case .saved = result { ok = seen.hasPrefix("54.8091") && seen.contains("S") && seen.contains("W") && seen.contains("Geotag.app") } else { ok = false }
            check("heif: \(photo.fileName) saved with its location, checked", ok, "\(result) | the Mac reads \(seen)")
        }
    }
}

extension SelfTest {
    /// "Name place…" and the Gap column: a card from a walk in Ushuaia, then a
    /// long break, then photos off the track; some named by hand.
    @MainActor
    static func naming(_ scratch: URL) async {
        let fm = FileManager.default
        // The gaps alone.
        func shot(_ name: String, _ taken: String?) -> ScannedPhoto {
            ScannedPhoto(url: URL(fileURLWithPath: "/card/\(name)"), fileName: name, size: 1, taken: taken, subSeconds: nil, zone: nil, model: nil)
        }
        let list = [shot("A.JPG", "2026:12:05 09:00:00"), shot("B.JPG", "2026:12:05 09:10:00"), shot("C.JPG", nil),
                    shot("D.JPG", "2026:12:05 09:40:00"), shot("E.JPG", "2026:12:05 09:41:00"), shot("F.JPG", "2026:12:05 14:00:30")]
        let gaps = Breaks.find(list, minutes: 20)
        check("gaps: the photos after a break of 20 min or more, the one with no time passed over",
              gaps == ["/card/D.JPG": 1_800, "/card/F.JPG": 15_570], "\(gaps)")
        check("gaps: written plainly", PhotoTextProbe.gap(1_800) == "30 min" && PhotoTextProbe.gap(15_570) == "4 h 19 min"
              && PhotoTextProbe.gap(7_200) == "2 h" && PhotoTextProbe.gap(97_200) == "1 d 3 h")

        // Through the app model.
        let lib = TrackLibrary(store: TrackStoreFolder(folder: scratch.appendingPathComponent("name-lib")))
        let start = 1_792_162_800 // 2026-10-16 15:00 UTC, 12:00 in Ushuaia
        writeGPX(scratch.appendingPathComponent("name-walk.gpx"), start: start, count: 1800, name: "Ushuaia walk", lat: -54.812, lon: -68.33)
        _ = try? await lib.importFile(scratch.appendingPathComponent("name-walk.gpx"), role: .reader)
        let cardRoot = scratch.appendingPathComponent("NAME-CARD")
        let card = cardRoot.appendingPathComponent("DCIM/100CANON")
        try? fm.createDirectory(at: card, withIntermediateDirectories: true)
        for (i, time) in ["12:02:00", "12:05:00", "12:08:00", "13:10:00", "13:12:00"].enumerated() {
            writePhoto(card.appendingPathComponent(String(format: "IMG_%04d.JPG", i + 1)), model: "Canon EOS R5m2", zone: "-03:00",
                       taken: "2026:10:16 \(time)")
        }
        var book = PeopleBook.family()
        book.people[0].saveFolder = scratch.appendingPathComponent("NAME-SAVED").path
        try? fm.createDirectory(at: scratch.appendingPathComponent("NAME-SAVED"), withIntermediateDirectories: true)
        for i in 0..<book.cameras.count where book.cameras[i].model == "Canon EOS R5m2" { book.cameras[i].offsetSeconds = 0 }
        let peopleFile = PeopleStoreFile(url: scratch.appendingPathComponent("name-people.json"))
        try? peopleFile.save(book)
        let osm = FakePlaces()
        let model = AppModel(library: lib, peopleStore: peopleFile,
                             history: HistoryStoreFolder(folder: scratch.appendingPathComponent("name-history")),
                             queue: QueueStoreFile(url: scratch.appendingPathComponent("name-queue.json")),
                             unplaced: UnplacedStoreFile(url: scratch.appendingPathComponent("name-unplaced.json")),
                             secrets: NoSecrets(), thumbnails: MapThumbnails(folder: scratch.appendingPathComponent("name-maps")),
                             exifTool: ExifTool(script: URL(fileURLWithPath: "Vendor/ExifTool/exiftool")),
                             nas: FakeNAS(root: scratch.appendingPathComponent("NAME-NAS")), notifier: RecordingNotifier(), places: osm)
        await model.showLibrary()
        let source = scratchCard(cardRoot)
        model.choose(source)
        model.askingWhose = nil
        model.saveWhenReady = false
        await model.read(source, for: model.book.people[0].id)
        model.aligning = false
        for _ in 0..<100 where !model.placesSettled { try? await Task.sleep(for: .milliseconds(20)) }
        let rows = model.rows
        guard rows.count == 5 else { check("naming: the card read", false, "\(rows.count) rows"); return }
        check("naming: the walk's photos placed in Ushuaia, the two after it with no place",
              rows.map { model.placeName($0) ?? "-" } == ["Ushuaia", "Ushuaia", "Ushuaia", "-", "-"] && model.placesSettled,
              "\(rows.map { model.placeName($0) ?? "-" })")
        check("naming: the break before the photos after the walk", model.breaks == [rows[3].id: 3_720], "\(model.breaks)")

        // Named by hand: one photo from the walk, and the two after it.
        model.givePlace("  Port Lockroy ", to: [rows[2].id, rows[3].id, rows[4].id])
        check("naming: a typed name wins over OpenStreetMap's", rows.map { model.placeName($0) ?? "-" }
              == ["Ushuaia", "Ushuaia", "Port Lockroy", "Port Lockroy", "Port Lockroy"])
        await model.savePhotos()
        let folders = model.queueEntries.map(\.relativePath).sorted()
        check("naming: saved into a folder of the day and each photo's place", folders == [
            "2026.10.16 Port Lockroy/IMG_0003.jpg", "2026.10.16 Port Lockroy/IMG_0004.jpg", "2026.10.16 Port Lockroy/IMG_0005.jpg",
            "2026.10.16 Ushuaia/IMG_0001.jpg", "2026.10.16 Ushuaia/IMG_0002.jpg",
        ], "\(folders)")
        model.givePlace("", to: [rows[2].id])
        check("naming: an empty name gives OpenStreetMap's back", model.placeName(rows[2]) == "Ushuaia")
        model.setBreakMinutes(90)
        check("naming: a longer setting, no break marked", model.breaks.isEmpty, "\(model.breaks)")
        model.setBreakMinutes(20)
    }
}

extension SelfTest {
    /// Altitude above, at and below sea level, and none (10 November 2026).
    /// Geotag's own writer for the phone, on camera originals (CR3 and JPG
    /// straight from the card), with ExifTool and the Mac's own check as the
    /// judge: it reads what ExifTool reads, it finds room in every photo, and
    /// every copy it writes passes the Mac's check. The originals only read.
    static func nativeWriting(_ scratch: URL, originals: URL) {
        let fm = FileManager.default
        let tool = ExifTool(script: URL(fileURLWithPath: "Vendor/ExifTool/exiftool"))
        let files = PhotoScanner.files(in: originals).filter { NativeMetadata.kind($0) != nil }
        let cr3 = files.filter { $0.pathExtension.lowercased() == "cr3" }, jpg = files.filter { $0.pathExtension.lowercased() != "cr3" }
        check("native: originals found", !cr3.isEmpty && !jpg.isEmpty, "\(cr3.count) CR3, \(jpg.count) JPG")
        let hashes = Dictionary(uniqueKeysWithValues: files.map { ($0.path, try? fm.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date) })

        // Reading: the same as ExifTool, for every photo.
        let byTool = (try? PhotoScanner(exifTool: tool).scan(files) { _ in }) ?? []
        let mine = NativeMetadata.scan(files) { _ in }
        var differ: [String] = []
        for (a, b) in zip(byTool, mine) {
            var x = a, y = b
            x.firmware = nil; y.firmware = nil // ExifTool reads it for the newest photo only
            if let p = x.ownLat, let q = y.ownLat, abs(p - q) < 1e-7 { y.ownLat = p }
            if let p = x.ownLon, let q = y.ownLon, abs(p - q) < 1e-7 { y.ownLon = p }
            if x != y { differ.append("\(a.fileName): \(a) vs \(b)") }
        }
        check("native: reads what ExifTool reads, on every photo", byTool.count == files.count && differ.isEmpty,
              "\(differ.count) differ \(differ.prefix(2))")
        let firmware = Set(mine.compactMap(\.firmware)), toolFirmware = Set(byTool.compactMap(\.firmware))
        check("native: reads the camera's firmware", !firmware.isEmpty && toolFirmware.isSubset(of: firmware), "\(firmware) \(toolFirmware)")

        // Room for the location in every photo.
        let spot = Position(lat: -54.8019123, lon: -68.3029456, alt: -3.2, moment: Date(timeIntervalSince1970: 1_794_316_131.456), fromPoint: 0)
        var refused: [String] = []
        for url in files {
            do { _ = try NativeMetadata.patches(for: url, position: spot, shift: 0) } catch { refused.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        check("native: finds room for the location in every photo", refused.isEmpty, "\(refused.count) \(refused.prefix(3))")

        // Writing, judged by the Mac's own check.
        let judge = Saver(exifTool: tool, folder: scratch)
        let alts: [Double?] = [123.45, 0, -0.1, -0.5, -12.3, nil]
        let picks = Array(cr3.prefix(6)) + Array(jpg.prefix(6))
        let photos = NativeMetadata.scan(picks) { _ in }
        for (i, photo) in photos.enumerated() {
            let alt = alts[i % alts.count]
            let where_ = Position(lat: i % 2 == 0 ? -54.8019123 : 38.7128, lon: i % 3 == 0 ? -68.3029456 : 9.1395, alt: alt,
                                  moment: Date(timeIntervalSince1970: 1_794_316_131.996 + Double(i) * 3600), fromPoint: 0)
            let saver = Saver(engine: .native, folder: scratch.appendingPathComponent("NATIVE-\(i)"))
            let result = saver.save(SaveItem(photo: photo, placement: .matched(where_), withoutLocation: false))
            let label = "native: \(photo.fileName) at \(alt.map { "\($0) m" } ?? "no altitude")"
            guard case .saved(let url) = result else { check(label + " saved", false, "\(result)"); continue }
            let size = { (u: URL) in (try? fm.attributesOfItem(atPath: u.path)[.size] as? NSNumber)?.intValue }
            let verdict = judge.check(copy: url, original: photo.url, position: where_)
            check(label + ", passes the Mac's check, same size", verdict == nil && size(url) == size(photo.url), verdict ?? "")
            // ExifTool finds nothing wrong in it.
            let warn = (try? tool.run(["-q", "-q", "-validate", "-warning", "-a", "-s3", url.path])).map { String(decoding: $0, as: UTF8.self) } ?? "?"
            let warnBefore = (try? tool.run(["-q", "-q", "-validate", "-warning", "-a", "-s3", photo.url.path])).map { String(decoding: $0, as: UTF8.self) } ?? "?"
            // Geotag's note is not one of the four words the standard lists;
            // the Mac's own copies carry the same warning.
            func lines(_ text: String) -> Set<String> {
                Set(text.split(separator: "\n").map(String.init).filter {
                    $0 != "OK" && !$0.hasSuffix(" Warning") && !$0.hasSuffix(" Warnings") && !$0.contains("GPSProcessingMethod")
                })
            }
            check(label + ", no new warnings", lines(warn).isSubset(of: lines(warnBefore)), warn)
        }

        // The dates corrected along with the location, and with none.
        let shift = 78_000_000
        for (n, url) in [cr3.first, jpg.first].compactMap({ $0 }).enumerated() {
            guard let photo = NativeMetadata.scan([url], progress: { _ in }).first else { continue }
            for (m, position) in [spot, nil].enumerated() {
                let saver = Saver(engine: .native, folder: scratch.appendingPathComponent("NATIVE-SHIFT-\(n)-\(m)"))
                let result = saver.save(SaveItem(photo: photo, placement: .matched(spot), withoutLocation: position == nil, shift: shift))
                guard case .saved(let copy) = result else { check("native: dates corrected, \(photo.fileName)", false, "\(result)"); continue }
                let verdict = judge.check(copy: copy, original: photo.url, position: position, shift: shift)
                let read = (try? tool.read(["QuickTime:CreateDate", "DateTimeOriginal"], from: copy)) ?? [:]
                check("native: dates corrected \(position == nil ? "without" : "with") a location, \(photo.fileName), passes the Mac's check",
                      verdict == nil, verdict ?? "\(read)")
            }
        }

        // Saved without a location, placed later on the phone.
        if let url = cr3.last, let photo = NativeMetadata.scan([url], progress: { _ in }).first {
            let saver = Saver(engine: .native, folder: scratch.appendingPathComponent("NATIVE-LATER"))
            if case .saved(let copy) = saver.save(SaveItem(photo: photo, placement: .review(.noTrack), withoutLocation: true)) {
                let unchanged = Saver.sha256(copy) == Saver.sha256(url)
                let problem = saver.addLocation(to: copy, spot)
                let verdict = judge.check(copy: copy, original: url, position: spot)
                check("native: a copy saved without a location gets one later and passes the Mac's check",
                      unchanged && problem == nil && verdict == nil, "\(problem ?? "") \(verdict ?? "")")
            } else {
                check("native: saved without a location", false)
            }
        }

        // A copy ExifTool already rewrote has no room left: refused, nothing left behind.
        if let url = jpg.dropFirst(7).first, let photo = NativeMetadata.scan([url], progress: { _ in }).first {
            let toolCopy = scratch.appendingPathComponent("NATIVE-REWRITTEN")
            if case .saved(let rewritten) = Saver(exifTool: tool, folder: toolCopy).save(SaveItem(photo: photo, placement: .matched(spot), withoutLocation: false)),
               let again = NativeMetadata.scan([rewritten], progress: { _ in }).first {
                let folder = scratch.appendingPathComponent("NATIVE-ON-REWRITTEN")
                let result = Saver(engine: .native, folder: folder).save(SaveItem(photo: again, placement: .matched(spot), withoutLocation: false))
                var ok = false
                switch result {
                case .saved(let u): ok = judge.check(copy: u, original: rewritten, position: spot) == nil
                case .failed: ok = ((try? fm.contentsOfDirectory(atPath: folder.appendingPathComponent(Saver.folderName(again, place: nil)).path)) ?? []).isEmpty
                default: ok = false
                }
                check("native: a file ExifTool rewrote is written correctly or refused cleanly", ok, "\(result)")
                // The same photo saved by either writer counts as the same photo.
                if case .saved(let mineCopy) = Saver(engine: .native, folder: scratch.appendingPathComponent("NATIVE-SAME")).save(
                    SaveItem(photo: photo, placement: .matched(spot), withoutLocation: false)) {
                    check("native: the same photo saved by ExifTool and by the phone is the same photo",
                          NativeMetadata.samePhoto(mineCopy, url) && NativeMetadata.sameLocation(mineCopy, rewritten)
                          && !NativeMetadata.sameLocation(mineCopy, url))
                }
            }
        }

        let after = Dictionary(uniqueKeysWithValues: files.map { ($0.path, try? fm.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date) })
        check("native: the originals were not changed", after == hashes)
    }

    static func altitude(_ scratch: URL, samples: URL) {
        let fm = FileManager.default
        let tool = ExifTool(script: URL(fileURLWithPath: "Vendor/ExifTool/exiftool"))
        // Altitude above, at, below sea level and none, on JPEG and CR3, read
        // back with its sign; the card file never changes.
        let altTo = scratch.appendingPathComponent("ALT-SAVED")
        let altFiles = ["390A5795.JPG", "DAVL0311.CR3"].map { samples.appendingPathComponent($0) }.filter { fm.fileExists(atPath: $0.path) }
        check("altitude: JPEG and CR3 samples present", altFiles.count == 2)
        for photo in (try? PhotoScanner(exifTool: tool).scan(altFiles) { _ in }) ?? [] {
            let cardHash = Saver.sha256(photo.url)
            for (n, alt) in ([123.45, 0, -0.1, -0.5, -12.3, nil] as [Double?]).enumerated() {
                let altSaver = Saver(exifTool: tool, folder: altTo.appendingPathComponent("\(n)"))
                let spot = Position(lat: 39.6, lon: -9.07, alt: alt, moment: Date(timeIntervalSince1970: 1_794_316_131), fromPoint: 0)
                let result = altSaver.save(SaveItem(photo: photo, placement: .matched(spot), withoutLocation: false))
                let label = "altitude: \(photo.fileName) at \(alt.map { "\($0) m" } ?? "none")"
                guard case .saved(let url) = result else { check(label, false, "\(result)"); continue }
                let data = try? tool.run(["-j", "-n", "-G1", "-GPS:GPSAltitude", "-GPS:GPSAltitudeRef", url.path])
                let read = ((data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [[String: Any]])?.first) ?? [:]
                let a = (read["GPS:GPSAltitude"] as? NSNumber)?.doubleValue
                let ref = (read["GPS:GPSAltitudeRef"] as? NSNumber)?.intValue
                let back = a.map { ref == 1 ? -$0 : $0 }
                let ok = alt.map { w in back.map { abs($0 - w) < 0.005 } ?? false && ref == (w < 0 ? 1 : 0) } ?? (a == nil && ref == nil)
                check(label + ", read back with its sign, card unchanged", ok && Saver.sha256(photo.url) == cardHash,
                      "\(back.map { "\($0)" } ?? "none") ref \(ref.map { "\($0)" } ?? "none")")
            }
        }
    }

    /// A camera whose clock is far out (David, 18 October 2026): the offset
    /// set from the start of the track its photos belong to, the copies'
    /// dates corrected on every kind of file, and a photo placed later not
    /// corrected twice.
    @MainActor
    static func clocks(_ scratch: URL, samples: URL, raws: URL?) async {
        let fm = FileManager.default
        let tool = ExifTool(script: URL(fileURLWithPath: "Vendor/ExifTool/exiftool"))
        let iso = ISO8601DateFormatter()

        // The offset that puts the first photo at a track's start.
        let r7 = Camera(personId: UUID(), model: "Canon EOS R7", zone: .fromPhoto)
        let shot = ScannedPhoto(url: URL(fileURLWithPath: "/x.JPG"), fileName: "x.JPG", size: 1, taken: "2024:05:12 13:44:00",
                                subSeconds: nil, zone: "-03:00", model: "Canon EOS R7")
        let trackStart = iso.date(from: "2026-10-17T11:56:00Z")! // 08:56 in Ushuaia
        let offset = Moments.offset(placing: shot, camera: r7, at: trackStart)
        var set = r7
        set.offsetSeconds = offset
        let lands = try? Moments.moment(shot, camera: set).get()
        let expected = Int(iso.date(from: "2024-05-12T16:44:00Z")!.timeIntervalSince(trackStart))
        check("clocks: a track's start gives the camera's offset, its first photo lands there", offset == expected && lands == trackStart,
              "\(String(describing: offset)) \(String(describing: lands))")

        // Saving with the dates corrected, on every kind of file.
        let shift = 78_000_000 // about two and a half years later
        var files = ["390A5795.JPG", "DAVL0311.CR3"].map { samples.appendingPathComponent($0) }
        if let raws { files += ["DSCN0014.NRW", "IMG_0126.CR2"].map { raws.appendingPathComponent($0) } }
        files = files.filter { fm.fileExists(atPath: $0.path) }
        let saveTo = scratch.appendingPathComponent("CLOCK-SAVED")
        let saver = Saver(exifTool: tool, folder: saveTo)
        let photos = (try? PhotoScanner(exifTool: tool).scan(files) { _ in }) ?? []
        for (i, photo) in photos.enumerated() {
            guard let clock = Moments.clockReading(photo) else { continue }
            let spot = Position(lat: -54.8, lon: -68.3, alt: nil, moment: clock.addingTimeInterval(Double(shift)), fromPoint: 0)
            // Every other one saved without a location: its dates are corrected all the same.
            let item = SaveItem(photo: photo, placement: i % 2 == 0 ? .matched(spot) : .review(.noTrack), withoutLocation: i % 2 == 1,
                                shift: shift)
            let result = saver.save(item)
            guard case .saved(let url) = result else {
                check("clocks: \(photo.fileName) saved with its dates corrected", false, "\(result)")
                continue
            }
            let read = (try? tool.read(["DateTimeOriginal"], from: url))?["DateTimeOriginal"]
            let wanted = Saver.shiftedProbe(photo.taken ?? "", by: shift)
            let cardDate = (try? fm.attributesOfItem(atPath: photo.url.path))?[.modificationDate] as? Date
            let copyDate = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            check("clocks: \(photo.fileName) saved with its dates corrected, in the corrected day's folder",
                  read == wanted && url.deletingLastPathComponent().lastPathComponent == Saver.dayFolder(photo, shift: shift)
                  && abs((cardDate?.addingTimeInterval(Double(shift)).timeIntervalSince1970 ?? 0) - (copyDate?.timeIntervalSince1970 ?? 1)) < 0.001,
                  "\(read ?? "-") wanted \(wanted ?? "-") in \(url.deletingLastPathComponent().lastPathComponent)")
        }

        // Through the app model: the offset set as "Use this offset" sets it,
        // the Photos page says so, and a photo placed later is not moved twice.
        let lib = TrackLibrary(store: TrackStoreFolder(folder: scratch.appendingPathComponent("clock-lib")))
        let walk = 1_792_162_800 // 2026-10-16 15:00 UTC, 12:00 in Ushuaia
        writeGPX(scratch.appendingPathComponent("clock-walk.gpx"), start: walk, count: 1800, name: "Ushuaia walk", lat: -54.812, lon: -68.33)
        _ = try? await lib.importFile(scratch.appendingPathComponent("clock-walk.gpx"), role: .reader)
        let cardRoot = scratch.appendingPathComponent("CLOCK-CARD")
        let card = cardRoot.appendingPathComponent("DCIM/100CANON")
        try? fm.createDirectory(at: card, withIntermediateDirectories: true)
        // The camera's clock says 12 May 2024; the walk was on 16 October 2026.
        for (i, time) in ["13:44:00", "13:50:00", "13:56:00", "16:30:00"].enumerated() {
            writePhoto(card.appendingPathComponent(String(format: "IMG_%04d.JPG", i + 1)), model: "Canon EOS R5m2", zone: "-03:00",
                       taken: "2024:05:12 \(time)")
        }
        var book = PeopleBook.family()
        book.people[0].saveFolder = scratch.appendingPathComponent("CLOCK-MODEL-SAVED").path
        try? fm.createDirectory(at: scratch.appendingPathComponent("CLOCK-MODEL-SAVED"), withIntermediateDirectories: true)
        let peopleFile = PeopleStoreFile(url: scratch.appendingPathComponent("clock-people.json"))
        try? peopleFile.save(book)
        let unplacedFile = UnplacedStoreFile(url: scratch.appendingPathComponent("clock-unplaced.json"))
        let model = AppModel(library: lib, peopleStore: peopleFile,
                             history: HistoryStoreFolder(folder: scratch.appendingPathComponent("clock-history")),
                             queue: QueueStoreFile(url: scratch.appendingPathComponent("clock-queue.json")), unplaced: unplacedFile,
                             secrets: NoSecrets(), thumbnails: MapThumbnails(folder: scratch.appendingPathComponent("clock-maps")),
                             exifTool: tool, nas: FakeNAS(root: scratch.appendingPathComponent("CLOCK-NAS")), notifier: RecordingNotifier(),
                             places: FakePlaces())
        await model.showLibrary()
        let source = scratchCard(cardRoot)
        model.choose(source)
        model.askingWhose = nil
        await model.read(source, for: model.book.people[0].id)
        model.aligning = false
        check("clocks: no photo falls on a track by the camera's own clock", model.rows.allSatisfy { $0.placement == .review(.offsetNotSet) },
              "\(model.rows.map { String(describing: $0.placement) })")
        // "Use this offset" with the walk chosen: its first photo at the walk's start.
        guard var camera = model.book.camera(personId: model.book.people[0].id, model: "Canon EOS R5m2"),
              let first = model.rows.first?.photo,
              let fromWalk = Moments.offset(placing: first, camera: camera, at: Date(timeIntervalSince1970: TimeInterval(walk))) else {
            check("clocks: the camera found", false)
            return
        }
        camera.offsetSeconds = fromWalk
        model.save(camera)
        let placed = model.rows.prefix(3).allSatisfy { if case .matched = $0.placement { return true } else { return false } }
        check("clocks: the photos now fall on the walk, the last one after it", placed && model.rows[3].placement == .review(.noTrack),
              "\(model.rows.map { String(describing: $0.placement) })")
        check("clocks: the Photos page says the clock is out, and where to set it",
              PhotoTextProbe.clockNote(model.wrongClocks).hasPrefix("The Canon EOS R5m2's clock is 886 d 22 h 16 min behind.")
              && PhotoTextProbe.clockNote(model.wrongClocks).hasSuffix("Set time and date in camera, in the menu bar."),
              PhotoTextProbe.clockNote(model.wrongClocks))
        await model.savePhotos()
        let saved = model.queueEntries.map(\.relativePath).sorted()
        check("clocks: the copies in the corrected day's folders", saved == [
            "2026.10.16 Ushuaia/IMG_0001.jpg", "2026.10.16 Ushuaia/IMG_0002.jpg", "2026.10.16 Ushuaia/IMG_0003.jpg", "2026.10.16/IMG_0004.jpg",
        ], "\(saved)")
        let lateCopy = scratch.appendingPathComponent("CLOCK-MODEL-SAVED/2026.10.16/IMG_0004.jpg")
        let corrected = (try? tool.read(["DateTimeOriginal"], from: lateCopy))?["DateTimeOriginal"]
        check("clocks: a photo saved without a location has its date corrected too", corrected == "2026:10:16 14:46:00",
              corrected ?? "-")
        // A second walk turns up covering it: placed later, its date stays corrected once.
        writeGPX(scratch.appendingPathComponent("clock-walk2.gpx"), start: walk + 9_000, count: 1800, name: "Afternoon walk", lat: -54.80, lon: -68.30)
        _ = try? await lib.importFile(scratch.appendingPathComponent("clock-walk2.gpx"), role: .reader)
        await model.showLibrary()
        await model.placeLater()
        let after = (try? tool.read(["DateTimeOriginal", "GPSLatitude"], from: lateCopy)) ?? [:]
        check("clocks: placed later, its date corrected once, not twice", after["DateTimeOriginal"] == "2026:10:16 14:46:00"
              && after["GPSLatitude"] != nil && ((try? unplacedFile.load()) ?? []).isEmpty, "\(after)")
    }
}

extension SelfTest {
    /// The cameras' software: read from every kind of photo, the newest kept
    /// per camera with its day, and a page for each model's latest.
    @MainActor
    static func firmware(_ scratch: URL, samples: URL, raws: URL?) async {
        let fm = FileManager.default
        check("firmware: the version out of what the cameras write",
              Firmware.version(["Firmware Version 1.7.1"]) == "1.7.1" && Firmware.version([nil, "1.0.2"]) == "1.0.2"
              && Firmware.version(["COOLPIX P950   V1.0"]) == "1.0" && Firmware.version([nil, "Canon"]) == nil)
        check("firmware: newer by number, part by part", Firmware.isNewer("1.10.0", than: "1.9.9") && Firmware.isNewer("1.1.1", than: "1.0.3")
              && !Firmware.isNewer("1.0", than: "1.0.0") && !Firmware.isNewer("1.0.3", than: "1.1.1"))
        check("firmware: a download page for each of the family's models", ["Canon EOS R5m2", "Canon EOS R7", "COOLPIX P950",
              "Canon EOS REBEL T3i", "Canon EOS 600D"].allSatisfy { Firmware.page(forModel: $0) != nil } && Firmware.page(forModel: "Leica Q3") == nil)

        let tool = ExifTool(script: URL(fileURLWithPath: "Vendor/ExifTool/exiftool"))
        var files = ["390A5795.JPG", "DAVL3660.JPG", "DAVL0311.CR3"].map { samples.appendingPathComponent($0) }
        if let raws { files += ["DSCN0014.NRW", "IMG_0126.CR2", "_MG_2587.CR2"].map { raws.appendingPathComponent($0) } }
        files = files.filter { fm.fileExists(atPath: $0.path) }
        let scanner = PhotoScanner(exifTool: tool)
        let read = ((try? scanner.scan(files) { _ in }) ?? []).map { "\($0.fileName) \($0.firmware ?? "-")" }
        // Only the newest photo of each model is asked: the older R5 Mark II JPEG is not.
        let wanted = ["390A5795.JPG 1.7.1", "DAVL3660.JPG -", "DAVL0311.CR3 1.1.1", "DSCN0014.NRW 1.0", "IMG_0126.CR2 1.0.2", "_MG_2587.CR2 1.0.1"]
        check("firmware: read from JPEG, CR3, NRW and CR2 alike, newest photo of each camera only",
              read == Array(wanted.prefix(read.count)) && read.count == files.count, "\(read)")
        let alone = (try? scanner.scan([samples.appendingPathComponent("DAVL3660.JPG")]) { _ in })?.first?.firmware
        check("firmware: an R5 Mark II JPEG read on its own", alone == "1.0.1", alone ?? "-")

        // A card with photos from before and after an update: the newer version kept.
        let cardRoot = scratch.appendingPathComponent("FIRMWARE-CARD")
        let card = cardRoot.appendingPathComponent("DCIM/100CANON")
        try? fm.createDirectory(at: card, withIntermediateDirectories: true)
        for name in ["DAVL3660.JPG", "DAVL0311.CR3"] { try? fm.copyItem(at: samples.appendingPathComponent(name), to: card.appendingPathComponent(name)) }
        let peopleFile = PeopleStoreFile(url: scratch.appendingPathComponent("firmware-people.json"))
        let model = AppModel(library: TrackLibrary(store: TrackStoreFolder(folder: scratch.appendingPathComponent("firmware-lib"))),
                             peopleStore: peopleFile, history: HistoryStoreFolder(folder: scratch.appendingPathComponent("firmware-history")),
                             queue: QueueStoreFile(url: scratch.appendingPathComponent("firmware-queue.json")),
                             unplaced: UnplacedStoreFile(url: scratch.appendingPathComponent("firmware-unplaced.json")),
                             secrets: NoSecrets(), thumbnails: MapThumbnails(folder: scratch.appendingPathComponent("firmware-maps")),
                             exifTool: tool, nas: FakeNAS(root: scratch.appendingPathComponent("FIRMWARE-NAS")), notifier: RecordingNotifier(),
                             places: FakePlaces())
        let source = scratchCard(cardRoot)
        model.choose(source)
        model.askingWhose = nil
        await model.read(source, for: model.book.people[0].id)
        let camera = model.book.camera(personId: model.book.people[0].id, model: "Canon EOS R5m2")
        let seen = camera?.firmwareSeen.map { Moments.reading.string(from: $0) }
        let kept = (try? peopleFile.load())?.flatMap { $0.camera(personId: model.book.people[0].id, model: "Canon EOS R5m2") }
        check("firmware: the newest version on the card kept, with its photo's day", camera?.firmware == "1.1.1"
              && seen?.hasPrefix("2026:01:01") == true && kept?.firmware == "1.1.1",
              "\(camera?.firmware ?? "-") \(seen ?? "-")")

        let olderRoot = scratch.appendingPathComponent("FIRMWARE-OLD")
        let older = olderRoot.appendingPathComponent("DCIM/100CANON")
        try? fm.createDirectory(at: older, withIntermediateDirectories: true)
        try? fm.copyItem(at: samples.appendingPathComponent("DAVL3660.JPG"), to: older.appendingPathComponent("DAVL3660.JPG"))
        let oldCard = scratchCard(olderRoot)
        model.choose(oldCard)
        model.askingWhose = nil
        await model.read(oldCard, for: model.book.people[0].id)
        let after = model.book.camera(personId: model.book.people[0].id, model: "Canon EOS R5m2")
        check("firmware: a card of older photos does not take the version back", after?.firmware == "1.1.1"
              && after?.firmwareSeen == camera?.firmwareSeen, after?.firmware ?? "-")
    }
}

extension SelfTest {
    /// The lenses the photos name: read with the rest of each photo, an
    /// extender left off, one per lens with the camera and day of its latest
    /// photo, and Canon's page for each.
    @MainActor
    static func lenses(_ scratch: URL, samples: URL, raws: URL?) async {
        let fm = FileManager.default
        check("lenses: the lens without its extender", Lenses.name("RF600mm F4 L IS USM +RF1.4x") == "RF600mm F4 L IS USM"
              && Lenses.name("EF100-400mm f/4.5-5.6L IS II USM +1.4x III") == "EF100-400mm f/4.5-5.6L IS II USM"
              && Lenses.name(" RF70-200mm F2.8 L IS USM Z ") == "RF70-200mm F2.8 L IS USM Z"
              && Lenses.name(nil) == nil && Lenses.name("") == nil && Lenses.name("----") == nil)
        check("lenses: a serial of zeros is none, a real one keeps its leading zeros",
              Lenses.serial("0000000000") == nil && Lenses.serial("0000131373") == "0000131373"
              && Lenses.serial(" 1490000207 ") == "1490000207" && Lenses.serial(nil) == nil && Lenses.serial("") == nil)
        // The pages checked on Canon U.S.A.'s site, 18 October 2026.
        let pages = [("RF70-200mm F2.8 L IS USM Z", "rf70-200mm-f2-8-l-is-usm-z"), ("RF70-200mm F2.8 L IS USM", "rf70-200mm-f2-8-l-is-usm"),
                     ("RF600mm F4 L IS USM", "rf600mm-f4-l-is-usm"), ("RF24-105mm F4 L IS USM", "rf24-105mm-f4-l-is-usm"),
                     ("RF-S18-150mm F3.5-6.3 IS STM", "rf-s18-150mm-f3-5-6-3-is-stm"), ("EF600mm f/4L IS III USM", "ef-600mm-f-4l-is-iii-usm"),
                     ("EF70-200mm f/2.8L IS III USM", "ef-70-200mm-f-2-8l-is-iii-usm"), ("EF-S18-55mm f/3.5-5.6 IS II", "ef-s-18-55mm-f-3-5-5-6-is-ii")]
        let wrong = pages.filter { Lenses.page(forLens: $0.0)?.absoluteString != "https://www.usa.canon.com/support/p/\($0.1)" }.map(\.0)
        check("lenses: Canon's page for each lens, named as Canon names its pages", wrong.isEmpty
              && Lenses.page(forLens: "TAMRON SP 90mm F/2.8 Di VC USD MACRO1:1 F017") == nil, "\(wrong)")

        // Read with everything else: JPEG, CR3 and CR2; the P950's own lens is never named.
        let tool = ExifTool(script: URL(fileURLWithPath: "Vendor/ExifTool/exiftool"))
        var files = ["390A5795.JPG", "DAVL2909.JPG", "DAVL0311.CR3"].map { samples.appendingPathComponent($0) }
        if let raws { files += ["IMG_0126.CR2", "_MG_2587.CR2", "DSCN0014.NRW"].map { raws.appendingPathComponent($0) } }
        files = files.filter { fm.fileExists(atPath: $0.path) }
        let read = ((try? PhotoScanner(exifTool: tool).scan(files) { _ in }) ?? [])
            .map { "\($0.fileName) \(Lenses.name($0.lens) ?? "-") \(Lenses.serial($0.lensSerial) ?? "-")" }
        let wanted = ["390A5795.JPG RF70-200mm F2.8 L IS USM Z 1490000207", "DAVL2909.JPG RF600mm F4 L IS USM 2510000103",
                      "DAVL0311.CR3 RF70-200mm F2.8 L IS USM Z 1490000207", "IMG_0126.CR2 EF-S18-55mm f/3.5-5.6 IS II 0000131373",
                      "_MG_2587.CR2 TAMRON SP 90mm F/2.8 Di VC USD MACRO1:1 F017 -", "DSCN0014.NRW - -"]
        check("lenses: read from JPEG, CR3 and CR2 with the rest of each photo",
              read == Array(wanted.prefix(read.count)) && read.count == files.count, "\(read)")

        // Kept per lens, from its latest photo.
        let david = UUID(), amanda = UUID()
        func photo(_ name: String, _ camera: String, _ lens: String?, _ serial: String?, _ taken: String?) -> ScannedPhoto {
            ScannedPhoto(url: URL(fileURLWithPath: "/nowhere/\(name)"), fileName: name, size: 1, taken: taken, subSeconds: nil,
                         zone: nil, model: camera, lens: lens, lensSerial: serial)
        }
        func show(_ lenses: [Lens]) -> [String] {
            lenses.map { "\($0.model) \($0.serial ?? "-") \($0.camera) \($0.seen.map { Moments.reading.string(from: $0) } ?? "-")" }
        }
        var known = Lenses.noting([
            photo("A.JPG", "Canon EOS R5m2", "RF70-200mm F2.8 L IS USM Z", "1490000207", "2025:03:23 17:44:20"),
            photo("B.JPG", "Canon EOS R5m2", "RF600mm F4 L IS USM", "2510000103", "2025:09:06 10:00:36"),
            photo("C.CR3", "Canon EOS R5m2", "RF70-200mm F2.8 L IS USM Z", "1490000207", "2026:01:01 10:30:47"),
            photo("D.JPG", "Canon EOS R5m2", "RF600mm F4 L IS USM +RF1.4x", "2510000103", "2025:09:06 11:00:00"),
            photo("E.JPG", "Canon EOS R5m2", nil, nil, "2026:01:02 09:00:00"),
        ], personId: david, into: [])
        check("lenses: one per lens, with or without an extender, from its latest photo", show(known) == [
            "RF70-200mm F2.8 L IS USM Z 1490000207 Canon EOS R5m2 2026:01:01 10:30:47",
            "RF600mm F4 L IS USM 2510000103 Canon EOS R5m2 2025:09:06 11:00:00"], "\(show(known))")
        let older = Lenses.noting([photo("F.JPG", "Canon EOS R7", "RF70-200mm F2.8 L IS USM Z", "1490000207", "2025:09:08 12:51:41")],
                                  personId: david, into: known)
        check("lenses: a card of older photos does not take a lens back", older == known, "\(show(older))")
        known = Lenses.noting([photo("G.JPG", "Canon EOS R5m2", "RF70-200mm F2.8 L IS USM Z +RF2x", "1490000207", "2026:10:18 09:00:00"),
                               photo("H.CR2", "Canon EOS REBEL T3i", "TAMRON SP 90mm F/2.8 Di VC USD MACRO1:1 F017", "0000000000", nil)],
                              personId: amanda, into: known)
        check("lenses: a later photo moves a lens to its camera and person; one with no serial or date is listed too",
              show(known) == ["RF70-200mm F2.8 L IS USM Z 1490000207 Canon EOS R5m2 2026:10:18 09:00:00",
                              "RF600mm F4 L IS USM 2510000103 Canon EOS R5m2 2025:09:06 11:00:00",
                              "TAMRON SP 90mm F/2.8 Di VC USD MACRO1:1 F017 - Canon EOS REBEL T3i -"]
              && known.map(\.personId) == [amanda, david, amanda], "\(show(known))")

        let saved = When.current
        When.current = When(order: .yearMonthDay, clock24: true)
        let line = LensTextProbe.line(known[0], owner: "Amanda"), bare = LensTextProbe.line(known[2], owner: nil)
        When.current = saved
        check("lenses: the Settings line", line == "Amanda · Canon EOS R5m2 · Serial 1490000207 · Last seen 2026-10-18"
              && bare == "Canon EOS REBEL T3i", "\(line) / \(bare)")

        let old = #"{"cameras":[],"people":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"David"}]}"#
        let decoded = try? JSONDecoder().decode(PeopleBook.self, from: Data(old.utf8))
        check("lenses: a people file from before lenses still reads", decoded?.people.count == 1 && decoded?.lenses.isEmpty == true)

        // A card read: its lenses kept on this Mac, and the same card read again changes nothing.
        let cardRoot = scratch.appendingPathComponent("LENS-CARD")
        let card = cardRoot.appendingPathComponent("DCIM/100CANON")
        try? fm.createDirectory(at: card, withIntermediateDirectories: true)
        for name in ["DAVL3660.JPG", "DAVL2909.JPG", "DAVL0311.CR3"] {
            try? fm.copyItem(at: samples.appendingPathComponent(name), to: card.appendingPathComponent(name))
        }
        let peopleFile = PeopleStoreFile(url: scratch.appendingPathComponent("lens-people.json"))
        let model = AppModel(library: TrackLibrary(store: TrackStoreFolder(folder: scratch.appendingPathComponent("lens-lib"))),
                             peopleStore: peopleFile, history: HistoryStoreFolder(folder: scratch.appendingPathComponent("lens-history")),
                             queue: QueueStoreFile(url: scratch.appendingPathComponent("lens-queue.json")),
                             unplaced: UnplacedStoreFile(url: scratch.appendingPathComponent("lens-unplaced.json")),
                             secrets: NoSecrets(), thumbnails: MapThumbnails(folder: scratch.appendingPathComponent("lens-maps")),
                             exifTool: tool, nas: FakeNAS(root: scratch.appendingPathComponent("LENS-NAS")), notifier: RecordingNotifier(),
                             places: FakePlaces())
        let source = scratchCard(cardRoot)
        model.choose(source)
        model.askingWhose = nil
        let davidId = model.book.people[0].id
        await model.read(source, for: davidId)
        let kept = (try? peopleFile.load()).flatMap { $0 }?.lenses ?? []
        check("lenses: a card's lenses kept on this Mac with the camera and day", show(model.book.lenses) == [
            "RF70-200mm F2.8 L IS USM Z 1490000207 Canon EOS R5m2 2026:01:01 10:30:47",
            "RF600mm F4 L IS USM 2510000103 Canon EOS R5m2 2025:09:06 10:00:36"]
              && kept == model.book.lenses && kept.allSatisfy { $0.personId == davidId }, "\(show(model.book.lenses))")
        let before = try? Data(contentsOf: peopleFile.url)
        await model.read(source, for: davidId)
        check("lenses: the same card read again changes nothing", (try? Data(contentsOf: peopleFile.url)) == before && kept == model.book.lenses)

        // The firmware typed in by hand: kept with its day, the same version
        // again changes nothing, a later photo keeps it, an empty one removes it.
        let lensId = model.book.lenses[0].id
        model.setFirmware(" 1.0.6 ", lens: lensId)
        let typed = model.book.lenses[0]
        let onDisk = (try? peopleFile.load()).flatMap { $0 }?.lenses.first
        check("lens firmware: typed in, kept with the day it was typed", typed.firmware == "1.0.6"
              && abs(typed.firmwareSet?.timeIntervalSinceNow ?? 99) < 60 && onDisk == typed, "\(typed.firmware ?? "-")")
        model.setFirmware("1.0.6", lens: lensId)
        check("lens firmware: the same version again keeps its day", model.book.lenses[0] == typed)
        let later = Lenses.noting([photo("I.JPG", "Canon EOS R7", "RF70-200mm F2.8 L IS USM Z", "1490000207", "2026:10:18 10:00:00")],
                                  personId: davidId, into: model.book.lenses)
        check("lens firmware: stays when a later photo moves the lens", later[0].camera == "Canon EOS R7"
              && later[0].firmware == "1.0.6" && later[0].firmwareSet == typed.firmwareSet)
        model.setFirmware("", lens: lensId)
        check("lens firmware: an empty one takes it away", model.book.lenses[0].firmware == nil && model.book.lenses[0].firmwareSet == nil
              && (try? peopleFile.load()).flatMap { $0 }?.lenses.first?.firmware == nil)

        let saved2 = When.current
        When.current = When(order: .yearMonthDay, clock24: true)
        let day = Date(timeIntervalSince1970: 1_792_342_800) // 2026-10-18 17:00 UTC, midday in Panama
        let shown = LensTextProbe.firmware(Lens(model: "RF600mm F4 L IS USM", serial: nil, personId: davidId, camera: "Canon EOS R5m2",
                                                seen: nil, firmware: "1.0.6", firmwareSet: day))
        let none = LensTextProbe.firmware(Lens(model: "RF600mm F4 L IS USM", serial: nil, personId: davidId, camera: "Canon EOS R5m2", seen: nil))
        When.current = saved2
        check("lens firmware: the line under the lens", shown == "Firmware 1.0.6, 2026-10-18" && none == nil, shown ?? "-")
    }
}

extension SelfTest {
    /// A card of thousands of photos on the Photos page, read while the page
    /// shows, then drawn and scrolled end to end while the model changes under
    /// it (GEOTAG_TABLE_STRESS=1, on its own). Geotag crashed on a CFexpress
    /// card of 3,630 photos (18 October 2026): a table cell reached for the
    /// window's objects where they were not reachable.
    @MainActor
    static func tableStress(_ scratch: URL, count: Int = 3600) async {
        let fm = FileManager.default
        let cardRoot = scratch.appendingPathComponent("BIG-CARD")
        let card = cardRoot.appendingPathComponent("DCIM/100EOSR5")
        try? fm.createDirectory(at: card, withIntermediateDirectories: true)
        let start = 1_792_162_800
        for i in 0..<count {
            writePhoto(card.appendingPathComponent(String(format: "DAVM%04d.JPG", i + 1)), model: "Canon EOS R5m2", zone: "-03:00",
                       taken: Moments.reading.string(from: Date(timeIntervalSince1970: TimeInterval(start + i * 7))))
        }
        var book = PeopleBook.family()
        for i in 0..<book.cameras.count where book.cameras[i].model == "Canon EOS R5m2" { book.cameras[i].offsetSeconds = 0 }
        let peopleFile = PeopleStoreFile(url: scratch.appendingPathComponent("big-people.json"))
        try? peopleFile.save(book)
        let model = AppModel(library: TrackLibrary(store: TrackStoreFolder(folder: scratch.appendingPathComponent("big-lib"))),
                             peopleStore: peopleFile, history: HistoryStoreFolder(folder: scratch.appendingPathComponent("big-history")),
                             queue: QueueStoreFile(url: scratch.appendingPathComponent("big-queue.json")),
                             unplaced: UnplacedStoreFile(url: scratch.appendingPathComponent("big-unplaced.json")),
                             secrets: NoSecrets(), thumbnails: MapThumbnails(folder: scratch.appendingPathComponent("big-maps")),
                             exifTool: ExifTool(script: URL(fileURLWithPath: "Vendor/ExifTool/exiftool")),
                             nas: FakeNAS(root: scratch.appendingPathComponent("BIG-NAS")), notifier: RecordingNotifier(), places: FakePlaces())
        let source = scratchCard(cardRoot)
        model.choose(source)
        model.askingWhose = nil

        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        model.screen = .photos
        let window = NSWindow(contentRect: NSRect(x: -9000, y: -9000, width: 1100, height: 720), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        let host = NSHostingView(rootView: RootView().environmentObject(model))
        window.contentView = host
        window.orderBack(nil)
        for _ in 0..<10 { spin(0.04); try? await Task.sleep(for: .milliseconds(40)) }
        await model.read(source, for: model.book.people[0].id)
        for _ in 0..<50 { spin(0.04); try? await Task.sleep(for: .milliseconds(40)) }

        func findTable(_ view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            for sub in view.subviews { if let table = findTable(sub) { return table } }
            return nil
        }
        guard let table = findTable(host) else {
            check("big card: the Photos table is drawn", false)
            return
        }
        let rows = table.numberOfRows
        for (n, row) in Array(stride(from: 0, to: rows, by: 40)).enumerated() {
            table.scrollRowToVisible(row)
            if n % 10 == 0 { model.setBreakMinutes(n % 20 == 0 ? 20 : 30) }
            spin(0.01)
        }
        for row in stride(from: rows - 1, through: 0, by: -97) {
            table.scrollRowToVisible(row)
            spin(0.005)
        }
        window.setContentSize(NSSize(width: 940, height: 620))
        spin(0.3)
        window.setContentSize(NSSize(width: 1440, height: 860))
        spin(0.3)
        check("big card: \(count) photos read, drawn and scrolled end to end", model.rows.count == count && rows == count,
              "\(model.rows.count) rows, table \(rows)")
        window.orderOut(nil)
    }
}

/// Each place a spinner or a bar sits beside a status line, for pictures:
/// the Photos page's row, saving, a Settings card's row, the Tracks window.
struct StatusProbe: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                StatusLine(text: "Reading 3630 of 3630", lines: 2, busy: true)
                Spacer()
                Button {} label: { Text("Columns").buttonLabel() }
            }
            .frame(minHeight: 40)
            HStack(spacing: 8) {
                StatusLine(text: "Saving 1200 of 3630", lines: 2, progress: 0.33)
                Spacer()
            }
            .frame(minHeight: 40)
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Button {} label: { Text("Save").buttonLabel() }
                Button {} label: { Text("Test connection").buttonLabel() }
                StatusLine(text: "Saved. Checking the NAS", lines: 2, busy: true)
            }
            StatusLine(text: "Refreshing tracks", busy: true)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

extension SelfTest {
    /// Every button that cannot do its work says why, with the way to the fix
    /// beside it (David, 1 November 2026), never nothing at all.
    @MainActor
    static func buttonsSay(_ scratch: URL) async {
        let fm = FileManager.default
        let model = AppModel(library: TrackLibrary(store: TrackStoreFolder(folder: scratch.appendingPathComponent("bs-lib"))),
                             peopleStore: familyFile( scratch.appendingPathComponent("bs-people.json")),
                             history: HistoryStoreFolder(folder: scratch.appendingPathComponent("bs-history")),
                             queue: QueueStoreFile(url: scratch.appendingPathComponent("bs-queue.json")),
                             unplaced: UnplacedStoreFile(url: scratch.appendingPathComponent("bs-unplaced.json")),
                             secrets: NoSecrets(), thumbnails: MapThumbnails(folder: scratch.appendingPathComponent("bs-maps")),
                             exifTool: ExifTool(script: URL(fileURLWithPath: "Vendor/ExifTool/exiftool")),
                             nas: FakeNAS(root: scratch.appendingPathComponent("BS-NAS")), notifier: RecordingNotifier(), places: FakePlaces())

        // A button that can't do anything now is dimmed (0.26.0, David, 6 November 2026).
        check("buttons: no card, Save photos and the map dimmed", !model.canSave && !model.canMap)

        let root = scratch.appendingPathComponent("BS-CARD")
        let folder = root.appendingPathComponent("DCIM/100CANON")
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for i in 0..<3 {
            writePhoto(folder.appendingPathComponent(String(format: "IMG_%04d.JPG", i + 1)), model: "Canon EOS R5m2", zone: "-03:00",
                       taken: String(format: "2026:10:16 18:%02d:00", i * 5))
        }
        let card = scratchCard(root)
        model.choose(card)
        check("buttons: a new card asks whose it is", model.askingWhose != nil)
        model.askingWhose = nil
        check("buttons: nobody chosen yet, Save photos dimmed", !model.canSave)

        let david = model.book.people[0]
        await model.read(card, for: david.id)
        check("buttons: no save folder, Save photos dimmed and the line says so on its own, with the way to it",
              !model.canSave && model.photosLine == "\(david.name) has no save folder yet." && model.photosFix == .chooseFolder(david.id),
              model.photosLine)
        model.tell("Something else")
        check("buttons: a new line clears the fix", model.photosFix == nil)

        var moved = david
        moved.saveFolder = scratch.appendingPathComponent("BS-GONE").path
        model.save(moved)
        check("buttons: a save folder not found, Save photos dimmed",
              !model.canSave && model.saveBlock?.line.hasPrefix("\(david.name)'s save folder can't be found") == true
              && model.saveBlock?.fix == .chooseFolder(david.id))

        // The R5 Mark II's zone comes from the photo; with none set, its photos can't be placed.
        guard let camera = model.book.camera(personId: david.id, model: "Canon EOS R5m2") else {
            check("buttons: David's R5 Mark II is on the list", false)
            return
        }
        var unzoned = camera
        unzoned.zone = .notSet
        model.save(unzoned)
        check("buttons: a camera with no time zone, the map dimmed", !model.canMap)
        model.save(camera)
        check("buttons: no tracks, the map dimmed", !model.canMap)

        let start = 1_792_162_800
        let gpx = scratch.appendingPathComponent("bs-walk.gpx")
        writeGPX(gpx, start: start, count: 1800, name: "Ushuaia walk", lat: -54.812, lon: -68.33)
        _ = try? await model.library.importFile(gpx, role: .reader)
        await model.showLibrary()
        model.openMap()
        check("buttons: with a track, the map opens", model.canMap && model.aligning)
        model.aligning = false

        // Saved for real, then nothing new is left on the card.
        moved.saveFolder = scratch.appendingPathComponent("BS-SAVED").path
        try? fm.createDirectory(atPath: moved.saveFolder!, withIntermediateDirectories: true)
        model.save(moved)
        check("buttons: a save folder, Save photos can go", model.canSave)
        await model.savePhotos()
        check("buttons: nothing new, Save photos dimmed", !model.canSave)
        check("buttons: saved photos still on the map", model.canMap && model.mappable.count == 3)
    }

    /// The setup shows on a new Mac only: one set up before it existed has a
    /// track service or a save folder, and is left alone.
    @MainActor
    static func setupNeeded(_ scratch: URL) {
        func model(_ name: String, _ book: PeopleBook) -> AppModel {
            let people = PeopleStoreFile(url: scratch.appendingPathComponent("\(name)-people.json"))
            try? people.save(book)
            return AppModel(library: TrackLibrary(store: TrackStoreFolder(folder: scratch.appendingPathComponent("\(name)-lib"))),
                            peopleStore: people, history: HistoryStoreFolder(folder: scratch.appendingPathComponent("\(name)-history")),
                            queue: QueueStoreFile(url: scratch.appendingPathComponent("\(name)-queue.json")),
                            unplaced: UnplacedStoreFile(url: scratch.appendingPathComponent("\(name)-unplaced.json")),
                            secrets: NoSecrets(), thumbnails: MapThumbnails(folder: scratch.appendingPathComponent("\(name)-maps")),
                            nas: FakeNAS(root: scratch.appendingPathComponent("\(name)-NAS")), notifier: RecordingNotifier())
        }
        let defaults = UserDefaults.standard
        let kept = (defaults.object(forKey: "setupDone"), defaults.string(forKey: "trackServiceAddress"), defaults.string(forKey: "macOwner"))
        defaults.removeObject(forKey: "setupDone")
        defaults.removeObject(forKey: "trackServiceAddress")

        let fresh = model("su-new", .family())
        check("setup: a new Mac needs it", fresh.needsSetup)
        var withFolder = PeopleBook.family()
        withFolder.people[1].saveFolder = scratch.path
        check("setup: a Mac with a save folder does not", !model("su-folder", withFolder).needsSetup)
        defaults.set("https://example.invalid", forKey: "trackServiceAddress")
        check("setup: a Mac with a track service does not", !model("su-service", .family()).needsSetup)
        defaults.removeObject(forKey: "trackServiceAddress")
        fresh.settingUp = true
        fresh.finishSetup()
        check("setup: once done, never again unasked", !fresh.settingUp && !model("su-again", .family()).needsSetup)

        let amanda = fresh.book.people[1]
        fresh.setMacOwner(amanda.id)
        check("setup: whose Mac it is comes first", fresh.peopleOwnerFirst.first?.id == amanda.id
              && fresh.peopleOwnerFirst.count == fresh.book.people.count)
        check("setup: and is kept", model("su-owner", fresh.book).macOwner == amanda.id)

        if let done = kept.0 { defaults.set(done, forKey: "setupDone") } else { defaults.removeObject(forKey: "setupDone") }
        defaults.set(kept.1, forKey: "trackServiceAddress")
        defaults.set(kept.2, forKey: "macOwner")
    }

    /// A service handing out tracks slowly, to see the loading line.
    final class SlowService: TrackServicePort {
        let items: [ServiceTrack]
        init(count: Int) {
            items = (0..<count).map { i in
                let json = #"{"id":"slow-\#(i)","source":"strava","name":"Walk \#(i)","start":\#(1_792_000_000 + i * 7200),"end":\#(1_792_000_060 + i * 7200),"pointCount":2,"bounds":{"minLat":-54.8,"maxLat":-54.79,"minLon":-68.33,"maxLon":-68.32}}"#
                return try! JSONDecoder().decode(ServiceTrack.self, from: Data(json.utf8))
            }
        }
        func status() async throws -> ServiceStatus { throw ServiceError.offline }
        func maps() async throws -> MapSource { throw ServiceError.offline }
        func tracks() async throws -> [ServiceTrack] { items }
        func points(_ id: String) async throws -> TrackPoints {
            try await Task.sleep(for: .milliseconds(20))
            guard let item = items.first(where: { $0.id == id }) else { throw ServiceError.offline }
            return TrackPoints(t: [item.start, item.end], lat: [-54.8, -54.79], lon: [-68.33, -68.32], alt: [nil, nil])
        }
        func upload(name: String, fileName: String?, points: TrackPoints) async throws -> UploadAnswer { throw ServiceError.offline }
        func sync() async throws -> String { "" }
        func connectLink() async throws -> URL { throw ServiceError.offline }
        func disconnect() async throws -> String { throw ServiceError.offline }
    }

    /// While tracks come in, the line says how many of how many.
    static func tracksLoading(_ scratch: URL) async {
        let lib = TrackLibrary(store: TrackStoreFolder(folder: scratch.appendingPathComponent("tl-lib")))
        let seen = Seen()
        let report = await lib.refresh(service: SlowService(count: 4), role: .reader) { done, total in
            await seen.add("\(done) of \(total)")
        }
        let heard = await seen.all
        check("tracks: loading says each track as it comes", heard == ["0 of 4", "1 of 4", "2 of 4", "3 of 4", "4 of 4"] && report.added == 4,
              "\(heard)")
        let again = Seen()
        _ = await lib.refresh(service: SlowService(count: 4), role: .reader) { done, total in await again.add("\(done) of \(total)") }
        let quiet = await again.all
        check("tracks: nothing new, nothing said", quiet.isEmpty, "\(quiet)")
    }

    actor Seen {
        var all: [String] = []
        func add(_ s: String) { all.append(s) }
    }

    /// Time left while saving or sending, and the warning to connect to power.
    static func timeLeft() {
        check("time left: under a minute", Remaining.text(20) == "less than a minute")
        check("time left: minutes", Remaining.text(12 * 60 + 10) == "about 12 min")
        check("time left: hours", Remaining.text(80 * 60) == "about 1 h 20 min" && Remaining.text(120 * 60) == "about 2 h")
        let start = Date(timeIntervalSince1970: 1_000_000)
        check("time left: not before three photos", Remaining.estimate(done: 2, total: 100, since: start, now: start.addingTimeInterval(60)) == nil)
        check("time left: at the pace so far",
              Remaining.estimate(done: 10, total: 100, since: start, now: start.addingTimeInterval(60)) == 540)

        let plain = AppModel.savingLine(done: 339, total: 3630, left: nil, battery: nil)
        check("saving line: before the pace is known", plain.line == "Saving 340 of 3,630" && plain.warning == nil, plain.line)
        let timed = AppModel.savingLine(done: 339, total: 3630, left: 12 * 60, battery: 3 * 3600)
        check("saving line: with the time left, battery enough", timed.line == "Saving 340 of 3,630, about 12 min left" && timed.warning == nil, timed.line)
        let short = AppModel.savingLine(done: 339, total: 3630, left: 25 * 60, battery: 15 * 60)
        check("saving line: battery too short, connect to power",
              short.warning == "Connect to power: about 25 min of saving left, the battery has about 15 min."
              && short.line == "Saving 340 of 3,630, about 25 min left. " + (short.warning ?? ""), short.line)
    }

    /// Command-Q asks while photos are uploading; Geotag opening with the NAS
    /// away says to turn on Tailscale, and the warning goes once it answers.
    @MainActor
    static func quitAndAway(_ scratch: URL) async {
        var book = PeopleBook.family()
        book.people[0].nasFolder = "homes/david"
        let peopleFile = PeopleStoreFile(url: scratch.appendingPathComponent("qa-people.json"))
        try? peopleFile.save(book)
        let queueFile = QueueStoreFile(url: scratch.appendingPathComponent("qa-queue.json"))
        let entries = (1...3).map { QueueEntry(personId: book.people[0].id, localPath: scratch.appendingPathComponent("qa-\($0).jpg").path,
                                               relativePath: "2026.10.27/qa-\($0).jpg") }
        try? queueFile.save(entries)
        let fake = FakeNAS(root: scratch.appendingPathComponent("QA-NAS"))
        fake.online = false
        let notes = RecordingNotifier()
        let model = AppModel(library: TrackLibrary(store: TrackStoreFolder(folder: scratch.appendingPathComponent("qa-lib"))),
                             peopleStore: peopleFile, history: HistoryStoreFolder(folder: scratch.appendingPathComponent("qa-history")),
                             queue: queueFile, unplaced: UnplacedStoreFile(url: scratch.appendingPathComponent("qa-unplaced.json")),
                             secrets: NoSecrets(), thumbnails: MapThumbnails(folder: scratch.appendingPathComponent("qa-maps")),
                             nas: fake, notifier: notes)
        check("quit: asks while photos are uploading",
              model.quitCutOff() == "3 photos are uploading to the NAS. Reopening Geotag will resume the upload.", model.quitCutOff() ?? "nil")

        await model.checkNAS()
        model.announceNASAway()
        check("nas away: said on opening", model.nasAway && model.photosLine == AppModel.nasAwayText, model.photosLine)
        check("nas away: and as a notification", notes.posted.contains(AppModel.nasAwayText), "\(notes.posted)")
        fake.online = true
        await model.checkNAS()
        check("nas away: goes once the NAS answers", !model.nasAway && model.photosLine.isEmpty, model.photosLine)

        let idle = AppModel(library: TrackLibrary(store: TrackStoreFolder(folder: scratch.appendingPathComponent("qa2-lib"))),
                            peopleStore: familyFile( scratch.appendingPathComponent("qa2-people.json")),
                            history: HistoryStoreFolder(folder: scratch.appendingPathComponent("qa2-history")),
                            queue: QueueStoreFile(url: scratch.appendingPathComponent("qa2-queue.json")),
                            unplaced: UnplacedStoreFile(url: scratch.appendingPathComponent("qa2-unplaced.json")),
                            secrets: NoSecrets(), thumbnails: MapThumbnails(folder: scratch.appendingPathComponent("qa2-maps")),
                            nas: FakeNAS(root: scratch.appendingPathComponent("QA2-NAS")), notifier: RecordingNotifier())
        check("quit: nothing going on, no question", idle.quitCutOff() == nil)
        await idle.checkNAS()
        idle.announceNASAway()
        check("nas away: nothing waiting, nothing said", !idle.nasAway && idle.photosLine.isEmpty)
    }

    /// A photo of the offset code screen: the code for `shown`, taken by a
    /// camera whose clock read `clock` (its own wall time, with hundredths).
    static func writeCodePhoto(_ url: URL, shown: Date, model: String, zone: String, clock: Date) {
        guard let code = OffsetCode.image(shown) else { return }
        let side = 600
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        ctx.interpolationQuality = .none
        ctx.draw(code, in: CGRect(x: 100, y: 100, width: 400, height: 400))
        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else { return }
        let whole = Date(timeIntervalSince1970: clock.timeIntervalSince1970.rounded(.down))
        let hundredths = Int(((clock.timeIntervalSince1970 - whole.timeIntervalSince1970) * 100).rounded())
        let exif: [CFString: Any] = [kCGImagePropertyExifDateTimeOriginal: Moments.reading.string(from: whole),
                                     kCGImagePropertyExifSubsecTimeOriginal: String(format: "%02d", hundredths),
                                     kCGImagePropertyExifOffsetTimeOriginal: zone]
        let props: [CFString: Any] = [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: model, kCGImagePropertyTIFFMake: "Test"],
                                      kCGImagePropertyExifDictionary: exif]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        CGImageDestinationFinalize(dest)
    }

    /// Drift between readings, and photos matched with it.
    static func drift() {
        let day0 = Date(timeIntervalSince1970: 1_793_000_000)
        let readings = [ClockReading(at: day0, offset: 1.0), ClockReading(at: day0.addingTimeInterval(10 * 86_400), offset: 3.0)]
        check("drift: per day from two readings", abs((Drift.perDay(readings) ?? 0) - 0.2) < 1e-9, "\(Drift.perDay(readings) ?? -1)")
        check("drift: one reading, no rate", Drift.perDay([readings[0]]) == nil)
        check("drift: between readings, in proportion",
              abs((Drift.offset(at: day0.addingTimeInterval(5 * 86_400), readings: readings) ?? 0) - 2.0) < 1e-9)
        check("drift: after the last, the drift since is added",
              abs((Drift.offset(at: day0.addingTimeInterval(15 * 86_400), readings: readings) ?? 0) - 4.0) < 1e-9)
        check("drift: before the first, the first", Drift.offset(at: day0.addingTimeInterval(-86_400), readings: readings) == 1.0)

        var camera = Camera(personId: UUID(), model: "Canon EOS R7", zone: .fromPhoto)
        for r in readings { camera.add(r) }
        check("drift: the offset follows the last reading", camera.offsetSeconds == 3 && camera.followsReadings)
        let later = day0.addingTimeInterval(15 * 86_400)
        // Taken at `later`, by a clock 4 s ahead then, in UTC-3.
        let photo = ScannedPhoto(url: URL(fileURLWithPath: "/x.jpg"), fileName: "x.jpg", size: 1,
                                 taken: Moments.reading.string(from: later.addingTimeInterval(4 - 3 * 3600)), subSeconds: nil, zone: "-03:00",
                                 model: "Canon EOS R7")
        if case .success(let moment) = Moments.moment(photo, camera: camera) {
            check("drift: a photo after the last reading is matched with the drift", abs(moment.timeIntervalSince(later)) < 0.01,
                  "\(moment.timeIntervalSince(later))")
        } else {
            check("drift: a photo after the last reading is matched with the drift", false)
        }
        var typed = camera
        typed.offsetSeconds = 10
        check("drift: an offset typed by hand takes over", !typed.followsReadings)

        var temps = CameraTemperatures()
        temps.add([TemperatureSample(at: day0.addingTimeInterval(86_400), celsius: -2),
                   TemperatureSample(at: day0.addingTimeInterval(2 * 86_400), celsius: 6),
                   TemperatureSample(at: day0.addingTimeInterval(20 * 86_400), celsius: 30)], camera: camera.id)
        let periods = DriftPeriod.periods(camera, temperatures: temps)
        check("drift window: one stretch, its drift and the camera's temperature",
              periods.count == 1 && abs(periods[0].perDay - 0.2) < 1e-9 && periods[0].average == 2 && periods[0].lowest == -2 && periods[0].highest == 6,
              "\(periods.map { ($0.perDay, $0.average ?? .nan) })")
    }

    /// A card holding a photo of the offset code sets that camera's offset to
    /// the hundredth; with every camera set, the photos save by themselves.
    @MainActor
    static func offsetCodes(_ scratch: URL) async {
        let fm = FileManager.default
        let root = scratch.appendingPathComponent("OC-CARD")
        let folder = root.appendingPathComponent("DCIM/100CANON")
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let shown = Date(timeIntervalSince1970: 1_793_000_000.25)
        // The R7 runs 3.42 s ahead; the photo records its wall time in UTC-3.
        let clock = shown.addingTimeInterval(3.42 - 3 * 3600)
        writeCodePhoto(folder.appendingPathComponent("IMG_0001.JPG"), shown: shown, model: "Canon EOS R7", zone: "-03:00", clock: clock)
        check("offset code: read back from a photo of it", OffsetCode.find(in: folder.appendingPathComponent("IMG_0001.JPG")) == shown,
              "\(String(describing: OffsetCode.find(in: folder.appendingPathComponent("IMG_0001.JPG"))))")
        for i in 2...4 {
            writePhoto(folder.appendingPathComponent(String(format: "IMG_%04d.JPG", i)), model: "Canon EOS R7", zone: "-03:00",
                       taken: Moments.reading.string(from: clock.addingTimeInterval(Double(i * 60))))
        }

        var book = PeopleBook.family()
        book.people[0].saveFolder = scratch.appendingPathComponent("OC-SAVED").path
        try? fm.createDirectory(atPath: book.people[0].saveFolder!, withIntermediateDirectories: true)
        let peopleFile = PeopleStoreFile(url: scratch.appendingPathComponent("oc-people.json"))
        try? peopleFile.save(book)
        let notes = RecordingNotifier()
        // A track under the photos, so nothing stops the save (0.27.0).
        let lib = TrackLibrary(store: TrackStoreFolder(folder: scratch.appendingPathComponent("oc-lib")))
        writeGPX(scratch.appendingPathComponent("oc-walk.gpx"), start: Int(shown.timeIntervalSince1970) - 600, count: 1800, name: "Walk")
        _ = try? await lib.importFile(scratch.appendingPathComponent("oc-walk.gpx"), role: .reader)
        let model = AppModel(library: lib,
                             peopleStore: peopleFile, history: HistoryStoreFolder(folder: scratch.appendingPathComponent("oc-history")),
                             queue: QueueStoreFile(url: scratch.appendingPathComponent("oc-queue.json")),
                             unplaced: UnplacedStoreFile(url: scratch.appendingPathComponent("oc-unplaced.json")),
                             secrets: NoSecrets(), thumbnails: MapThumbnails(folder: scratch.appendingPathComponent("oc-maps")),
                             exifTool: ExifTool(script: URL(fileURLWithPath: "Vendor/ExifTool/exiftool")),
                             nas: FakeNAS(root: scratch.appendingPathComponent("OC-NAS")), notifier: notes, places: FakePlaces())
        await model.showLibrary()
        let david = model.book.people[0].id
        guard let before = model.book.camera(personId: david, model: "Canon EOS R7") else {
            check("offset code: David's R7 is on the list", false)
            return
        }
        check("offset code: the R7 starts with no offset", before.offsetSeconds == nil && !model.camerasReady)
        let card = scratchCard(root)
        model.choose(card)
        model.askingWhose = nil
        await model.read(card, for: david)
        let after = model.book.camera(personId: david, model: "Canon EOS R7")
        check("offset code: sets the offset to the hundredth",
              after?.offsetSeconds == 3 && after?.readings.count == 1 && abs((after?.readings.first?.offset ?? 0) - 3.42) < 0.005,
              "\(after?.readings.map(\.offset) ?? [])")
        check("offset code: every camera set, saved straight away without the map",
              !model.aligning && model.results.count == 4 && model.results.values.allSatisfy { $0.url != nil }, model.photosLine)

        // The weekly reminder, a week after the reading and each week after.
        let reading = after?.readings.last?.at ?? shown
        UserDefaults.standard.removeObject(forKey: "clockReminders")
        model.remindClocks(now: reading.addingTimeInterval(6 * 86_400))
        check("reminder: not before a week", notes.posted.filter { $0.hasPrefix("Time to photograph") }.isEmpty)
        model.remindClocks(now: reading.addingTimeInterval(7 * 86_400 + 60))
        check("reminder: a week on", notes.posted.contains("Time to photograph the offset code with David's Canon EOS R7."), "\(notes.posted)")
        model.remindClocks(now: reading.addingTimeInterval(8 * 86_400))
        check("reminder: once that week", notes.posted.filter { $0.hasPrefix("Time to photograph") }.count == 1)
        model.remindClocks(now: reading.addingTimeInterval(14 * 86_400 + 120))
        check("reminder: and the week after", notes.posted.filter { $0.hasPrefix("Time to photograph") }.count == 2)
        UserDefaults.standard.removeObject(forKey: "clockReminders")
    }

    /// Each step of one photo's send is said, in order, with the share of it
    /// that has reached the NAS and been read back (David, 2 November 2026).
    static func sendSteps(_ scratch: URL) {
        let fm = FileManager.default
        let mac = scratch.appendingPathComponent("STEPS-MAC")
        try? fm.createDirectory(at: mac, withIntermediateDirectories: true)
        let file = mac.appendingPathComponent("BIG.jpg")
        var bytes = [UInt8](repeating: 0, count: 5 << 20)
        for i in bytes.indices { bytes[i] = UInt8(truncatingIfNeeded: i &* 31) }
        try? Data(bytes).write(to: file)
        let day = scratch.appendingPathComponent("STEPS-NAS/2026.11.02")
        final class Steps: @unchecked Sendable {
            let lock = NSLock()
            var all: [SendStep] = []
            func add(_ s: SendStep) { lock.withLock { all.append(s) } }
        }
        let steps = Steps()
        let outcome = try? NASSender.send(file, as: "BIG.jpg", into: day, update: false, clean: true, exifTool: nil) { steps.add($0) }
        let all = steps.all
        let names = all.map { step -> String in
            switch step {
            case .looking: return "looking"
            case .sending: return "sending"
            case .checking: return "checking"
            case .naming: return "naming"
            }
        }
        var order: [String] = []
        for n in names where order.last != n { order.append(n) }
        check("send steps: looking, sending, checking, naming, in that order",
              order == ["looking", "sending", "checking", "naming"] && outcome == .sent(day.appendingPathComponent("BIG.jpg")), "\(order)")
        let sent = all.compactMap { if case .sending(let f) = $0 { return f } else { return nil } }
        let checked = all.compactMap { if case .checking(let f) = $0 { return f } else { return nil } }
        check("send steps: the share sent and checked climbs to all of it, a piece at a time",
              sent.count >= 3 && sent.last == 1 && sent == sent.sorted() && checked.count >= 3 && checked.last == 1, "\(sent) \(checked)")
        // While it goes up, its working file never looks like an old leftover:
        // another photo starting in the folder would clear it away.
        let old = mac.appendingPathComponent("OLD.jpg")
        try? Data(bytes.prefix(1 << 20)).write(to: old)
        try? fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -86_400 * 5)], ofItemAtPath: old.path)
        final class Seen: @unchecked Sendable {
            let lock = NSLock()
            var cleared = false
        }
        let seen = Seen()
        let olderDay = scratch.appendingPathComponent("STEPS-NAS/2026.10.29")
        let kept = try? NASSender.send(old, as: "OLD.jpg", into: olderDay, update: false, clean: true, exifTool: nil) { step in
            guard step == .naming else { return }
            NASSender.clearLeftovers(in: olderDay)
            seen.lock.withLock { seen.cleared = true }
        }
        let landedDate = (try? fm.attributesOfItem(atPath: olderDay.appendingPathComponent("OLD.jpg").path))?[.modificationDate] as? Date
        check("send steps: another photo tidying the folder leaves this one's upload alone, and it keeps the Mac copy's date",
              seen.cleared && kept == .sent(olderDay.appendingPathComponent("OLD.jpg"))
              && landedDate.map { abs($0.timeIntervalSinceNow + 86_400 * 5) < 5 } == true, "\(String(describing: kept))")
        check("send steps: said short", SendStep.sending(0.42).text == "Sending 42%" && SendStep.checking(0.6).text == "Checking 60%"
              && SendStep.looking.text == "Looking" && SendStep.naming.text == "Naming")
        // The whole photo, each step weighted by its share of the time.
        let w = StepWeights(looking: 0.1, sending: 0.5, checking: 0.3, naming: 0.1)
        check("send steps: one share for the whole photo, each step weighted",
              SendStep.looking.whole(w) == 0 && abs(SendStep.sending(0.5).whole(w) - 0.35) < 1e-9
              && abs(SendStep.checking(1).whole(w) - 0.9) < 1e-9 && abs(SendStep.naming.whole(w) - 0.9) < 1e-9
              && SendStep.sending(0.42).word == "Sending")
        var times = StepTimes()
        times.add([1, 10, 8, 1], for: "smb://a")
        times.add([1, 10, 8, 1], for: "smb://a")
        check("send steps: the guess until three photos are timed", times.weights(for: "smb://a") == .guess)
        times.add([2, 20, 16, 2], for: "smb://a")
        let learnt = times.weights(for: "smb://a")
        check("send steps: then each step's share of the time, for that address only",
              abs(learnt.sending - 0.5) < 1e-9 && abs(learnt.checking - 0.4) < 1e-9 && abs(learnt.looking - 0.05) < 1e-9
              && times.weights(for: "smb://b") == .guess, "\(learnt)")
        for _ in 0..<30 { times.add([1, 1, 1, 1], for: "smb://a") }
        check("send steps: only the last 20 photos count", times.byAddress["smb://a"]?.count == 20
              && abs(times.weights(for: "smb://a").sending - 0.25) < 1e-9)
    }

    /// Several photos up to the NAS at once, as many as Settings says, each
    /// with its own step; two of the same name into one folder never race for it.
    @MainActor
    static func sendTogether(_ scratch: URL) async {
        let fm = FileManager.default
        var book = PeopleBook.family()
        book.people[0].nasFolder = "homes/david/Photos"
        let peopleFile = PeopleStoreFile(url: scratch.appendingPathComponent("st-people.json"))
        try? peopleFile.save(book)
        let david = book.people[0].id
        let mac = scratch.appendingPathComponent("ST-MAC")
        func queue(_ tag: String, count: Int) -> [QueueEntry] {
            (0..<count).map { i in
                let folder = mac.appendingPathComponent("\(tag)/\(i)")
                try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
                let url = folder.appendingPathComponent("IMG_\(i % 4).JPG")
                var bytes = [UInt8](repeating: UInt8(i), count: 3 << 20)
                bytes[0] = UInt8(truncatingIfNeeded: i &* 7)
                try? Data(bytes).write(to: url)
                // Photos 0 and 4 share a name and a day: so do 1 and 5, and so on.
                return QueueEntry(personId: david, localPath: url.path, relativePath: "\(tag)/IMG_\(i % 4).JPG",
                                  added: Date().addingTimeInterval(Double(i)))
            }
        }
        func run(_ tag: String, atOnce: Int) async -> (most: Int, model: AppModel, entries: [QueueEntry]) {
            let entries = queue(tag, count: 8)
            // Its own folder: the record of sent photos sits beside the queue.
            let queueFile = QueueStoreFile(url: scratch.appendingPathComponent("st-\(tag)/queue.json"))
            try? queueFile.save(entries)
            let model = AppModel(library: TrackLibrary(store: TrackStoreFolder(folder: scratch.appendingPathComponent("st-lib"))),
                                 peopleStore: peopleFile, history: HistoryStoreFolder(folder: scratch.appendingPathComponent("st-history")),
                                 queue: queueFile, unplaced: UnplacedStoreFile(url: scratch.appendingPathComponent("st-unplaced.json")),
                                 secrets: NoSecrets(), thumbnails: MapThumbnails(folder: scratch.appendingPathComponent("st-maps")),
                                 exifTool: nil, nas: FakeNAS(root: scratch.appendingPathComponent("ST-NAS-\(tag)")), notifier: RecordingNotifier())
            model.setSendAtOnce(atOnce)
            var most = 0
            let watch = Task { @MainActor in
                while !Task.isCancelled {
                    most = max(most, model.meter.count)
                    try? await Task.sleep(for: .milliseconds(2))
                }
            }
            await model.sendWaiting()
            watch.cancel()
            return (most, model, entries)
        }

        UserDefaults.standard.removeObject(forKey: "stepTimes")
        UserDefaults.standard.removeObject(forKey: "sendSpeeds")
        let one = await run("one", atOnce: 1)
        check("send together: set to 1, one at a time", one.most == 1, "\(one.most)")
        let three = await run("three", atOnce: 3)
        check("send together: set to 3, three at once and never more", three.most == 3, "\(three.most)")
        let nas = scratch.appendingPathComponent("ST-NAS-three/homes/david/Photos/three")
        let there = Set((try? fm.contentsOfDirectory(atPath: nas.path)) ?? [])
        check("send together: every photo there, the second of each name numbered",
              three.model.queueEntries.allSatisfy { $0.state == .sent }
              && there == Set((0..<4).flatMap { ["IMG_\($0).JPG", "IMG_\($0)_2.JPG"] }), "\(there.sorted())")
        check("send together: each arrived whole", three.entries.allSatisfy { e in
            let landed = three.model.queueEntries.first { $0.id == e.id }.map { $0.sentAs ?? (e.relativePath as NSString).lastPathComponent }
            return landed.map { Saver.sha256(nas.appendingPathComponent($0)) == Saver.sha256(URL(fileURLWithPath: e.localPath)) } ?? false
        })
        check("send together: nothing left going up", three.model.meter.count == 0)
        let records = three.model.sentRecords
        check("send together: each photo sent is recorded, where it landed",
              records.count == 8 && Set(records.map(\.nasPath)) == Set((0..<4).flatMap { ["three/IMG_\($0).JPG", "three/IMG_\($0)_2.JPG"] })
              && (try? SentLogFile(url: scratch.appendingPathComponent("st-three/sent.jsonl")).load())?.count == 8,
              "\(records.map(\.nasPath).sorted())")
        check("send together: every step of every photo timed, for the address that answered",
              three.model.stepTimes.byAddress["smb://test"]?.count == 16
              && three.model.stepTimes.byAddress["smb://test"]?.allSatisfy { $0.count == 4 && $0.allSatisfy { $0 >= 0 } } == true,
              "\(three.model.stepTimes.byAddress.mapValues(\.count))")
        check("send together: every photo's speed kept for the address, between launches",
              three.model.sendSpeeds.byAddress["smb://test"]?.count == 16
              && (UserDefaults.standard.data(forKey: "sendSpeeds").flatMap { try? JSONDecoder().decode(SendSpeeds.self, from: $0) })?.byAddress["smb://test"]?.count == 16,
              "\(three.model.sendSpeeds.byAddress.mapValues(\.count))")
        UserDefaults.standard.removeObject(forKey: "sendAtOnce")
        UserDefaults.standard.removeObject(forKey: "stepTimes")
        UserDefaults.standard.removeObject(forKey: "sendSpeeds")

        // The time left goes by bytes at the recent pace, and slow, average
        // and fast by where a speed falls among all those timed.
        var speeds = SendSpeeds()
        check("send speeds: nothing timed, no time left", speeds.seconds(for: 1_000, through: "home") == nil)
        speeds.add(bytes: 10_000_000, seconds: 10, for: "home")
        check("send speeds: from the first photo, bytes over the pace",
              speeds.seconds(for: 50_000_000, through: "home").map { abs($0 - 50) < 0.001 } == true)
        check("send speeds: each address its own pace", speeds.seconds(for: 1, through: "away") == nil)
        for i in 1...30 { speeds.add(bytes: 30_000_000, seconds: Double(300 + i), for: "away") }
        check("send speeds: only the latest photos count",
              speeds.rate(for: "away").map { abs($0 - 30_000_000 * 20 / Double((11...30).map { 300 + $0 }.reduce(0, +))) < 0.01 } == true)
        check("send speeds: none of it rated before ten", SendSpeeds().rating(of: 1) == nil)
        for _ in 1...15 { speeds.add(bytes: 30_000_000, seconds: 10, for: "home") }
        check("send speeds: away slow, home fast",
              speeds.rating(of: speeds.latest(for: "away")!) == .slow && speeds.rating(of: speeds.latest(for: "home")!) == .fast,
              "\(String(describing: speeds.rating(of: speeds.latest(for: "away")!)))")
        check("send speeds: in between, average", speeds.rating(of: 1_000_000) == .average)
        for _ in 1...300 { speeds.add(bytes: 1, seconds: 1, for: "home") }
        check("send speeds: at most 200 kept a place", speeds.byAddress["home"]?.count == SendSpeeds.kept)
    }

    /// Copies on this Mac removed once on the NAS long enough, by the record
    /// alone: never one still to send, waiting for a location, or changed
    /// since it went (David, 5 November 2026).
    @MainActor
    static func macTidy(_ scratch: URL) {
        let fm = FileManager.default
        var book = PeopleBook.family()
        let root = scratch.appendingPathComponent("TIDY-MAC")
        book.people[0].saveFolder = root.path
        book.people[0].nasFolder = "homes/david/Photos"
        let peopleFile = PeopleStoreFile(url: scratch.appendingPathComponent("tidy-people.json"))
        try? peopleFile.save(book)
        let david = book.people[0].id
        let old = Date().addingTimeInterval(-40 * 86_400)
        func copy(_ day: String, _ name: String, bytes: Int = 1000) -> URL {
            let folder = root.appendingPathComponent(day)
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(name)
            try? Data(repeating: 7, count: bytes).write(to: url)
            return url
        }
        func record(_ url: URL, sent: Date) -> SentRecord {
            let stamp = SentRecord.stamp(url.path)!
            return SentRecord(personId: david, localPath: url.path, nasPath: "\(url.deletingLastPathComponent().lastPathComponent)/\(url.lastPathComponent)", sent: sent, size: stamp.size, modified: stamp.modified)
        }
        let gone = copy("2026.09.01", "A.jpg", bytes: 2000)
        let lone = copy("2026.09.02", "B.jpg", bytes: 3000)
        let fresh = copy("2026.10.30", "C.jpg")
        let waiting = copy("2026.09.03", "D.jpg")
        let unplacedOne = copy("2026.09.03", "E.jpg")
        let changed = copy("2026.09.03", "F.jpg")
        let vanished = copy("2026.09.03", "G.jpg")
        var log = [record(gone, sent: old), record(lone, sent: old), record(fresh, sent: Date().addingTimeInterval(-5 * 86_400)),
                   record(waiting, sent: old), record(unplacedOne, sent: old), record(changed, sent: old), record(vanished, sent: old)]
        log[0].nasPath = "2026.09.01/A_2.jpg"
        let logFile = SentLogFile(url: scratch.appendingPathComponent("tidy-sent.jsonl"))
        try? logFile.add(log)
        // Edited since, the same size: its date tells.
        try? Data(repeating: 9, count: 1000).write(to: changed)
        try? fm.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: changed.path)
        try? fm.removeItem(at: vanished)
        // A newer copy of D waiting to go, E waiting for a location.
        let queueFile = QueueStoreFile(url: scratch.appendingPathComponent("tidy-queue.json"))
        try? queueFile.save([QueueEntry(personId: david, localPath: waiting.path, relativePath: "2026.09.03/D.jpg", update: true)])
        let unplacedFile = UnplacedStoreFile(url: scratch.appendingPathComponent("tidy-unplaced.json"))
        try? unplacedFile.save([UnplacedEntry(personId: david, localPath: unplacedOne.path, photo: photo("2026:09:03 10:00:00", zone: nil))])

        let model = AppModel(library: TrackLibrary(store: TrackStoreFolder(folder: scratch.appendingPathComponent("tidy-lib"))),
                             peopleStore: peopleFile, history: HistoryStoreFolder(folder: scratch.appendingPathComponent("tidy-history")),
                             queue: queueFile, unplaced: unplacedFile,
                             secrets: NoSecrets(), thumbnails: MapThumbnails(folder: scratch.appendingPathComponent("tidy-maps")),
                             exifTool: nil, nas: FakeNAS(root: scratch.appendingPathComponent("TIDY-NAS")), notifier: RecordingNotifier(),
                             sentLog: logFile)
        check("tidy: 30 days after the NAS to start", model.keepOnMac == .thirtyDays)
        model.setKeepOnMac(.always)
        check("tidy: set to Always, nothing removed", [gone, lone, fresh, waiting, unplacedOne, changed].allSatisfy { fm.fileExists(atPath: $0.path) })
        model.setKeepOnMac(.thirtyDays)
        check("tidy: on the NAS over 30 days, removed", !fm.fileExists(atPath: gone.path) && !fm.fileExists(atPath: lone.path))
        check("tidy: an emptied day folder removed, the save folder kept",
              !fm.fileExists(atPath: gone.deletingLastPathComponent().path) && fm.fileExists(atPath: root.path))
        check("tidy: sent 5 days ago, kept", fm.fileExists(atPath: fresh.path))
        check("tidy: a newer copy still to send, kept", fm.fileExists(atPath: waiting.path))
        check("tidy: without a location, removed after 30 days like the rest, and off that list",
              !fm.fileExists(atPath: unplacedOne.path) && ((try? unplacedFile.load()) ?? []).isEmpty)
        check("tidy: changed since it was sent, kept", fm.fileExists(atPath: changed.path))
        check("tidy: the space freed counted, a copy already gone not", model.freedOnMac == 6000, "\(model.freedOnMac)")
        let onDisk = (try? logFile.load()) ?? []
        check("tidy: the record keeps every photo, the removed marked, written to disk",
              onDisk.count == 7 && onDisk.filter { $0.removed != nil }.count == 4 && onDisk[0].nasPath == "2026.09.01/A_2.jpg")
        model.setKeepOnMac(.untilOnNAS)
        check("tidy: Until on the NAS, the fresh one removed too", !fm.fileExists(atPath: fresh.path)
              && fm.fileExists(atPath: waiting.path) && fm.fileExists(atPath: changed.path))

        // A copy sent twice counts by its latest send.
        let twice = copy("2026.09.04", "H.jpg")
        let plan = MacTidy.plan([record(twice, sent: old), record(twice, sent: Date())], keep: .thirtyDays, busy: [])
        check("tidy: a copy sent again lately waits for the latest send", plan.remove.isEmpty && plan.gone.isEmpty)

        // The first run: the photos the queue lists as sent go into the record.
        let seedQueue = QueueStoreFile(url: scratch.appendingPathComponent("tidy-seed/queue.json"))
        let seedOne = copy("2026.09.05", "S.jpg")
        var sentEntry = QueueEntry(personId: david, localPath: seedOne.path, relativePath: "2026.09.05/S.jpg")
        sentEntry.state = .sent
        sentEntry.sent = Date().addingTimeInterval(-3 * 86_400)
        sentEntry.sentAs = "S_2.jpg"
        try? seedQueue.save([sentEntry])
        let seeded = AppModel(library: TrackLibrary(store: TrackStoreFolder(folder: scratch.appendingPathComponent("tidy-lib"))),
                              peopleStore: peopleFile, history: HistoryStoreFolder(folder: scratch.appendingPathComponent("tidy-history")),
                              queue: seedQueue, unplaced: UnplacedStoreFile(url: scratch.appendingPathComponent("seed-unplaced.json")),
                              secrets: NoSecrets(), thumbnails: MapThumbnails(folder: scratch.appendingPathComponent("tidy-maps")),
                              exifTool: nil, nas: FakeNAS(root: scratch.appendingPathComponent("TIDY-NAS")), notifier: RecordingNotifier())
        check("tidy: the first time, what the queue lists as sent goes into the record, beside the queue",
              seeded.sentRecords.map(\.nasPath) == ["2026.09.05/S_2.jpg"]
              && (try? SentLogFile(url: scratch.appendingPathComponent("tidy-seed/sent.jsonl")).load())?.contains { $0.localPath == seedOne.path } == true)
        UserDefaults.standard.removeObject(forKey: "keepOnMac")
    }

    /// Command and a number for every sidebar item in order, Settings keeping Command-comma.
    @MainActor
    static func shortcuts() {
        let pages = Shortcuts.pages.map { "\($0.title) \(Shortcuts.key($0).map { String($0.character) } ?? "-")" }
        check("shortcuts: Photos 1 to Download 7, Settings none",
              pages == ["Photos 1", "Queue 2", "History 3", "Tracks 4", "Clock drift 5", "Camera clocks 6", "Download 7"]
              && Shortcuts.key(.settings) == nil, "\(pages)")
        check("pages: every sidebar item is a page of the one window", Set(Screen.sidebar + Screen.tools) == Set(Screen.allCases))
    }

    @MainActor
    /// The photo behind the sidebar: one per card, the newest upright JPEG,
    /// else the newest JPEG, kept as Geotag's own copy beside the people list.
    static func sidebarPhoto(_ scratch: URL) async {
        let fm = FileManager.default
        let dir = scratch.appendingPathComponent("sidebar")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        func jpeg(_ name: String, _ w: Int, _ h: Int, turned: Bool = false, taken: String) -> ScannedPhoto {
            let url = dir.appendingPathComponent(name)
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 3,
                                       hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            if let image = rep.cgImage, let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, image, [kCGImagePropertyOrientation: turned ? 6 : 1] as CFDictionary)
                CGImageDestinationFinalize(dest)
            }
            return ScannedPhoto(url: url, fileName: name, size: 1, taken: taken, subSeconds: nil, zone: nil, model: "Canon EOS R5m2", hasLocation: false)
        }
        let wide = jpeg("WIDE.JPG", 300, 200, taken: "2026:10:20 10:00:00")
        let tall = jpeg("TALL.JPG", 200, 300, taken: "2026:10:18 10:00:00")
        let turned = jpeg("TURNED.JPG", 300, 200, turned: true, taken: "2026:10:19 10:00:00")
        let older = jpeg("OLDER.JPG", 200, 300, taken: "2026:10:01 10:00:00")
        let raw = ScannedPhoto(url: dir.appendingPathComponent("NEWEST.CR3"), fileName: "NEWEST.CR3", size: 1, taken: "2026:10:30 10:00:00",
                               subSeconds: nil, zone: nil, model: "Canon EOS R5m2", hasLocation: false)
        check("sidebar photo: the newest upright JPEG, turned by the camera counting",
              SidebarPhoto.choose([older, tall, wide, turned, raw])?.lastPathComponent == "TURNED.JPG")
        check("sidebar photo: the upright one before a newer wide one",
              SidebarPhoto.choose([older, tall, wide, raw])?.lastPathComponent == "TALL.JPG")
        check("sidebar photo: no upright one, the newest JPEG", SidebarPhoto.choose([wide, raw])?.lastPathComponent == "WIDE.JPG")
        check("sidebar photo: no JPEG, none", SidebarPhoto.choose([raw]) == nil)

        let peopleFile = PeopleStoreFile(url: dir.appendingPathComponent("mac/people.json"))
        func mac() -> AppModel {
            AppModel(library: TrackLibrary(store: TrackStoreFolder(folder: dir.appendingPathComponent("mac/lib"))),
                     peopleStore: peopleFile, history: HistoryStoreFolder(folder: dir.appendingPathComponent("mac/History")),
                     queue: QueueStoreFile(url: dir.appendingPathComponent("mac/queue.json")),
                     unplaced: UnplacedStoreFile(url: dir.appendingPathComponent("mac/unplaced.json")),
                     secrets: NoSecrets(), thumbnails: MapThumbnails(folder: dir.appendingPathComponent("mac/maps")),
                     exifTool: nil, nas: FakeNAS(root: dir.appendingPathComponent("NAS")), notifier: RecordingNotifier())
        }
        let model = mac()
        check("sidebar photo: none before a card", model.sidebarImage == nil)
        await model.chooseSidebarPhoto([wide, turned, raw])
        let kept = dir.appendingPathComponent("mac/Sidebar.jpg")
        let size = model.sidebarImage.map { $0.representations.first.map { CGSize(width: $0.pixelsWide, height: $0.pixelsHigh) } ?? .zero }
        check("sidebar photo: kept beside the people list, the right way up",
              fm.fileExists(atPath: kept.path) && size.map { $0.height > $0.width } == true, "\(String(describing: size))")
        await model.chooseSidebarPhoto([raw])
        check("sidebar photo: a card with no JPEG leaves it", model.sidebarImage != nil && fm.fileExists(atPath: kept.path))
        check("sidebar photo: still there after a restart", mac().sidebarImage != nil)
        check("sidebar photo: the card's photo untouched", SidebarPhoto.upright(turned.url) == true
              && (CGImageSourceCreateWithURL(turned.url as CFURL, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] })?[kCGImagePropertyPixelWidth] as? Int == 300)
    }

    /// This Mac and iCloud kept the same both ways (0.21.0): settings, people
    /// without save folders, and the lists of photos read combined; never a
    /// secret, never what stays on each Mac; a new install takes everything.
    /// A test's iCloud stays in its scratch folder.
    @MainActor
    static func cloudCopy(_ scratch: URL) async {
        let fm = FileManager.default
        var book = PeopleBook.family()
        book.people[0].nasFolder = "homes/david/Photos"
        book.people[0].saveFolder = "/Users/test/Pictures/Geotag"
        let peopleFile = PeopleStoreFile(url: scratch.appendingPathComponent("cloud/people.json"))
        try? fm.createDirectory(at: peopleFile.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? peopleFile.save(book)
        let history = HistoryStoreFolder(folder: scratch.appendingPathComponent("cloud/History"))
        try? history.save(book.people[0].id, [HistoryEntry(fileName: "IMG_0001.JPG", size: 1000, taken: "2026:11:01 10:00:00",
                                                           subSeconds: "12", imported: Date())])
        func mac(_ tag: String, people: PeopleStoreFile, history: HistoryStoreFolder, cloud: URL? = nil) -> AppModel {
            AppModel(library: TrackLibrary(store: TrackStoreFolder(folder: scratch.appendingPathComponent("\(tag)/lib"))),
                     peopleStore: people, history: history,
                     queue: QueueStoreFile(url: scratch.appendingPathComponent("\(tag)/queue.json")),
                     unplaced: UnplacedStoreFile(url: scratch.appendingPathComponent("\(tag)/unplaced.json")),
                     secrets: NoSecrets(), thumbnails: MapThumbnails(folder: scratch.appendingPathComponent("\(tag)/maps")),
                     exifTool: nil, nas: FakeNAS(root: scratch.appendingPathComponent("CLOUD-NAS")), notifier: RecordingNotifier(),
                     cloudFolder: cloud)
        }
        let model = mac("cloud", people: peopleFile, history: history)
        guard let folder = model.cloudFolder else { check("cloud: a test's iCloud folder", false); return }
        check("cloud: a test's iCloud stays in its scratch folder", folder.path.hasPrefix(scratch.path), folder.path)
        let defaults = UserDefaults.standard
        defaults.set(240, forKey: "maxGapSeconds")
        defaults.set("tester", forKey: "nasUser")
        defaults.set("smb://10.9.9.9", forKey: "nasAddress")
        defaults.set(4, forKey: "sendAtOnce")
        defaults.set("thirtyDays", forKey: "keepOnMac")
        defaults.set("not-a-real-one", forKey: "nasPassword")
        await model.syncWithCloud()
        func cloudSettings() -> [String: Any] {
            (try? Data(contentsOf: folder.appendingPathComponent("settings.plist")))
                .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] } ?? [:]
        }
        let settings = cloudSettings()
        check("cloud: the shared settings go up", settings["maxGapSeconds"] as? Int == 240 && settings["nasUser"] as? String == "tester",
              "\(settings.keys.sorted())")
        check("cloud: what stays on each Mac does not", Set(settings.keys).isSubset(of: Set(CloudCopy.sharedKeys))
              && settings["sendAtOnce"] == nil && settings["keepOnMac"] == nil && settings["macOwner"] == nil)
        let everything = (fm.enumerator(at: folder, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined()
        check("cloud: no secret in iCloud", !everything.contains("not-a-real-one") && !everything.contains("nasPassword"))
        let up = try? PeopleStoreFile(url: folder.appendingPathComponent("people.json")).load()
        check("cloud: people go up without this Mac's save folders",
              up?.people.map(\.name) == book.people.map(\.name) && up?.people.allSatisfy { $0.saveFolder == nil } == true
              && up?.people[0].nasFolder == "homes/david/Photos" && (try? peopleFile.load())?.people[0].saveFolder == "/Users/test/Pictures/Geotag")
        check("cloud: the list of photos read goes up",
              (try? HistoryStoreFolder(folder: folder.appendingPathComponent("History")).load(book.people[0].id))?.count == 1)
        let first = CloudCopy.macs(in: folder)
        check("cloud: this Mac named in the header, with when it synced", first.count == 1 && model.cloudMacs == first
              && first[0].name == (Host.current().localizedName ?? "This Mac") && model.cloudProblem == nil, "\(first)")
        await model.syncWithCloud()
        check("cloud: nothing changed, nothing written", CloudCopy.macs(in: folder) == first)

        // A new install of David's, on the same iCloud: nobody, then everything.
        let otherPeople = PeopleStoreFile(url: scratch.appendingPathComponent("cloud-other/people.json"))
        let otherHistory = HistoryStoreFolder(folder: scratch.appendingPathComponent("cloud-other/History"))
        let other = mac("cloud-other", people: otherPeople, history: otherHistory, cloud: folder)
        check("cloud: a new install starts with nobody", other.book.people.isEmpty)
        await other.syncWithCloud()
        check("cloud: and takes everyone from iCloud, with no save folder of the other Mac's",
              other.book.people.map(\.name) == book.people.map(\.name) && other.book.people.allSatisfy { $0.saveFolder == nil })
        check("cloud: and the list of photos read", (try? otherHistory.load(book.people[0].id))?.count == 1)
        check("cloud: and it still asks for the NAS password", other.needsSetup)

        // A card read on the new Mac counts on the first, and a name changed there too.
        try? otherHistory.save(book.people[0].id, ((try? otherHistory.load(book.people[0].id)) ?? [])
                               + [HistoryEntry(fileName: "IMG_0002.JPG", size: 2000, taken: nil, subSeconds: nil, imported: Date())])
        var renamed = other.book.people[1]
        renamed.name = "Amanda R"
        other.save(renamed)
        var otherDavid = other.book.people[0]
        otherDavid.saveFolder = "/Volumes/Other/Geotag"
        other.save(otherDavid)
        await other.syncWithCloud()
        await model.syncWithCloud()
        check("cloud: a photo read on another Mac counts here", (try? history.load(book.people[0].id))?.count == 2)
        check("cloud: a name changed on another Mac changes here, this Mac's save folder kept",
              model.book.people[1].name == "Amanda R" && model.book.people[0].saveFolder == "/Users/test/Pictures/Geotag")

        // A setting changed on another Mac is taken here, and shown.
        var changed = cloudSettings()
        changed["maxGapSeconds"] = 300
        try? PropertyListSerialization.data(fromPropertyList: changed, format: .xml, options: 0)
            .write(to: folder.appendingPathComponent("settings.plist"))
        await model.syncWithCloud()
        check("cloud: a setting changed on another Mac is taken here", model.maxGapSeconds == 300, "\(model.maxGapSeconds)")

        check("cloud: which way", CloudSync.way(local: "a", cloud: nil, seen: nil, localNewer: false) == .push
              && CloudSync.way(local: nil, cloud: "b", seen: nil, localNewer: true) == .pull
              && CloudSync.way(local: "a", cloud: "b", seen: "a", localNewer: true) == .pull
              && CloudSync.way(local: "a", cloud: "b", seen: "b", localNewer: false) == .push
              && CloudSync.way(local: "a", cloud: "b", seen: "c", localNewer: true) == .push
              && CloudSync.way(local: "a", cloud: "a", seen: nil, localNewer: false) == .same)
        for key in ["maxGapSeconds", "nasUser", "nasAddress", "sendAtOnce", "keepOnMac", "nasPassword",
                    "cloudSeen-" + peopleFile.url.path, "cloudSeen-" + otherPeople.url.path] { defaults.removeObject(forKey: key) }
    }

    /// The map window opens by itself after a card is read only when one of
    /// the tracks runs within a day of the card's photos (David, 18 October
    /// 2026: a card of September 2025 opened it on an empty world map). The
    /// button still opens it.
    @MainActor
    static func mapOpens(_ scratch: URL) async {
        let fm = FileManager.default
        let lib = TrackLibrary(store: TrackStoreFolder(folder: scratch.appendingPathComponent("mo-lib")))
        let start = 1_792_162_800 // 2026-10-16 15:00 UTC, 12:00 in Ushuaia
        let gpx = scratch.appendingPathComponent("mo-walk.gpx")
        writeGPX(gpx, start: start, count: 1800, name: "Ushuaia walk", lat: -54.812, lon: -68.33)
        _ = try? await lib.importFile(gpx, role: .reader)

        func card(_ name: String, day: String) -> PhotoSource {
            let root = scratch.appendingPathComponent(name)
            let folder = root.appendingPathComponent("DCIM/100CANON")
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            for i in 0..<6 {
                writePhoto(folder.appendingPathComponent(String(format: "IMG_%04d.JPG", i + 1)), model: "Canon EOS R5m2", zone: "-03:00",
                           taken: String(format: "\(day) 18:%02d:00", i * 5))
            }
            return scratchCard(root)
        }
        let model = AppModel(library: lib, peopleStore: familyFile( scratch.appendingPathComponent("mo-people.json")),
                             history: HistoryStoreFolder(folder: scratch.appendingPathComponent("mo-history")),
                             queue: QueueStoreFile(url: scratch.appendingPathComponent("mo-queue.json")),
                             unplaced: UnplacedStoreFile(url: scratch.appendingPathComponent("mo-unplaced.json")),
                             secrets: NoSecrets(), thumbnails: MapThumbnails(folder: scratch.appendingPathComponent("mo-maps")),
                             exifTool: ExifTool(script: URL(fileURLWithPath: "Vendor/ExifTool/exiftool")),
                             nas: FakeNAS(root: scratch.appendingPathComponent("MO-NAS")), notifier: RecordingNotifier(), places: FakePlaces())
        await model.showLibrary()
        let david = model.book.people[0].id

        // The same day as the walk, hours after it: off the track, but near it.
        let near = card("MO-NEAR", day: "2026:10:16")
        model.choose(near)
        model.askingWhose = nil
        await model.read(near, for: david)
        check("map window: never opens by itself, the button has photos to show", !model.aligning && model.canMap,
              "aligning \(model.aligning), \(model.mappable.count) to show")

        // A year before any track: nothing to line up with.
        let far = card("MO-FAR", day: "2025:09:24")
        model.choose(far)
        model.askingWhose = nil
        await model.read(far, for: david)
        check("map window: stays shut for photos with no track within a day", !model.aligning && !model.mappable.isEmpty,
              "aligning \(model.aligning), \(model.mappable.count) to show")

        // The card out: the list stays, and so does the map (David, 6 November 2026).
        model.choose(near)
        model.askingWhose = nil
        await model.read(near, for: david)
        // Choosing a card it has seen starts reading it too: wait for whichever read finishes last.
        for _ in 0..<100 where model.rows.isEmpty || model.photosBusy { try? await Task.sleep(for: .milliseconds(100)) }
        model.cardOutForTest()
        check("map window: the card out, the photos still on the map", model.source == nil && !model.rows.isEmpty && model.canMap && !model.canSave)

        // A restart keeps the list too: only Clear photos or the next card empties it (David, 6 November 2026).
        func reopened() -> AppModel {
            AppModel(library: lib, peopleStore: PeopleStoreFile(url: scratch.appendingPathComponent("mo-people.json")),
                     history: HistoryStoreFolder(folder: scratch.appendingPathComponent("mo-history")),
                     queue: QueueStoreFile(url: scratch.appendingPathComponent("mo-queue.json")),
                     unplaced: UnplacedStoreFile(url: scratch.appendingPathComponent("mo-unplaced.json")),
                     secrets: NoSecrets(), thumbnails: MapThumbnails(folder: scratch.appendingPathComponent("mo-maps")),
                     exifTool: ExifTool(script: URL(fileURLWithPath: "Vendor/ExifTool/exiftool")),
                     nas: FakeNAS(root: scratch.appendingPathComponent("MO-NAS")), notifier: RecordingNotifier(), places: FakePlaces())
        }
        model.keepList()
        let again = reopened()
        await again.showLibrary()
        check("photo list: kept through a restart, with whose it is and the card out",
              again.rows == model.rows && again.results == model.results && again.importPerson == david
              && again.source == nil && again.photosLine == AppModel.cardOut && again.canMap,
              "\(again.rows.count) of \(model.rows.count) rows, line \"\(again.photosLine)\"")
        again.clearPhotos()
        again.keepList()
        check("photo list: Clear photos empties it for the next restart too",
              reopened().rows.isEmpty && !fm.fileExists(atPath: scratch.appendingPathComponent("mo-photos.json").path))

        model.clearPhotos()
        check("map window: Clear photos empties the list, and the map has nothing", model.rows.isEmpty && !model.canMap)
    }
}

final class SheetFlag: ObservableObject {
    @Published var shown = false
}

/// A window with a SwiftUI sheet, as the map window and the editors are.
struct SheetHost: View {
    @ObservedObject var flag: SheetFlag
    var body: some View {
        Color.gray.frame(width: 400, height: 300)
            .sheet(isPresented: $flag.shown) {
                Text("A sheet").frame(width: 200, height: 100)
            }
    }
}

extension SelfTest {
    /// Quitting with a sheet open, in a program of its own: SwiftUI shows a
    /// sheet again straight after it is closed from outside, and the Mac
    /// would not quit while it was there (18 October 2026). The program says
    /// whether it quit the Mac's own way.
    static func quitting() {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.environment = ProcessInfo.processInfo.environment.merging(["GEOTAG_QUIT_CHILD": "1"]) { $1 }
        let out = Pipe()
        child.standardOutput = out
        child.standardError = FileHandle.nullDevice
        let started = Date()
        try? child.run()
        while child.isRunning, Date().timeIntervalSince(started) < 20 { usleep(50_000) }
        let stuck = child.isRunning
        if stuck { child.terminate() }
        let said = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        check("quit: with a sheet open, Geotag quits at once and the Mac's own way",
              !stuck && said.contains("sheet open") && said.contains("quitting properly") && !said.contains("still running"),
              said.split(separator: "\n").joined(separator: " / "))
    }

    /// The program the test above runs: a sheet open, then Quitting.now().
    @MainActor
    static func quitChild() async {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
            print("quitting properly")
            fflush(stdout)
        }
        let flag = SheetFlag()
        let window = NSWindow(contentRect: NSRect(x: -9000, y: -9000, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: SheetHost(flag: flag))
        window.orderBack(nil)
        for _ in 0..<20 { spin(0.025); try? await Task.sleep(for: .milliseconds(25)) }
        flag.shown = true
        for _ in 0..<40 { spin(0.025); try? await Task.sleep(for: .milliseconds(25)) }
        print(window.attachedSheet != nil ? "sheet open" : "no sheet")
        fflush(stdout)
        Quitting.now()
        for _ in 0..<120 { spin(0.025); try? await Task.sleep(for: .milliseconds(25)) }
        print("still running")
        fflush(stdout)
        exit(3)
    }
}

extension SelfTest {
    /// The icon in the menu bar while Geotag works (David, 18 October 2026):
    /// a pin in a ring that fills, its menu, and the lines it shows through a
    /// card read, saved and sent; nothing while photos only wait for the NAS.
    @MainActor
    static func menuBar(_ scratch: URL, samples: URL) async {
        // The icon: a template, the ring filled from the top, clockwise.
        let icon = WorkIcon.image(0.25)
        var rect = NSRect(origin: .zero, size: NSSize(width: 36, height: 36))
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 36, pixelsHigh: 36, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        icon.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()
        _ = rect
        // On the ring, 7.3 pt from the middle, at 2 pixels a point; y counts from the top.
        func alpha(degrees: Double) -> CGFloat {
            let a = degrees * .pi / 180
            let x = Int((18 + cos(a) * 14.6).rounded()), y = Int((18 - sin(a) * 14.6).rounded())
            return rep.colorAt(x: x, y: y)?.alphaComponent ?? 0
        }
        let filled = alpha(degrees: 45), empty = alpha(degrees: 180), pin = rep.colorAt(x: 18, y: 17)?.alphaComponent ?? 0
        check("menu bar: the icon takes the menu bar's colour and fills from the top, clockwise", icon.isTemplate
              && icon.size == WorkIcon.size && filled > 0.8 && empty > 0.1 && empty < 0.5 && pin > 0.5,
              String(format: "filled %.2f, empty %.2f, pin %.2f", filled, empty, pin))
        let menu = MenuBarIcon.menu(lines: ["Saving 340 of 3,630", "Sending to the NAS: 12 of 200"], target: nil)
        check("menu bar: its menu, what is going on and Open Geotag", menu.items.map(\.title)
              == ["Saving 340 of 3,630", "Sending to the NAS: 12 of 200", "", "Open Geotag"]
              && menu.items.prefix(2).allSatisfy { !$0.isEnabled } && menu.items[2].isSeparatorItem && menu.items[3].isEnabled)

        // A card read, saved and sent, the lines watched all the way.
        let fm = FileManager.default
        let tool = ExifTool(script: URL(fileURLWithPath: "Vendor/ExifTool/exiftool"))
        let card = scratch.appendingPathComponent("MENU-CARD")
        let dcim = card.appendingPathComponent("DCIM/100CANON")
        try? fm.createDirectory(at: dcim, withIntermediateDirectories: true)
        for f in ((try? fm.contentsOfDirectory(at: samples, includingPropertiesForKeys: nil)) ?? []).filter({ PhotoKinds.isPhoto($0) }) {
            try? fm.copyItem(at: f, to: dcim.appendingPathComponent(f.lastPathComponent))
        }
        let saveTo = scratch.appendingPathComponent("MENU-SAVED")
        try? fm.createDirectory(at: saveTo, withIntermediateDirectories: true)
        let nas = FakeNAS(root: scratch.appendingPathComponent("MENU-NAS"))
        let model = AppModel(library: TrackLibrary(store: TrackStoreFolder(folder: scratch.appendingPathComponent("menu-lib"))),
                             peopleStore: familyFile( scratch.appendingPathComponent("menu-people.json")),
                             history: HistoryStoreFolder(folder: scratch.appendingPathComponent("menu-history")),
                             queue: QueueStoreFile(url: scratch.appendingPathComponent("menu-queue.json")),
                             unplaced: UnplacedStoreFile(url: scratch.appendingPathComponent("menu-unplaced.json")),
                             secrets: NoSecrets(), thumbnails: MapThumbnails(folder: scratch.appendingPathComponent("menu-maps")),
                             exifTool: tool, nas: nas, notifier: RecordingNotifier(), places: FakePlaces())
        var david = model.book.people[0]
        david.saveFolder = saveTo.path
        david.nasFolder = "homes/david"
        model.save(david)
        var seen: [[String]] = [], fractions: [Double] = []
        let watch = model.work.$lines.sink { seen.append($0) }
        let watchRing = model.work.$fraction.sink { if let f = $0 { fractions.append(f) } }
        let source = scratchCard(card)
        model.choose(source)
        model.askingWhose = nil
        await model.read(source, for: david.id)
        let photos = model.readyToSave.count
        let afterReading = model.work.lines
        await model.savePhotos()
        let afterSaving = model.work.lines
        await model.sendWaiting()
        let all = seen.flatMap { $0 }
        check("menu bar: reading, saving and sending each shown, then nothing",
              all.contains { $0.hasPrefix("Reading ") } && all.contains("Saving 1 of \(photos)")
              && all.contains("Sending to the NAS: 1 of \(photos)") && afterReading.isEmpty && afterSaving.isEmpty
              && model.work.lines.isEmpty && !model.work.shown && photos > 0,
              "\(Array(Set(all)).sorted().prefix(12))")
        check("menu bar: only what is going on, never the line said when it is done",
              !all.contains { $0.contains("saved.") }, "\(all.filter { $0.contains("saved.") })")
        check("menu bar: the ring fills as the work goes", fractions.contains(0) && (fractions.max() ?? 0) >= 0.75,
              "\(Array(Set(fractions)).sorted())")

        // The NAS away: saved photos only wait, and the icon goes.
        nas.online = false
        let card2 = scratch.appendingPathComponent("MENU-CARD2")
        try? fm.createDirectory(at: card2.appendingPathComponent("DCIM/100CANON"), withIntermediateDirectories: true)
        writePhoto(card2.appendingPathComponent("DCIM/100CANON/IMG_0001.JPG"), model: "Canon EOS R5m2", zone: "-03:00",
                   taken: "2026:10:18 09:00:00")
        let source2 = scratchCard(card2)
        model.choose(source2)
        model.askingWhose = nil
        await model.read(source2, for: david.id)
        await model.savePhotos()
        await model.sendWaiting()
        check("menu bar: photos only waiting for the NAS show nothing", model.work.lines.isEmpty
              && model.queueEntries.contains { $0.state == .waiting }, "\(model.work.lines)")
        watch.cancel()
        watchRing.cancel()
    }
}

/// The menu bar icon at actual size and four times over, on a light and a
/// dark strip like the menu bar, empty, part filled and full.
struct WorkIconProbe: View {
    let steps: [Double?] = [nil, 0, 0.25, 0.6, 1]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach([false, true], id: \.self) { dark in
                HStack(spacing: 18) {
                    ForEach(steps.indices, id: \.self) { i in
                        VStack(spacing: 6) {
                            Image(nsImage: WorkIcon.image(steps[i])).renderingMode(.template)
                            Image(nsImage: WorkIcon.image(steps[i])).renderingMode(.template).resizable().interpolation(.high)
                                .frame(width: 72, height: 72)
                        }
                    }
                }
                .foregroundStyle(dark ? Color.white : Color.black)
                .padding(10)
                .background(dark ? Color(white: 0.17) : Color(white: 0.93))
            }
        }
        .padding(12)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
