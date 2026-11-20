import Combine
import Foundation
import SqueakyCore
import Network
import SwiftUI

/// The internet as Squeaky sees it, for the red line at the top (0.31.8,
/// David, 18 November 2026): none at all, from the device's own network
/// state, or unstable, from `NetHealth`.
@MainActor
public final class InternetState: ObservableObject {
    public static let shared = InternetState()

    @Published public private(set) var connected = true
    @Published public private(set) var unstable = false
    private var monitor: NWPathMonitor?
    private var timer: Timer?

    /// What the red line says; nil while all is well.
    public var line: String? {
        if !connected { return Words.t("No internet connection") }
        if unstable { return Words.t("The internet connection is unstable") }
        return nil
    }

    public func start() {
        guard monitor == nil else { return }
        #if DEBUG
        // Pictures of the red line in the simulator.
        if CommandLine.arguments.contains("--show-unstable") { unstable = true; return }
        #endif
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let on = path.status == .satisfied
            Task { @MainActor in self?.connected = on }
        }
        monitor.start(queue: .global(qos: .utility))
        self.monitor = monitor
        // Failures age out after a minute, so it is looked at again every two seconds.
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let now = NetHealth.shared.unstable()
                if now != self.unstable { self.unstable = now }
            }
        }
    }
}

/// The red line, fixed at the top of the window or screen while it applies.
public struct InternetLine: View {
    @ObservedObject var state: InternetState

    @MainActor public init() { self.state = .shared }

    public var body: some View {
        if let line = state.line {
            Text(line)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .padding(.horizontal, 16)
                .background(Color.red.ignoresSafeArea(edges: .top))
                .accessibilityAddTraits(.isStaticText)
        }
    }
}

/// Notices that stay until closed (0.31.9, David: offset codes read): inside
/// Squeaky, under the red line, never a system notification.
public struct NoticeLines: View {
    @ObservedObject var model: AppModel

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        VStack(spacing: 0) {
            ForEach(model.offsetNotices, id: \.self) { line in
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(line).lineLimit(1).minimumScaleFactor(0.8)
                    Spacer(minLength: 8)
                    Button {
                        model.offsetNotices.removeAll { $0 == line }
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(Words.t("Close"))
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 16)
                .background(.regularMaterial)
            }
            // A track a family phone passed on, acknowledged with OK (0.32.0, David).
            ForEach(model.trackNotices, id: \.self) { line in
                HStack(spacing: 10) {
                    Image(systemName: "point.topleft.down.to.point.bottomright.curvepath").foregroundStyle(.green)
                    Text(line).lineLimit(2).minimumScaleFactor(0.8)
                    Spacer(minLength: 8)
                    Button(Words.t("OK")) {
                        model.trackNotices.removeAll { $0 == line }
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 16)
                .background(.regularMaterial)
            }
        }
    }
}
