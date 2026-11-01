import AppKit
import SwiftUI
import GeotagCore

/// How far the Mac's clock is from the time server it sets itself by, asked
/// as the clock screen opens: the code shows the corrected time.
public enum MacClock {
    public struct Check: Equatable, Sendable {
        /// Seconds the Mac's clock is behind the server: added to show the true time.
        public var correction: Double
        /// Give or take this much.
        public var within: Double
        public var server: String
    }

    /// The server the Mac itself uses, else Apple's.
    static var server: String {
        let conf = (try? String(contentsOfFile: "/etc/ntp.conf", encoding: .utf8)) ?? ""
        for line in conf.split(separator: "\n") {
            let parts = line.split(separator: " ")
            if parts.count >= 2, parts[0] == "server" { return String(parts[1]) }
        }
        return "time.apple.com"
    }

    /// Nil without an answer: no internet, or the server did not reply.
    public static func check() async -> Check? {
        let server = server
        return await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sntp")
            process.arguments = ["-t", "3", server]
            let out = Pipe()
            process.standardOutput = out
            process.standardError = Pipe()
            guard (try? process.run()) != nil else { return nil }
            process.waitUntilExit()
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            // "+0.219916 +/- 0.309675 time.apple.com 17.253.28.37"
            for line in text.split(separator: "\n") {
                let parts = line.split(separator: " ")
                if parts.count >= 3, parts[1] == "+/-", let offset = Double(parts[0]), let within = Double(parts[2]) {
                    return Check(correction: offset, within: within, server: server)
                }
            }
            return nil
        }.value
    }
}

/// "Show offset code": the true time, big, with the code a camera photographs
/// to set its clock offset (David, 1 November 2026). Full screen; Escape closes.
public struct OffsetCodeView: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var check: MacClock.Check?
    @State private var checked = false

    public init() {}

    private var correction: Double { check?.correction ?? 0 }

    private var line: String {
        guard checked else { return "Checking this Mac's clock" }
        guard let check else { return "This Mac's clock could not be checked: no answer from \(MacClock.server). The code shows the Mac's clock as it is." }
        return "This Mac's clock is checked against \(check.server): corrected by \(String(format: "%.2f", check.correction)) s, give or take \(String(format: "%.2f", check.within)) s."
    }

    public var body: some View {
        // Every frame the screen draws, so the code holds the time it is shown at,
        // within a sixtieth of a second.
        TimelineView(.animation(minimumInterval: 1.0 / 60)) { context in
            let now = context.date.addingTimeInterval(correction)
            GeometryReader { geo in
                // Side by side on a wide window, one above the other on a narrow one,
                // the code as big as fits and the time shrinking to its width.
                let wide = geo.size.width > geo.size.height * 1.3
                let side = wide ? min(geo.size.height * 0.6, geo.size.width * 0.4) : min(geo.size.width * 0.6, geo.size.height * 0.45)
                VStack(spacing: 24) {
                    Spacer(minLength: 0)
                    if wide {
                        HStack(spacing: side * 0.12) {
                            code(now, side: side)
                            clock(now, side: side)
                        }
                    } else {
                        VStack(spacing: side * 0.08) {
                            code(now, side: side)
                            clock(now, side: side)
                        }
                    }
                    Spacer(minLength: 0)
                    Text(line)
                        .foregroundStyle(check == nil && checked ? .orange : .secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    Button {
                        dismissWindow(id: "offset-code")
                    } label: {
                        Text("Close").buttonLabel()
                    }
                    .keyboardShortcut(.cancelAction)
                }
                .padding(32)
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            check = await MacClock.check()
            checked = true
        }
        .background(FullScreen())
    }

    private func code(_ now: Date, side: CGFloat) -> some View {
        Group {
            if let image = OffsetCode.image(now) {
                Image(decorative: image, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(side * 0.06)
                    .background(Color.white)
            }
        }
        .frame(width: side, height: side)
    }

    private func clock(_ now: Date, side: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Self.time.string(from: now))
                .font(.system(size: max(side * 0.28, 40), weight: .semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.2)
            Text(Self.day.string(from: now) + " UTC")
                .font(.title)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            // The code changes with every frame: a slower shutter, or one that
            // reads the sensor line by line, catches two codes at once.
            Text("Shutter 1/500 s or faster, mechanical shutter.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
    }

    static let time: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "HH:mm:ss.SS"
        return f
    }()

    static let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy.MM.dd"
        return f
    }()
}

/// Puts the window it sits in into full screen, once it is in one: asked
/// before, the window was not there yet and it stayed small.
struct FullScreen: NSViewRepresentable {
    final class Watcher: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            DispatchQueue.main.async {
                if !window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
            }
        }
    }

    func makeNSView(context: Context) -> NSView { Watcher() }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
