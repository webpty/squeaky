import Foundation

/// What the library keeps on this Mac.
public protocol TrackStorePort: Sendable {
    func loadIndex() throws -> [Track]
    func saveIndex(_ tracks: [Track]) throws
    func loadPoints(_ id: String) throws -> TrackPoints?
    func savePoints(_ id: String, _ points: TrackPoints) throws
}

/// Tracks kept as files in a folder: `index.json` and `points/<id>.json`.
/// Files are written whole and replaced, never removed.
public struct TrackStoreFolder: TrackStorePort {
    public let folder: URL

    public init(folder: URL) {
        self.folder = folder
    }

    /// ~/Library/Application Support/Squeaky/Tracks
    public static func standard() -> TrackStoreFolder {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return TrackStoreFolder(folder: support.appendingPathComponent("Squeaky/Tracks", isDirectory: true))
    }

    private var indexURL: URL { folder.appendingPathComponent("index.json") }

    private func pointsURL(_ id: String) -> URL {
        folder.appendingPathComponent("points", isDirectory: true).appendingPathComponent("\(id).json")
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    public func loadIndex() throws -> [Track] {
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode([Track].self, from: Data(contentsOf: indexURL))
    }

    public func saveIndex(_ tracks: [Track]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        try write(encoder.encode(tracks), to: indexURL)
    }

    public func loadPoints(_ id: String) throws -> TrackPoints? {
        let url = pointsURL(id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(TrackPoints.self, from: Data(contentsOf: url))
    }

    public func savePoints(_ id: String, _ points: TrackPoints) throws {
        try write(JSONEncoder().encode(points), to: pointsURL(id))
    }
}
