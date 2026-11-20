import CryptoKit
import Foundation
import ImageIO

/// What writes and reads the photos' details: ExifTool on the Mac, Geotag's
/// own reader and writer for CR3 and JPG on the iPhone.
public enum PhotoEngine: Sendable {
    #if os(macOS)
    case exifTool(ExifTool)
    #endif
    case native
}

/// One photo to save, and where it goes.
public struct SaveItem: Sendable {
    public var photo: ScannedPhoto
    public var placement: Placement
    public var withoutLocation: Bool
    /// The town or area the photo was taken in, which names its folder.
    public var place: String?
    /// Seconds to move the photo's own dates by, when its camera's clock was
    /// far out (David, 18 October 2026); 0 leaves them as the camera wrote them.
    public var shift: Int
    /// "burst_01": the burst folder inside the day folder, for a photo of a burst (0.29.6).
    public var burst: String?

    public init(photo: ScannedPhoto, placement: Placement, withoutLocation: Bool, place: String? = nil, shift: Int = 0) {
        self.photo = photo
        self.placement = placement
        self.withoutLocation = withoutLocation
        self.place = place
        self.shift = shift
    }

    /// The position to write, or nil when the copy keeps the card's bytes.
    public var position: Position? {
        if case .matched(let p) = placement, !withoutLocation { return p }
        return nil
    }
}

public enum SaveResult: Codable, Equatable, Sendable {
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
    let engine: PhotoEngine
    /// The person's save folder.
    public let folder: URL

    #if os(macOS)
    public init(exifTool: ExifTool, folder: URL) {
        self.engine = .exifTool(exifTool)
        self.folder = folder
    }
    #endif

    public init(engine: PhotoEngine, folder: URL) {
        self.engine = engine
        self.folder = folder
    }

    /// "2027.01.12": the day the camera's clock said, like David's library,
    /// moved by `shift` seconds when its clock was far out.
    public static func dayFolder(_ photo: ScannedPhoto, shift: Int = 0) -> String {
        guard let taken = photo.taken, taken.count >= 10 else { return "Undated" }
        if shift != 0 {
            guard let clock = Moments.clockReading(photo) else { return "Undated" }
            return dayFormat.string(from: clock.addingTimeInterval(Double(shift)))
        }
        let day = taken.prefix(10).replacingOccurrences(of: ":", with: ".")
        return day.range(of: #"^\d{4}\.\d{2}\.\d{2}$"#, options: .regularExpression) != nil ? day : "Undated"
    }

    static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy.MM.dd"
        return f
    }()

    /// "2027.01.12 Ushuaia": the day and the place a photo was taken, each
    /// pair a folder of its own; the day alone for a photo with no location,
    /// or whose place could not be named (David, 18 October 2026).
    public static func folderName(_ photo: ScannedPhoto, place: String?, shift: Int = 0) -> String {
        let day = dayFolder(photo, shift: shift)
        guard let place = cleanPlace(place) else { return day }
        return "\(day) \(place)"
    }

    /// Every date the camera wrote into a photo, moved by `seconds`: the EXIF
    /// dates, any XMP ones, and a raw file's container dates. The time zone
    /// fields are left as they are. Empty for no move.
    public static func shiftArguments(_ seconds: Int) -> [String] {
        guard seconds != 0 else { return [] }
        let sign = seconds < 0 ? "-" : "+"
        let a = abs(seconds)
        let value = "0:0:\(a / 86_400) \(a % 86_400 / 3600):\(a % 3600 / 60):\(a % 60)"
        return ["AllDates", "XMP-xmp:CreateDate", "XMP-xmp:ModifyDate", "XMP-exif:DateTimeOriginal", "XMP-photoshop:DateCreated",
                "QuickTime:CreateDate", "QuickTime:ModifyDate", "QuickTime:TrackCreateDate", "QuickTime:TrackModifyDate",
                "QuickTime:MediaCreateDate", "QuickTime:MediaModifyDate"].map { "-\($0)\(sign)=\(value)" }
    }

