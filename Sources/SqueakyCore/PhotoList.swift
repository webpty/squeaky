import Foundation

/// The Photos list as it last stood, kept through a restart: only Clear
/// photos or the next card empties it (David, 6 November 2026).
public struct KeptPhotoList: Codable, Equatable, Sendable {
    public var personId: UUID?
    public var rows: [ImportRow]
    /// Each row's outcome, by row id, once saving reached it.
    public var results: [String: SaveResult]

    public init(personId: UUID?, rows: [ImportRow], results: [String: SaveResult]) {
        self.personId = personId
        self.rows = rows
        self.results = results
    }
}

/// `photos.json` beside `queue.json`, written whole; no list, no file.
public struct PhotoListFile: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// `photos.json` beside `queue.json`; beside a test's "mo-queue.json", "mo-photos.json".
    public static func beside(_ queue: URL) -> PhotoListFile {
        let stem = queue.deletingPathExtension().lastPathComponent
        let name = stem == "queue" ? "photos.json" : stem.replacingOccurrences(of: "queue", with: "") + "photos.json"
        return PhotoListFile(url: queue.deletingLastPathComponent().appendingPathComponent(name))
    }

    public func load() -> KeptPhotoList? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(KeptPhotoList.self, from: data)
    }

    public func save(_ list: KeptPhotoList?) throws {
        guard let list, !list.rows.isEmpty else {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            return
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(list).write(to: url, options: .atomic)
    }
}
