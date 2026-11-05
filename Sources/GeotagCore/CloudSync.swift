import CryptoKit
import Foundation

/// Keeps this Mac and Geotag's iCloud folder the same (0.21.0, David,
/// 5 November 2026): whichever side changed since they last agreed is
/// copied to the other; both changed, the newer wins. The lists of photos
/// read are combined, so a photo read on any Mac counts on all of them.
/// Save folders stay on each Mac.
public enum CloudSync {
    /// Which way one piece goes.
    public enum Way: Equatable, Sendable {
        case same, push, pull, wait
    }

    /// `local` and `cloud` are fingerprints, nil when that side has none;
    /// `seen` is where they last agreed.
    public static func way(local: String?, cloud: String?, seen: String?, localNewer: Bool) -> Way {
        switch (local, cloud) {
        case (nil, nil): return .same
        case (_, nil): return .push
        case (nil, _): return .pull
        default:
            if local == cloud { return .same }
            if local == seen { return .pull }
            if cloud == seen { return .push }
            return localNewer ? .push : .pull
        }
    }

    public static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Where both sides last agreed, kept on this Mac.
    public struct Seen: Codable, Equatable, Sendable {
        public var people: String?
        public var temperatures: String?
        public var settings: String?
        public init() {}
    }

    public struct Local: Sendable {
        public var people: URL
        public var temperatures: URL
        public var history: URL
        public var macName: String

        public init(people: URL, temperatures: URL, history: URL, macName: String) {
            self.people = people
            self.temperatures = temperatures
            self.history = history
            self.macName = macName
        }
    }

    public struct Outcome: @unchecked Sendable {
        public var seen: Seen
        public var peopleTaken = false
        public var temperaturesTaken = false
        /// The settings to put in place of this Mac's, when iCloud's were newer.
        public var settingsTaken: [String: Any]?
        public var historyTaken = false
        public var wrote = false
        public var macs: [CloudCopy.Mac] = []
    }

    /// A file iCloud has not brought down yet: asked for, and nothing done with it this time.
    static func waiting(_ url: URL) -> Bool {
        let placeholder = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud")
        guard !FileManager.default.fileExists(atPath: url.path), FileManager.default.fileExists(atPath: placeholder.path) else { return false }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        return true
    }

