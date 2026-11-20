import Foundation

public enum WatchTrackError: Error, LocalizedError {
    case empty

    public var errorDescription: String? {
        Words.t("The watch sent a track with no positions.")
    }
}

/// One part of a track as the watch sends it (Watch 0.2.0):
/// `{ k: "part", id: start seconds, n: part, of: parts, pts: points, end: seconds, d: base64 }`.
/// Each point is 14 bytes, big-endian: time (s, int32), latitude and longitude
/// (degrees x 10^7, int32), altitude (m, int16; -32768 when unknown).
public struct WatchPart: Equatable, Sendable {
    public var trackId: Int
    public var index: Int
    public var count: Int
    public var points: Int
    public var data: Data

    public init(trackId: Int, index: Int, count: Int, points: Int, data: Data) {
        self.trackId = trackId
        self.index = index
        self.count = count
        self.points = points
        self.data = data
    }

    /// The watch's message, as the Garmin kit hands it over; nil for anything else.
    public init?(message: Any) {
        guard let d = message as? [String: Any], d["k"] as? String == "part",
              let id = (d["id"] as? NSNumber)?.intValue, let n = (d["n"] as? NSNumber)?.intValue,
              let of = (d["of"] as? NSNumber)?.intValue, n >= 0, of > 0, n < of else { return nil }
        let text = d["d"] as? String ?? ""
        guard let data = text.isEmpty ? Data() : Data(base64Encoded: text) else { return nil }
        self.init(trackId: id, index: n, count: of, points: (d["pts"] as? NSNumber)?.intValue ?? 0, data: data)
    }

    public static let pointSize = 14
    public static let noAltitude = -32768

    /// The points in a run of parts' bytes, in order.
    public static func decode(_ bytes: Data) -> TrackPoints {
        var points = TrackPoints(t: [], lat: [], lon: [], alt: [])
        let b = [UInt8](bytes)
        var i = 0
        func int32(_ at: Int) -> Int {
            Int(Int32(bitPattern: UInt32(b[at]) << 24 | UInt32(b[at + 1]) << 16 | UInt32(b[at + 2]) << 8 | UInt32(b[at + 3])))
        }
        while i + pointSize <= b.count {
            let t = int32(i)
            let alt = Int(Int16(bitPattern: UInt16(b[i + 12]) << 8 | UInt16(b[i + 13])))
            // A second the watch wrote twice is kept once.
            if let last = points.t.last, t <= last { i += pointSize; continue }
            points.t.append(t)
            points.lat.append(Double(int32(i + 4)) / 10_000_000)
            points.lon.append(Double(int32(i + 8)) / 10_000_000)
            points.alt.append(alt == noAltitude ? nil : Double(alt))
            i += pointSize
        }
        return points
    }
}

/// Parts of the tracks coming in from the watch, kept as files until each
/// track is whole, so a dropped link or a closed app resumes where it stopped.
/// `<folder>/<track id>/<part>.bin`.
public struct WatchInbox: Sendable {
    public let folder: URL

    public init(folder: URL) {
        self.folder = folder
    }

    /// ~/Library/Application Support/Squeaky/Watch
    public static func standard() -> WatchInbox {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return WatchInbox(folder: support.appendingPathComponent("Squeaky/Watch", isDirectory: true))
    }

    private func trackFolder(_ id: Int) -> URL {
        folder.appendingPathComponent(String(id), isDirectory: true)
    }

    /// Keeps a part; answers how many of the track's parts are here.
    @discardableResult
    public func keep(_ part: WatchPart) throws -> Int {
        let dir = trackFolder(part.trackId)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try part.data.write(to: dir.appendingPathComponent("\(part.index).bin"), options: .atomic)
        return received(part.trackId, of: part.count)
    }

    public func received(_ id: Int, of count: Int) -> Int {
        (0..<count).filter { FileManager.default.fileExists(atPath: trackFolder(id).appendingPathComponent("\($0).bin").path) }.count
    }

    /// The whole track once every part is here, else nil.
    public func whole(_ id: Int, of count: Int) -> TrackPoints? {
        var bytes = Data()
        for k in 0..<count {
            guard let d = try? Data(contentsOf: trackFolder(id).appendingPathComponent("\(k).bin")) else { return nil }
            bytes.append(d)
        }
        return WatchPart.decode(bytes)
    }

    /// The library's id for a watch track: its start, as the watch numbers it.
    public static func libraryId(_ trackId: Int) -> String {
        "watch-\(trackId)"
    }
}
