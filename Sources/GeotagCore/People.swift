import Foundation
import ImageIO

public struct Person: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    /// Where this person's photos are saved on this Mac.
    public var saveFolder: String?
    /// Their folder on the NAS.
    public var nasFolder: String?

    public init(id: UUID = UUID(), name: String, saveFolder: String? = nil, nasFolder: String? = nil) {
        self.id = id
        self.name = name
        self.saveFolder = saveFolder
        self.nasFolder = nasFolder
    }
}

/// The time zone a camera's clock is set to.
public enum CameraZone: Equatable, Sendable {
    /// The camera writes its zone into each photo.
    case fromPhoto
    /// The camera writes none; its clock is set to this zone.
    case fixed(String)
    case notSet
}

public struct Camera: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var personId: UUID
    /// As the photos record it, which is how a photo finds its camera.
    public var model: String
    public var zone: CameraZone
    /// Seconds the camera's clock is ahead of the real time; negative when
    /// behind. Nil until set: its photos then go to the review list.
    public var offsetSeconds: Int?
    /// The newest software version its photos have shown, and when the photo
    /// that showed it was taken, by the camera's clock.
    public var firmware: String?
    public var firmwareSeen: Date?
    /// Every offset code photo, oldest first: the clock's drift is worked out
    /// from them, and photos are matched with it (David, 1 November 2026).
    public var readings: [ClockReading] = []

    public init(id: UUID = UUID(), personId: UUID, model: String, zone: CameraZone, offsetSeconds: Int? = nil) {
        self.id = id
        self.personId = personId
        self.model = model
        self.zone = zone
        self.offsetSeconds = offsetSeconds
    }

    /// The offset follows the readings, drift included, while it is the last
    /// reading's: an offset typed or slid by hand since takes over.
    public var followsReadings: Bool {
        guard let last = readings.last else { return false }
        return offsetSeconds == Int(last.offset.rounded())
    }

    /// A new offset code photo: kept with the others, and the offset set from it.
    public mutating func add(_ reading: ClockReading) {
        readings.removeAll { abs($0.at.timeIntervalSince(reading.at)) < 60 }
        readings.append(reading)
        readings.sort { $0.at < $1.at }
        offsetSeconds = Int((readings.last?.offset ?? reading.offset).rounded())
    }

    /// Ready for matching: both the zone and the offset are known.
    public var isReady: Bool { zone != .notSet && offsetSeconds != nil }

    private enum CodingKeys: String, CodingKey { case id, personId, model, zone, zoneId, offsetSeconds, firmware, firmwareSeen, readings }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        personId = try c.decode(UUID.self, forKey: .personId)
        model = try c.decode(String.self, forKey: .model)
        offsetSeconds = try c.decodeIfPresent(Int.self, forKey: .offsetSeconds)
        firmware = try c.decodeIfPresent(String.self, forKey: .firmware)
        firmwareSeen = try c.decodeIfPresent(Date.self, forKey: .firmwareSeen)
        readings = try c.decodeIfPresent([ClockReading].self, forKey: .readings) ?? []
        switch try c.decode(String.self, forKey: .zone) {
        case "photo": zone = .fromPhoto
        case "fixed": zone = .fixed(try c.decode(String.self, forKey: .zoneId))
        default: zone = .notSet
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(personId, forKey: .personId)
        try c.encode(model, forKey: .model)
        try c.encodeIfPresent(offsetSeconds, forKey: .offsetSeconds)
        try c.encodeIfPresent(firmware, forKey: .firmware)
        try c.encodeIfPresent(firmwareSeen, forKey: .firmwareSeen)
        if !readings.isEmpty { try c.encode(readings, forKey: .readings) }
        switch zone {
        case .fromPhoto: try c.encode("photo", forKey: .zone)
        case .fixed(let id): try c.encode("fixed", forKey: .zone); try c.encode(id, forKey: .zoneId)
        case .notSet: try c.encode("unset", forKey: .zone)
        }
    }
}

/// Everyone, their cameras and the lenses their photos name, as kept on this Mac.
public struct PeopleBook: Codable, Equatable, Sendable {
    public var people: [Person]
    public var cameras: [Camera]
    public var lenses: [Lens]

    public init(people: [Person] = [], cameras: [Camera] = [], lenses: [Lens] = []) {
        self.people = people
        self.cameras = cameras
        self.lenses = lenses
    }

    private enum CodingKeys: String, CodingKey { case people, cameras, lenses }

