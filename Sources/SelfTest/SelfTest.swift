import AppKit
import AVFoundation
import Foundation
import SqueakyCore
import SwiftUI
import DiskArbitration

// Checks the rules without the interface. Everything happens in a temporary
// folder; the real library in Application Support is never touched.
//
//   SQUEAKY_SCRATCH=<folder> swift run -c release SelfTest [fit folder] [service address]
//
// Its files go in a new folder inside SQUEAKY_SCRATCH; set it to a scratch
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
        let root = ProcessInfo.processInfo.environment["SQUEAKY_SCRATCH"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        let scratch = root.appendingPathComponent("squeaky-selftest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let realBefore = realData()
        bursts(scratch)
        await tracksLoading(scratch)
        await watchTracks(scratch)
        cardMemory(scratch)
        matching(scratch)
        await videos(scratch)
        gpx(scratch)
        if args.count > 1, !args[1].isEmpty { fit(URL(fileURLWithPath: args[1])) }
        if args.count > 2 { await library(scratch, address: args[2]) }

        let realAfter = realData()
        let touched = Set(realBefore.keys).union(realAfter.keys).filter { realBefore[$0] != realAfter[$0] }.sorted()
        check("tests left David's own Squeaky files alone", touched.isEmpty, "\(touched)")

        print(failures == 0 ? "all passed" : "\(failures) failed")
        print("scratch: \(scratch.path)")
        exit(failures == 0 ? 0 : 1)
    }

    /// Size and last change of Squeaky's own records on this Mac. The tests
    /// must work only in their scratch folder, never in these.
    static func realData() -> [String: String] {
        let fm = FileManager.default
        let folder = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Squeaky")
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

}

extension SelfTest {
}

extension SelfTest {

    /// What was read from a card's photos, kept (0.34.12): the next read opens
    /// only photos not seen before, or changed since.
    static func cardMemory(_ scratch: URL) {
        let fm = FileManager.default
        let card = scratch.appendingPathComponent("MEMCARD")
        let dcim = card.appendingPathComponent("DCIM/100CANON")
        try? fm.createDirectory(at: dcim, withIntermediateDirectories: true)
        for n in 1...3 { writePhoto(dcim.appendingPathComponent("IMG_000\(n).JPG"), model: "Canon EOS R5m2", zone: "-03:00") }
        let memory = CardReadMemory(folder: scratch.appendingPathComponent("memstore"), card: "CARD-1234")
        let files = PhotoScanner.files(in: card)
        let first = memory.remembered(files, root: card)
        check("card memory: a new card reads every photo", first.known.isEmpty && first.toRead.count == 3)
        let read = NativeMetadata.scan(first.toRead) { _ in }
        memory.keep(read, stamps: first.stamps, root: card, present: Set(files.map { CardReadMemory.place($0, root: card) }))

        writePhoto(dcim.appendingPathComponent("IMG_0004.JPG"), model: "Canon EOS R5m2", zone: "-03:00", taken: "2026:10:16 12:05:00")
        let files2 = PhotoScanner.files(in: card)
        let second = memory.remembered(files2, root: card)
        check("card memory: only the new photo is read", second.toRead.map(\.lastPathComponent) == ["IMG_0004.JPG"] && second.known.count == 3,
              "\(second.toRead.map(\.lastPathComponent))")
        check("card memory: what was read comes back the same",
              second.known[CardReadMemory.place(files[0], root: card)] == read[0])
        // The same card reached by another path (the phone's path to a card can
        // change between openings): still known.
        let elsewhere = scratch.appendingPathComponent("MEMELSEWHERE")
        try? fm.copyItem(at: card, to: elsewhere)
        let moved = memory.remembered(PhotoScanner.files(in: elsewhere), root: elsewhere)
        check("card memory: known whatever path the card is reached by",
              moved.known.count == 3 && moved.known.values.allSatisfy { $0.url.path.hasPrefix(elsewhere.path) }, "\(moved.known.count)")
        // A photo changed on the card is read again. Listed afresh, as each read
        // does: a URL keeps the size it was listed with.
        if let h = try? FileHandle(forWritingTo: files[1]) { h.seekToEndOfFile(); h.write(Data([0])); try? h.close() }
        let files3 = PhotoScanner.files(in: card)
        let third = memory.remembered(files3, root: card)
        check("card memory: a changed photo is read again", Set(third.toRead.map(\.lastPathComponent)) == ["IMG_0002.JPG", "IMG_0004.JPG"])
        check("card memory: a fresh read reads everything", memory.remembered(files3, root: card, ignoring: true).toRead.count == 4)
        // Another card is not this one.
        let other = CardReadMemory(folder: scratch.appendingPathComponent("memstore"), card: "CARD-5678")
        check("card memory: kept per card", other.remembered(files3, root: card).known.isEmpty)
        // A file gone from the card is forgotten; one not read this time but still there is kept.
        memory.keep([], stamps: third.stamps, root: card, present: Set(files3.dropFirst().map { CardReadMemory.place($0, root: card) }))
        let fourth = memory.remembered(files3, root: card)
        check("card memory: a photo gone is forgotten, the others kept",
              fourth.toRead.map(\.lastPathComponent).contains("IMG_0001.JPG") && fourth.known.count == 1,
              "\(fourth.known.keys.sorted())")
    }

}

extension SelfTest {
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
        let read = NativeMetadata.scan([located, bare]) { _ in }
        check("scan: a photo's own location noticed", read.map(\.hasLocation) == [true, false])
    }
}

