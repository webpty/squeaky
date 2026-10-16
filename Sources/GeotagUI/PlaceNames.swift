import Foundation
import GeotagCore

/// Names a place from its position with OpenStreetMap's own lookup
/// (Nominatim): "Ushuaia, Argentina". Answers are kept while Geotag runs, and
/// asked for one at a time, as OpenStreetMap asks of everyone.
@MainActor
final class PlaceNames {
    static let shared = PlaceNames()
    private var known: [String: String] = [:]
    private var last = Date.distantPast

    func name(lat: Double, lon: Double) async -> String? {
        let key = String(format: "%.2f,%.2f", lat, lon)
        if let name = known[key] { return name }
        // No more than one question a second.
        let wait = 1.1 - Date().timeIntervalSince(last)
        if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
        last = Date()
        var parts = URLComponents(string: "https://nominatim.openstreetmap.org/reverse")!
        parts.queryItems = [
            URLQueryItem(name: "format", value: "jsonv2"),
            URLQueryItem(name: "lat", value: String(lat)),
            URLQueryItem(name: "lon", value: String(lon)),
            URLQueryItem(name: "zoom", value: "12"),
            URLQueryItem(name: "accept-language", value: Locale.current.language.languageCode?.identifier ?? "en"),
        ]
        var request = URLRequest(url: parts.url!)
        request.setValue("Geotag/\(appVersion) (private family photo app)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let address = body["address"] as? [String: Any] else { return nil }
        let place = ["city", "town", "village", "hamlet", "municipality", "suburb", "county", "state_district", "state"]
            .lazy.compactMap { address[$0] as? String }.first
        let country = address["country"] as? String
        let name = [place, country].compactMap { $0 }.joined(separator: ", ")
        guard !name.isEmpty else { return nil }
        known[key] = name
        return name
    }
}
