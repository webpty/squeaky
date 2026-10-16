import AppKit
import Foundation
import GeotagCore
import GeotagUI

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
        gpx(scratch)
        if args.count > 1, !args[1].isEmpty { fit(URL(fileURLWithPath: args[1])) }
        if args.count > 2 { await library(scratch, address: args[2]) }
        await thumbnail(scratch)

        print(failures == 0 ? "all passed" : "\(failures) failed")
        print("scratch: \(scratch.path)")
        exit(failures == 0 ? 0 : 1)
    }

    /// A small JPEG with the camera details a photo carries.
    static func writePhoto(_ url: URL, model: String, zone: String?) {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 3,
                                   hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        guard let image = rep.cgImage,
              let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else { return }
        var exif: [CFString: Any] = [kCGImagePropertyExifDateTimeOriginal: "2026:10:16 12:00:00"]
        if let zone { exif[kCGImagePropertyExifOffsetTimeOriginal] = zone }
        let props: [CFString: Any] = [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: model, kCGImagePropertyTIFFMake: "Test"],
            kCGImagePropertyExifDictionary: exif,
        ]
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

    static func writeGPX(_ url: URL, start: Int, count: Int, name: String) {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var points = ""
        for i in 0..<count {
            let t = f.string(from: Date(timeIntervalSince1970: TimeInterval(start + i)))
            points += "<trkpt lat=\"\(-54.81 + Double(i) * 1e-5)\" lon=\"\(-68.29 + Double(i) * 2e-5)\"><ele>\(5.0 + Double(i) / 10)</ele><time>\(t)</time><extensions><ns3:TrackPointExtension><ns3:hr>90</ns3:hr></ns3:TrackPointExtension></extensions></trkpt>\n"
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
