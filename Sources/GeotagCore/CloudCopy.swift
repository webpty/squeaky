import Foundation

/// This Mac's settings and its list of photos read, copied into Geotag's
/// folder in iCloud Drive whenever they change (0.20.0, David, 5 November
/// 2026). Step one of two: nothing is read back yet. The NAS password and
/// the track service key stay in this Mac's keychain and never go.
///
///     Geotag/settings.plist      the settings shared between David's Macs
///     Geotag/people.json         people, cameras and lenses
///     Geotag/temperatures.json
///     Geotag/History/<person id>.json
///     Geotag/Macs/<this Mac>.json   its name and when it last copied
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

    public struct What {
        public var settings: [String: Any]
        public var people: URL
        public var temperatures: URL
        public var history: URL
        public var macName: String

        public init(settings: [String: Any], people: URL, temperatures: URL, history: URL, macName: String) {
            self.settings = settings
            self.people = people
            self.temperatures = temperatures
            self.history = history
            self.macName = macName
        }
    }

    /// Copies what changed since the last time. True when anything was written.
    @discardableResult
    public static func copy(_ what: What, into folder: URL, now: Date = Date()) throws -> Bool {
        let fm = FileManager.default
        try fm.createDirectory(at: folder.appendingPathComponent("History"), withIntermediateDirectories: true)
        try fm.createDirectory(at: folder.appendingPathComponent("Macs"), withIntermediateDirectories: true)
        var wrote = false

        let settingsURL = folder.appendingPathComponent("settings.plist")
        let there = (try? Data(contentsOf: settingsURL))
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? NSDictionary }
        if there != (what.settings as NSDictionary) {
            let data = try PropertyListSerialization.data(fromPropertyList: what.settings, format: .xml, options: 0)
            try data.write(to: settingsURL, options: .atomic)
            wrote = true
        }

        var files: [(URL, URL)] = [
            (what.people, folder.appendingPathComponent("people.json")),
            (what.temperatures, folder.appendingPathComponent("temperatures.json")),
        ]
        for name in (try? fm.contentsOfDirectory(atPath: what.history.path)) ?? [] where name.hasSuffix(".json") {
            files.append((what.history.appendingPathComponent(name), folder.appendingPathComponent("History/\(name)")))
        }
        for (from, to) in files {
            guard let data = try? Data(contentsOf: from) else { continue }
            if (try? Data(contentsOf: to)) == data { continue }
            try data.write(to: to, options: .atomic)
            wrote = true
        }

        let macURL = folder.appendingPathComponent("Macs/\(macId).json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let known = (try? Data(contentsOf: macURL)).flatMap { try? decoder.decode(Mac.self, from: $0) }
        // Its time moves only with a copy, or a new name or version.
        if wrote || known == nil || known?.name != what.macName || known?.version != appVersion {
            try encoder.encode(Mac(name: what.macName, copied: now, version: appVersion)).write(to: macURL, options: .atomic)
        }
        return wrote
    }

    /// The Macs that have copied into the folder, by name.
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