    /// For the self-test.
    public static func shiftedProbe(_ reading: String, by seconds: Int) -> String? { shifted(reading, by: seconds) }

    /// "2026:01:01 10:30:47" moved by `seconds`, as ExifTool writes it.
    static func shifted(_ reading: String, by seconds: Int) -> String? {
        guard let date = Moments.reading.date(from: String(reading.prefix(19))) else { return nil }
        return Moments.reading.string(from: date.addingTimeInterval(Double(seconds)))
    }

    /// A place name fit for a folder on the Mac and the NAS.
    static func cleanPlace(_ place: String?) -> String? {
        var text = (place ?? "").replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        text = text.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        while text.hasPrefix(".") { text.removeFirst() }
        text = String(text.prefix(60)).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    public func save(_ item: SaveItem) -> SaveResult {
        let fm = FileManager.default
        let source = item.photo.url
        var day = folder.appendingPathComponent(Self.folderName(item.photo, place: item.place, shift: item.shift), isDirectory: true)
        if let burst = item.burst { day.appendPathComponent(burst, isDirectory: true) }
        do {
            try fm.createDirectory(at: day, withIntermediateDirectories: true)
        } catch {
            return .failed(Words.t("The folder {0} could not be made: {1}", day.lastPathComponent, error.localizedDescription))
        }

        // The card's own dates, given to the copy at the end, moved with the
        // photo's when its camera's clock was far out.
        let attributes = (try? fm.attributesOfItem(atPath: source.path)) ?? [:]
        let created = (attributes[.creationDate] as? Date)?.addingTimeInterval(Double(item.shift))
        let modified = (attributes[.modificationDate] as? Date)?.addingTimeInterval(Double(item.shift))

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

        // A video goes through Geotag's own writer on the Mac too (0.33.0). One
        // whose file has no room for a location is saved without one: never rebuilt.
        let video = PhotoKinds.isVideo(source)
        var position = item.position
        if video, position != nil, (try? NativeMetadata.patches(for: source, position: position, shift: item.shift)) == nil {
            position = nil
        }
        var native = video
        if case .native = engine { native = true }

        // Geotag's own writer: the card read once, copied with the location written on the way (0.29.9).
        var expected: String?
        if native {
            do {
                expected = try NativeMetadata.copyPatched(from: source, to: work, position: position, shift: item.shift)
            } catch {
                if (error as NSError).code == NSFileWriteOutOfSpaceError { return fail(Self.diskFull) }
                return fail(position == nil ? Words.t("It could not be copied from the card: {0}", error.localizedDescription)
                                            : Words.t("The location could not be written: {0}", error.localizedDescription))
            }
        } else {
            do {
                try fm.copyItem(at: source, to: work)
            } catch {
                if (error as NSError).code == NSFileWriteOutOfSpaceError { return fail(Self.diskFull) }
                return fail(Words.t("It could not be copied from the card: {0}", error.localizedDescription))
            }
        }

        // The location, and the dates moved, in one go.
        if expected == nil, item.position != nil || item.shift != 0 {
            do {
                try write(work, original: source, position: item.position, shift: item.shift)
            } catch {
                return fail(item.position == nil ? Words.t("The dates could not be corrected: {0}", error.localizedDescription)
                                                 : Words.t("The location could not be written: {0}", error.localizedDescription))
            }
        }
        do {
            var dates: [FileAttributeKey: Any] = [:]
            if let created { dates[.creationDate] = created }
            if let modified { dates[.modificationDate] = modified }
            if !dates.isEmpty { try fm.setAttributes(dates, ofItemAtPath: work.path) }
        } catch {
            return fail(Words.t("The card's dates could not be kept: {0}", error.localizedDescription))
        }

        let problem = expected.map { NativeMetadata.checkCopy(work, expected: $0, position: position, shift: item.shift, taken: item.photo.taken) }
            ?? check(copy: work, original: source, position: item.position, shift: item.shift)
        if let problem { return fail(problem) }

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
                        return .failed(Words.t("Previously saved in another location"))
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
                return fail(Words.t("The copy could not be named {0}: {1}", name, error.localizedDescription))
            }
        }
    }

    public static let diskFull = "Destination full"

    /// Writes the location and the corrected dates into `work`, a copy of
    /// `original`: through ExifTool on the Mac, Geotag's own writer on the phone.
    func write(_ work: URL, original: URL, position: Position?, shift: Int) throws {
        if PhotoKinds.isVideo(work) {
            _ = try NativeMetadata.write(into: work, original: original, position: position, shift: shift)
            return
        }
        switch engine {
        #if os(macOS)
        case .exifTool(let exifTool):
            let arguments = position.map(Self.gpsArguments) ?? ["-q", "-q", "-m", "-overwrite_original", "-P"]
            _ = try exifTool.run(arguments + Self.shiftArguments(shift) + [work.path])
        #endif
        case .native:
            _ = try NativeMetadata.write(into: work, original: original, position: position, shift: shift)
        }
    }

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

    /// Written with every location Geotag adds, in the GPS block's own field
    /// for how the position was found (David, 17 October 2026).
    public static let processingMethod = "GPS coordinates added by Geotag.app"

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
            "-GPS:GPSProcessingMethod=\(processingMethod)",
        ]
        if let alt = p.alt {
            // The flag as a number (#): written plain, ExifTool reads "1" as a
            // word and leaves the photo above sea level.
            args += ["-GPS:GPSAltitude=\(String(format: "%.2f", abs(alt)))", "-GPS:GPSAltitudeRef#=\(alt < 0 ? 1 : 0)"]
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
    /// its dates moved by exactly `shift` when they were to be corrected, and
    /// no other detail moved. Nil when all is well; else what failed.
    public func check(copy: URL, original: URL, position: Position?, shift: Int = 0) -> String? {
        if PhotoKinds.isVideo(copy) { return NativeMetadata.check(copy: copy, original: original, position: position, shift: shift) }
        #if os(macOS)
        guard case .exifTool(let exifTool) = engine else {
            return NativeMetadata.check(copy: copy, original: original, position: position, shift: shift)
        }
        // It opens, the way Finder and Photos open it.
        guard let src = CGImageSourceCreateWithURL(copy as CFURL, nil), CGImageSourceGetCount(src) > 0,
              CGImageSourceCopyPropertiesAtIndex(src, 0, nil) != nil,
              CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                                                           kCGImageSourceThumbnailMaxPixelSize: 256] as CFDictionary) != nil else {
            return Words.t("The copy does not open.")
        }

        if position == nil, shift == 0 {
            // Copied unchanged: it must be the card's file, byte for byte.
            guard let a = Self.sha256(copy), a == Self.sha256(original) else { return Words.t("The copy differs from the card's file.") }
            return nil
        }

        let tags: [[String: Any]]
        do {
            let data = try exifTool.run(["-j", "-a", "-G1", "-n", "-q", "-q", "-api", "ImageHashType=SHA256", "-ImageDataHash", "-all",
                                         original.path, copy.path])
            tags = (try JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
        } catch {
            return Words.t("The copy could not be read back: {0}", error.localizedDescription)
        }
        guard tags.count == 2 else { return Words.t("The copy could not be read back.") }
        let before = tags[0], after = tags[1]

        // The picture itself is untouched, wherever ExifTool files the hash.
        func hash(_ r: [String: Any]) -> String? {
            r.first { $0.key.hasSuffix(":ImageDataHash") }.map { "\($0.value)" }
        }
        switch (hash(before), hash(after)) {
        case let (a?, b?): if a != b { return Words.t("The picture in the copy changed.") }
        case (_?, nil): return Words.t("The picture in the copy could not be checked.")
        default: break // a kind of file ExifTool cannot hash; the other checks stand
        }

        if let position {
            // The location reads back as written.
            func number(_ key: String) -> Double? { (after[key] as? NSNumber)?.doubleValue }
            guard let lat = number("GPS:GPSLatitude"), let lon = number("GPS:GPSLongitude"),
                  let latRef = after["GPS:GPSLatitudeRef"] as? String, let lonRef = after["GPS:GPSLongitudeRef"] as? String else {
                return Words.t("The location is not in the copy.")
            }
            let readLat = latRef.uppercased().hasPrefix("S") ? -lat : lat
            let readLon = lonRef.uppercased().hasPrefix("W") ? -lon : lon
            if abs(readLat - position.lat) > 1e-6 || abs(readLon - position.lon) > 1e-6 {
                return Words.t("The location in the copy is not the one written.")
            }
            if let alt = position.alt {
                guard let a = number("GPS:GPSAltitude") else { return Words.t("The altitude is not in the copy.") }
                let ref = (after["GPS:GPSAltitudeRef"] as? NSNumber)?.intValue ?? 0
                // Half a metre: the watch is no closer than that.
                if abs((ref == 1 ? -a : a) - alt) > 0.5 { return Words.t("The altitude in the copy is not the one written.") }
            }
            guard after["GPS:GPSDateStamp"] != nil, after["GPS:GPSTimeStamp"] != nil else { return Words.t("The GPS time is not in the copy.") }
            guard (after["GPS:GPSProcessingMethod"] as? String) == Self.processingMethod else {
                return Words.t("The note that Geotag added the location is not in the copy.")
            }
        }

        if shift != 0 {
            // The date taken moved by exactly the camera's error.
            let key = before.keys.first { $0.hasSuffix(":DateTimeOriginal") && $0.hasPrefix("ExifIFD") }
                ?? before.keys.first { $0.hasSuffix(":DateTimeOriginal") }
            if let key, let was = before[key].map({ "\($0)" }) {
                guard let expected = Self.shifted(was, by: shift), after[key].map({ "\($0)" }) == expected else {
                    return Words.t("The date in the copy was not corrected.")
                }
            }
        }

        // No other detail moved.
        let changed = Self.otherDetailsChanged(before, after, datesMoved: shift != 0)
        if !changed.isEmpty { return Words.t("Other details changed in the copy: {0}.", changed.prefix(3).joined(separator: ", ")) }
        return nil
        #else
        return NativeMetadata.check(copy: copy, original: original, position: position, shift: shift)
        #endif
    }

    /// Tags that differ, leaving out the location itself, the file system's
    /// own entries, ExifTool's notes, offsets that move as metadata grows,
    /// and the dates when they were corrected.
    static func otherDetailsChanged(_ a: [String: Any], _ b: [String: Any], datesMoved: Bool = false) -> [String] {
        func ignored(_ key: String) -> Bool {
            let group = key.split(separator: ":").first.map(String.init) ?? ""
            let tag = key.split(separator: ":").last.map(String.init) ?? key
            if datesMoved, tag.contains("Date") { return true }
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
        if PhotoKinds.isVideo(a) { return NativeMetadata.sameLocation(a, b) }
        #if os(macOS)
        guard case .exifTool(let exifTool) = engine else { return NativeMetadata.sameLocation(a, b) }
        guard let data = try? exifTool.run(["-j", "-n", "-q", "-q", "-GPS:GPSLatitude", "-GPS:GPSLatitudeRef",
                                            "-GPS:GPSLongitude", "-GPS:GPSLongitudeRef", a.path, b.path]),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], rows.count == 2 else { return false }
        func spot(_ r: [String: Any]) -> String {
            let lat = (r["GPSLatitude"] as? NSNumber).map { String(format: "%.6f", $0.doubleValue) } ?? "-"
            let lon = (r["GPSLongitude"] as? NSNumber).map { String(format: "%.6f", $0.doubleValue) } ?? "-"
            return "\(lat)\(r["GPSLatitudeRef"] ?? "") \(lon)\(r["GPSLongitudeRef"] ?? "")"
        }
        return spot(rows[0]) == spot(rows[1])
        #else
        return NativeMetadata.sameLocation(a, b)
        #endif
    }

    /// Two files hold the same photo: the same picture and the same moment.
    func samePhoto(_ a: URL, _ b: URL) -> Bool {
        if PhotoKinds.isVideo(a) { return NativeMetadata.samePhoto(a, b) }
        #if os(macOS)
        guard case .exifTool(let exifTool) = engine else { return NativeMetadata.samePhoto(a, b) }
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
        #else
        return NativeMetadata.samePhoto(a, b)
        #endif
    }
}

