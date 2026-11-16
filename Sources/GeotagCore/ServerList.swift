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
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)),
                  let list = try? decoder.decode([Camera].self, from: data) else { continue }
            for camera in list where camera.offsetSeconds != nil {
                if let known = newest[camera.model], known.offsetDate >= camera.offsetDate { continue }
                newest[camera.model] = camera
            }
        }
        return newest.values.sorted { $0.model < $1.model }
    }

    /// Every device's list, together; a list that cannot be read is left out.
    public static func read(from personFolder: URL) -> [HistoryEntry] {
        let folder = personFolder.appendingPathComponent(folderName, isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        var seen = Set<String>()
        var out: [HistoryEntry] = []
        for name in names.sorted() where name.hasPrefix("saved-") && name.hasSuffix(".json") {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)),
                  let list = try? decoder.decode([HistoryEntry].self, from: data) else { continue }
            for entry in list where seen.insert(entry.key).inserted { out.append(entry) }
        }
        return out
    }
}
