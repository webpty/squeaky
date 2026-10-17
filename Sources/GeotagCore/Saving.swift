import CryptoKit
import Foundation
import ImageIO

/// One photo to save, and where it goes.
public struct SaveItem: Sendable {
    public var photo: ScannedPhoto
    public var placement: Placement
    public var withoutLocation: Bool

    public init(photo: ScannedPhoto, placement: Placement, withoutLocation: Bool) {
        self.photo = photo
        self.placement = placement
        self.withoutLocation = withoutLocation
    }

    /// The position to write, or nil when the copy keeps the card's bytes.
    public var position: Position? {
        if case .matched(let p) = placement, !withoutLocation { return p }
        return nil
    }
}

public enum SaveResult: Equatable, Sendable {
    /// Saved at this place.
    case saved(URL)
    /// The same photo was already in the folder under this name.
    case alreadyThere(URL)
    /// Not saved, and why. Nothing of it is left behind.
    case failed(String)

    public var url: URL? {
        switch self {
        case .saved(let u), .alreadyThere(let u): return u
        case .failed: return nil
        }
    }
}

/// Saves copies of card photos into a person's folder, with the location
/// written in. The card is only ever read. A copy is made under a hidden
/// working name, checked, and only then given its final name; one that fails
/// a check is removed (it is Geotag's own copy, never the original), and an
/// existing file is never overwritten.
public struct Saver: Sendable {
    let exifTool: ExifTool
    /// The person's save folder.
    public let folder: URL

    public init(exifTool: ExifTool, folder: URL) {
        self.exifTool = exifTool
        self.folder = folder
    }