extension SelfTest {
}

extension SelfTest {

}

extension SelfTest {
}

extension SelfTest {
}

extension SelfTest {
}

extension SelfTest {
}

extension SelfTest {
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
}

extension SelfTest {
}

extension SelfTest {
    /// Bursts in their own folders (0.29.6).
    static func bursts(_ scratch: URL) {
        func photo(_ name: String, _ time: String, _ sub: String, drive: Int?, model: String = "Canon EOS R5m2") -> ScannedPhoto {
            var p = ScannedPhoto(url: URL(fileURLWithPath: "/card/\(name)"), fileName: name, size: 1, taken: "2026:11:16 \(time)",
                                 subSeconds: sub, zone: "+01:00", model: model)
            p.drive = drive
            return p
        }
        // A fast burst in RAW+JPG, a slow one, quick single shots, and a lone continuous frame.
        let photos = [
            photo("A1.CR3", "10:00:00", "10", drive: 5), photo("A1.JPG", "10:00:00", "10", drive: 5),
            photo("A2.CR3", "10:00:00", "20", drive: 5), photo("A2.JPG", "10:00:00", "20", drive: 5),
            photo("A3.JPG", "10:00:00", "30", drive: 5),
            photo("B1.JPG", "10:05:00", "00", drive: 4), photo("B2.JPG", "10:05:01", "50", drive: 4), photo("B3.JPG", "10:05:03", "40", drive: 4),
            photo("C1.JPG", "10:10:00", "00", drive: 0), photo("C2.JPG", "10:10:00", "80", drive: 0), photo("C3.JPG", "10:10:01", "60", drive: 0),
            photo("D1.JPG", "10:20:00", "00", drive: 5),
            photo("N1.JPG", "11:00:00", "00", drive: nil, model: "COOLPIX P950"), photo("N2.JPG", "11:00:00", "50", drive: nil, model: "COOLPIX P950"),
            photo("N3.JPG", "11:00:01", "00", drive: nil, model: "COOLPIX P950"),
        ]
        let found = Bursts.find(photos).map { $0.map { ($0 as NSString).lastPathComponent }.sorted() }
        check("bursts: a fast burst, RAW and JPG together", found.first == ["A1.CR3", "A1.JPG", "A2.CR3", "A2.JPG", "A3.JPG"], "\(found)")
        check("bursts: a slow burst, frames up to two seconds apart", found.count > 1 && found[1] == ["B1.JPG", "B2.JPG", "B3.JPG"], "\(found)")
        check("bursts: quick single shots and a lone continuous frame are not bursts",
              !found.joined().contains { $0.hasPrefix("C") || $0.hasPrefix("D") })
        check("bursts: a camera with no drive mode, three frames under a second apart", found.count == 3 && found[2] == ["N1.JPG", "N2.JPG", "N3.JPG"])
        // Numbered on from the folders already there.
        let day = scratch.appendingPathComponent("BURST-DAY")
        try? FileManager.default.createDirectory(at: day.appendingPathComponent("burst_01"), withIntermediateDirectories: true)
        check("bursts: numbered on from those already in the day folder",
              Bursts.nextName(in: day) == "burst_02" && Bursts.nextName(in: day, taken: ["burst_02"]) == "burst_03")
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



}

extension SelfTest {
}

extension SelfTest {
}

extension SelfTest {
}

extension SelfTest {
}

extension SelfTest {


}

extension SelfTest {
}

extension SelfTest {
}

extension SelfTest {
}


extension SelfTest {


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
    /// Tracks from the watch (0.32.0): the watch's bytes, parts kept until whole,
    /// and of two tracks starting within 20 s, the longer listed.
    static func watchTracks(_ scratch: URL) async {
        func point(_ t: Int, _ lat: Double, _ lon: Double, _ alt: Int) -> Data {
            var d = Data()
            func put32(_ v: Int32) { withUnsafeBytes(of: v.bigEndian) { d.append(contentsOf: $0) } }
            put32(Int32(t)); put32(Int32((lat * 10_000_000).rounded())); put32(Int32((lon * 10_000_000).rounded()))
            withUnsafeBytes(of: Int16(alt).bigEndian) { d.append(contentsOf: $0) }
            return d
        }
        let start = 1_795_000_000
        var first = Data(), second = Data()
        for i in 0..<290 { first.append(point(start + i, -54.8 - Double(i) / 100_000, -68.3, 12)) }
        for i in 290..<400 { second.append(point(start + i, -54.8 - Double(i) / 100_000, -68.3, i == 399 ? WatchPart.noAltitude : 15)) }
        second.append(point(start + 399, 0, 0, 0))

        let p0 = WatchPart(message: ["k": "part", "id": NSNumber(value: start), "n": NSNumber(value: 0), "of": NSNumber(value: 2),
                                     "pts": NSNumber(value: 400), "d": first.base64EncodedString()])
        let p1 = WatchPart(message: ["k": "part", "id": NSNumber(value: start), "n": NSNumber(value: 1), "of": NSNumber(value: 2),
                                     "pts": NSNumber(value: 400), "d": second.base64EncodedString()])
        check("watch: parts read", p0?.index == 0 && p1?.index == 1 && p0?.count == 2)
        check("watch: anything else ignored", WatchPart(message: ["k": "ack"]) == nil && WatchPart(message: "hello") == nil)

        let inbox = WatchInbox(folder: scratch.appendingPathComponent("watch"))
        if let p1 { _ = try? inbox.keep(p1) }
        check("watch: not whole with one part of two", inbox.whole(start, of: 2) == nil && inbox.received(start, of: 2) == 1)
        if let p0 { _ = try? inbox.keep(p0) }
        if let p0 { _ = try? inbox.keep(p0) }
        let points = inbox.whole(start, of: 2)
        check("watch: whole once both are here, a part sent twice kept once", points?.count == 400, "\(points?.count ?? -1)")
        check("watch: positions and times", points?.t.first == start && points?.t.last == start + 399
              && abs((points?.lat.first ?? 0) + 54.8) < 0.000_001 && points?.lon.first == -68.3)
        check("watch: altitude, and none where unknown", points?.alt.first == 12 && points?.alt.last == .some(nil))

        let library = TrackLibrary(store: TrackStoreFolder(folder: scratch.appendingPathComponent("watch-library")))
        guard let points, case .added(let t)? = try? await library.importWatch(id: WatchInbox.libraryId(start), name: "From David's fēnix watch",
                                                                          points: points, role: .owner) else {
            check("watch: into the library", false)
            return
        }
        check("watch: waits to upload on the owner's phone", t.status == .waitingToUpload && t.source == .watch)
        let again = try? await library.importWatch(id: WatchInbox.libraryId(start), name: "x", points: points, role: .owner)
        if case .alreadyHere? = again { check("watch: same track twice is one", true) } else { check("watch: same track twice is one", false) }

        // A shorter track 15 s later: the same outing, set aside.
        let short = TrackPoints(t: Array(start + 15 ..< start + 115), lat: Array(repeating: -54.8, count: 100),
                                lon: Array(repeating: -68.3, count: 100), alt: Array(repeating: nil, count: 100))
        _ = try? await library.importWatch(id: "watch-short", name: "short", points: short, role: .reader)
        var listed = await library.listed().map(\.id)
        check("watch: of two within 20 s, the longer listed", listed == [WatchInbox.libraryId(start)], "\(listed)")
        // A longer one 25 s after: a different outing, both kept.
        let other = TrackPoints(t: Array(start + 25 ..< start + 1025), lat: Array(repeating: -54.8, count: 1000),
                                lon: Array(repeating: -68.3, count: 1000), alt: Array(repeating: nil, count: 1000))
        _ = try? await library.importWatch(id: "watch-other", name: "other", points: other, role: .owner)
        listed = await library.listed().map(\.id)
        check("watch: 25 s apart, both kept", listed.count == 2 && listed.contains("watch-other"), "\(listed)")
        check("watch: every watch track offered to family phones", await library.watchTracks().count == 3)
    }

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

}

extension SelfTest {
}


extension SelfTest {
    /// A small video made here, then the same with Canon's boxes added at its
    /// end as a Canon camera keeps them: read, pictured, saved with and without
    /// room for a location, every other byte the card's (0.33.0).
    static func videos(_ scratch: URL) async {
        let fm = FileManager.default
        let card = scratch.appendingPathComponent("video-card/DCIM/100CANON", isDirectory: true)
        try? fm.createDirectory(at: card, withIntermediateDirectories: true)
        let plain = card.appendingPathComponent("MVI_0001.MP4")
        guard await makeVideo(plain, seconds: 2) else { check("videos: a test video is made", false); return }
        check("videos: listed with the photos", PhotoScanner.files(in: card).map(\.lastPathComponent) == ["MVI_0001.MP4"])
        guard let read = NativeMetadata.scan([plain], progress: { _ in }).first else { check("videos: read", false); return }
        check("videos: length read", abs((read.duration ?? 0) - 2) < 0.2, "\(read.duration ?? -1)")
        check("videos: start time read from the container", read.taken != nil && read.zone == "+00:00", read.taken ?? "-")
        check("videos: a frame is made", MovieFrames.picture(plain, maxPixel: 120) != nil)
        check("videos: length written 10:07", MovieFrames.length(607) == "10:07" && MovieFrames.length(3727) == "1:02:07")

        let position = Position(lat: 45.123456, lon: -6.654321, alt: 1234.5, moment: Date(timeIntervalSince1970: 1_790_000_000), fromPoint: 0)
        let out = scratch.appendingPathComponent("video-out", isDirectory: true)
        let saver = Saver(engine: .native, folder: out)
        // No room for a location: saved without one, unchanged.
        let item = SaveItem(photo: read, placement: .matched(position), withoutLocation: false)
        if case .saved(let url) = saver.save(item) {
            check("videos: no room, saved unchanged without a location",
                  Saver.sha256(url) == Saver.sha256(plain) && (try? NativeMetadata.read(url))?.lat == nil)
        } else { check("videos: no room, saved unchanged without a location", false) }

        // Canon's boxes: the location goes in, every other byte is the card's.
        let canon = card.appendingPathComponent("MVI_0002.MP4")
        guard var bytes = try? Data(contentsOf: plain) else { return }
        bytes.append(canonBoxes(taken: "2026:11:20 10:30:00"))
        try? bytes.write(to: canon)
        guard let canonRead = NativeMetadata.scan([canon], progress: { _ in }).first else { check("videos: Canon read", false); return }
        check("videos: Canon's time read", canonRead.taken == "2026:11:20 10:30:00" && canonRead.model == "Canon EOS R5m2",
              "\(canonRead.taken ?? "-") \(canonRead.model ?? "-")")
        check("videos: Canon video still plays", MovieFrames.picture(canon, maxPixel: 120) != nil)
        let canonItem = SaveItem(photo: canonRead, placement: .matched(position), withoutLocation: false)
        if case .saved(let url) = saver.save(canonItem) {
            let back = try? NativeMetadata.read(url)
            check("videos: location written into Canon's room",
                  abs((back?.lat ?? 0) - position.lat) < 1e-6 && abs((back?.lon ?? 0) - position.lon) < 1e-6, "\(back?.lat ?? 0)")
            let patches = (try? NativeMetadata.patches(for: canon, position: position, shift: 0)) ?? []
            check("videos: every other byte is the card's", NativeMetadata.compare(copy: url, original: canon, patches: patches) == nil)
            check("videos: same size as on the card", (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) == bytes.count)
        } else { check("videos: location written into Canon's room", false) }
    }

