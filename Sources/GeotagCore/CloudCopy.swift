import Foundation

/// Geotag's folder in iCloud Drive, shared by David's Macs: the settings
/// came from it from 0.21.0 (step one, 0.20.0, only copied them there).
/// The NAS password and the track service key stay in each Mac's keychain
/// and never go.
///
///     Geotag/settings.plist      the settings shared between David's Macs
///     Geotag/people.json         people, cameras and lenses; no save folders
///     Geotag/temperatures.json
///     Geotag/History/<person id>.json
///     Geotag/Macs/<this Mac>.json   its name and when it last synced
public enum CloudCopy {
    /// Settings that are the same on every one of David's Macs. The rest stay
    /// on each Mac: whose Mac it is, photos at once, how long copies are kept,
    /// pausing, the step times and the setup.
    public static let sharedKeys = [
        "appearance", "breakMinutes", "cardPeople", "clockFixMinutes", "clockReminders", "clock24", "dateOrder",
        "mapCredit", "maxGapSeconds", "nasAddress", "nasBackupAddress", "nasUser", "openOnCard", "trackServiceAddress",
    ]

    /// Geotag's folder in iCloud Drive; nil when iCloud Drive is off on this Mac.
    public static var standardFolder: URL? {
        let drive = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        var folder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: drive.path, isDirectory: &folder), folder.boolValue else { return nil }
        return drive.appendingPathComponent("Geotag", isDirectory: true)
    }

    /// This Mac, the same after every restart and rename.
    public static var macId: String {
        var uuid: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        var wait = timespec(tv_sec: 0, tv_nsec: 0)
        guard gethostuuid(&uuid, &wait) == 0 else { return "unknown" }
        return UUID(uuid: uuid).uuidString
    }

    public struct Mac: Codable, Equatable, Sendable {
        public var name: String
        public var copied: Date
        public var version: String
    }

    /// The Macs that have synced with the folder, by name.
    public static func macs(in folder: URL) -> [Mac] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let dir = folder.appendingPathComponent("Macs")
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix(".json") }
            .compactMap { (try? Data(contentsOf: dir.appendingPathComponent($0))).flatMap { try? decoder.decode(Mac.self, from: $0) } }
            .sorted { $0.name < $1.name }
    }
}
