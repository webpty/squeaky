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
            VStack(spacing: 32) {
                Spacer()
                HStack(spacing: 60) {
                    if let image = OffsetCode.image(now) {
                        Image(decorative: image, scale: 1)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 420, height: 420)
                            .padding(24)
                            .background(Color.white)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(Self.time.string(from: now))
                            .font(.system(size: 110, weight: .semibold).monospacedDigit())
                            .lineLimit(1)
                        Text(Self.day.string(from: now) + " UTC")
                            .font(.title)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
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
                .padding(.bottom, 32)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            check = await MacClock.check()
            checked = true
        }
        .background(FullScreen())
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

/// Puts the window it sits in into full screen, once.
struct FullScreen: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window, !window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
