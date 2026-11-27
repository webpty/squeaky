import Foundation

/// What was read from each photo on a card, kept so that the next time the card
/// is opened only the photos not seen before are read (0.34.12, David: "since
/// you know this card had 1900 photos last time, only 20 are new"). A photo is
/// taken as the same one when its place on the card, its size and its
/// modification date all match; anything else is read again.
public struct CardReadMemory: Sendable {
    /// Raised whenever what is read from a photo changes, so every card is read
    /// afresh once rather than trusting what an older reader made of it.
    public static let reader = 1

    /// A file's size and modification date, as the card reports them.
    public struct Stamp: Codable, Equatable, Sendable {
        public var size: Int64
        public var modified: Double
    }

    struct Entry: Codable, Sendable {
        var stamp: Stamp
        var photo: ScannedPhoto
    }

    struct Kept: Codable {
        var reader: Int
        var entries: [String: Entry]
    }

    let file: URL

    /// One file per card, in `folder`.
    public init(folder: URL, card: String) {
        let safe = card.map { $0.isLetter || $0.isNumber || $0 == "-" ? String($0) : "_" }.joined()
        file = folder.appendingPathComponent("cardread", isDirectory: true).appendingPathComponent("\(safe).json")
    }

    /// The file's place on the card: the same whichever path the card is reached by.
    public static func place(_ url: URL, root: URL) -> String {
        let path = url.standardizedFileURL.path
        let base = root.standardizedFileURL.path
        let prefix = base.hasSuffix("/") ? base : base + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    public static func stamp(_ url: URL) -> Stamp? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize else { return nil }
        return Stamp(size: Int64(size), modified: values.contentModificationDate?.timeIntervalSince1970 ?? 0)
    }

    private func load() -> [String: Entry] {
        guard let data = try? Data(contentsOf: file),
              let kept = try? JSONDecoder().decode(Kept.self, from: data),
              kept.reader == Self.reader else { return [:] }
        return kept.entries
    }

    /// The photos already read, by place, each pointed at its file now; the
    /// files still to be read; and every file's stamp, for `keep`. With
    /// `ignoring`, nothing counts as read: every file is to be read again.
    public func remembered(_ files: [URL], root: URL, ignoring: Bool = false) -> (known: [String: ScannedPhoto], toRead: [URL], stamps: [String: Stamp]) {
        let entries = ignoring ? [:] : load()
        var known: [String: ScannedPhoto] = [:]
        var toRead: [URL] = []
        var stamps: [String: Stamp] = [:]
        for url in files {
            let place = Self.place(url, root: root)
            let stamp = Self.stamp(url)
            if let stamp { stamps[place] = stamp }
            if let stamp, let entry = entries[place], entry.stamp == stamp {
                var photo = entry.photo
                photo.url = url
                known[place] = photo
            } else {
                toRead.append(url)
            }
        }
        return (known, toRead, stamps)
    }

    /// What was read from the card, forgotten (the card removed in Settings).
    public func forget() {
        try? FileManager.default.removeItem(at: file)
    }

    /// Keeps what was read from these photos. Photos remembered before and
    /// still on the card (`present`, by place) are kept too, so a card read for
    /// someone else, JPGs only, does not forget its raws; anything no longer on
    /// the card is forgotten.
    public func keep(_ photos: [ScannedPhoto], stamps: [String: Stamp], root: URL, present: Set<String>) {
        var entries = load().filter { present.contains($0.key) }
        for photo in photos {
            let place = Self.place(photo.url, root: root)
            guard let stamp = stamps[place] else { continue }
            entries[place] = Entry(stamp: stamp, photo: photo)
        }
        guard let data = try? JSONEncoder().encode(Kept(reader: Self.reader, entries: entries)) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}

/// What looking for an offset code found in each photo (0.34.13, David: a card
/// with no new photos needs no looking): the moment the code showed, or nothing.
/// Kept by the photo's key, so a photo is looked at once, whichever card it is on.
public struct OffsetCodeMemory: Sendable {
    let file: URL

    public init(folder: URL) {
        file = folder.appendingPathComponent("offsetcodes.json")
    }

    /// Photo key to the code's moment in seconds since 1970, or nil when the
    /// photo held no code.
    public func load() -> [String: Double?] {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: Double?].self, from: $0) } ?? [:]
    }

    public func add(_ found: [String: Double?]) {
        guard !found.isEmpty else { return }
        var all = load()
        for (k, v) in found { all[k] = v }
        guard let data = try? JSONEncoder().encode(all) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}
