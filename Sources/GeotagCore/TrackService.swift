import Foundation

public enum KeyRole: String, Codable, Sendable {
    case owner
    case reader
}

public struct ServiceStatus: Codable, Equatable, Sendable {
    public struct Strava: Codable, Equatable, Sendable {
        public var connected: Bool
        public var athlete: String?
        public var since: String
        public var lastRun: Int?
        public var lastResult: String?
    }

    public var role: KeyRole
    public var tracks: Int
    public var strava: Strava
}

/// A track as the service hands it out.
public struct ServiceTrack: Codable, Equatable, Sendable {
    public var id: String
    public var source: TrackSource
    public var fileName: String?
    public var name: String
    public var sport: String?
    public var start: Int
    public var end: Int
    public var timeZone: String?
    public var pointCount: Int
    public var distance: Double?
    public var bounds: Bounds

    public var track: Track {
        Track(id: id, source: source, name: name, sport: sport, fileName: fileName,
              start: Date(timeIntervalSince1970: TimeInterval(start)),
              end: Date(timeIntervalSince1970: TimeInterval(end)),
              timeZone: timeZone, pointCount: pointCount, distance: distance,
              bounds: bounds, status: .onService)
    }
}

/// Where the small maps come from, as the service says: tile addresses with
/// {z}, {x} and {y}, the credit the maps need, and the key, if one is set.
public struct MapSource: Codable, Equatable, Sendable {
    public var light: String
    public var dark: String
    public var credit: String
    public var key: String?

    public init(light: String, dark: String, credit: String, key: String?) {
        self.light = light
        self.dark = dark
        self.credit = credit
        self.key = key
    }
}

public struct UploadAnswer: Codable, Sendable {
    public var added: Bool
    public var track: ServiceTrack
}

public enum ServiceError: Error, LocalizedError, Equatable {
    case notSetUp
    case offline
    case refused(String)
    case unexpected(String)

    public var errorDescription: String? {
        switch self {
        case .notSetUp: return Words.t("The track service is not set up in Settings.")
        case .offline: return Words.t("The track service cannot be reached.")
        case .refused(let message): return message
        case .unexpected(let message): return message
        }
    }
}

/// What the app needs from the track service.
public protocol TrackServicePort: Sendable {
    func status() async throws -> ServiceStatus
    func maps() async throws -> MapSource
    func tracks() async throws -> [ServiceTrack]
    func points(_ id: String) async throws -> TrackPoints
    func upload(name: String, fileName: String?, points: TrackPoints) async throws -> UploadAnswer
    func sync() async throws -> String
    func connectLink() async throws -> URL
    func disconnect() async throws -> String
}

/// The track service over HTTP.
public struct TrackServiceHTTP: TrackServicePort {
    let base: URL
    let key: String
    let session: URLSession

    public init?(address: String, key: String, session: URLSession = .shared) {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty, !text.contains("://") { text = "https://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        guard !key.isEmpty, let url = URL(string: text), url.host != nil else { return nil }
        self.base = url
        self.key = key
        self.session = session
    }

    private struct Problem: Decodable { let error: String }
    private struct Result: Decodable { let result: String }
    private struct Link: Decodable { let url: URL }
    private struct List: Decodable { let tracks: [ServiceTrack] }

    private func call<T: Decodable>(_ method: String, _ path: String, body: Data? = nil, as: T.Type) async throws -> T {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 60
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where [.notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
                                             .cannotConnectToHost, .timedOut, .dnsLookupFailed,
                                             .internationalRoamingOff, .dataNotAllowed].contains(error.code) {
            throw ServiceError.offline
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            if let problem = try? JSONDecoder().decode(Problem.self, from: data) {
                throw ServiceError.refused(problem.error)
            }
            throw ServiceError.unexpected(Words.t("The track service answered {0}.", status))
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ServiceError.unexpected(Words.t("The track service's answer could not be read."))
        }
    }

    public func status() async throws -> ServiceStatus {
        try await call("GET", "v1/status", as: ServiceStatus.self)
    }

    public func maps() async throws -> MapSource {
        try await call("GET", "v1/maps", as: MapSource.self)
    }

    public func tracks() async throws -> [ServiceTrack] {
        try await call("GET", "v1/tracks", as: List.self).tracks
    }

    public func points(_ id: String) async throws -> TrackPoints {
        try await call("GET", "v1/tracks/\(id)/points", as: TrackPoints.self)
    }

    public func upload(name: String, fileName: String?, points: TrackPoints) async throws -> UploadAnswer {
        struct Body: Encodable {
            let name: String
            let fileName: String?
            let points: TrackPoints
        }
        let body = try JSONEncoder().encode(Body(name: name, fileName: fileName, points: points))
        return try await call("POST", "v1/tracks", body: body, as: UploadAnswer.self)
    }

    public func sync() async throws -> String {
        try await call("POST", "v1/sync", as: Result.self).result
    }

    public func connectLink() async throws -> URL {
        try await call("POST", "v1/strava/connect", as: Link.self).url
    }

    public func disconnect() async throws -> String {
        try await call("POST", "v1/strava/disconnect", as: Result.self).result
    }
}
