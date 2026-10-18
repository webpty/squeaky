import Foundation

/// Why a photo cannot be placed by itself and waits for a decision.
public enum ReviewReason: Error, Equatable, Sendable {
    case noTrack
    case offsetNotSet
    case zoneNotSet
    case noZoneInPhoto
    case noTime
    case unknownCamera
}

public struct Position: Equatable, Sendable {
    public var lat: Double
    public var lon: Double
    public var alt: Double?
    /// The real moment, UTC: what the GPS date and time stamps are written from.
    public var moment: Date
    /// Seconds between that moment and the nearest track point.
    public var fromPoint: Int
    /// The track it was found on.
    public var trackId: String?

    public init(lat: Double, lon: Double, alt: Double?, moment: Date, fromPoint: Int, trackId: String? = nil) {
        self.lat = lat
        self.lon = lon
        self.alt = alt
        self.moment = moment
        self.fromPoint = fromPoint
        self.trackId = trackId
    }
}

public enum Placement: Equatable, Sendable {
    case matched(Position)
    /// The camera wrote a location of its own; it is kept.
    case ownLocation
    case review(ReviewReason)
}

public enum Moments {
    public static let reading: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f
    }()

    /// "-05:00" or "+08:00" as seconds east of UTC.
    public static func zoneSeconds(_ text: String) -> Int? {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t == "Z" { return 0 }
        guard t.count >= 5, let sign = t.first, sign == "+" || sign == "-" else { return nil }
        let parts = t.dropFirst().split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        return (sign == "-" ? -1 : 1) * (h * 3600 + m * 60)
    }

    /// The camera clock's reading as if it were UTC, sub-seconds included.
    public static func clockReading(_ photo: ScannedPhoto) -> Date? {
        guard let taken = photo.taken, let date = reading.date(from: String(taken.prefix(19))) else { return nil }
        let fraction = photo.subSeconds.flatMap { Double("0.\($0.filter(\.isNumber))") } ?? 0
        return date.addingTimeInterval(fraction)
    }

    /// The real moment a photo was taken, or why it cannot be known. The
    /// camera's offset is how far its clock is ahead, so it is taken off.
    public static func moment(_ photo: ScannedPhoto, camera: Camera?, extraOffset: Int = 0) -> Result<Date, ReviewReason> {
        guard let camera else { return .failure(.unknownCamera) }
        guard let clock = clockReading(photo) else { return .failure(.noTime) }
        let zone: Int
        switch camera.zone {
        case .notSet:
            return .failure(.zoneNotSet)
        case .fromPhoto:
            guard let z = photo.zone.flatMap(zoneSeconds) else { return .failure(.noZoneInPhoto) }
            zone = z
        case .fixed(let id):
            guard let tz = TimeZone(identifier: id) else { return .failure(.zoneNotSet) }
            zone = tz.secondsFromGMT(for: clock.addingTimeInterval(-Double(tz.secondsFromGMT(for: clock))))
        }
        guard let offset = camera.offsetSeconds else { return .failure(.offsetNotSet) }
        return .success(clock.addingTimeInterval(-Double(zone) - Double(offset + extraOffset)))
    }

    /// The clock offset that puts this photo at that moment: how a camera
    /// whose clock is far out is set from the start of the track its photos
    /// belong to (David, 18 October 2026). Nil when its time cannot be read.
    public static func offset(placing photo: ScannedPhoto, camera: Camera, at moment: Date) -> Int? {
        var onTime = camera
        onTime.offsetSeconds = 0
        guard case .success(let read) = Moments.moment(photo, camera: onTime) else { return nil }
        return Int(read.timeIntervalSince(moment).rounded())
    }
}

/// Every track's points, ready to be asked "where was I at this moment".
public struct TrackTimeline: Sendable {
    public struct Piece: Sendable {
        public let id: String
        public let points: TrackPoints
        public var start: Int { points.t.first ?? 0 }
        public var end: Int { points.t.last ?? 0 }
    }

    public let pieces: [Piece]

    public init(_ tracks: [(id: String, points: TrackPoints)]) {
        pieces = tracks.filter { $0.points.count > 0 }.map { Piece(id: $0.id, points: $0.points) }
    }

    /// Where the moment falls, within `gap` seconds of a track point, or nil.
    /// Between two close points the place is shared out in proportion to the
    /// time; next to a gap in the track, or just past its ends, it is the
    /// nearest point.
    public func position(at moment: Date, gap: Int) -> Position? {
        let t = moment.timeIntervalSince1970
        var best: Position?
        for piece in pieces where Double(piece.start - gap) <= t && t <= Double(piece.end + gap) {
            let p = piece.points
            // The last point at or before t.
            var lo = 0, hi = p.count - 1, before = -1
            while lo <= hi {
                let mid = (lo + hi) / 2
                if Double(p.t[mid]) <= t { before = mid; lo = mid + 1 } else { hi = mid - 1 }
            }
            let after = before + 1 < p.count ? before + 1 : -1
            let dBefore = before >= 0 ? t - Double(p.t[before]) : .infinity
            let dAfter = after >= 0 ? Double(p.t[after]) - t : .infinity
            let nearest = min(dBefore, dAfter)
            guard nearest <= Double(gap) else { continue }
            var found: Position
            if before >= 0, after >= 0, dBefore <= Double(gap), dAfter <= Double(gap), p.t[after] > p.t[before] {
                let f = dBefore / Double(p.t[after] - p.t[before])
                let alt: Double?
                if let a = p.alt[before], let b = p.alt[after] { alt = a + (b - a) * f } else { alt = p.alt[before] ?? p.alt[after] }
                found = Position(lat: p.lat[before] + (p.lat[after] - p.lat[before]) * f,
                                 lon: p.lon[before] + (p.lon[after] - p.lon[before]) * f,
                                 alt: alt, moment: moment, fromPoint: Int(nearest.rounded()), trackId: piece.id)
            } else {
                let i = dBefore <= dAfter ? before : after
                found = Position(lat: p.lat[i], lon: p.lon[i], alt: p.alt[i], moment: moment, fromPoint: Int(nearest.rounded()), trackId: piece.id)
            }
            if best == nil || found.fromPoint < best!.fromPoint { best = found }
        }
        return best
    }

    /// The tracks that run within a day of these moments.
    public func pieces(near moments: [Date]) -> [Piece] {
        guard let first = moments.min(), let last = moments.max() else { return [] }
        let a = Int(first.timeIntervalSince1970) - 86_400, b = Int(last.timeIntervalSince1970) + 86_400
        return pieces.filter { $0.end >= a && $0.start <= b }
    }
}

public enum Matcher {
    /// Where each photo goes. Photos with a location of their own keep it.
    public static func place(_ photo: ScannedPhoto, camera: Camera?, timeline: TrackTimeline, gap: Int,
                             extraOffset: Int = 0) -> Placement {
        if photo.hasLocation { return .ownLocation }
        switch Moments.moment(photo, camera: camera, extraOffset: extraOffset) {
        case .failure(let reason):
            return .review(reason)
        case .success(let moment):
            guard let position = timeline.position(at: moment, gap: gap) else { return .review(.noTrack) }
            return .matched(position)
        }
    }
}
