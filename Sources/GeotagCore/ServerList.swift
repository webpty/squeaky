import Foundation

/// The photos already saved from cards, kept on the server in each person's
/// folder so every Mac and phone knows them (David, 16 November 2026): a
/// "~Geotag" folder (hidden ".geotag" before 0.29.24) with one list per device, so two never write over
/// each other. Each device writes its own whole list; a card being read is
/// checked against all of them.
public enum ServerList {
    /// Visible (0.29.23): the phone reaches the NAS through the Files app,
    /// which hides a folder whose name starts with a dot, so ".geotag" looked
    /// absent there and the Mac's list was never read.
    /// "~Geotag" (0.29.24, David): the tilde keeps it at the top of the folder's list.
    public static let folderName = "~Geotag"
    static let oldFolderName = ".geotag"

    /// Once per folder: the files of the hidden ".geotag" moved to "~Geotag".
    public static func moveFromHidden(in personFolder: URL) {
        let fm = FileManager.default
        let old = personFolder.appendingPathComponent(oldFolderName, isDirectory: true)
        let new = personFolder.appendingPathComponent(folderName, isDirectory: true)
        guard let names = try? fm.contentsOfDirectory(atPath: old.path), !names.isEmpty else { return }
        try? fm.createDirectory(at: new, withIntermediateDirectories: true)
        for name in names where name.hasSuffix(".json") {
            let to = new.appendingPathComponent(name)
            if !fm.fileExists(atPath: to.path) { try? fm.moveItem(at: old.appendingPathComponent(name), to: to) }
        }
        if ((try? fm.contentsOfDirectory(atPath: old.path)) ?? []).isEmpty { try? fm.removeItem(at: old) }
    }

    public static func file(in personFolder: URL, device: String) -> URL {
        let safe = device.replacingOccurrences(of: "/", with: "-")
        return personFolder.appendingPathComponent(folderName, isDirectory: true).appendingPathComponent("saved-\(safe).json")
    }

    /// This device's whole list, written over its last one.
    public static func write(_ entries: [HistoryEntry], into personFolder: URL, device: String) throws {
        let url = file(in: personFolder, device: device)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        try put(encoder.encode(entries), at: url)
    }

