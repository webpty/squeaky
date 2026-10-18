import Foundation

/// Long breaks between photos next to each other in a card's list: a break
/// usually means the photographer moved on, so the photos between two breaks
/// are usually one place (David, 18 October 2026).
public enum Breaks {
    /// The photo after each break of at least `minutes`, with the break in
    /// seconds, by the camera's own clock. A photo with no time is passed over.
    public static func find(_ photos: [ScannedPhoto], minutes: Int) -> [String: Int] {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(secondsFromGMT: 0)
        parser.dateFormat = "yyyy:MM:dd HH:mm:ss"
        var out: [String: Int] = [:]
        var previous: Date?
        for photo in photos {
            guard let taken = photo.taken, var moment = parser.date(from: taken) else { continue }
            if let sub = photo.subSeconds, let fraction = Double("0." + sub) { moment += fraction }
            if let previous {
                let gap = moment.timeIntervalSince(previous)
                if gap >= Double(minutes * 60) { out[photo.id] = Int(gap.rounded()) }
            }
            previous = moment
        }
        return out
    }
}
