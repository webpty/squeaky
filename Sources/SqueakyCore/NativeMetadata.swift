import CryptoKit
import Foundation
import ImageIO

/// Reads and writes a camera's CR3 and JPG files without ExifTool, for the
/// iPhone, where ExifTool cannot run (David, 14 November 2026: the phone
/// handles CR3 and JPG from his cameras, nothing else).
///
/// Canon leaves fixed room for the location in both: in a JPG, the GPS block
/// sits in space reserved before the thumbnail; in a CR3, the GPS block is a
/// box of its own (CMT4) padded with zeros. The location is written into that
/// room and nothing else in the file moves: the copy has the card's size, and
/// every byte outside the location (and the dates, when they are corrected)
/// is the card's. A file without that room is refused, never rebuilt.
public enum NativeMetadata {
    public struct Failure: Error, LocalizedError, Equatable {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }

    /// `movie`: a video, MP4, MOV or Canon's RAW video CRM (0.33.0). Canon
    /// keeps the same CMT boxes in its videos as in a CR3, so the location is
    /// written into the same padded room; read and written the same way on the
    /// phone and the Mac, never through ExifTool.
    public enum Kind: Sendable { case jpeg, cr3, movie }

    public static let extensions: Set<String> = ["cr3", "jpg", "jpeg", "mp4", "mov", "crm"]

