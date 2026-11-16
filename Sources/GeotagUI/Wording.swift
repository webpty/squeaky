import Foundation
import GeotagCore

public enum PhotoText {
    /// The camera's own clock reading, shown as it was, with its zone.
    public static func taken(_ photo: ScannedPhoto) -> String {
        taken(raw: photo.taken, zone: photo.zone)
    }

    /// "2026:10:16 12:00:00" as the camera writes it, in the format chosen in Settings.
    public static func taken(raw: String?, zone: String?) -> String {
        guard let raw else { return Words.t("No time") }
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
        let each = wrong.map { Words.t("The {0}'s clock is {1}.", $0.camera.model, OffsetText.describe($0.offset)) }
        return each.joined(separator: " ") + Words.t(" Set it in the camera: Set time and date in camera, in the menu bar.")
    }

    /// "1 h 25 min", "45 min", "2 d 3 h": a break between two photos.
    public static func gap(_ seconds: Int) -> String {
        let minutes = seconds / 60, hours = minutes / 60, days = hours / 24
        if days > 0 { return hours % 24 == 0 ? Words.t("{0} d", days) : Words.t("{0} d", days) + " " + Words.t("{0} h", hours % 24) }
        if hours > 0 { return minutes % 60 == 0 ? Words.t("{0} h", hours) : Words.t("{0} h", hours) + " " + Words.t("{0} min", minutes % 60) }
        return Words.t("{0} min", minutes)
    }

    public static func location(_ row: ImportRow, gap: Int) -> String {
        guard let placement = row.placement else { return "" }
        switch placement {
        case .matched(let p): return p.fromPoint == 0 ? Words.t("Location matched") : Words.t("Location matched, {0} s from the track", p.fromPoint)
        case .ownLocation: return Words.t("Own location")
        case .review(let reason):
            switch reason {
            case .noTrack: return Words.t("No track within {0} min", gap / 60)
            case .offsetNotSet: return Words.t("Camera time offset not set")
            case .zoneNotSet: return Words.t("Camera time zone not set")
            case .noZoneInPhoto: return Words.t("No time zone in the photo")
            case .noTime: return Words.t("No time in the photo")
            case .unknownCamera: return Words.t("Camera not registered")
            }
        }
    }

    public static func status(_ status: ImportStatus) -> String {
        switch status {
        case .new: return Words.t("New")
        case .alreadyImported: return Words.t("Already imported")
        case .unknownCamera: return Words.t("Camera not registered")
        }
    }
}

public enum QueueText {
    /// "Shared with the NAS: 14:32" (the server, on the phone), or why not.
    public static func shared(at: Date?, problem: String?) -> String {
        if let problem { return Words.t("Shared with the NAS: no. {0}", problem) }
        guard let at else { return Words.t("Shared with the NAS: not yet") }
        return Words.t("Shared with the NAS: {0}", When.current.time(at))
    }

    public static func status(_ entry: QueueEntry) -> String {
        switch entry.state {
        case .waiting: return Words.t("Waiting")
        case .sending: return Words.t("Sending")
        case .sent: return entry.sentAs.map { Words.t("On the NAS as {0}", $0) } ?? Words.t("On the NAS")
        case .failed: return Words.t("Not sent: {0}", entry.reason ?? "")
        }
    }

    /// A photo on the Photos page, once saved on this Mac.
    public static func photo(_ entry: QueueEntry) -> String {
        switch entry.state {
        case .waiting: return Words.t("Waiting for the NAS")
        case .sending: return Words.t("Sending to the NAS")
        case .sent: return Words.t("On the NAS")
        case .failed: return Words.t("Not on the NAS: {0}", entry.reason ?? "")
        }
    }

    public static func reach(_ reach: NASReach) -> String {
        switch reach {
        case .checking: return Words.t("Checking")
        case .through(let address): return AppModel.host(address)
        case .unreachable: return Words.t("Not reachable")
        case .notSetUp: return Words.t("Not set up")
        }
    }
}
