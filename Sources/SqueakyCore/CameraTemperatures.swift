import Foundation

/// A camera's own temperature, as one of its photos recorded it, with when
/// and where: for the Clock drift window (David, 1 November 2026: the
/// camera's temperature shows how it met the elements).
public struct TemperatureSample: Codable, Equatable, Sendable {
    /// The real moment, UTC, by the camera's clock less its offset.
    public var at: Date
    public var celsius: Double
    public var lat: Double?
    public var lon: Double?

    public init(at: Date, celsius: Double, lat: Double? = nil, lon: Double? = nil) {
        self.at = at
        self.celsius = celsius
        self.lat = lat
        self.lon = lon
    }
}

/// Every camera's samples, by camera id, kept in one file.
public struct CameraTemperatures: Codable, Equatable, Sendable {
    public var byCamera: [UUID: [TemperatureSample]] = [:]

    public init() {}

    /// New samples in, one per moment, oldest first.
    public mutating func add(_ samples: [TemperatureSample], camera: UUID) {
        var all = byCamera[camera] ?? []
        let known = Set(all.map(\.at))
        all += samples.filter { !known.contains($0.at) }
        byCamera[camera] = all.sorted { $0.at < $1.at }
    }

    /// Those taken between two moments.
    public func samples(_ camera: UUID, from: Date, to: Date) -> [TemperatureSample] {
        (byCamera[camera] ?? []).filter { $0.at >= from && $0.at <= to }
    }
}

public protocol TemperatureStorePort: Sendable {
    func load() throws -> CameraTemperatures?
    func save(_ temperatures: CameraTemperatures) throws
}

public struct TemperatureStoreFile: TemperatureStorePort {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public static func standard() -> TemperatureStoreFile {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Squeaky", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return TemperatureStoreFile(url: folder.appendingPathComponent("temperatures.json"))
    }

    public func load() throws -> CameraTemperatures? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(CameraTemperatures.self, from: Data(contentsOf: url))
    }

    public func save(_ temperatures: CameraTemperatures) throws {
        try JSONEncoder().encode(temperatures).write(to: url, options: .atomic)
    }
}

public enum TemperatureReader {
    /// The temperature each photo's camera recorded, in degrees Celsius, by
    /// file path. Canon writes it in its maker notes, which the card's fast
    /// read skips, so only these photos are asked.
}
