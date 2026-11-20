import SqueakyCore
import SqueakyUI
import Network
import SwiftUI
import UIKit

/// How far the phone's clock is from Apple's time server, asked as the code
/// opens, as the Mac does (0.29.1, David, 16 November 2026).
enum PhoneClock {
    struct Check: Sendable {
        /// Seconds the phone's clock is behind the server: added to show the true time.
        var correction: Double
        var within: Double
    }

    static let server = "time.apple.com"

    /// One NTP question; nil without an answer within three seconds.
    static func check() async -> Check? {
        await withCheckedContinuation { (done: CheckedContinuation<Check?, Never>) in
            let connection = NWConnection(host: NWEndpoint.Host(server), port: 123, using: .udp)
            let once = OnceFlag()
            func finish(_ result: Check?) {
                guard once.first() else { return }
                connection.cancel()
                done.resume(returning: result)
            }
            var packet = [UInt8](repeating: 0, count: 48)
            packet[0] = 0x1B
            var sent = Date()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    sent = Date()
                    connection.send(content: Data(packet), completion: .contentProcessed { _ in })
                    connection.receiveMessage { data, _, _, _ in
                        let back = Date()
                        guard let d = data.map([UInt8].init), d.count >= 48 else { return finish(nil) }
                        func stamp(_ at: Int) -> Date {
                            let s = (0..<4).reduce(UInt64(0)) { $0 << 8 | UInt64(d[at + $1]) }
                            let f = (4..<8).reduce(UInt64(0)) { $0 << 8 | UInt64(d[at + $1]) }
                            return Date(timeIntervalSince1970: Double(s) - 2_208_988_800 + Double(f) / 4_294_967_296)
                        }
                        let received = stamp(32), answered = stamp(40)
                        let offset = (received.timeIntervalSince(sent) + answered.timeIntervalSince(back)) / 2
                        let delay = back.timeIntervalSince(sent) - answered.timeIntervalSince(received)
                        finish(Check(correction: offset, within: max(delay / 2, 0)))
                    }
                case .failed, .cancelled: finish(nil)
                default: break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { finish(nil) }
        }
    }
}

final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func first() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
}

/// The offset code, full screen: the true time and the code a camera
/// photographs to set its clock offset, as on the Mac.
struct OffsetCodeScreen: View {
    @Environment(\.dismiss) private var dismiss
    @State private var check: PhoneClock.Check?
    @State private var checked = false
    @State private var brightness: CGFloat = 0.5

    private var line: String {
        guard checked else { return Words.t("Checking this iPhone's clock") }
        guard let check else {
            return Words.t("This iPhone's clock could not be checked: no answer from {0}. The code shows the iPhone's clock as it is.", PhoneClock.server)
        }
        return Words.t("This iPhone's clock is checked against {0}: corrected by {1} s, give or take {2} s.", PhoneClock.server,
                       String(format: "%.2f", check.correction), String(format: "%.2f", check.within))
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60)) { context in
            let now = context.date.addingTimeInterval(check?.correction ?? 0)
            GeometryReader { geo in
                let side = min(geo.size.width - 48, geo.size.height * 0.5)
                VStack(spacing: 20) {
                    Spacer(minLength: 0)
                    if let image = OffsetCode.image(now) {
                        Image(decorative: image, scale: 1)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .padding(side * 0.06)
                            .background(Color.white)
                            .frame(width: side, height: side)
                    }
                    Text(Self.time.string(from: now))
                        .font(.system(size: 52, weight: .semibold).monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.3)
                    Text(Self.day.string(from: now) + " UTC")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text(Words.t("Shutter 1/500 s or faster, mechanical shutter."))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    Text(Words.t("Camera facing the screen straight on."))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    Spacer(minLength: 0)
                    Text(line)
                        .font(.footnote)
                        .foregroundStyle(check == nil && checked ? .orange : .secondary)
                        .multilineTextAlignment(.center)
                    Button { dismiss() } label: { Text(Words.t("Close")).frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                }
                .padding(24)
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .background(Color(.systemBackground))
        .task {
            check = await PhoneClock.check()
            checked = true
        }
        .onAppear {
            brightness = UIScreen.main.brightness
            UIScreen.main.brightness = 1
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            UIScreen.main.brightness = brightness
            UIApplication.shared.isIdleTimerDisabled = false
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
