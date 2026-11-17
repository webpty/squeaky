import GeotagCore
import Foundation
#if os(macOS)
import AppKit
#endif
#if os(macOS)
import IOKit.ps
#endif

/// How long the battery has left, as the Mac reckons it.
public protocol PowerPort: Sendable {
    /// Seconds of battery left; nil on power, on a Mac with no battery, or
    /// while the Mac cannot tell yet (just after it is unplugged).
    func batteryLeft() -> TimeInterval?
}

/// The Mac's own estimate, the one its battery menu shows.
public struct MacPower: PowerPort {
    public init() {}

    public func batteryLeft() -> TimeInterval? {
        #if os(iOS)
        return nil
        #else
        let left = IOPSGetTimeRemainingEstimate()
        guard left != kIOPSTimeRemainingUnlimited, left != kIOPSTimeRemainingUnknown, left > 0 else { return nil }
        return left
        #endif
    }
}

/// "less than a minute", "about 12 min", "about 1 h 20 min": time still to go.
public enum Remaining {
    public static func text(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 1 { return Words.t("less than a minute") }
        let h = minutes / 60, m = minutes % 60
        let said = minutes < 60 ? Words.t("about {0} min", minutes)
            : m == 0 ? Words.t("about {0} h", h) : Words.t("about {0} h {1} min", h, m)
        #if os(iOS)
        // A time is never split over two lines on the phone (0.29.29).
        return said.replacingOccurrences(of: " ", with: "\u{00A0}")
        #else
        return said
        #endif
    }

    /// "9 h 15 min", never split over two lines: the phone's Queue page
    /// (0.29.29; without the ≈ from 0.29.41, David, 17 November 2026).
    public static func approx(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        let h = minutes / 60, m = minutes % 60
        var parts: [String] = []
        if h > 0 { parts.append(Words.t("{0} h", h)) }
        if m > 0 || h == 0 { parts.append(Words.t("{0} min", m)) }
        return parts.joined(separator: " ").replacingOccurrences(of: " ", with: "\u{00A0}")
    }

    /// "2 min 24 s", "40 s", "1 h 5 min": the time one photo takes (0.29.41).
    public static func each(_ seconds: TimeInterval) -> String {
        let whole = max(1, Int(seconds.rounded()))
        let h = whole / 3600, m = (whole % 3600) / 60, sec = whole % 60
        var parts: [String] = []
        if h > 0 {
            parts.append(Words.t("{0} h", h))
            if m > 0 { parts.append(Words.t("{0} min", m)) }
        } else {
            if m > 0 { parts.append(Words.t("{0} min", m)) }
            if sec > 0 || m == 0 { parts.append(Words.t("{0} s", sec)) }
        }
        return parts.joined(separator: " ").replacingOccurrences(of: " ", with: "\u{00A0}")
    }

    /// What is left at the pace so far: nil until enough has gone to tell.
    public static func estimate(done: Int, total: Int, since start: Date, now: Date = Date()) -> TimeInterval? {
        let elapsed = now.timeIntervalSince(start)
        guard done >= 3, elapsed >= 5, total > done else { return nil }
        return elapsed / Double(done) * Double(total - done)
    }
}

/// Where a phone line may break when it does not fit on one line: a soft
/// break reads ", " on one line and starts a new line otherwise (0.29.29).
public enum LineBreaks {
    public static let soft = "\u{E000}"

    /// The line as one line.
    public static func oneLine(_ text: String) -> String {
        text.replacingOccurrences(of: soft, with: ", ")
    }

    /// The line broken: at each soft break, and after each sentence.
    public static func broken(_ text: String) -> String {
        // A line begun at a soft break starts with a capital: "Starts 17 Nov" (0.29.35).
        let pieces = text.components(separatedBy: soft)
        var out = ([pieces[0]] + pieces.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }).joined(separator: "\n")
        for end in [". ", "? ", "! "] {
            out = out.replacingOccurrences(of: end, with: String(end.first!) + "\n")
        }
        // Chinese full stops have no space after them.
        out = out.replacingOccurrences(of: "。", with: "。\n")
        while out.hasSuffix("\n") { out.removeLast() }
        return out
    }
}

/// The Tailscale app, which reaches the NAS from away from home.
public enum Tailscale {
    /// Where it is on this Mac, from the Mac App Store or Tailscale's own download.
    @MainActor
    public static var app: URL? {
        #if os(iOS)
        return nil
        #else
        for id in ["io.tailscale.ipn.macos", "io.tailscale.ipn.macsys"] {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return url }
        }
        return nil
        #endif
    }

    @MainActor
    public static func open() {
        #if os(macOS)
        guard let app else { return }
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        #endif
    }
}