    /// A book from before 0.14.1 has no lenses.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        people = try c.decode([Person].self, forKey: .people)
        cameras = try c.decode([Camera].self, forKey: .cameras)
        lenses = try c.decodeIfPresent([Lens].self, forKey: .lenses) ?? []
    }

    /// The family and their five cameras, as David listed them on 16 October 2026.
    public static func family() -> PeopleBook {
        let david = Person(name: "David"), amanda = Person(name: "Amanda")
        let patrick = Person(name: "Patrick"), gilbert = Person(name: "Gilbert")
        return PeopleBook(
            people: [david, amanda, patrick, gilbert],
            cameras: [
                Camera(personId: david.id, model: "Canon EOS R5m2", zone: .fromPhoto),
                Camera(personId: david.id, model: "Canon EOS R7", zone: .fromPhoto),
                Camera(personId: amanda.id, model: "Canon EOS R5m2", zone: .fromPhoto),
                Camera(personId: gilbert.id, model: "COOLPIX P950", zone: .notSet),
                Camera(personId: patrick.id, model: "Canon EOS REBEL T3i", zone: .notSet),
            ]
        )
    }

    public func person(_ id: UUID) -> Person? {
        people.first { $0.id == id }
    }

    public func cameras(of personId: UUID) -> [Camera] {
        cameras.filter { $0.personId == personId }
    }

    /// The camera a photo came from: its owner's camera with that model.
    public func camera(personId: UUID, model: String) -> Camera? {
        let wanted = model.trimmingCharacters(in: .whitespaces).lowercased()
        return cameras.first { $0.personId == personId && $0.model.trimmingCharacters(in: .whitespaces).lowercased() == wanted }
    }

    public mutating func save(_ person: Person) {
        if let i = people.firstIndex(where: { $0.id == person.id }) { people[i] = person } else { people.append(person) }
    }

    /// Takes the person and their cameras off the list. Photos are never touched.
    public mutating func remove(person id: UUID) {
        people.removeAll { $0.id == id }
        cameras.removeAll { $0.personId == id }
    }

    public mutating func save(_ camera: Camera) {
        if let i = cameras.firstIndex(where: { $0.id == camera.id }) { cameras[i] = camera } else { cameras.append(camera) }
    }

    public mutating func remove(camera id: UUID) {
        cameras.removeAll { $0.id == id }
    }
}

public protocol PeopleStorePort: Sendable {
    func load() throws -> PeopleBook?
    func save(_ book: PeopleBook) throws
}

/// `people.json` in Geotag's folder in Application Support, written whole.
public struct PeopleStoreFile: PeopleStorePort {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public static func standard() -> PeopleStoreFile {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return PeopleStoreFile(url: support.appendingPathComponent("Geotag/people.json"))
    }

    public func load() throws -> PeopleBook? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(PeopleBook.self, from: Data(contentsOf: url))
    }

    public func save(_ book: PeopleBook) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(book).write(to: url, options: .atomic)
    }
}

/// What a photo says about the camera that took it.
public struct CameraReading: Equatable, Sendable {
    public var model: String
    /// The zone the camera wrote, such as "-05:00", or nil when it wrote none.
    public var zone: String?

    public init(model: String, zone: String?) {
        self.model = model
        self.zone = zone
    }
}

public enum CameraReader {
    /// Reads the model and the time zone from a photo. ExifTool when there is
    /// one: the Mac's own reading misses the zone in Canon raw files.
    #if os(macOS)
    public static func read(_ url: URL, exifTool: ExifTool? = .bundled()) -> CameraReading? {
        if let exifTool, let tags = try? exifTool.read(["Model", "OffsetTimeOriginal", "OffsetTime"], from: url),
           let model = tags["Model"]?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty {
            let zone = tags["OffsetTimeOriginal"] ?? tags["OffsetTime"]
            return CameraReading(model: model, zone: zone?.isEmpty == false ? zone : nil)
        }
        return readWithImageIO(url)
    }
    #else
    public static func read(_ url: URL) -> CameraReading? {
        if let d = try? NativeMetadata.read(url), let model = d.model { return CameraReading(model: model, zone: d.zone) }
        return readWithImageIO(url)
    }
    #endif

    static func readWithImageIO(_ url: URL) -> CameraReading? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        guard let model = (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !model.isEmpty else { return nil }
        let zone = (exif[kCGImagePropertyExifOffsetTimeOriginal] as? String)
            ?? (exif[kCGImagePropertyExifOffsetTime] as? String)
        return CameraReading(model: model, zone: zone?.isEmpty == false ? zone : nil)
    }
}
