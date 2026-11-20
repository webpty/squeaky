import Foundation

/// One photo that reached the NAS and passed the check on arrival, kept for
/// good. Removing the Mac copy later goes by this alone: Squeaky never looks
/// at the NAS again, where photos may be sorted, renamed or deleted
/// (David, 5 November 2026).
public struct SentRecord: Codable, Equatable, Sendable {
    public var personId: UUID
    /// The copy on this Mac.
    public var localPath: String
    /// Its place under the person's NAS folder, as it landed: "2026.10.29/IMG_0001.jpg".
    public var nasPath: String
    public var sent: Date
    /// The Mac copy as it was sent: a copy changed since is not the one on the NAS.
    public var size: Int64
    public var modified: Date
    /// When the Mac copy was removed, or found gone.
    public var removed: Date?
    /// The space Squeaky freed removing it; nil when it was found gone.
    public var freed: Int64?

    public init(personId: UUID, localPath: String, nasPath: String, sent: Date, size: Int64, modified: Date) {
        self.personId = personId
        self.localPath = localPath
        self.nasPath = nasPath
        self.sent = sent
        self.size = size
        self.modified = modified
    }

    /// The Mac copy's size and modification date now; nil when it is gone.
    public static func stamp(_ path: String) -> (size: Int64, modified: Date)? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attributes[.size] as? NSNumber)?.int64Value,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        return (size, modified)
    }
}

/// How long a copy saved on this Mac stays once it is on the NAS.
public enum KeepOnMac: String, CaseIterable, Sendable {
    /// The same as the Mac's own Trash: time to use the photos while fresh.
    case thirtyDays
    case untilOnNAS
    case always

    public var label: String {
        switch self {
        case .thirtyDays: return "30 days after reaching the NAS"
        case .untilOnNAS: return "Until on the NAS"
        case .always: return "Always"
        }
    }

    /// Days after the send, or nil to keep them.
    public var days: Int? {
        switch self {
        case .thirtyDays: return 30
        case .untilOnNAS: return 0
        case .always: return nil
        }
    }
}

public protocol SentLogPort: Sendable {
    func load() throws -> [SentRecord]
    func add(_ records: [SentRecord]) throws
    func save(_ records: [SentRecord]) throws
}

/// `sent.jsonl` in Squeaky's folder in Application Support: a line per photo,
/// added to as photos go, written whole only when copies are removed.
public struct SentLogFile: SentLogPort {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public static func standard() -> SentLogFile {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return SentLogFile(url: support.appendingPathComponent("Squeaky/sent.jsonl"))
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    public func load() throws -> [SentRecord] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        // A line cut short by a crash is passed over, the rest kept.
        return try Data(contentsOf: url).split(separator: UInt8(ascii: "\n")).compactMap {
            try? decoder.decode(SentRecord.self, from: Data($0))
        }
    }

    public func add(_ records: [SentRecord]) throws {
        guard !records.isEmpty else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = Data()
        for record in records {
            data.append(try Self.encoder.encode(record))
            data.append(UInt8(ascii: "\n"))
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: url, options: .atomic)
        }
    }

    public func save(_ records: [SentRecord]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = Data()
        for record in records {
            data.append(try Self.encoder.encode(record))
            data.append(UInt8(ascii: "\n"))
        }
        try data.write(to: url, options: .atomic)
    }
}

/// Which Mac copies can go now: on the NAS for long enough, nothing still
/// to do with them, and unchanged since they were sent.
public enum MacTidy {
    public struct Plan: Equatable, Sendable {
        /// Indexes into the records: copies to remove.
        public var remove: [Int] = []
        /// Copies already gone from the Mac: only marked.
        public var gone: [Int] = []
    }

    public static func plan(_ records: [SentRecord], keep: KeepOnMac, busy: Set<String>, now: Date = Date(),
                            stamp: (String) -> (size: Int64, modified: Date)? = SentRecord.stamp) -> Plan {
        var plan = Plan()
        guard let days = keep.days else { return plan }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        // A copy sent more than once counts by its latest send.
        var latest: [String: Int] = [:]
        for (i, r) in records.enumerated() where latest[r.localPath].map({ records[$0].sent <= r.sent }) ?? true {
            latest[r.localPath] = i
        }
        for i in latest.values.sorted() {
            let r = records[i]
            guard r.removed == nil, r.sent <= cutoff, !busy.contains(r.localPath) else { continue }
            guard let now = stamp(r.localPath) else {
                plan.gone.append(i)
                continue
            }
            // Changed since it was sent: that is not the copy on the NAS.
            guard now.size == r.size, abs(now.modified.timeIntervalSince(r.modified)) < 0.01 else { continue }
            plan.remove.append(i)
        }
        return plan
    }
}
