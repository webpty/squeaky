import Foundation

/// The kinds of file a camera card holds that Squeaky imports.
public enum PhotoKinds {
    public static let photos: Set<String> = ["cr3", "cr2", "nef", "nrw", "arw", "dng", "jpg", "jpeg", "heic", "heif", "hif"]
    /// Videos, on the phone and the Mac alike (0.33.0, David); CRM is Canon's RAW video.
    public static let videos: Set<String> = ["mp4", "mov", "crm"]
    public static let extensions: Set<String> = photos.union(videos)

    /// A file Squeaky lists from a card: a photo or a video.
    public static func isPhoto(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }

    public static func isVideo(_ url: URL) -> Bool { videos.contains(url.pathExtension.lowercased()) }
    /// A RAW video: copied and sent, never played or added to Photos.
    public static func isRawVideo(_ url: URL) -> Bool { url.pathExtension.lowercased() == "crm" }
}

/// One photo found on a card, as its camera recorded it.
public struct ScannedPhoto: Identifiable, Codable, Equatable, Sendable {
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
    /// The camera wrote a location of its own.
    public var hasLocation: Bool
    /// That location, signed (south and west negative), when there is one.
    public var ownLat: Double?
    public var ownLon: Double?
    /// The camera's software version when the photo was taken: "1.1.1".
    /// Read only for the newest photo of each model on a card.
    public var firmware: String?
    /// The lens as the camera names it, and its serial number.
    public var lens: String?
    public var lensSerial: String?
    /// Canon's drive mode (its ContinuousDrive value), for finding bursts;
    /// nil when the camera records none, or before 0.29.6.
    public var drive: Int?
    /// A video's length in seconds; nil for a photo (0.33.0).
    public var duration: Double?
    public var isVideo: Bool { PhotoKinds.isVideo(url) }

    public init(url: URL, fileName: String, size: Int64, taken: String?, subSeconds: String?, zone: String?, model: String?,
                hasLocation: Bool = false, ownLat: Double? = nil, ownLon: Double? = nil, firmware: String? = nil,
                lens: String? = nil, lensSerial: String? = nil) {
        self.url = url
        self.fileName = fileName
        self.size = size
        self.taken = taken
        self.subSeconds = subSeconds
        self.zone = zone
        self.model = model
        self.hasLocation = hasLocation
        self.ownLat = ownLat
        self.ownLon = ownLon
        self.firmware = firmware
        self.lens = lens
        self.lensSerial = lensSerial
    }

    /// Name, size and time taken: what says two photos are the same one.
    public var key: String {
        "\(fileName.lowercased())|\(size)|\(taken ?? "")\(subSeconds.map { ".\($0)" } ?? "")"
    }
}

/// Reads every photo in a folder and below, through ExifTool. Reading only:
/// nothing on the card is ever written.
public struct PhotoScanner: Sendable {

    /// A real position: both numbers there, and not the 0, 0 some cameras write.
    static func hasLocation(_ row: [String: Any]) -> Bool {
        guard let lat = (row["GPSLatitude"] as? NSNumber)?.doubleValue,
              let lon = (row["GPSLongitude"] as? NSNumber)?.doubleValue else { return false }
        return !(lat == 0 && lon == 0)
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

/// One file per person in Squeaky's History folder, written whole.
public struct HistoryStoreFolder: HistoryStorePort {
    public let folder: URL

    public init(folder: URL) {
        self.folder = folder
    }

    public static func standard() -> HistoryStoreFolder {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return HistoryStoreFolder(folder: support.appendingPathComponent("Squeaky/History", isDirectory: true))
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

public enum ImportStatus: Codable, Equatable, Sendable {
    case new
    case alreadyImported
    /// New, but its camera is not on this person's list.
    case unknownCamera
}

public struct ImportRow: Identifiable, Codable, Equatable, Sendable {
    public var photo: ScannedPhoto
    public var status: ImportStatus
    public var ticked: Bool
    /// Where the photo goes, once matched.
    public var placement: Placement?
    /// Chosen for a photo in review: import it all the same, with no location.
    public var withoutLocation = false
    public var id: String { photo.id }

    public init(photo: ScannedPhoto, status: ImportStatus, ticked: Bool, placement: Placement? = nil, withoutLocation: Bool = false) {
        self.photo = photo
        self.status = status
        self.ticked = ticked
        self.placement = placement
        self.withoutLocation = withoutLocation
    }

    public var needsReview: Bool {
        if case .review = placement { return true }
        return false
    }

    /// Dump, tag and save (David, 17 October 2026): every new photo is saved,
    /// with its location when it has one and without when it cannot be placed.
    /// Sorting happens later, elsewhere.
    public var willImport: Bool {
        ticked && placement != nil
    }
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

/// What a copy is called when saved: the photo's own name, except that every
/// JPEG ends in ".jpg" (David's rule, 16 October 2026). Raw and HEIF files
/// keep their names exactly.
public enum CopyName {
    public static func forCopy(_ fileName: String) -> String {
        let ext = (fileName as NSString).pathExtension
        guard ["jpg", "jpeg"].contains(ext.lowercased()) else { return fileName }
        return (fileName as NSString).deletingPathExtension + ".jpg"
    }
}

/// Whether a folder chosen in the Files list is an SD card (0.34.14, David): a
/// camera's card holds a DCIM folder. The card itself, its DCIM folder or a
/// folder inside DCIM is taken; any other folder, a NAS folder say, is refused.
public enum SDCard {
    public static func looksLikeCard(_ url: URL) -> Bool {
        if url.pathComponents.contains(where: { $0.uppercased() == "DCIM" }) { return true }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return names.contains { $0.uppercased() == "DCIM" }
    }
}