    public static func kind(_ url: URL) -> Kind? {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": return .jpeg
        case "cr3": return .cr3
        case "mp4", "mov", "crm": return .movie
        default: return nil
        }
    }

    // MARK: Reading

    /// What Squeaky needs from a photo.
    public struct Details: Equatable, Sendable {
        public var taken: String?
        public var subSeconds: String?
        public var zone: String?
        public var model: String?
        public var lens: String?
        public var lensSerial: String?
        public var firmware: String?
        public var lat: Double?
        public var lon: Double?
        public var alt: Double?
        public var gpsDate: String?
        public var gpsTime: [Double]?
        public var processingMethod: String?
        public var mapDatum: String?
        /// Canon's drive mode: CameraSettings, the sixth value (0.29.6).
        public var drive: Int?
        /// A video's length in seconds (0.33.0).
        public var duration: Double?
    }

    public static func read(_ url: URL) throws -> Details {
        let layout = try Layout.load(url)
        var d = Details()
        if let x = layout.ifd0, let ifd = x.0.ifd(at: x.1) {
            d.model = ifd.string(0x0110)
        }
        if let x = layout.exif, let ifd = x.0.ifd(at: x.1) {
            d.taken = ifd.string(0x9003)
            d.subSeconds = ifd.string(0x9291)
            d.zone = ifd.string(0x9011) ?? ifd.string(0x9010)
            d.lens = ifd.string(0xA434)
            d.lensSerial = ifd.string(0xA435)
        }
        if let x = layout.maker, let ifd = x.0.ifd(at: x.1) {
            d.firmware = Firmware.version([ifd.string(0x0007)])
            if let e = ifd.entry(0x0001), e.type == 3, e.count > 5 { d.drive = x.0.u16(e.data + 2 * 5) }
        }
        if let gps = layout.gps, let ifd = gps.tiff.ifd(at: gps.ifd) {
            if let r = ifd.rationals(0x0002), r.count == 3, let ref = ifd.string(0x0001) {
                let v = r[0] + r[1] / 60 + r[2] / 3600
                d.lat = ref.uppercased().hasPrefix("S") ? -v : v
            }
            if let r = ifd.rationals(0x0004), r.count == 3, let ref = ifd.string(0x0003) {
                let v = r[0] + r[1] / 60 + r[2] / 3600
                d.lon = ref.uppercased().hasPrefix("W") ? -v : v
            }
            if let a = ifd.rationals(0x0006)?.first {
                d.alt = ifd.integer(0x0005) == 1 ? -a : a
            }
            d.gpsDate = ifd.string(0x001D)
            d.gpsTime = ifd.rationals(0x0007)
            d.mapDatum = ifd.string(0x0012)
            if let raw = ifd.bytes(0x001B), raw.count >= 8 {
                d.processingMethod = String(decoding: raw.dropFirst(8).prefix { $0 != 0 }, as: UTF8.self)
            }
        }
        d.duration = layout.duration
        // A video without Canon's details: its container's start, which is in UTC.
        if layout.kind == .movie, d.taken == nil, let start = layout.created {
            d.taken = Moments.reading.string(from: start)
            d.zone = "+00:00"
        }
        return d
    }

    /// A real position: both numbers there, and not the 0, 0 some cameras write.
    public static func hasLocation(_ d: Details) -> Bool {
        guard let lat = d.lat, let lon = d.lon else { return false }
        return !(lat == 0 && lon == 0)
    }

    /// The photos' details, as the Mac's scanner reads them.
    /// A HEIF photo (.HIF, .HEIC) through the phone's own reader: Squeaky
    /// never writes into one, so only its time, zone and camera are needed (0.29.28).
    static func readHEIF(_ url: URL) -> Details {
        var d = Details()
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return d }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        d.taken = exif[kCGImagePropertyExifDateTimeOriginal] as? String
        d.subSeconds = (exif[kCGImagePropertyExifSubsecTimeOriginal] as? String) ?? (exif[kCGImagePropertyExifSubsecTimeOriginal]).map { "\($0)" }
        d.zone = (exif[kCGImagePropertyExifOffsetTimeOriginal] as? String) ?? (exif[kCGImagePropertyExifOffsetTime] as? String)
        d.model = (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespaces)
        return d
    }

    public static func isHEIF(_ url: URL) -> Bool { ["hif", "heic", "heif"].contains(url.pathExtension.lowercased()) }

    public static func scan(_ files: [URL], progress: @Sendable (Int) -> Void) -> [ScannedPhoto] {
        var out: [ScannedPhoto] = []
        for (i, url) in files.enumerated() {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(Int64.init) ?? 0
            let d = isHEIF(url) ? readHEIF(url) : ((try? read(url)) ?? Details())
            let located = hasLocation(d)
            out.append(ScannedPhoto(url: url, fileName: url.lastPathComponent, size: size, taken: d.taken, subSeconds: d.subSeconds,
                                    zone: d.zone, model: d.model, hasLocation: located,
                                    ownLat: located ? d.lat : nil, ownLon: located ? d.lon : nil,
                                    firmware: d.firmware, lens: d.lens, lensSerial: d.lensSerial))
            out[out.count - 1].drive = d.drive
            out[out.count - 1].duration = d.duration
            if (i + 1) % 25 == 0 || i + 1 == files.count { progress(i + 1) }
        }
        return out
    }

    // MARK: Writing

    /// A run of bytes to put into the copy at a place in the file.
    public struct Patch: Equatable, Sendable {
        public var offset: Int
        public var bytes: [UInt8]
        public var range: Range<Int> { offset..<(offset + bytes.count) }
    }

    /// What has to change in `url` to carry `position` and dates moved by
    /// `shift` seconds. Nothing is written.
    public static func patches(for url: URL, position: Position?, shift: Int) throws -> [Patch] {
        let layout = try Layout.load(url)
        var out: [Patch] = []
        if let position { out.append(try layout.gpsPatch(position)) }
        if shift != 0 { out += try layout.datePatches(shift) }
        return out
    }

    /// Writes the location and the dates into `copy`, which holds the same
    /// bytes as `original`; the room for them is found in `original`.
    public static func write(into copy: URL, original: URL, position: Position?, shift: Int) throws -> [Patch] {
        let list = try patches(for: original, position: position, shift: shift)
        guard !list.isEmpty else { return [] }
        let handle = try FileHandle(forUpdating: copy)
        defer { try? handle.close() }
        for p in list {
            try handle.seek(toOffset: UInt64(p.offset))
            try handle.write(contentsOf: Data(p.bytes))
        }
        try handle.synchronize()
        return list
    }

    /// The card's file copied once, the location and dates written into the
    /// bytes on their way (0.29.9, David, 16 November 2026: 800 photos took 26
    /// minutes, the card read twice for each). Answers the fingerprint of
    /// what was meant to be written, for `checkCopy`.
    public static func copyPatched(from original: URL, to copy: URL, position: Position?, shift: Int) throws -> String {
        let list = try patches(for: original, position: position, shift: shift).sorted { $0.offset < $1.offset }
        let input = try FileHandle(forReadingFrom: original)
        defer { try? input.close() }
        guard FileManager.default.createFile(atPath: copy.path, contents: nil) else {
            throw Failure(Words.t("It could not be copied from the card: {0}", copy.lastPathComponent))
        }
        let output = try FileHandle(forWritingTo: copy)
        defer { try? output.close() }
        var hasher = SHA256()
        var at = 0
        while let chunk = try input.read(upToCount: 4 << 20), !chunk.isEmpty {
            var bytes = [UInt8](chunk)
            let range = at..<(at + bytes.count)
            for p in list where p.range.overlaps(range) {
                for i in max(p.offset, range.lowerBound)..<min(p.range.upperBound, range.upperBound) {
                    bytes[i - at] = p.bytes[i - p.offset]
                }
            }
            let data = Data(bytes)
            try output.write(contentsOf: data)
            hasher.update(data: data)
            at += bytes.count
        }
        try output.synchronize()
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The copy made by `copyPatched`: its bytes are what was meant (it is
    /// read, the card is not), it opens, and the location and dates read back.
    public static func checkCopy(_ copy: URL, expected: String, position: Position?, shift: Int, taken: String?) -> String? {
        guard Saver.sha256(copy) == expected else {
            return position == nil && shift == 0 ? Words.t("The copy differs from the card's file.") : Words.t("Other details changed in the copy.")
        }
        guard opens(copy) else { return Words.t("The copy does not open.") }
        guard position != nil || shift != 0 else { return nil }
        let after: Details
        do { after = try read(copy) } catch { return Words.t("The copy could not be read back: {0}", error.localizedDescription) }
        if let position {
            guard let lat = after.lat, let lon = after.lon else { return Words.t("The location is not in the copy.") }
            if abs(lat - position.lat) > 1e-6 || abs(lon - position.lon) > 1e-6 { return Words.t("The location in the copy is not the one written.") }
            if let alt = position.alt {
                guard let a = after.alt else { return Words.t("The altitude is not in the copy.") }
                if abs(a - alt) > 0.5 { return Words.t("The altitude in the copy is not the one written.") }
            }
            guard after.gpsDate != nil, after.gpsTime?.count == 3 else { return Words.t("The GPS time is not in the copy.") }
            guard after.processingMethod == Saver.processingMethod else {
                return Words.t("The note that Squeaky added the location is not in the copy.")
            }
        }
        if shift != 0, let was = taken {
            guard let want = Saver.shiftedProbe(was, by: shift), after.taken == want else { return Words.t("The date in the copy was not corrected.") }
        }
        return nil
    }

    /// The copy opens, the location and dates read back as written, and every
    /// other byte is the card's. Nil when all is well; else what failed.
    public static func check(copy: URL, original: URL, position: Position?, shift: Int) -> String? {
        guard opens(copy) else { return Words.t("The copy does not open.") }
        let expected: [Patch]
        do {
            expected = try patches(for: original, position: position, shift: shift)
        } catch {
            return Words.t("The copy could not be checked: {0}", error.localizedDescription)
        }
        // Only the expected bytes differ, and they hold what was meant.
        if let problem = compare(copy: copy, original: original, patches: expected) { return problem }

        let after: Details
        do { after = try read(copy) } catch { return Words.t("The copy could not be read back: {0}", error.localizedDescription) }
        if let position {
            guard let lat = after.lat, let lon = after.lon else { return Words.t("The location is not in the copy.") }
            if abs(lat - position.lat) > 1e-6 || abs(lon - position.lon) > 1e-6 {
                return Words.t("The location in the copy is not the one written.")
            }
            if let alt = position.alt {
                guard let a = after.alt else { return Words.t("The altitude is not in the copy.") }
                if abs(a - alt) > 0.5 { return Words.t("The altitude in the copy is not the one written.") }
            }
            guard after.gpsDate != nil, after.gpsTime?.count == 3 else { return Words.t("The GPS time is not in the copy.") }
            guard after.processingMethod == Saver.processingMethod else {
                return Words.t("The note that Squeaky added the location is not in the copy.")
            }
        }
        if shift != 0, let was = (try? read(original))?.taken {
            guard let want = Saver.shiftedProbe(was, by: shift), after.taken == want else {
                return Words.t("The date in the copy was not corrected.")
            }
        }
        return nil
    }

    /// A photo opens as a picture; a video's boxes read through to its media
    /// data, every byte of which the byte check then proves is the card's.
    static func opens(_ copy: URL) -> Bool {
        if kind(copy) == .movie { return (try? Layout.load(copy))?.picture != nil }
        guard let src = CGImageSourceCreateWithURL(copy as CFURL, nil), CGImageSourceGetCount(src) > 0,
              CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                                                           kCGImageSourceThumbnailMaxPixelSize: 256] as CFDictionary) != nil else { return false }
        return true
    }

    /// The picture a video carries of itself, Canon's preview or thumbnail, as
    /// JPG bytes: the only frame of a RAW video the phone and the Mac can show.
    public static func moviePreview(_ url: URL) -> Data? {
        guard let layout = try? Layout.load(url), let range = layout.preview,
              let bytes = try? Layout.headAt(url, range.lowerBound, range.count) else { return nil }
        return Data(bytes)
    }

    /// Byte for byte: the copy is the original with `patches` applied.
    public static func compare(copy: URL, original: URL, patches: [Patch]) -> String? {
        guard let a = try? FileHandle(forReadingFrom: original), let b = try? FileHandle(forReadingFrom: copy) else {
            return Words.t("The copy could not be read back.")
        }
        defer { try? a.close(); try? b.close() }
        let sorted = patches.sorted { $0.offset < $1.offset }
        var at = 0
        while true {
            // The end of a file reads as nothing at all.
            guard let x = try? (a.read(upToCount: 4 << 20) ?? Data()), let y = try? (b.read(upToCount: 4 << 20) ?? Data()) else {
                return Words.t("The copy could not be read back.")
            }
            if x.isEmpty && y.isEmpty { return nil }
            guard x.count == y.count else { return Words.t("The copy is not the size of the card's file.") }
            let chunk = at..<(at + x.count)
            var want = x
            var touched = false
            for p in sorted where p.range.overlaps(chunk) {
                touched = true
                for i in max(p.offset, chunk.lowerBound)..<min(p.range.upperBound, chunk.upperBound) {
                    want[want.startIndex + i - at] = p.bytes[i - p.offset]
                }
            }
            if want != y { return touched ? Words.t("The location in the copy is not the one written.") : Words.t("Other details changed in the copy.") }
            at += x.count
        }
    }

    /// The picture alone, for telling two copies of one photo apart from two
    /// photos: a JPG's image data, a CR3's media data.
    public static func pictureHash(_ url: URL) -> String? {
        guard let layout = try? Layout.load(url), let range = layout.picture,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            try handle.seek(toOffset: UInt64(range.lowerBound))
            var left = range.count
            while left > 0, let chunk = try handle.read(upToCount: min(left, 4 << 20)), !chunk.isEmpty {
                hasher.update(data: chunk)
                left -= chunk.count
            }
        } catch { return nil }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The same picture taken at the same moment.
    public static func samePhoto(_ a: URL, _ b: URL) -> Bool {
        guard let x = pictureHash(a), let y = pictureHash(b) else { return Saver.sha256(a) == Saver.sha256(b) }
        let p = try? read(a), q = try? read(b)
        return x == y && p?.taken == q?.taken && p?.subSeconds == q?.subSeconds
    }

    /// Two files carry the same GPS position, or neither has one.
    public static func sameLocation(_ a: URL, _ b: URL) -> Bool {
        guard let p = try? read(a), let q = try? read(b) else { return false }
        func spot(_ d: Details) -> String {
            "\(d.lat.map { String(format: "%.6f", $0) } ?? "-") \(d.lon.map { String(format: "%.6f", $0) } ?? "-")"
        }
        return spot(p) == spot(q)
    }
}

