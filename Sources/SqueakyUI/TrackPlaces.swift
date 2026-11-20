import Foundation
import SqueakyCore

/// A track named by where it is (0.29.5, David, 16 November 2026): its
/// start, middle and end looked up on OpenStreetMap; "Ronda, Andalusia" when
/// all three are in one town, else the region it starts in. In English.
/// Looked up once per track and kept; until then the track keeps its name.
public enum TrackPlaces {
    public struct Spot: Equatable {
        public var town: String?
        public var region: String?
        public init(town: String?, region: String?) {
            self.town = town
            self.region = region
        }
    }

    /// Kept beside Squeaky's other files.
    static func file(beside people: URL?) -> URL {
        if let people { return people.deletingLastPathComponent().appendingPathComponent("trackplaces.json") }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Squeaky/trackplaces.json")
    }

    static func load(_ url: URL) -> [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))) ?? [:]
    }

    static func save(_ names: [String: String], _ url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(names).write(to: url, options: .atomic)
    }

    /// The name from the three spots; nil when the map had no region.
    public static func name(_ start: Spot, _ middle: Spot, _ end: Spot) -> String? {
        if let town = start.town, town == middle.town, town == end.town {
            return start.region.map { $0 == town ? town : "\(town), \($0)" } ?? town
        }
        return start.region ?? start.town
    }

    /// One spot; nil when OpenStreetMap did not answer.
    static func spot(_ lat: Double, _ lon: Double) async -> Spot? {
        var parts = URLComponents(string: "https://nominatim.openstreetmap.org/reverse")!
        parts.queryItems = [
            URLQueryItem(name: "format", value: "jsonv2"),
            URLQueryItem(name: "lat", value: String(lat)),
            URLQueryItem(name: "lon", value: String(lon)),
            URLQueryItem(name: "zoom", value: "10"),
            URLQueryItem(name: "accept-language", value: "en"),
        ]
        var request = URLRequest(url: parts.url!)
        request.setValue("Squeaky/\(appVersion) (private family photo app)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let address = body["address"] as? [String: Any] ?? [:]
        let town = ["city", "town", "village", "municipality"].lazy.compactMap { address[$0] as? String }.first
        let region = ["state", "region", "province", "county"].lazy.compactMap { address[$0] as? String }.first
        return Spot(town: town, region: region)
    }
}
