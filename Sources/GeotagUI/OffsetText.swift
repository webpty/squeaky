import Foundation
import GeotagCore

/// A camera's clock offset in words.
public enum OffsetText {
    public static func describe(_ seconds: Int?) -> String {
        guard let seconds else { return Words.t("Offset not set") }
        if seconds == 0 { return Words.t("On time") }
        return way(amount(abs(seconds)), ahead: seconds > 0)
    }

    /// "1 d 2 h 5 min 3 s".
    static func amount(_ a: Int) -> String {
        var parts: [String] = []
        if a >= 86_400 { parts.append(Words.t("{0} d", a / 86_400)) }
        if a % 86_400 >= 3600 { parts.append(Words.t("{0} h", a % 86_400 / 3600)) }
        if a % 3600 >= 60 { parts.append(Words.t("{0} min", a % 3600 / 60)) }
        if a % 60 > 0 { parts.append(Words.t("{0} s", a % 60)) }
        return parts.joined(separator: " ")
    }

    /// "3 min ahead", "3 min behind".
    static func way(_ amount: String, ahead: Bool) -> String {
        ahead ? Words.t("{0} ahead", amount) : Words.t("{0} behind", amount)
    }

    /// "3.42 s ahead", "0.08 s behind", "on time": an offset to the hundredth.
    public static func exact(_ seconds: Double) -> String {
        let a = abs(seconds)
        if a < 0.005 { return Words.t("on time") }
        let figure = a >= 60 ? amount(Int(a.rounded())) : Words.t("{0} s", String(format: "%.2f", a))
        return way(figure, ahead: seconds > 0)
    }

    /// "Drifts 0.40 s a day, from 5 readings", or the one reading so far.
    public static func drift(_ camera: Camera) -> String? {
        guard let last = camera.readings.last else { return nil }
        guard let rate = Drift.perDay(camera.readings) else {
            return Words.t("Offset code {0}: clock {1}", When.current.day(last.at), exact(last.offset))
        }
        let figure = String(format: "%.2f", abs(rate))
        return rate >= 0 ? Words.t("Gains {0} s a day, from {1} readings", figure, camera.readings.count)
            : Words.t("Loses {0} s a day, from {1} readings", figure, camera.readings.count)
    }
}
