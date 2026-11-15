import GeotagCore
import GeotagUI
import SwiftUI
import UIKit

/// Geotag on the iPhone (14 November 2026): the Mac's own model, with the
/// card chosen in the Files list, CR3 and JPG written by Geotag's own writer,
/// and the NAS reached through the Files app.
@main
struct GeotagPhoneApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var phase
    @State private var finishing: UIBackgroundTaskIdentifier = .invalid

    init() {
        PhoneWords.load()
        #if DEBUG
        DebugHooks.run()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            PhoneRoot(model: model)
                .task {
                    #if DEBUG
                    if await DebugHooks.flow(model) { exit(0) }
                    #endif
                    await model.start()
                }
        }
        .onChange(of: phase) { _, now in
            // Sent to the background mid-photo: a little time to finish it.
            if now == .background, finishing == .invalid {
                finishing = UIApplication.shared.beginBackgroundTask(withName: "Geotag") {
                    UIApplication.shared.endBackgroundTask(finishing)
                    finishing = .invalid
                }
            } else if now == .active, finishing != .invalid {
                UIApplication.shared.endBackgroundTask(finishing)
                finishing = .invalid
            }
        }
    }
}

struct PhoneRoot: View {
    @ObservedObject var model: AppModel
    @ObservedObject var meter: SendMeter
    @State private var tab = Tab.photos

    enum Tab { case photos, tracks, queue, settings }

    init(model: AppModel) {
        self.model = model
        self.meter = model.meter
        #if DEBUG
        // Opens on a tab, for pictures of the screens in the simulator.
        if let i = CommandLine.arguments.firstIndex(of: "--tab"), CommandLine.arguments.count > i + 1 {
            let tabs: [String: Tab] = ["photos": .photos, "tracks": .tracks, "queue": .queue, "settings": .settings]
            _tab = State(initialValue: tabs[CommandLine.arguments[i + 1]] ?? .photos)
        }
        #endif
    }

    var body: some View {
        TabView(selection: $tab) {
            PhotosTab(model: model)
                .tabItem { Label(Words.t("Photos"), systemImage: "photo.on.rectangle") }
                .tag(Tab.photos)
            TracksTab(model: model)
                .tabItem { Label(Words.t("Tracks"), systemImage: "point.topleft.down.to.point.bottomright.curvepath") }
                .tag(Tab.tracks)
            QueueTab(model: model)
                .tabItem { Label(Words.t("Queue"), systemImage: "arrow.up.circle") }
                .tag(Tab.queue)
            SettingsTab(model: model)
                .tabItem { Label(Words.t("Settings"), systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        // The screen stays on while photos are saved or sent: a locked phone stops both.
        .onChange(of: model.saving || meter.count > 0) { _, busy in
            UIApplication.shared.isIdleTimerDisabled = busy
        }
        .sheet(isPresented: Binding(get: { model.trackCheck != nil }, set: { _ in })) {
            if let check = model.trackCheck { TrackCheckSheet(model: model, check: check) }
        }
    }
}

/// Three dots rising in turn while something is waited for.
struct LoaderDots: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 6) {
                ForEach(0..<3) { i in
                    let phase = (t * 2.4 - Double(i) * 0.35).truncatingRemainder(dividingBy: 2.4)
                    let lift = phase < 1 ? sin(phase * .pi) : 0
                    Circle()
                        .fill(Color.secondary)
                        .frame(width: 8, height: 8)
                        .offset(y: -6 * lift)
                        .opacity(0.4 + 0.6 * lift)
                }
            }
            .frame(height: 20)
        }
    }
}

/// The check before saving, as on the Mac (0.27.0).
struct TrackCheckSheet: View {
    @ObservedObject var model: AppModel
    let check: TrackCheck

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch check {
            case .checking:
                Text(Words.t("Checking for matching tracks")).font(.headline)
                LoaderDots().frame(maxWidth: .infinity)
            case .noTrack, .offline:
                if case .offline = check {
                    Text(Words.t("The track service isn't answering.")).font(.headline)
                }
                Text(Words.t("Not all photos have a track. Make sure this is correct."))
                    .font(check.isOffline ? .body : .headline)
                VStack(spacing: 10) {
                    Button { model.checkTracksAgain() } label: { Text(Words.t("Check tracks again")).frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent)
                    Button { model.saveAnyway() } label: { Text(Words.t("Save anyway")).frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered)
                    Button { model.dontSave() } label: { Text(Words.t("Don't save")).frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered)
                }
                .controlSize(.large)
            }
        }
        .padding(24)
        .presentationDetents([.height(check == .checking ? 140 : 300)])
        .interactiveDismissDisabled()
    }
}

extension TrackCheck {
    var isOffline: Bool {
        if case .offline = self { return true }
        return false
    }
}

/// A line that says what is going on, with a spinner while it is.
struct StatusRow: View {
    let text: String
    let busy: Bool

    var body: some View {
        if busy || !text.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if busy { ProgressView() }
                Text(text).foregroundStyle(.secondary)
            }
        }
    }
}