// MARK: - TIFF blocks

/// A TIFF block (the start of a JPG's EXIF, or one of a CR3's CMT boxes),
/// with where it sits in the file.
struct TIFFBlock {
    let bytes: [UInt8]
    /// Where bytes[0] is in the file.
    let base: Int
    let little: Bool

    init?(_ bytes: [UInt8], base: Int) {
        guard bytes.count >= 8 else { return nil }
        if bytes[0] == 0x49, bytes[1] == 0x49 { little = true } else if bytes[0] == 0x4D, bytes[1] == 0x4D { little = false } else { return nil }
        self.bytes = bytes
        self.base = base
        let magic = little ? Int(bytes[2]) | Int(bytes[3]) << 8 : Int(bytes[2]) << 8 | Int(bytes[3])
        guard magic == 42 else { return nil }
    }

    var firstIFD: Int? { u32(4) }

    func u16(_ o: Int) -> Int? {
        guard o >= 0, o + 2 <= bytes.count else { return nil }
        return little ? Int(bytes[o]) | Int(bytes[o + 1]) << 8 : Int(bytes[o]) << 8 | Int(bytes[o + 1])
    }

    func u32(_ o: Int) -> Int? {
        guard o >= 0, o + 4 <= bytes.count else { return nil }
        let b = (0..<4).map { Int(bytes[o + $0]) }
        return little ? b[0] | b[1] << 8 | b[2] << 16 | b[3] << 24 : b[0] << 24 | b[1] << 16 | b[2] << 8 | b[3]
    }