    /// Canon's uuid box with its CMT1, CMT2 and a padded CMT4, as in a CR3.
    static func canonBoxes(taken: String) -> Data {
        func be32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
        func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] }
        func le32(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24 & 0xFF)] }
        func box(_ type: String, _ payload: [UInt8]) -> [UInt8] { be32(8 + payload.count) + Array(type.utf8) + payload }
        // A TIFF block with one IFD of ASCII entries whose values follow the table.
        func tiff(_ entries: [(Int, String)], pad: Int = 0) -> [UInt8] {
            var head: [UInt8] = [0x49, 0x49, 42, 0] + le32(8)
            let tableEnd = 8 + 2 + 12 * entries.count + 4
            var data: [UInt8] = []
            head += le16(entries.count)
            for (tag, text) in entries {
                let raw = Array(text.utf8) + [0]
                head += le16(tag) + le16(2) + le32(raw.count)
                if raw.count <= 4 { head += raw + [UInt8](repeating: 0, count: 4 - raw.count) }
                else { head += le32(tableEnd + data.count); data += raw }
            }
            head += le32(0)
            return head + data + [UInt8](repeating: 0, count: pad)
        }
        let gps: [UInt8] = [0x49, 0x49, 42, 0] + le32(8) + le16(1) + le16(0) + le16(1) + le32(4) + [2, 3, 0, 0] + le32(0)
            + [UInt8](repeating: 0, count: 600)
        let uuid: [UInt8] = [0x85, 0xC0, 0xB6, 0x87, 0x82, 0x0F, 0x11, 0xE0, 0x81, 0x11, 0xF4, 0xCE, 0x46, 0x2B, 0x6A, 0x48]
        let inner = box("CMT1", tiff([(0x0110, "Canon EOS R5m2"), (0x0132, taken)]))
            + box("CMT2", tiff([(0x9003, taken), (0x9004, taken)]))
            + box("CMT4", gps)
        return Data(box("uuid", uuid + inner))
    }

    /// A few seconds of grey frames, written the way the phone writes a video.
    static func makeVideo(_ url: URL, seconds: Int) async -> Bool {
        try? FileManager.default.removeItem(at: url)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return false }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 120,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 160,
            kCVPixelBufferHeightKey as String: 120,
        ])
        writer.add(input)
        guard writer.startWriting() else { return false }
        writer.startSession(atSourceTime: .zero)
        for frame in 0...(seconds * 10) {
            while !input.isReadyForMoreMediaData { try? await Task.sleep(for: .milliseconds(5)) }
            guard let pool = adaptor.pixelBufferPool else { return false }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { return false }
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddress(buffer), Int32(60 + frame), CVPixelBufferGetDataSize(buffer))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10))
        }
        input.markAsFinished()
        await writer.finishWriting()
        return writer.status == .completed
    }
}