    static func modified(_ url: URL) -> Date {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date) ?? .distantPast
    }

    static func plist(_ settings: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: settings, format: .xml, options: 0)
    }

    public static func sync(_ local: Local, settings: [String: Any], seen: Seen, into folder: URL, now: Date = Date()) throws -> Outcome {
        let fm = FileManager.default
        try fm.createDirectory(at: folder.appendingPathComponent("History"), withIntermediateDirectories: true)
        try fm.createDirectory(at: folder.appendingPathComponent("Macs"), withIntermediateDirectories: true)
        var out = Outcome(seen: seen)

        // People: iCloud's copy has no save folders; this Mac keeps its own.
        let cloudPeople = PeopleStoreFile(url: folder.appendingPathComponent("people.json"))
        let localPeople = PeopleStoreFile(url: local.people)
        if !waiting(cloudPeople.url) {
            let mine = try localPeople.load()
            var shared = mine
            for i in (shared?.people ?? []).indices { shared?.people[i].saveFolder = nil }
            let theirs = try? cloudPeople.load()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .secondsSince1970
            func print(_ book: PeopleBook?) -> String? {
                // Nobody yet is no list: a fresh install takes iCloud's.
                guard var book, !book.people.isEmpty else { return nil }
                for i in book.people.indices { book.people[i].saveFolder = nil }
                return (try? encoder.encode(book)).map(fingerprint)
            }
            let l = print(shared), c = print(theirs)
            switch way(local: l, cloud: c, seen: seen.people, localNewer: modified(local.people) > modified(cloudPeople.url)) {
            case .push:
                try cloudPeople.save(shared!)
                out.wrote = true
                out.seen.people = l
            case .pull:
                var taken = theirs!
                for i in taken.people.indices {
                    taken.people[i].saveFolder = mine?.person(taken.people[i].id)?.saveFolder
                }
                try localPeople.save(taken)
                out.peopleTaken = true
                out.seen.people = c
            case .same, .wait:
                out.seen.people = l
            }
        }

        // Camera temperatures, the file whole.
        let cloudTemps = folder.appendingPathComponent("temperatures.json")
        if !waiting(cloudTemps) {
            let l = (try? Data(contentsOf: local.temperatures)).map(fingerprint)
            let cData = try? Data(contentsOf: cloudTemps)
            let c = cData.map(fingerprint)
            switch way(local: l, cloud: c, seen: seen.temperatures, localNewer: modified(local.temperatures) > modified(cloudTemps)) {
            case .push:
                try Data(contentsOf: local.temperatures).write(to: cloudTemps, options: .atomic)
                out.wrote = true
                out.seen.temperatures = l
            case .pull:
                try fm.createDirectory(at: local.temperatures.deletingLastPathComponent(), withIntermediateDirectories: true)
                try cData!.write(to: local.temperatures, options: .atomic)
                out.temperaturesTaken = true
                out.seen.temperatures = c
            case .same, .wait:
                out.seen.temperatures = l
            }
        }

        // The shared settings. Both changed at once: this Mac's win.
        let cloudSettings = folder.appendingPathComponent("settings.plist")
        if !waiting(cloudSettings) {
            let theirs = (try? Data(contentsOf: cloudSettings))
                .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
            let l = settings.isEmpty ? nil : fingerprint(try plist(settings))
            let c = theirs.flatMap { $0.isEmpty ? nil : try? fingerprint(plist($0)) }
            switch way(local: l, cloud: c, seen: seen.settings, localNewer: true) {
            case .push:
                try plist(settings).write(to: cloudSettings, options: .atomic)
                out.wrote = true
                out.seen.settings = l
            case .pull:
                out.settingsTaken = theirs
                out.seen.settings = c
            case .same, .wait:
                out.seen.settings = l
            }
        }

        // The lists of photos read: combined, both ways.
        let cloudHistory = folder.appendingPathComponent("History")
        let names = Set(((try? fm.contentsOfDirectory(atPath: local.history.path)) ?? []) + ((try? fm.contentsOfDirectory(atPath: cloudHistory.path)) ?? []))
            .filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }
        for name in names.sorted() {
            guard let id = UUID(uuidString: String(name.dropLast(5))) else { continue }
            let mine = HistoryStoreFolder(folder: local.history), theirs = HistoryStoreFolder(folder: cloudHistory)
            if waiting(cloudHistory.appendingPathComponent(name)) { continue }
            let a = (try? mine.load(id)) ?? [], b = (try? theirs.load(id)) ?? []
            var keys = Set(a.map(\.key))
            let both = a + b.filter { keys.insert($0.key).inserted }
            if both.count != a.count {
                try fm.createDirectory(at: local.history, withIntermediateDirectories: true)
                try mine.save(id, both)
                out.historyTaken = true
            }
            if both.count != b.count || !fm.fileExists(atPath: cloudHistory.appendingPathComponent(name).path) {
                try theirs.save(id, both)
                out.wrote = true
            }
        }

        // This Mac, for the header: when it last synced, at least every ten minutes.
        let macURL = folder.appendingPathComponent("Macs/\(CloudCopy.macId).json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let known = (try? Data(contentsOf: macURL)).flatMap { try? decoder.decode(CloudCopy.Mac.self, from: $0) }
        let changed = out.wrote || out.peopleTaken || out.temperaturesTaken || out.settingsTaken != nil || out.historyTaken
        if changed || known == nil || known?.name != local.macName || known?.version != appVersion
            || now.timeIntervalSince(known?.copied ?? .distantPast) >= 600 {
            try encoder.encode(CloudCopy.Mac(name: local.macName, copied: now, version: appVersion)).write(to: macURL, options: .atomic)
        }
        out.macs = CloudCopy.macs(in: folder)
        return out
    }
}