// MARK: - The upload queue

public enum QueueState: String, Codable, Sendable {
    case waiting, sending, sent, failed
}

/// A saved copy on its way to the NAS.
public struct QueueEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var personId: UUID
    /// The copy on this Mac.
    public var localPath: String
    /// Its place under the person's NAS folder: "2027.01.12/IMG_0001.jpg".
    public var relativePath: String
    public var added: Date
    public var state: QueueState
    /// Replaces Geotag's own earlier copy of the same photo on the NAS: its
    /// location was written in after that copy went.
    public var update: Bool
    /// Why it was not sent, or why the last try broke off.
    public var reason: String?
    /// When it reached the NAS.
    public var sent: Date?
    /// Its name on the NAS, when another photo already had its own.
    public var sentAs: String?
    /// Tries that broke off, and when to try it again.
    public var tries: Int
    public var notBefore: Date?
    /// Saved without a track while the track service could not be reached:
    /// held back until the tracks have been checked again (0.27.0).
    public var held: Bool

    public init(personId: UUID, localPath: String, relativePath: String, added: Date = Date(), update: Bool = false,
                held: Bool = false) {
        self.id = UUID()
        self.personId = personId
        self.localPath = localPath
        self.relativePath = relativePath
        self.added = Date(timeIntervalSince1970: added.timeIntervalSince1970.rounded())
        self.state = .waiting
        self.update = update
        self.tries = 0
        self.held = held
    }

    private enum CodingKeys: String, CodingKey {
        case id, personId, localPath, relativePath, added, state, update, reason, sent, sentAs, tries, notBefore, held
    }

    /// Reads queues written before 0.12.0 too, which had no sending details.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        personId = try c.decode(UUID.self, forKey: .personId)
        localPath = try c.decode(String.self, forKey: .localPath)
        relativePath = try c.decode(String.self, forKey: .relativePath)
        added = try c.decode(Date.self, forKey: .added)
        state = (try? c.decode(QueueState.self, forKey: .state)) ?? .waiting
        update = try c.decodeIfPresent(Bool.self, forKey: .update) ?? false
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
        sent = try c.decodeIfPresent(Date.self, forKey: .sent)
        sentAs = try c.decodeIfPresent(String.self, forKey: .sentAs)
        tries = try c.decodeIfPresent(Int.self, forKey: .tries) ?? 0
        notBefore = try c.decodeIfPresent(Date.self, forKey: .notBefore)
        held = try c.decodeIfPresent(Bool.self, forKey: .held) ?? false
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
        // Not spaced out: it is written after every change, and grows on a long trip.
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(entries).write(to: url, options: .atomic)
    }
}

