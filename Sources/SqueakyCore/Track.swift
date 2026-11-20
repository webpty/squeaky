import Foundation

/// Every point of a track, as parallel lists. Times are seconds since 1970, UTC.
public struct TrackPoints: Codable, Equatable, Sendable {
    public var t: [Int]
    public var lat: [Double]
    public var lon: [Double]
    public var alt: [Double?]

    public init(t: [Int], lat: [Double], lon: [Double], alt: [Double?]) {
        self.t = t
        self.lat = lat
        self.lon = lon
        self.alt = alt
    }

    public var count: Int { t.count }
}

public struct Bounds: Codable, Equatable, Sendable {
    public var minLat: Double
    public var maxLat: Double
    public var minLon: Double
    public var maxLon: Double

    public init(minLat: Double, maxLat: Double, minLon: Double, maxLon: Double) {
        self.minLat = minLat
        self.maxLat = maxLat
        self.minLon = minLon
        self.maxLon = maxLon
    }
}

public enum TrackSource: String, Codable, Sendable {
    case strava
    case file
    /// Sent by the Squeaky app on a Garmin watch, or passed on by a family phone (0.32.0).
    case watch
}

/// Where a track stands between this Mac and the track service.
public enum TrackStatus: String, Codable, Sendable {
    /// Came from the service, or went up to it.
    case onService
    /// Imported on the owner's Mac, not yet on the service.
    case waitingToUpload
    /// Imported on a Mac whose key can only read: it stays here.
    case thisMacOnly
    /// Imported here and since uploaded; the service's copy is the one shown.
    case uploaded
}

public struct Track: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var source: TrackSource
    public var name: String
    public var sport: String?
    public var fileName: String?
    public var start: Date
    public var end: Date
    /// IANA zone where the track was recorded, when known.
    public var timeZone: String?
    public var pointCount: Int
    public var distance: Double?
    public var bounds: Bounds
    public var status: TrackStatus
    /// For an uploaded file: the service's id for the same track.
    public var serviceId: String?
    /// Where it is, named by the track service (0.29.20).
    public var place: String?
    /// Another track starts within `sameStartSeconds` and is longer: this one is kept but not listed (0.32.0).
    public var setAside: Bool?

    public init(id: String, source: TrackSource, name: String, sport: String?, fileName: String?,
                start: Date, end: Date, timeZone: String?, pointCount: Int, distance: Double?,
                bounds: Bounds, status: TrackStatus, serviceId: String? = nil) {
        self.id = id
        self.source = source
        self.name = name
        self.sport = sport
        self.fileName = fileName
        self.start = start
        self.end = end
        self.timeZone = timeZone
        self.pointCount = pointCount
        self.distance = distance
        self.bounds = bounds
        self.status = status
        self.serviceId = serviceId
    }

    public var duration: TimeInterval { end.timeIntervalSince(start) }

    /// Shown in the list: uploaded files appear once, as the service's copy;
    /// of two starting together, only the longer.
    public var isListed: Bool { status != .uploaded && setAside != true }
}

/// Two tracks starting this close together are the same outing; the shorter
/// is set aside (0.32.0, David: 20 seconds, not 60).
public let sameStartSeconds: TimeInterval = 20

public enum Geo {
    static let earthMetres = 6_371_008.8

    public static func metres(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let r = Double.pi / 180
        let dLat = (lat2 - lat1) * r
        let dLon = (lon2 - lon1) * r
        let a = sin(dLat / 2) * sin(dLat / 2) + cos(lat1 * r) * cos(lat2 * r) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthMetres * asin(min(1, a.squareRoot()))
    }

    public static func distance(_ p: TrackPoints) -> Double {
        var total = 0.0
        for i in 1..<max(1, p.count) {
            total += metres(p.lat[i - 1], p.lon[i - 1], p.lat[i], p.lon[i])
        }
        return total.rounded()
    }

    public static func bounds(_ p: TrackPoints) -> Bounds {
        Bounds(minLat: p.lat.min() ?? 0, maxLat: p.lat.max() ?? 0,
               minLon: p.lon.min() ?? 0, maxLon: p.lon.max() ?? 0)
    }
}
