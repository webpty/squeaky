import Foundation
import GeotagCore

/// A camera's clock offset in words.
public enum OffsetText {
    public static func describe(_ seconds: Int?) -> String {
        guard let seconds else { return "Offset not set" }
        if seconds == 0 { return "On time" }
        let a = abs(seconds)
        var parts: [String] = []
        if a >= 86_400 { parts.append("\(a / 86_400) d") }
        if a % 86_400 >= 3600 { parts.append("\(a % 86_400 / 3600) h") }
        if a % 3600 >= 60 { parts.append("\(a % 3600 / 60) min") }
        if a % 60 > 0 { parts.append("\(a % 60) s") }
        return parts.joined(separator: " ") + (seconds > 0 ? " ahead" : " behind")
    }

    /// "3.42 s ahead", "0.08 s behind", "on time": an offset to the hundredth.
    public static func exact(_ seconds: Double) -> String {
        let a = abs(seconds)
        if a < 0.005 { return "on time" }
        let figure = a >= 60 ? describe(Int(seconds.rounded())).replacingOccurrences(of: " ahead", with: "").replacingOccurrences(of: " behind", with: "")
            : String(format: "%.2f s", a)
        return figure + (seconds > 0 ? " ahead" : " behind")
    }

    /// "Drifts 0.40 s a day, from 5 readings", or the one reading so far.
    public static func drift(_ camera: Camera) -> String? {
        guard let last = camera.readings.last else { return nil }
        guard let rate = Drift.perDay(camera.readings) else {
            return "Offset code \(When.current.day(last.at)): clock \(exact(last.offset))"
        }
        let way = rate >= 0 ? "Gains" : "Loses"
        return "\(way) \(String(format: "%.2f", abs(rate))) s a day, from \(camera.readings.count) readings"
    }
}