// MARK: - Placing saved photos later

/// A copy saved without a location, kept so it can be placed later: when its
/// camera's offset or zone is set, the gap changes, or new tracks arrive.
public struct UnplacedEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var personId: UUID
    /// The copy on this Mac.
    public var localPath: String
    public var fileName: String
    public var taken: String?
    public var subSeconds: String?
    public var zone: String?
    public var model: String?
    /// Seconds the copy's dates were already moved by when it was saved, so
    /// placing it later moves them only by what is left.
    public var shifted: Int

    public init(personId: UUID, localPath: String, photo: ScannedPhoto, shifted: Int = 0) {
        self.id = UUID()
        self.personId = personId
        self.localPath = localPath
        self.fileName = photo.fileName
        self.taken = photo.taken
        self.subSeconds = photo.subSeconds
        self.zone = photo.zone
        self.model = photo.model
        self.shifted = shifted
    }

    private enum CodingKeys: String, CodingKey {
        case id, personId, localPath, fileName, taken, subSeconds, zone, model, shifted
    }

    /// Reads lists written before 0.14.0 too, which had no dates moved.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        personId = try c.decode(UUID.self, forKey: .personId)
        localPath = try c.decode(String.self, forKey: .localPath)
        fileName = try c.decode(String.self, forKey: .fileName)
        taken = try c.decodeIfPresent(String.self, forKey: .taken)
        subSeconds = try c.decodeIfPresent(String.self, forKey: .subSeconds)
        zone = try c.decodeIfPresent(String.self, forKey: .zone)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        shifted = try c.decodeIfPresent(Int.self, forKey: .shifted) ?? 0
    }

    /// The copy as a photo to match: its time, zone and camera as the card had them.
    public var photo: ScannedPhoto {
        ScannedPhoto(url: URL(fileURLWithPath: localPath), fileName: fileName, size: 0, taken: taken,
                     subSeconds: subSeconds, zone: zone, model: model, hasLocation: false)
    }
}

