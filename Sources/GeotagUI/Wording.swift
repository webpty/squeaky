import Foundation
import GeotagCore

public enum PhotoText {
    /// The camera's own clock reading, shown as it was, with its zone.
    public static func taken(_ photo: ScannedPhoto) -> String {
        taken(raw: photo.taken, zone: photo.zone)
    }

    /// "2026:10:16 12:00:00" as the camera writes it, in the format chosen in Settings.
    public static func taken(raw: String?, zone: String?) -> String {
        guard let raw else { return "No time" }
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(secondsFromGMT: 0)
        parser.dateFormat = "yyyy:MM:dd HH:mm:ss"
        guard let date = parser.date(from: raw) else { return raw }
        return When.current.dayAndTime(date, zone: TimeZone(secondsFromGMT: 0)!, seconds: true) + (zone.map { " (\($0))" } ?? "")
    }

    public static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// "The Canon EOS R7's clock is 520 d 20 h 5 min behind. Set it in the
    /// camera: Set time and date in camera, in the menu bar."
    public static func clockNote(_ wrong: [(camera: Camera, offset: Int)]) -> String {
        guard !wrong.isEmpty else { return "" }
        let each = wrong.map { "The \($0.camera.model)'s clock is \(OffsetText.describe($0.offset))." }
        return each.joined(separator: " ") + " Set it in the camera: Set time and date in camera, in the menu bar."
    }

    /// "1 h 25 min", "45 min", "2 d 3 h": a break between two photos.
    public static func gap(_ seconds: Int) -> String {
        let minutes = seconds / 60, hours = minutes / 60, days = hours / 24
        if days > 0 { return hours % 24 == 0 ? "\(days) d" : "\(days) d \(hours % 24) h" }
        if hours > 0 { return minutes % 60 == 0 ? "\(hours) h" : "\(hours) h \(minutes % 60) min" }
        return "\(minutes) min"
    }

    public static func location(_ row: ImportRow, gap: Int) -> String {
        guard let placement = row.placement else { return "" }
        switch placement {
        case .matched(let p): return p.fromPoint == 0 ? "Location matched" : "Location matched, \(p.fromPoint) s from the track"
        case .ownLocation: return "Own location"
        case .review(let reason):
            switch reason {
            case .noTrack: return "No track within \(gap / 60) min"
            case .offsetNotSet: return "Camera time offset not set"
            case .zoneNotSet: return "Camera time zone not set"
            case .noZoneInPhoto: return "No time zone in the photo"
            case .noTime: return "No time in the photo"
            case .unknownCamera: return "Camera not registered"
            }
        }
    }

    public static func status(_ status: ImportStatus) -> String {
        switch status {
        case .new: return "New"
        case .alreadyImported: return "Already imported"
        case .unknownCamera: return "Camera not registered"
        }
    }
}

public enum QueueText {
    public static func status(_ entry: QueueEntry) -> String {
        switch entry.state {
        case .waiting: return "Waiting"
        case .sending: return "Sending"
        case .sent: return entry.sentAs.map { "On the NAS as \($0)" } ?? "On the NAS"
        case .failed: return "Not sent: \(entry.reason ?? "")"
        }
    }

    /// A photo on the Photos page, once saved on this Mac.
    public static func photo(_ entry: QueueEntry) -> String {
        switch entry.state {
        case .waiting: return "Waiting for the NAS"
        case .sending: return "Sending to the NAS"
        case .sent: return "On the NAS"
        case .failed: return "Not on the NAS: \(entry.reason ?? "")"
        }
    }

    public static func reach(_ reach: NASReach) -> String {
        switch reach {
        case .checking: return "Checking"
        case .through(let address): return AppModel.host(address)
        case .unreachable: return "Not reachable"
        case .notSetUp: return "Not set up"
        }
    }
}