    static let typeSize: [Int: Int] = [1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 6: 1, 7: 1, 8: 2, 9: 4, 10: 8, 11: 4, 12: 8]

    struct Entry {
        var tag: Int, type: Int, count: Int
        /// Where the value or its offset is, in the block.
        var field: Int
        var size: Int
        /// Where the value is, in the block.
        var data: Int
    }

    struct IFD {
        let block: TIFFBlock
        let at: Int
        let entries: [Entry]
        let next: Int
        /// The table itself: count, entries, next pointer.
        var table: Range<Int> { at..<(at + 2 + 12 * entries.count + 4) }

        func entry(_ tag: Int) -> Entry? { entries.first { $0.tag == tag } }

        func bytes(_ tag: Int) -> ArraySlice<UInt8>? {
            guard let e = entry(tag), e.data >= 0, e.data + e.size <= block.bytes.count else { return nil }
            return block.bytes[e.data..<(e.data + e.size)]
        }

        func string(_ tag: Int) -> String? {
            guard let raw = bytes(tag) else { return nil }
            let text = String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }

        func integer(_ tag: Int) -> Int? {
            guard let e = entry(tag) else { return nil }
            switch e.type {
            case 1, 7: return e.data < block.bytes.count ? Int(block.bytes[e.data]) : nil
            case 3: return block.u16(e.data)
            case 4: return block.u32(e.data)
            default: return nil
            }
        }

        func rationals(_ tag: Int) -> [Double]? {
            guard let e = entry(tag), e.type == 5 else { return nil }
            return (0..<e.count).compactMap { i in
                guard let n = block.u32(e.data + 8 * i), let d = block.u32(e.data + 8 * i + 4), d != 0 else { return nil }
                return Double(n) / Double(d)
            }
        }

        /// Every range the table and its values take up.
        var used: [Range<Int>] {
            [table] + entries.filter { $0.size > 4 }.map { $0.data..<($0.data + $0.size) }
        }
    }

    func ifd(at o: Int) -> IFD? {
        guard let n = u16(o), n > 0, n < 1000, o + 2 + 12 * n + 4 <= bytes.count else { return nil }
        var list: [Entry] = []
        for i in 0..<n {
            let p = o + 2 + 12 * i
            guard let tag = u16(p), let type = u16(p + 2), let count = u32(p + 4) else { return nil }
            let size = (Self.typeSize[type] ?? 1) * count
            let data = size <= 4 ? p + 8 : (u32(p + 8) ?? -1)
            list.append(Entry(tag: tag, type: type, count: count, field: p + 8, size: size, data: data))
        }
        return IFD(block: self, at: o, entries: list, next: u32(o + 2 + 12 * n) ?? 0)
    }