    /// "2027.01.12": the day the camera's clock said, like David's library.
    public static func dayFolder(_ photo: ScannedPhoto) -> String {
        guard let taken = photo.taken, taken.count >= 10 else { return "Undated" }
        let day = taken.prefix(10).replacingOccurrences(of: ":", with: ".")
        return day.range(of: #"^\d{4}\.\d{2}\.\d{2}$"#, options: .regularExpression) != nil ? day : "Undated"
    }

    public func save(_ item: SaveItem) -> SaveResult {
        let fm = FileManager.default
        let source = item.photo.url
        let day = folder.appendingPathComponent(Self.dayFolder(item.photo), isDirectory: true)
        do {
            try fm.createDirectory(at: day, withIntermediateDirectories: true)
        } catch {
            return .failed("The folder \(day.lastPathComponent) could not be made: \(error.localizedDescription)")
        }

        // The card's own dates, given to the copy at the end.
        let attributes = (try? fm.attributesOfItem(atPath: source.path)) ?? [:]
        let created = attributes[.creationDate] as? Date
        let modified = attributes[.modificationDate] as? Date

        let wanted = CopyName.forCopy(item.photo.fileName)
        // Hidden, unique, and still ending in the photo's own extension: the Mac
        // and ExifTool both go by it (a Nikon NRW without it reads as plain TIFF).
        let ext = (wanted as NSString).pathExtension
        let stem = (wanted as NSString).deletingPathExtension
        let work = day.appendingPathComponent(".\(stem).geotag-\(UUID().uuidString.prefix(8))" + (ext.isEmpty ? "" : ".\(ext)"))
        func fail(_ why: String) -> SaveResult {
            try? fm.removeItem(at: work)
            return .failed(why)
        }

        do {
            try fm.copyItem(at: source, to: work)
        } catch {
            if (error as NSError).code == NSFileWriteOutOfSpaceError { return fail(Self.diskFull) }
            return fail("It could not be copied from the card: \(error.localizedDescription)")
        }

        if let p = item.position {
            do {
                _ = try exifTool.run(Self.gpsArguments(p) + [work.path])
            } catch {
                return fail("The location could not be written: \(error.localizedDescription)")
            }
        }
        do {
            var dates: [FileAttributeKey: Any] = [:]
            if let created { dates[.creationDate] = created }
            if let modified { dates[.modificationDate] = modified }
            if !dates.isEmpty { try fm.setAttributes(dates, ofItemAtPath: work.path) }
        } catch {
            return fail("The card's dates could not be kept: \(error.localizedDescription)")
        }

        if let problem = check(copy: work, original: source, position: item.position) {
            return fail(problem)
        }

        // The final name: the wanted one, unless another photo has it.
        var n = 1
        while true {
            let name = n == 1 ? wanted : Self.numbered(wanted, n)
            let target = day.appendingPathComponent(name)
            if fm.fileExists(atPath: target.path) {
                if samePhoto(target, work) {
                    let differs = !sameLocation(target, work)
                    try? fm.removeItem(at: work)
                    if differs {
                        return .failed("It was saved before with a different location, and that copy is kept as it is.")
                    }
                    return .alreadyThere(target)
                }
                n += 1
                continue
            }
            do {
                // A move never replaces: if the name was taken meanwhile, look again.
                try fm.moveItem(at: work, to: target)
                return .saved(target)
            } catch CocoaError.fileWriteFileExists {
                n += 1
            } catch {
                return fail("The copy could not be named \(name): \(error.localizedDescription)")
            }
        }
    }

    public static let diskFull = "The disk the photos are saved to is full."

    /// Geotag's own working copies left by a save that was cut off (a crash, a
    /// Mac switched off): hidden files named ".<photo>.geotag-<id>.<ext>" in
    /// the day folders. Only these are removed, never anything else.
    public func clearLeftovers() {
        let fm = FileManager.default
        guard let days = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        for day in days where (try? day.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            for file in (try? fm.contentsOfDirectory(atPath: day.path)) ?? []
            where file.hasPrefix(".") && file.range(of: #"\.geotag-[0-9A-F]{8}(\.|$)"#, options: .regularExpression) != nil {
                try? fm.removeItem(at: day.appendingPathComponent(file))
            }
        }
    }

    /// "IMG_0001.jpg" becomes "IMG_0001_2.jpg".
    public static func numbered(_ name: String, _ n: Int) -> String {
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        return ext.isEmpty ? "\(base)_\(n)" : "\(base)_\(n).\(ext)"
    }

    /// What ExifTool is told: every tag named in the EXIF GPS block (left to
    /// choose, ExifTool also writes XMP into a CR3 with no S or W), any old
    /// location cleared first, and nothing else touched.
    public static func gpsArguments(_ p: Position) -> [String] {
        let utc = TimeZone(secondsFromGMT: 0)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: p.moment)
        // Hundredths, cut rather than rounded, so 59.996 never becomes 60.00.
        let seconds = ((Double(c.second ?? 0) + Double(c.nanosecond ?? 0) / 1e9) * 100).rounded(.down) / 100
        var args = [
            "-q", "-q", "-m", "-overwrite_original", "-P",
            "-GPS:all=", "-XMP-exif:GPS*=",
            "-GPS:GPSVersionID=2.3.0.0",
            "-GPS:GPSLatitude=\(String(format: "%.7f", abs(p.lat)))", "-GPS:GPSLatitudeRef=\(p.lat < 0 ? "S" : "N")",
            "-GPS:GPSLongitude=\(String(format: "%.7f", abs(p.lon)))", "-GPS:GPSLongitudeRef=\(p.lon < 0 ? "W" : "E")",
            "-GPS:GPSDateStamp=\(String(format: "%04d:%02d:%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0))",
            "-GPS:GPSTimeStamp=\(String(format: "%02d:%02d:%05.2f", c.hour ?? 0, c.minute ?? 0, seconds))",
            "-GPS:GPSMapDatum=WGS-84",
        ]
        if let alt = p.alt {
            args += ["-GPS:GPSAltitude=\(String(format: "%.2f", abs(alt)))", "-GPS:GPSAltitudeRef=\(alt < 0 ? 1 : 0)"]
        }
        return args
    }

    // MARK: Checks

    public static func sha256(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The copy opens, its picture is the card's, the location reads back,
    /// and no other detail moved. Nil when all is well; else what failed.
    func check(copy: URL, original: URL, position: Position?) -> String? {
        // It opens, the way Finder and Photos open it.
        guard let src = CGImageSourceCreateWithURL(copy as CFURL, nil), CGImageSourceGetCount(src) > 0,
              CGImageSourceCopyPropertiesAtIndex(src, 0, nil) != nil,
              CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                                                           kCGImageSourceThumbnailMaxPixelSize: 256] as CFDictionary) != nil else {
            return "The copy does not open."
        }

        guard let position else {
            // Copied unchanged: it must be the card's file, byte for byte.
            guard let a = Self.sha256(copy), a == Self.sha256(original) else { return "The copy differs from the card's file." }
            return nil
        }

        let tags: [[String: Any]]
        do {
            let data = try exifTool.run(["-j", "-a", "-G1", "-n", "-q", "-q", "-api", "ImageHashType=SHA256", "-ImageDataHash", "-all",
                                         original.path, copy.path])
            tags = (try JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
        } catch {
            return "The copy could not be read back: \(error.localizedDescription)"
        }
        guard tags.count == 2 else { return "The copy could not be read back." }
        let before = tags[0], after = tags[1]

        // The picture itself is untouched, wherever ExifTool files the hash.
        func hash(_ r: [String: Any]) -> String? {
            r.first { $0.key.hasSuffix(":ImageDataHash") }.map { "\($0.value)" }
        }
        switch (hash(before), hash(after)) {
        case let (a?, b?): if a != b { return "The picture in the copy changed." }
        case (_?, nil): return "The picture in the copy could not be checked."
        default: break // a kind of file ExifTool cannot hash; the other checks stand
        }

        // The location reads back as written.
        func number(_ key: String) -> Double? { (after[key] as? NSNumber)?.doubleValue }
        guard let lat = number("GPS:GPSLatitude"), let lon = number("GPS:GPSLongitude"),
              let latRef = after["GPS:GPSLatitudeRef"] as? String, let lonRef = after["GPS:GPSLongitudeRef"] as? String else {
            return "The location is not in the copy."
        }
        let readLat = latRef.uppercased().hasPrefix("S") ? -lat : lat
        let readLon = lonRef.uppercased().hasPrefix("W") ? -lon : lon
        if abs(readLat - position.lat) > 1e-6 || abs(readLon - position.lon) > 1e-6 {
            return "The location in the copy is not the one written."
        }
        if let alt = position.alt {
            guard let a = number("GPS:GPSAltitude") else { return "The altitude is not in the copy." }
            let ref = (after["GPS:GPSAltitudeRef"] as? NSNumber)?.intValue ?? 0
            if abs((ref == 1 ? -a : a) - alt) > 0.01 { return "The altitude in the copy is not the one written." }
        }
        guard after["GPS:GPSDateStamp"] != nil, after["GPS:GPSTimeStamp"] != nil else { return "The GPS time is not in the copy." }

        // No other detail moved.
        let changed = Self.otherDetailsChanged(before, after)
        if !changed.isEmpty { return "Other details changed in the copy: \(changed.prefix(3).joined(separator: ", "))." }
        return nil
    }

    /// Tags that differ, leaving out the location itself, the file system's
    /// own entries, ExifTool's notes, and offsets that move as metadata grows.
    static func otherDetailsChanged(_ a: [String: Any], _ b: [String: Any]) -> [String] {
        func ignored(_ key: String) -> Bool {
            let group = key.split(separator: ":").first.map(String.init) ?? ""
            let tag = key.split(separator: ":").last.map(String.init) ?? key
            if ["GPS", "System", "File", "ExifTool", "SourceFile"].contains(group) || key == "SourceFile" { return true }
            if group == "Composite", tag.hasPrefix("GPS") || tag == "ImageSize" || tag == "ImageDataHash" { return true }
            if group.hasPrefix("XMP"), tag.hasPrefix("GPS") || tag == "XMPToolkit" { return true }
            for part in ["Offset", "Start", "Length", "ByteCount", "MediaDataSize", "Size"] where tag.contains(part) { return true }
            return false
        }
        var keys = Set(a.keys).union(b.keys)
        keys = keys.filter { !ignored($0) }
        return keys.filter { key in
            let x = a[key].map { "\($0)" }, y = b[key].map { "\($0)" }
            return x != y
        }.sorted()
    }

    /// Two files carry the same GPS position, or neither has one.
    func sameLocation(_ a: URL, _ b: URL) -> Bool {
        guard let data = try? exifTool.run(["-j", "-n", "-q", "-q", "-GPS:GPSLatitude", "-GPS:GPSLatitudeRef",
                                            "-GPS:GPSLongitude", "-GPS:GPSLongitudeRef", a.path, b.path]),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], rows.count == 2 else { return false }
        func spot(_ r: [String: Any]) -> String {
            let lat = (r["GPSLatitude"] as? NSNumber).map { String(format: "%.6f", $0.doubleValue) } ?? "-"
            let lon = (r["GPSLongitude"] as? NSNumber).map { String(format: "%.6f", $0.doubleValue) } ?? "-"
            return "\(lat)\(r["GPSLatitudeRef"] ?? "") \(lon)\(r["GPSLongitudeRef"] ?? "")"
        }
        return spot(rows[0]) == spot(rows[1])
    }

    /// Two files hold the same photo: the same picture and the same moment.
    func samePhoto(_ a: URL, _ b: URL) -> Bool {
        guard let data = try? exifTool.run(["-j", "-q", "-q", "-api", "ImageHashType=SHA256", "-ImageDataHash",
                                            "-DateTimeOriginal", "-SubSecTimeOriginal", a.path, b.path]),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], rows.count == 2 else {
            return Self.sha256(a) == Self.sha256(b)
        }
        func id(_ r: [String: Any]) -> String {
            "\(r["ImageDataHash"] ?? "")|\(r["DateTimeOriginal"] ?? "")|\(r["SubSecTimeOriginal"] ?? "")"
        }
        guard rows[0]["ImageDataHash"] != nil else { return Self.sha256(a) == Self.sha256(b) }
        return id(rows[0]) == id(rows[1])
    }
}