    /// Bytes written through a coordinated write, as the Files app expects
    /// of a file provider (the NAS on the phone), where a plain write can
    /// wait on it for ever (0.29.21).
    public static func put(_ bytes: Data, at url: URL) throws {
        var result: Result<Void, Error> = .success(())
        var coordination: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordination) { writable in
            result = Result { try bytes.write(to: writable, options: .atomic) }
        }
        if let coordination { throw coordination }
        try result.get()
    }

    /// This device's cameras and their offsets (0.29.1).
    public static func writeCameras(_ cameras: [Camera], into personFolder: URL, device: String) throws {
        let safe = device.replacingOccurrences(of: "/", with: "-")
        let url = personFolder.appendingPathComponent(folderName, isDirectory: true).appendingPathComponent("cameras-\(safe).json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        try put(encoder.encode(cameras), at: url)
    }

    /// For each camera model, the one whose offset was set most recently on any device.
    public static func readCameras(from personFolder: URL) -> [Camera] {
        let folder = personFolder.appendingPathComponent(folderName, isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        var newest: [String: Camera] = [:]
        for name in names.sorted() where name.hasPrefix("cameras-") && name.hasSuffix(".json") {
            guard let bytes = try? data(folder.appendingPathComponent(name)),
                  let list = try? decoder.decode([Camera].self, from: bytes) else { continue }
            for camera in list where camera.offsetSeconds != nil {
                if let known = newest[camera.model], known.offsetDate >= camera.offsetDate { continue }
                newest[camera.model] = camera
            }
        }
        return newest.values.sorted { $0.model < $1.model }
    }

    /// The device that wrote last into the folder, and when (0.29.3), and
    /// how many photos the shared list holds (0.29.27).
    public struct LastSave: Equatable, Sendable {
        public var byPhone: Bool
        public var at: Date
        public var count: Int
        public init(byPhone: Bool, at: Date, count: Int = 0) {
            self.byPhone = byPhone
            self.at = at
            self.count = count
        }
    }

    // MARK: One list per person (0.29.27, David: "i want a synced list. everyone their own is not a sync")

    /// "saved.json": every photo saved by any device for the person.
    public struct SavedFile: Codable, Sendable {
        public var entries: [HistoryEntry]
        public var updatedAt: Date
        /// "mac" or "iphone".
        public var updatedBy: String
        public init(entries: [HistoryEntry], updatedAt: Date, updatedBy: String) {
            self.entries = entries
            self.updatedAt = updatedAt
            self.updatedBy = updatedBy
        }
    }

    /// "cameras.json": each camera's newest offset, from any device.
    public struct CamerasFile: Codable, Sendable {
        public var cameras: [Camera]
        public var updatedAt: Date
        public var updatedBy: String
        public init(cameras: [Camera], updatedAt: Date, updatedBy: String) {
            self.cameras = cameras
            self.updatedAt = updatedAt
            self.updatedBy = updatedBy
        }
    }

    /// What the folder holds: the shared lists, and the per-device files of
    /// 0.29.2 to 0.29.26, still to be merged in.
    public struct Shared: Sendable {
        public var saved: SavedFile?
        public var cameras: CamerasFile?
        public var oldEntries: [HistoryEntry] = []
        public var oldCameras: [Camera] = []
        public var oldFiles: [String] = []
        public var problem: String?

        /// Every photo listed, shared and old, once each.
        public var allEntries: [HistoryEntry] { ServerList.union(saved?.entries ?? [], oldEntries) }
        /// For each camera model, the newest offset.
        public var allCameras: [Camera] { ServerList.newest((cameras?.cameras ?? []) + oldCameras) }
    }

    public static func union(_ a: [HistoryEntry], _ b: [HistoryEntry]) -> [HistoryEntry] {
        var seen = Set<String>()
        return (a + b).filter { seen.insert($0.key).inserted }
    }

    public static func newest(_ cameras: [Camera]) -> [Camera] {
        var by: [String: Camera] = [:]
        for c in cameras where c.offsetSeconds != nil {
            if let known = by[c.model], known.offsetDate >= c.offsetDate { continue }
            by[c.model] = c
        }
        return by.values.sorted { $0.model < $1.model }
    }

    static let coder: (JSONEncoder, JSONDecoder) = {
        let e = JSONEncoder(), d = JSONDecoder()
        e.dateEncodingStrategy = .secondsSince1970
        d.dateDecodingStrategy = .secondsSince1970
        e.outputFormatting = [.sortedKeys]
        return (e, d)
    }()

    /// The two lists as kept at the buffer server (0.31.8): the same files as on the NAS.
    public static func encode(_ saved: SavedFile) throws -> Data { try coder.0.encode(saved) }
    public static func encode(_ cameras: CamerasFile) throws -> Data { try coder.0.encode(cameras) }
    public static func decodeSaved(_ data: Data) throws -> SavedFile { try coder.1.decode(SavedFile.self, from: data) }
    public static func decodeCameras(_ data: Data) throws -> CamerasFile { try coder.1.decode(CamerasFile.self, from: data) }

    public static func readShared(from personFolder: URL) -> Shared {
        let folder = personFolder.appendingPathComponent(folderName, isDirectory: true)
        var out = Shared()
        let decoder = coder.1
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        } catch {
            if (error as NSError).code != NSFileReadNoSuchFileError { out.problem = error.localizedDescription }
            return out
        }
        for name in names.sorted() where name.hasSuffix(".json") {
            let url = folder.appendingPathComponent(name)
            do {
                let bytes = try data(url)
                switch name {
                case "saved.json": out.saved = try decoder.decode(SavedFile.self, from: bytes)
                case "cameras.json": out.cameras = try decoder.decode(CamerasFile.self, from: bytes)
                default:
                    if name.hasPrefix("saved-") {
                        out.oldEntries += try decoder.decode([HistoryEntry].self, from: bytes)
                        out.oldFiles.append(name)
                    } else if name.hasPrefix("cameras-") {
                        out.oldCameras += try decoder.decode([Camera].self, from: bytes)
                        out.oldFiles.append(name)
                    }
                }
            } catch {
                out.problem = "\(name): \(error.localizedDescription)"
            }
        }
        return out
    }

    public static func writeShared(_ saved: SavedFile, _ cameras: CamerasFile, into personFolder: URL) throws {
        let folder = personFolder.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try put(coder.0.encode(saved), at: folder.appendingPathComponent("saved.json"))
        try put(coder.0.encode(cameras), at: folder.appendingPathComponent("cameras.json"))
    }

    /// The per-device files, once merged into the shared lists.
    public static func removeOld(_ names: [String], in personFolder: URL) {
        let folder = personFolder.appendingPathComponent(folderName, isDirectory: true)
        for name in names { try? FileManager.default.removeItem(at: folder.appendingPathComponent(name)) }
    }

    public static func lastSave(in personFolder: URL) -> LastSave? {
        let folder = personFolder.appendingPathComponent(folderName, isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var newest: LastSave?
        for name in names where name.hasSuffix(".json") && (name.hasPrefix("saved-") || name.hasPrefix("cameras-")) {
            guard let at = (try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(name).path))?[.modificationDate] as? Date
            else { continue }
            if let known = newest, known.at >= at { continue }
            newest = LastSave(byPhone: name.contains("-iphone-"), at: at)
        }
        return newest
    }

    /// Every device's list, together; a list that cannot be read is left out.
    public static func read(from personFolder: URL) -> [HistoryEntry] { readChecked(from: personFolder).entries }

    /// A file's bytes, fetched the way the Files app expects: a coordinated
    /// read makes a file provider (the NAS on the phone) bring the file down
    /// first, where a plain read can wait on it for ever (0.29.18).
    public static func data(_ url: URL) throws -> Data {
        var result: Result<Data, Error> = .failure(CocoaError(.fileReadUnknown))
        var coordination: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordination) { readable in
            result = Result { try Data(contentsOf: readable) }
        }
        if let coordination { throw coordination }
        return try result.get()
    }

    /// The sync files in the folder, for saying which one is being read.
    public static func files(in personFolder: URL) -> [String] {
        let folder = personFolder.appendingPathComponent(folderName, isDirectory: true)
        return ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasSuffix(".json") && ($0.hasPrefix("saved-") || $0.hasPrefix("cameras-")) }.sorted()
    }

    /// The same, with why a list could not be read, when one could not (0.29.11).
    public static func readChecked(from personFolder: URL) -> (entries: [HistoryEntry], problem: String?) {
        let folder = personFolder.appendingPathComponent(folderName, isDirectory: true)
        var problem: String?
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        } catch {
            // No sync folder yet is no problem; anything else is said.
            if (error as NSError).code != NSFileReadNoSuchFileError { problem = error.localizedDescription }
            names = []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        var seen = Set<String>()
        var out: [HistoryEntry] = []
        for name in names.sorted() where name.hasPrefix("saved-") && name.hasSuffix(".json") {
            do {
                let list = try decoder.decode([HistoryEntry].self, from: data(folder.appendingPathComponent(name)))
                for entry in list where seen.insert(entry.key).inserted { out.append(entry) }
            } catch {
                problem = "\(name): \(error.localizedDescription)"
            }
        }
        return (out, problem)
    }
}