    func put16(_ v: Int, _ out: inout [UInt8]) {
        out += little ? [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] : [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
    }

    func put32(_ v: Int, _ out: inout [UInt8]) {
        let b = [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
        out += little ? b.reversed() : b
    }
}

// MARK: - Where things are in a file

struct Layout {
    var kind: NativeMetadata.Kind
    var ifd0: (TIFFBlock, Int)?
    var exif: (TIFFBlock, Int)?
    var maker: (TIFFBlock, Int)?
    /// The GPS block, and the room it may fill.
    var gps: (tiff: TIFFBlock, ifd: Int, room: Range<Int>)?
    /// The photo's own dates, "YYYY:MM:DD HH:MM:SS", as places in the file.
    var dates: [Int] = []
    /// A CR3's container dates: place in the file, width (4 or 8 bytes) and
    /// value, seconds since 1904.
    var containerDates: [(Int, Int, Int64)] = []
    /// Where the picture itself is in the file.
    var picture: Range<Int>?
    /// A video's length in seconds, and its container's start (UTC).
    var duration: Double?
    var created: Date?
    /// A video's own picture of itself, a JPG, in the file.
    var preview: Range<Int>?

    typealias Failure = NativeMetadata.Failure

    static func head(_ url: URL, _ count: Int) throws -> [UInt8] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return [UInt8](try handle.read(upToCount: count) ?? Data())
    }

    static func load(_ url: URL) throws -> Layout {
        switch NativeMetadata.kind(url) {
        case .jpeg: return try jpeg(url)
        case .cr3: return try cr3(url)
        case .movie: return try movie(url)
        case nil: throw Failure(Words.t("Squeaky on the iPhone only handles CR3 and JPG."))
        }
    }

    // A JPG: the EXIF block in its first APP1 segment.
    static func jpeg(_ url: URL) throws -> Layout {
        let d = try head(url, 256 << 10)
        guard d.count > 4, d[0] == 0xFF, d[1] == 0xD8 else { throw Failure(Words.t("This is not a JPG.")) }
        var layout = Layout(kind: .jpeg)
        var p = 2
        var tiff: TIFFBlock?
        while p + 4 <= d.count, d[p] == 0xFF {
            let marker = d[p + 1]
            if marker == 0xD8 || (0xD0...0xD7).contains(marker) || marker == 0x01 { p += 2; continue }
            let length = Int(d[p + 2]) << 8 | Int(d[p + 3])
            if marker == 0xDA {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } ?? 0
                layout.picture = (p + 2 + length)..<size
                break
            }
            if marker == 0xE1, tiff == nil, p + 10 <= d.count, Array(d[(p + 4)..<(p + 10)]) == Array("Exif".utf8) + [0, 0] {
                let end = min(p + 2 + length, d.count)
                tiff = TIFFBlock(Array(d[(p + 10)..<end]), base: p + 10)
            }
            p += 2 + length
        }
        guard let t = tiff, let first = t.firstIFD, let ifd0 = t.ifd(at: first) else {
            throw Failure(Words.t("The photo's details could not be found."))
        }
        layout.ifd0 = (t, first)
        var others: [Range<Int>] = ifd0.used
        if let e = ifd0.entry(0x0132) { layout.dates.append(t.base + e.data) }
        if let o = ifd0.integer(0x8769), let exif = t.ifd(at: o) {
            layout.exif = (t, o)
            others += exif.used
            for tag in [0x9003, 0x9004] { if let e = exif.entry(tag), e.size >= 19 { layout.dates.append(t.base + e.data) } }
            if let m = exif.entry(0x927C), m.data > 0 { layout.maker = (t, m.data) }
            if let o = exif.integer(0xA005), let interop = t.ifd(at: o) { others += interop.used }
        }
        if ifd0.next > 0, let ifd1 = t.ifd(at: ifd0.next) {
            others += ifd1.used
            if let start = ifd1.integer(0x0201), let length = ifd1.integer(0x0202) { others.append(start..<(start + length)) }
        }
        if let g = ifd0.integer(0x8825) {
            // The room: from the GPS block to whatever comes next.
            let end = others.map(\.lowerBound).filter { $0 > g }.min() ?? t.bytes.count
            layout.gps = (t, g, g..<end)
            if others.contains(where: { $0.overlaps(g..<end) }) { layout.gps = nil }
        }
        return layout
    }

    // A CR3: Canon's boxes inside moov.
    static let canonUUID: [UInt8] = [0x85, 0xC0, 0xB6, 0x87, 0x82, 0x0F, 0x11, 0xE0, 0x81, 0x11, 0xF4, 0xCE, 0x46, 0x2B, 0x6A, 0x48]

