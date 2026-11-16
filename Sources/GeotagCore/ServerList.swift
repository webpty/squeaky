import Foundation

/// The photos already saved from cards, kept on the server in each person's
/// folder so every Mac and phone knows them (David, 16 November 2026): a
/// hidden ".geotag" folder with one list per device, so two never write over
/// each other. Each device writes its own whole list; a card being read is
/// checked against all of them.
public enum ServerList {
    public static let folderName = ".geotag"

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
        try encoder.encode(entries).write(to: url, options: .atomic)
    }

    /// This device's cameras and their offsets (0.29.1).
    public static func writeCameras(_ cameras: [Camera], into personFolder: URL, device: String) throws {
        let safe = device.replacingOccurrences(of: "/", with: "-")
        let url = personFolder.appendingPathComponent(folderName, isDirectory: true).appendingPathComponent("cameras-\(safe).json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(cameras).write(to: url, options: .atomic)
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

    /// The device that wrote last into the folder, and when (0.29.3).
    public struct LastSave: Equatable, Sendable {
        public var byPhone: Bool
        public var at: Date
        public init(byPhone: Bool, at: Date) {
            self.byPhone = byPhone
            self.at = at
        }
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
