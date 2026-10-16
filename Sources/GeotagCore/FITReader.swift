import Foundation

/// Reads the positions out of a Garmin FIT activity file: every `record`
/// message's time, latitude, longitude and altitude. Nothing else is decoded.
enum FITReader {
    /// FIT counts seconds from 1989-12-31 00:00:00 UTC.
    static let fitEpochOffset = 631_065_600

    private struct Field {
        let number: UInt8
        let size: Int
    }

    private struct Definition {
        let global: UInt16
        let bigEndian: Bool
        let fields: [Field]
        let developerBytes: Int
    }

    static func read(_ data: Data, fileName: String) throws -> (name: String?, points: TrackPoints) {
        let bytes = [UInt8](data)
        var points = TrackPoints(t: [], lat: [], lon: [], alt: [])
        var offset = 0
        var readOne = false
        // A file may hold several FIT files one after another.
        while offset + 12 <= bytes.count {
            guard let end = try? readFile(bytes, at: offset, into: &points) else { break }
            readOne = true
            offset = end
        }
        guard readOne else { throw TrackFileError.unreadable(fileName) }
        return (nil, points)
    }

    /// Reads one FIT file starting at `start`; returns where the next one would begin.
    private static func readFile(_ b: [UInt8], at start: Int, into points: inout TrackPoints) throws -> Int {
        let headerSize = Int(b[start])
        guard headerSize == 12 || headerSize == 14, start + headerSize <= b.count,
              b[start + 8] == 0x2E, b[start + 9] == 0x46, b[start + 10] == 0x49, b[start + 11] == 0x54 else {
            throw TrackFileError.unreadable("")
        }
        let dataSize = Int(UInt32(b[start + 4]) | UInt32(b[start + 5]) << 8 | UInt32(b[start + 6]) << 16 | UInt32(b[start + 7]) << 24)
        var i = start + headerSize
        let end = min(b.count, i + dataSize)

        var definitions: [UInt8: Definition] = [:]
        var lastTimestamp: UInt32 = 0

        while i < end {
            let header = b[i]
            i += 1
            if header & 0x80 != 0 {
                // Compressed timestamp header: a data message carrying 5 bits of time.
                let local = (header >> 5) & 0x03
                let offsetBits = UInt32(header & 0x1F)
                var ts = (lastTimestamp & ~UInt32(0x1F)) + offsetBits
                if offsetBits < (lastTimestamp & 0x1F) { ts += 0x20 }
                lastTimestamp = ts
                guard let def = definitions[local] else { throw TrackFileError.unreadable("") }
                i = try readData(b, at: i, end: end, def: def, timestamp: &lastTimestamp, compressed: true, into: &points)
            } else if header & 0x40 != 0 {
                // Definition message.
                let local = header & 0x0F
                let hasDeveloper = header & 0x20 != 0
                guard i + 5 <= end else { throw TrackFileError.unreadable("") }
                let bigEndian = b[i + 1] == 1
                let global = bigEndian ? UInt16(b[i + 2]) << 8 | UInt16(b[i + 3]) : UInt16(b[i + 3]) << 8 | UInt16(b[i + 2])
                let count = Int(b[i + 4])
                i += 5
                guard i + count * 3 <= end else { throw TrackFileError.unreadable("") }
                var fields: [Field] = []
                for f in 0..<count {
                    fields.append(Field(number: b[i + f * 3], size: Int(b[i + f * 3 + 1])))
                }
                i += count * 3
                var developerBytes = 0
                if hasDeveloper {
                    guard i < end else { throw TrackFileError.unreadable("") }
                    let devCount = Int(b[i])
                    i += 1
                    guard i + devCount * 3 <= end else { throw TrackFileError.unreadable("") }
                    for f in 0..<devCount { developerBytes += Int(b[i + f * 3 + 1]) }
                    i += devCount * 3
                }
                definitions[local] = Definition(global: global, bigEndian: bigEndian, fields: fields, developerBytes: developerBytes)
            } else {
                let local = header & 0x0F
                guard let def = definitions[local] else { throw TrackFileError.unreadable("") }
                i = try readData(b, at: i, end: end, def: def, timestamp: &lastTimestamp, compressed: false, into: &points)
            }
        }
        // Two bytes of checksum follow the data.
        return end + 2
    }

    private static func readData(_ b: [UInt8], at start: Int, end: Int, def: Definition, timestamp: inout UInt32,
                                 compressed: Bool, into points: inout TrackPoints) throws -> Int {
        let size = def.fields.reduce(0) { $0 + $1.size } + def.developerBytes
        guard start + size <= end else { throw TrackFileError.unreadable("") }

        func unsigned(_ at: Int, _ n: Int) -> UInt64 {
            var v: UInt64 = 0
            for k in 0..<n {
                let byte = UInt64(b[at + (def.bigEndian ? k : n - 1 - k)])
                v = v << 8 | byte
            }
            return v
        }

        var lat: Int32?
        var lon: Int32?
        var altitude: Double?
        var enhanced: Double?
        var at = start
        for f in def.fields {
            switch (f.number, f.size) {
            case (253, 4):
                let v = UInt32(unsigned(at, 4))
                if v != 0xFFFF_FFFF { timestamp = v }
            case (0, 4) where def.global == 20:
                let v = UInt32(unsigned(at, 4))
                if v != 0x7FFF_FFFF { lat = Int32(bitPattern: v) }
            case (1, 4) where def.global == 20:
                let v = UInt32(unsigned(at, 4))
                if v != 0x7FFF_FFFF { lon = Int32(bitPattern: v) }
            case (2, 2) where def.global == 20:
                let v = UInt16(unsigned(at, 2))
                if v != 0xFFFF { altitude = Double(v) / 5 - 500 }
            case (78, 4) where def.global == 20:
                let v = UInt32(unsigned(at, 4))
                if v != 0xFFFF_FFFF { enhanced = Double(v) / 5 - 500 }
            default:
                break
            }
            at += f.size
        }

        if def.global == 20, let lat, let lon, timestamp != 0 {
            let degrees = 180.0 / 2_147_483_648.0
            points.t.append(Int(timestamp) + fitEpochOffset)
            points.lat.append(Double(lat) * degrees)
            points.lon.append(Double(lon) * degrees)
            points.alt.append(enhanced ?? altitude)
        }
        return start + size
    }
}
