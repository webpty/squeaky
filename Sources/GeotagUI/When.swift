import GeotagCore
import Foundation

/// The order a date is written in, as chosen in Settings.
public enum DateOrder: String, CaseIterable, Identifiable, Sendable {
    /// As the Mac's own settings have it, until a choice is made.
    case system
    case dayMonthYear
    case monthDayYear
    case yearMonthDay

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .system: return "As the Mac"
        case .dayMonthYear: return "Day month year"
        case .monthDayYear: return "Month day year"
        case .yearMonthDay: return "Year month day"
        }
    }
}

/// Every date and time in Geotag, written the way Settings says.
public struct When: Sendable {
    public var order: DateOrder
    /// Nil follows the Mac's own setting.
    public var clock24: Bool?

    public init(order: DateOrder = .system, clock24: Bool? = nil) {
        self.order = order
        self.clock24 = clock24
    }

    /// Set by the app model from Settings; read by every view.
    nonisolated(unsafe) public static var current = When()

    /// The Mac's own settings for its own styles; for a chosen format, the
    /// Mac's language alone, since the Mac's "24-hour time" setting would
    /// otherwise overrule a 12-hour choice.
    private func formatter(_ zone: TimeZone, chosen: Bool) -> DateFormatter {
        let f = DateFormatter()
        f.locale = chosen ? Locale(identifier: Locale.current.identifier) : .current
        f.timeZone = zone
        return f
    }

    public func day(_ date: Date, zone: TimeZone = .current, weekday: Bool = false) -> String {
        let f = formatter(zone, chosen: order != .system)
        switch order {
        case .system:
            f.dateStyle = weekday ? .full : .medium
            f.timeStyle = .none
        case .dayMonthYear:
            f.dateFormat = weekday ? "EEEE d MMMM yyyy" : "d MMM yyyy"
        case .monthDayYear:
            f.dateFormat = weekday ? "EEEE, MMMM d, yyyy" : "MMM d, yyyy"
        case .yearMonthDay:
            f.dateFormat = weekday ? "EEEE yyyy-MM-dd" : "yyyy-MM-dd"
        }
        return f.string(from: date)
    }

    public func time(_ date: Date, zone: TimeZone = .current, seconds: Bool = false) -> String {
        let f = formatter(zone, chosen: clock24 != nil)
        switch clock24 {
        case nil:
            f.dateStyle = .none
            f.timeStyle = seconds ? .medium : .short
        case true?:
            f.dateFormat = seconds ? "HH:mm:ss" : "HH:mm"
        case false?:
            f.dateFormat = seconds ? "h:mm:ss a" : "h:mm a"
        }
        return f.string(from: date)
    }

    public func dayAndTime(_ date: Date, zone: TimeZone = .current, weekday: Bool = false, seconds: Bool = false) -> String {
        Words.t("{0} at {1}", day(date, zone: zone, weekday: weekday), time(date, zone: zone, seconds: seconds))
    }
}
