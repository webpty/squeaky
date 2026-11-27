import Foundation
import SqueakyCore

/// What a lookup of a position found.
public enum PlaceLookup: Equatable, Sendable {
    /// The town or area, such as "Ushuaia".
    case found(String)
    /// Asked and answered: nothing to name there (open sea).
    case nothing
    /// No answer: no internet, or OpenStreetMap away.
    case unreachable
}

/// What names a place from its position, for the folders photos are saved in.
@MainActor
public protocol PlaceNaming {
    func place(lat: Double, lon: Double) async -> PlaceLookup
}

/// Names a place from its position with OpenStreetMap's own lookup
/// (Nominatim): the town or area, and its country. Answers are kept while
/// Squeaky runs, and asked for one at a time, as OpenStreetMap asks of everyone.
@MainActor
final class PlaceNames: PlaceNaming {
    static let shared = PlaceNames()
    private var known: [String: (place: String?, country: String?)] = [:]
    private var last = Date.distantPast

    /// "Ushuaia, Argentina", for a window's title.
    func name(lat: Double, lon: Double) async -> String? {
        guard let found = await lookUp(lat: lat, lon: lon) else { return nil }
        let name = [found.place, found.country].compactMap { $0 }.joined(separator: ", ")
        return name.isEmpty ? nil : name
    }

    /// "Ushuaia", for a folder's name; the country where there is no town.
    func place(lat: Double, lon: Double) async -> PlaceLookup {
        guard let found = await lookUp(lat: lat, lon: lon) else { return .unreachable }
        return (found.place ?? found.country).map { .found($0) } ?? .nothing
    }

    /// Nil when OpenStreetMap did not answer; empty parts where it had nothing.
    private func lookUp(lat: Double, lon: Double) async -> (place: String?, country: String?)? {
        let key = String(format: "%.2f,%.2f", lat, lon)
        if let found = known[key] { return found }
        // No more than one question a second.
        let wait = 1.1 - Date().timeIntervalSince(last)
        if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
        last = Date()
        var parts = URLComponents(string: "https://nominatim.openstreetmap.org/reverse")!
        parts.queryItems = [
            URLQueryItem(name: "format", value: "jsonv2"),
            URLQueryItem(name: "lat", value: String(lat)),
            URLQueryItem(name: "lon", value: String(lon)),
            // Town level: at 12, South Georgia came back under Argentina's
            // province and Grytviken went unnamed (18 October 2026).
            URLQueryItem(name: "zoom", value: "14"),
            URLQueryItem(name: "accept-language", value: Locale.current.language.languageCode?.identifier ?? "en"),
        ]
        var request = URLRequest(url: parts.url!)
        request.setValue("Squeaky/\(appVersion) (https://geotrac.cc)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        // Answered: an address, or an error saying there is nothing there.
        let address = body["address"] as? [String: Any] ?? [:]
        // The settlement before the district around it: Puerto Williams, not
        // the Cape Horn commune it lies in; Puerto Natales, not a hamlet
        // OpenStreetMap places inside it.
        let place = ["town", "village", "city", "hamlet", "municipality", "suburb", "county", "state_district", "state"]
            .lazy.compactMap { address[$0] as? String }.first
        let found = (place: place, country: address["country"] as? String)
        known[key] = found
        return found
    }
}