// MARK: - The upload queue

/// A saved copy waiting to go to the NAS. Sending is stage 8.
public struct QueueEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var personId: UUID
    /// The copy on this Mac.
    public var localPath: String
    /// Its place under the person's NAS folder: "2027.01.12/IMG_0001.jpg".
    public var relativePath: String
    public var added: Date
    public var state: String

    public init(personId: UUID, localPath: String, relativePath: String, added: Date = Date()) {
        self.id = UUID()
        self.personId = personId
        self.localPath = localPath
        self.relativePath = relativePath
        self.added = Date(timeIntervalSince1970: added.timeIntervalSince1970.rounded())
        self.state = "waiting"
    }
}

public protocol QueueStorePort: Sendable {
    func load() throws -> [QueueEntry]
    func save(_ entries: [QueueEntry]) throws
}

/// `queue.json` in Geotag's folder in Application Support, written whole.
public struct QueueStoreFile: QueueStorePort {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public static func standard() -> QueueStoreFile {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return QueueStoreFile(url: support.appendingPathComponent("Geotag/queue.json"))
    }

    public func load() throws -> [QueueEntry] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode([QueueEntry].self, from: Data(contentsOf: url))
    }

    public func save(_ entries: [QueueEntry]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(entries).write(to: url, options: .atomic)
    }
}