public protocol UnplacedStorePort: Sendable {
    func load() throws -> [UnplacedEntry]
    func save(_ entries: [UnplacedEntry]) throws
}

/// `unplaced.json` in Geotag's folder in Application Support, written whole.
public struct UnplacedStoreFile: UnplacedStorePort {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public static func standard() -> UnplacedStoreFile {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return UnplacedStoreFile(url: support.appendingPathComponent("Geotag/unplaced.json"))
    }

    public func load() throws -> [UnplacedEntry] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([UnplacedEntry].self, from: Data(contentsOf: url))
    }

    public func save(_ entries: [UnplacedEntry]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(entries).write(to: url, options: .atomic)
    }
}

extension Saver {
    /// Writes a location into a copy already saved on this Mac. The new version
    /// is made beside it under a working name, checked against the copy (same
    /// picture, same details, the location reads back, the same dates), and
    /// only then swapped in. Nil when done; else why not, the copy untouched.
    public func addLocation(to copy: URL, _ position: Position, shift: Int = 0) -> String? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: copy.path) else { return Words.t("The copy is no longer there.") }
        let attributes = (try? fm.attributesOfItem(atPath: copy.path)) ?? [:]
        // Its dates moved too, when its camera's clock turned out far out.
        let created = (attributes[.creationDate] as? Date)?.addingTimeInterval(Double(shift))
        let modified = (attributes[.modificationDate] as? Date)?.addingTimeInterval(Double(shift))
        let name = copy.lastPathComponent
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        let work = copy.deletingLastPathComponent()
            .appendingPathComponent(".\(stem).geotag-\(UUID().uuidString.prefix(8))" + (ext.isEmpty ? "" : ".\(ext)"))
        func fail(_ why: String) -> String {
            try? fm.removeItem(at: work)
            return why
        }
        do {
            try fm.copyItem(at: copy, to: work)
            try write(work, original: copy, position: position, shift: shift)
            var dates: [FileAttributeKey: Any] = [:]
            if let created { dates[.creationDate] = created }
            if let modified { dates[.modificationDate] = modified }
            if !dates.isEmpty { try fm.setAttributes(dates, ofItemAtPath: work.path) }
        } catch {
            return fail(Words.t("The location could not be written: {0}", error.localizedDescription))
        }
        if let problem = check(copy: work, original: copy, position: position, shift: shift) { return fail(problem) }
        do {
            _ = try fm.replaceItemAt(copy, withItemAt: work)
        } catch {
            return fail(Words.t("The copy could not be replaced: {0}", error.localizedDescription))
        }
        return nil
    }
}