    static func cr3(_ url: URL) throws -> Layout {
        let start = try head(url, 64)
        // ftyp, then moov.
        func box(_ d: [UInt8], _ p: Int) -> (size: Int, type: String, header: Int)? {
            guard p + 8 <= d.count else { return nil }
            var size = (0..<4).reduce(0) { $0 << 8 | Int(d[p + $1]) }
            let type = String(decoding: d[(p + 4)..<(p + 8)], as: UTF8.self)
            var header = 8
            if size == 1 {
                guard p + 16 <= d.count else { return nil }
                size = (8..<16).reduce(0) { $0 << 8 | Int(d[p + $1]) }
                header = 16
            }
            return size >= header ? (size, type, header) : nil
        }
        guard let ftyp = box(start, 0), ftyp.type == "ftyp" else { throw Failure(Words.t("This is not a CR3.")) }
        var d = try head(url, ftyp.size + 16)
        guard let moov = box(d, ftyp.size), moov.type == "moov", moov.size < 16 << 20 else {
            throw Failure(Words.t("The photo's details could not be found."))
        }
        d = try head(url, ftyp.size + moov.size + 64)
        var layout = Layout(kind: .cr3)
        var cmt: [String: TIFFBlock] = [:]
        var cmt4Payload: Range<Int>?

        func walk(_ from: Int, _ to: Int) {
            var p = from
            while p < to, let b = box(d, p), p + b.size <= to {
                let inner = p + b.header
                switch b.type {
                case "trak", "mdia":
                    walk(inner, p + b.size)
                case "mvhd", "tkhd", "mdhd":
                    let width = d[inner] == 1 ? 8 : 4
                    for at in [inner + 4, inner + 4 + width] where at + width <= d.count {
                        let value = (0..<width).reduce(Int64(0)) { $0 << 8 | Int64(d[at + $1]) }
                        layout.containerDates.append((at, width, value))
                    }
                case "uuid" where Array(d[inner..<min(inner + 16, d.count)]) == canonUUID:
                    var q = inner + 16
                    while q < p + b.size, let c = box(d, q), q + c.size <= p + b.size {
                        if c.type.hasPrefix("CMT"), let t = TIFFBlock(Array(d[(q + c.header)..<(q + c.size)]), base: q + c.header) {
                            cmt[c.type] = t
                            if c.type == "CMT4" { cmt4Payload = 0..<(c.size - c.header) }
                        }
                        q += c.size
                    }
                default: break
                }
                p += b.size
            }
        }
        walk(ftyp.size + moov.header, ftyp.size + moov.size)

        if let t = cmt["CMT1"], let o = t.firstIFD, let ifd = t.ifd(at: o) {
            layout.ifd0 = (t, o)
            if let e = ifd.entry(0x0132) { layout.dates.append(t.base + e.data) }
        }
        if let t = cmt["CMT2"], let o = t.firstIFD, let ifd = t.ifd(at: o) {
            layout.exif = (t, o)
            for tag in [0x9003, 0x9004] { if let e = ifd.entry(tag), e.size >= 19 { layout.dates.append(t.base + e.data) } }
        }
        if let t = cmt["CMT3"], let o = t.firstIFD { layout.maker = (t, o) }
        if let t = cmt["CMT4"], let o = t.firstIFD, let room = cmt4Payload { layout.gps = (t, o, o..<room.upperBound) }

        // The picture: the media data after moov.
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } ?? 0
        var p = ftyp.size + moov.size
        while true {
            let h = try headAt(url, p, 16)
            guard let b = box(h, 0) else { break }
            if b.type == "mdat" { layout.picture = (p + b.header)..<min(p + b.size, size); break }
            p += b.size
        }
        return layout
    }

    /// Canon's preview box in a CR3 or CRM, holding a JPG.
    static let previewUUID: [UInt8] = [0xEA, 0xF4, 0x2B, 0x5E, 0x1C, 0x98, 0x4B, 0x88, 0xB9, 0xFB, 0xB7, 0xDC, 0x40, 0x6E, 0x4D, 0x16]

    /// A video (0.33.0): every box at the top read by its header alone, the
    /// moov and Canon's boxes read whole, wherever they sit (a camera may put
    /// moov after the media data). Kept apart from `cr3`, which stays as it was.
    static func movie(_ url: URL) throws -> Layout {
        func box(_ d: [UInt8], _ p: Int) -> (size: Int, type: String, header: Int)? {
            guard p >= 0, p + 8 <= d.count else { return nil }
            var size = (0..<4).reduce(0) { $0 << 8 | Int(d[p + $1]) }
            let type = String(decoding: d[(p + 4)..<(p + 8)], as: UTF8.self)
            var header = 8
            if size == 1 {
                guard p + 16 <= d.count else { return nil }
                size = (8..<16).reduce(0) { $0 << 8 | Int(d[p + $1]) }
                header = 16
            }
            if size == 0 { size = Int.max }   // to the end of what holds it
            return size >= header ? (size, type, header) : nil
        }
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } ?? 0
        var layout = Layout(kind: .movie)
        var cmt: [String: TIFFBlock] = [:]
        var cmt4Payload: Range<Int>?
        var thumb: Range<Int>?

        /// The first JPG start in the first bytes of a box's payload, to its end.
        func jpeg(_ d: [UInt8], _ base: Int, _ from: Int, _ to: Int) -> Range<Int>? {
            var i = from
            while i + 3 <= min(to, from + 64) {
                if d[i] == 0xFF, d[i + 1] == 0xD8, d[i + 2] == 0xFF { return (base + i)..<(base + to) }
                i += 1
            }
            return nil
        }

        // `d` holds a box read whole, which starts at `base` in the file.
        func walk(_ d: [UInt8], _ base: Int, _ from: Int, _ to: Int) {
            var p = from
            while p < to, let b = box(d, p) {
                let end = b.size == Int.max ? to : p + b.size
                guard end <= to else { break }
                let inner = p + b.header
                switch b.type {
                case "trak", "mdia", "udta":
                    walk(d, base, inner, end)
                case "mvhd", "tkhd", "mdhd":
                    guard inner < d.count else { break }
                    let width = d[inner] == 1 ? 8 : 4
                    func value(_ at: Int, _ w: Int) -> Int64? {
                        guard at + w <= d.count else { return nil }
                        return (0..<w).reduce(Int64(0)) { $0 << 8 | Int64(d[at + $1]) }
                    }
                    for at in [inner + 4, inner + 4 + width] {
                        if let v = value(at, width) { layout.containerDates.append((base + at, width, v)) }
                    }
                    if b.type == "mvhd", let scale = value(inner + 4 + 2 * width, 4), scale > 0,
                       let length = value(inner + 8 + 2 * width, width) {
                        layout.duration = Double(length) / Double(scale)
                        if let start = value(inner + 4, width), start > 0 {
                            layout.created = Date(timeIntervalSince1970: Double(start) - 2_082_844_800)
                        }
                    }
                case "uuid" where inner + 16 <= d.count && Array(d[inner..<(inner + 16)]) == canonUUID:
                    var q = inner + 16
                    while q < end, let c = box(d, q), c.size != Int.max, q + c.size <= end {
                        if c.type.hasPrefix("CMT"), let t = TIFFBlock(Array(d[(q + c.header)..<(q + c.size)]), base: base + q + c.header) {
                            cmt[c.type] = t
                            if c.type == "CMT4" { cmt4Payload = 0..<(c.size - c.header) }
                        }
                        if c.type == "THMB" { thumb = jpeg(d, base, q + c.header, q + c.size) }
                        q += c.size
                    }
                case "uuid" where inner + 16 <= d.count && Array(d[inner..<(inner + 16)]) == previewUUID:
                    var q = inner + 16 + 8
                    while q < end, let c = box(d, q), c.size != Int.max, q + c.size <= end {
                        if c.type == "PRVW" { layout.preview = jpeg(d, base, q + c.header, q + c.size) }
                        q += c.size
                    }
                default: break
                }
                if b.size == Int.max { break }
                p = end
            }
        }

        var p = 0
        while p + 8 <= fileSize {
            let h = try headAt(url, p, 16)
            guard let b = box(h, 0) else { break }
            let size = b.size == Int.max ? fileSize - p : b.size
            if p == 0, b.type != "ftyp" { throw Failure(Words.t("This video could not be read.")) }
            switch b.type {
            case "moov", "uuid":
                guard size < 64 << 20 else {
                    if b.type == "moov" { throw Failure(Words.t("This video could not be read.")) }
                    break
                }
                let d = try headAt(url, p, size)
                guard d.count == size else { throw Failure(Words.t("This video could not be read.")) }
                if b.type == "moov" { walk(d, p, b.header, size) } else { walk(d, p, 0, size) }
            case "mdat":
                if layout.picture == nil { layout.picture = (p + b.header)..<min(p + size, fileSize) }
            default: break
            }
            p += size
        }
        guard layout.picture != nil else { throw Failure(Words.t("This video could not be read.")) }
        if layout.preview == nil { layout.preview = thumb }

        if let t = cmt["CMT1"], let o = t.firstIFD, let ifd = t.ifd(at: o) {
            layout.ifd0 = (t, o)
            if let e = ifd.entry(0x0132) { layout.dates.append(t.base + e.data) }
        }
        if let t = cmt["CMT2"], let o = t.firstIFD, let ifd = t.ifd(at: o) {
            layout.exif = (t, o)
            for tag in [0x9003, 0x9004] { if let e = ifd.entry(tag), e.size >= 19 { layout.dates.append(t.base + e.data) } }
        }
        if let t = cmt["CMT3"], let o = t.firstIFD { layout.maker = (t, o) }
        if let t = cmt["CMT4"], let o = t.firstIFD, let room = cmt4Payload { layout.gps = (t, o, o..<room.upperBound) }
        return layout
    }

    static func headAt(_ url: URL, _ offset: Int, _ count: Int) throws -> [UInt8] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        return [UInt8](try handle.read(upToCount: count) ?? Data())
    }

    // MARK: The location

    /// The new GPS block, written over the old one and the room after it.
    func gpsPatch(_ p: Position) throws -> NativeMetadata.Patch {
        guard let gps else { throw Failure(Words.t("This photo has no room for a location.")) }
        let t = gps.tiff
        guard let old = t.ifd(at: gps.ifd) else { throw Failure(Words.t("This photo has no room for a location.")) }
        // The room must hold only the old block and zeros: never write over
        // anything else the camera put there.
        let mine = old.used
        for i in gps.room where !mine.contains(where: { $0.contains(i) }) {
            guard t.bytes[i] == 0 else { throw Failure(Words.t("This photo's room for a location holds something else.")) }
        }
        for r in mine where !(r.lowerBound >= gps.room.lowerBound && r.upperBound <= gps.room.upperBound) {
            throw Failure(Words.t("This photo's location is not where Squeaky can write it."))
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: p.moment)
        let hundredths = Int(((Double(c.second ?? 0) + Double(c.nanosecond ?? 0) / 1e9) * 100).rounded(.down))

        // Degrees, minutes, and seconds to the millionth, carried properly.
        func dms(_ v: Double) -> [(Int, Int)] {
            let micro = Int((abs(v) * 3600 * 1_000_000).rounded())
            return [(micro / 3_600_000_000, 1), (micro % 3_600_000_000 / 60_000_000, 1), (micro % 60_000_000, 1_000_000)]
        }
        enum Value { case bytes(Int, [UInt8]), rationals([(Int, Int)]) }
        var fields: [(Int, Value)] = [
            (0x0000, .bytes(1, [2, 3, 0, 0])),
            (0x0001, .bytes(2, Array((p.lat < 0 ? "S" : "N").utf8) + [0])),
            (0x0002, .rationals(dms(p.lat))),
            (0x0003, .bytes(2, Array((p.lon < 0 ? "W" : "E").utf8) + [0])),
            (0x0004, .rationals(dms(p.lon))),
        ]
        if let alt = p.alt {
            fields.append((0x0005, .bytes(1, [alt < 0 ? 1 : 0])))
            fields.append((0x0006, .rationals([(Int((abs(alt) * 100).rounded()), 100)])))
        }
        fields += [
            (0x0007, .rationals([(c.hour ?? 0, 1), (c.minute ?? 0, 1), (hundredths, 100)])),
            (0x0012, .bytes(2, Array("WGS-84".utf8) + [0])),
            (0x001B, .bytes(7, Array("ASCII".utf8) + [0, 0, 0] + Array(Saver.processingMethod.utf8))),
            (0x001D, .bytes(2, Array(String(format: "%04d:%02d:%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0).utf8) + [0])),
        ]

        let start = gps.room.lowerBound
        var table: [UInt8] = []
        var data: [UInt8] = []
        let dataStart = start + 2 + 12 * fields.count + 4
        t.put16(fields.count, &table)
        for (tag, value) in fields {
            var raw: [UInt8] = []
            let type: Int, count: Int
            switch value {
            case .bytes(let ty, let b): type = ty; count = b.count; raw = b
            case .rationals(let list):
                type = 5; count = list.count
                for (n, d) in list { t.put32(n, &raw); t.put32(d, &raw) }
            }
            t.put16(tag, &table)
            t.put16(type, &table)
            t.put32(count, &table)
            if raw.count <= 4 {
                table += raw + [UInt8](repeating: 0, count: 4 - raw.count)
            } else {
                if data.count % 2 == 1 { data.append(0) }
                t.put32(dataStart + data.count, &table)
                data += raw
            }
        }
        t.put32(old.next, &table)
        var bytes = table + data
        guard bytes.count <= gps.room.count else { throw Failure(Words.t("This photo's room for a location is too small.")) }
        // Cleared to the end of the old block's room, so nothing old is left.
        let clearTo = max(bytes.count, (mine.map(\.upperBound).max() ?? start) - start)
        bytes += [UInt8](repeating: 0, count: clearTo - bytes.count)
        return NativeMetadata.Patch(offset: t.base + start, bytes: bytes)
    }

    // MARK: The dates

    func datePatches(_ shift: Int) throws -> [NativeMetadata.Patch] {
        var out: [NativeMetadata.Patch] = []
        let all = [ifd0?.0, exif?.0].compactMap { $0 }
        for at in dates {
            guard let t = all.first(where: { at >= $0.base && at + 19 <= $0.base + $0.bytes.count }) else { continue }
            let i = at - t.base
            let was = String(decoding: t.bytes[i..<(i + 19)], as: UTF8.self)
            guard let moved = Saver.shiftedProbe(was, by: shift), moved.utf8.count == 19 else {
                throw Failure(Words.t("The dates could not be corrected."))
            }
            out.append(.init(offset: at, bytes: Array(moved.utf8)))
        }
        guard !out.isEmpty else { throw Failure(Words.t("The dates could not be corrected.")) }
        return out + (try containerPatches(shift))
    }

    /// A CR3's container dates moved too, as ExifTool moves them on the Mac;
    /// one left at zero by the camera stays zero.
    func containerPatches(_ shift: Int) throws -> [NativeMetadata.Patch] {
        containerDates.compactMap { item in
            let (offset, width, value) = item
            guard value != 0 else { return nil }
            let moved = value + Int64(shift)
            guard moved > 0 else { return nil }
            var out: [UInt8] = []
            for k in stride(from: width - 1, through: 0, by: -1) { out.append(UInt8(truncatingIfNeeded: moved >> (8 * Int64(k)))) }
            return NativeMetadata.Patch(offset: offset, bytes: out)
        }
    }
}
