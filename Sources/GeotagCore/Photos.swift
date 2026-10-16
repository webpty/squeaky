import Foundation

/// The kinds of file a camera card holds that Geotag imports.
public enum PhotoKinds {
    public static let extensions: Set<String> = ["cr3", "cr2", "nef", "nrw", "arw", "dng", "jpg", "jpeg", "heic", "heif", "hif"]

    public static func isPhoto(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }
}

/// One photo found on a card, as its camera recorded it.
public struct ScannedPhoto: Identifiable, Equatable, Sendable {
    public var id: String { url.path }
    public var url: URL
    public var fileName: String
    public var size: Int64
    /// The camera's own clock reading, "YYYY:MM:DD HH:MM:SS".
    public var taken: String?
    public var subSeconds: String?
    /// The zone the camera wrote, such as "-05:00".
    public var zone: String?
    public var model: String?

    public init(url: URL, fileName: String, size: Int64, taken: String?, subSeconds: String?, zone: String?, model: String?) {
        self.url = url
        self.fileName = fileName
        self.size = size
        self.taken = taken
        self.subSeconds = subSeconds
        self.zone = zone
        self.model = model
    }

    /// Name, size and time taken: what says two photos are the same one.
    public var key: String {
        "\(fileName.lowercased())|\(size)|\(taken ?? "")\(subSeconds.map { ".\($0)" } ?? "")"
    }
}

/// Reads every photo in a folder and below, through ExifTool. Reading only:
/// nothing on the card is ever written.
public struct PhotoScanner: Sendable {
    let exifTool: ExifTool

    public init(exifTool: ExifTool) {
        self.exifTool = exifTool
    }

    /// Every photo file, in name order, hidden folders left out.
    public static func files(in folder: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                                                           options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [URL] = []
        for case let url as URL in walker where PhotoKinds.isPhoto(url) {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { out.append(url) }
        }
        return out.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// The photos' details, a batch at a time; `progress` hears how many are read.
    public func scan(_ files: [URL], progress: @Sendable (Int) -> Void) throws -> [ScannedPhoto] {
        var out: [ScannedPhoto] = []
        var done = 0
        for start in stride(from: 0, to: files.count, by: 100) {
            let batch = Array(files[start..<min(start + 100, files.count)])
            let data = try exifTool.run(["-j", "-q", "-q", "-fast2", "-charset", "filename=utf8",
                                         "-DateTimeOriginal", "-SubSecTimeOriginal", "-OffsetTimeOriginal", "-OffsetTime", "-Model"]
                                        + batch.map(\.path))
            let rows = (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
            var byPath: [String: [String: Any]] = [:]
            for row in rows { if let path = row["SourceFile"] as? String { byPath[path] = row } }
            for url in batch {
                let row = byPath[url.path] ?? [:]
                func text(_ key: String) -> String? {
                    guard let v = row[key] else { return nil }
                    let s = "\(v)".trimmingCharacters(in: .whitespacesAndNewlines)
                    return s.isEmpty ? nil : s
                }
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(Int64.init) ?? 0
                out.append(ScannedPhoto(url: url, fileName: url.lastPathComponent, size: size,
                                        taken: text("DateTimeOriginal"), subSeconds: text("SubSecTimeOriginal"),
                                        zone: text("OffsetTimeOriginal") ?? text("OffsetTime"), model: text("Model")))
            }
            done += batch.count
            progress(done)
        }
        return out
    }
}

// MARK: - History

/// A photo once imported for a person.
public struct HistoryEntry: Codable, Equatable, Sendable {
    public var fileName: String
    public var size: Int64
    public var taken: String?
    public var subSeconds: String?
    public var imported: Date

    public init(fileName: String, size: Int64, taken: String?, subSeconds: String?, imported: Date) {
        self.fileName = fileName
        self.size = size
        self.taken = taken
        self.subSeconds = subSeconds
        // Whole seconds, so it reads back exactly as written.
        self.imported = Date(timeIntervalSince1970: imported.timeIntervalSince1970.rounded())
    }

    public var key: String {
        "\(fileName.lowercased())|\(size)|\(taken ?? "")\(subSeconds.map { ".\($0)" } ?? "")"
    }
}

public protocol HistoryStorePort: Sendable {
    func load(_ personId: UUID) throws -> [HistoryEntry]
    func save(_ personId: UUID, _ entries: [HistoryEntry]) throws
}

/// One file per person in Geotag's History folder, written whole.
public struct HistoryStoreFolder: HistoryStorePort {
    public let folder: URL

    public init(folder: URL) {
        self.folder = folder
    }

    public static func standard() -> HistoryStoreFolder {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return HistoryStoreFolder(folder: support.appendingPathComponent("Geotag/History", isDirectory: true))
    }

    private func url(_ personId: UUID) -> URL {
        folder.appendingPathComponent("\(personId.uuidString).json")
    }

    public func load(_ personId: UUID) throws -> [HistoryEntry] {
        let file = url(personId)
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode([HistoryEntry].self, from: Data(contentsOf: file))
    }

    public func save(_ personId: UUID, _ entries: [HistoryEntry]) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(entries).write(to: url(personId), options: .atomic)
    }
}

// MARK: - The import list

public enum ImportStatus: Equatable, Sendable {
    case new
    case alreadyImported
    /// New, but its camera is not on this person's list.
    case unknownCamera
}

public struct ImportRow: Identifiable, Equatable, Sendable {
    public var photo: ScannedPhoto
    public var status: ImportStatus
    public var ticked: Bool
    public var id: String { photo.id }
}

public enum ImportList {
    /// Each photo against the person's history and cameras. What was imported
    /// before starts unticked; everything else ticked.
    public static func rows(_ photos: [ScannedPhoto], history: [HistoryEntry], book: PeopleBook, personId: UUID) -> [ImportRow] {
        let seen = Set(history.map(\.key))
        return photos.map { photo in
            if seen.contains(photo.key) { return ImportRow(photo: photo, status: .alreadyImported, ticked: false) }
            let known = photo.model.flatMap { book.camera(personId: personId, model: $0) } != nil
            return ImportRow(photo: photo, status: known ? .new : .unknownCamera, ticked: true)
        }
    }
}
