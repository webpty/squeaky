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
        if minutes < 1 { return "less than a minute" }
        if minutes < 60 { return "about \(minutes) min" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "about \(h) h" : "about \(h) h \(m) min"
    }

    /// What is left at the pace so far: nil until enough has gone to tell.
    public static func estimate(done: Int, total: Int, since start: Date, now: Date = Date()) -> TimeInterval? {
        let elapsed = now.timeIntervalSince(start)
        guard done >= 3, elapsed >= 5, total > done else { return nil }
        return elapsed / Double(done) * Double(total - done)
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
