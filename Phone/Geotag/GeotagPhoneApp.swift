import GeotagCore
import GeotagUI
import SwiftUI
import UIKit
import Network
import UserNotifications

/// Geotag on the iPhone (14 November 2026): the Mac's own model, with the
/// card chosen in the Files list, CR3 and JPG written by Geotag's own writer,
/// and the NAS reached through the Files app.
/// The one model, made before any screen: the phone may wake Geotag in the
/// background to hand back photos sent to the buffer server (0.30.0).
/// HeroUI's default blue, deeper than the iPhone's own (0.31.2, David):
/// oklch(62.04% 0.195 253.83), #0485F7. Also the app's accent colour.
extension Color {
    static let heroBlue = Color(red: 0.0166, green: 0.5216, blue: 0.9685)
}

@MainActor
enum PhoneModel {
    static let shared = AppModel()
}

/// The phone's call when every background transfer to the buffer server is
/// done: the next photos are handed over, then the phone is told (0.30.0).
final class PhoneAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == BufferUploads.identifier else { completionHandler(); return }
        MainActor.assumeIsolated {
            let model = PhoneModel.shared
            model.bufferUploads.finishEvents = {
                Task { @MainActor in
                    await model.sendWaiting()
                    completionHandler()
                }
            }
            model.bufferUploads.wake()
        }
    }
}

@main
struct GeotagPhoneApp: App {
    @UIApplicationDelegateAdaptor(PhoneAppDelegate.self) private var delegate
    @StateObject private var model = PhoneModel.shared
    @Environment(\.scenePhase) private var phase
    @State private var finishing: UIBackgroundTaskIdentifier = .invalid

    init() {
        PhoneWords.load()
        #if DEBUG
        DebugHooks.time()
        DebugHooks.run()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            PhoneRoot(model: model)
                .tint(.heroBlue)
                .background(KeyboardCloser())
                .task {
                    #if DEBUG
                    if await DebugHooks.flow(model) { exit(0) }
                    if await DebugHooks.watch(model) { exit(0) }
                    if await DebugHooks.pull(model) { exit(0) }
                    if await DebugHooks.list(model) { exit(0) }
                    await DebugHooks.show(model)
                    #endif
                    await model.start()
                }
        }
        .onChange(of: phase) { _, now in
            if now == .background, model.saving { model.backgroundedDuringSave = true }
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
    @State private var cards: CardWatch?
    @State private var work: BackgroundWork?
    @State private var network = NetworkWatch()
    @State private var remindMobileData = false
    @Environment(\.scenePhase) private var phase

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
        // The red internet line, fixed at the top over every tab (0.31.8, David): above
        // the tabs rather than laid over them, so each page's title row sits under it.
        VStack(spacing: 0) {
        InternetLine()
        NoticeLines(model: model)
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
        }
        // Remembered cards are looked for while Geotag is in front.
        .onAppear {
            InternetState.shared.start()
            if cards == nil { cards = CardWatch(model: model) }
            cards?.start()
            if work == nil {
                work = BackgroundWork(model: model)
                work?.start()
            }
            network.start(model: model)
        }
        .onChange(of: phase) { _, now in
            if now == .active { cards?.start() } else { cards?.stop() }
        }
        // The screen stays on while photos are saved or sent: a locked phone stops both.
        // The screen stays on while saving or sending only when the phone has not
        // taken the work on in the background (0.29.15).
        .onChange(of: model.saving || meter.count > 0) { _, busy in
            UIApplication.shared.isIdleTimerDisabled = busy && !(work?.isRunning ?? false)
            if busy, let refused = work?.refused { model.tell(refused) }
        }
        .sheet(isPresented: Binding(get: { model.trackCheck != nil }, set: { _ in })) {
            if let check = model.trackCheck { TrackCheckSheet(model: model, check: check) }
        }
        // Once on each phone: mobile data is the iPhone's to switch off (0.29.38).
        .alert(Words.t("Mobile data"), isPresented: $remindMobileData) {
            Button(Words.t("Open iPhone Settings")) {
                UserDefaults.standard.set(true, forKey: Self.remindedKey)
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            Button(Words.t("Close"), role: .cancel) { UserDefaults.standard.set(true, forKey: Self.remindedKey) }
        } message: {
            Text(Words.t("Geotag sends photos to your server over mobile data when there is no WiFi. To stop it, turn off Mobile Data for Geotag in the iPhone's Settings."))
        }
        .task {
            #if DEBUG
            if CommandLine.arguments.contains("--flow-test") { return }
            #endif
            guard !UserDefaults.standard.bool(forKey: Self.remindedKey) else { return }
            // After the iPhone's own question about notifications, never on top of it.
            for _ in 0..<240 {
                if await UNUserNotificationCenter.current().notificationSettings().authorizationStatus != .notDetermined { break }
                try? await Task.sleep(for: .milliseconds(500))
            }
            try? await Task.sleep(for: .milliseconds(600))
            remindMobileData = true
        }
    }

    static let remindedKey = "mobileDataReminded"
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

    /// The newest track, by when it starts.
    var latest: Track? { model.tracks.max { $0.start < $1.start } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch check {
            case .checking:
                Text(Words.t("Checking for matching tracks")).font(.headline)
                LoaderDots().frame(maxWidth: .infinity)
            case .ready, .noTrack, .offline:
                // Before every save on the phone (0.29.5, David, 16 November 2026).
                if case .offline = check {
                    Text(Words.t("The track service isn't answering.")).font(.headline)
                }
                if let latest {
                    // Its map, as on the Tracks page (0.31.9, David).
                    VStack(alignment: .leading, spacing: 2) {
                        TrackLargeMap(model: model, track: latest)
                            .frame(height: 170)
                        if !model.mapCredit.isEmpty {
                            Text(model.mapCredit).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.6)
                        }
                    }
                    // The place stays whole; the start goes on its own line when it does not fit (0.29.35).
                    Sentences(text: Words.t("Latest track: {0}", model.trackTitle(latest)) + LineBreaks.soft
                              + Words.t("starts {0}", When.current.dayAndTime(latest.start, zone: latest.timeZone.flatMap(TimeZone.init(identifier:)) ?? .current)))
                        .font(.headline)
                }
                if check != .ready {
                    Text(Words.t("Not all photos have a track. Make sure this is correct."))
                }
                // The choice stays the person's (0.31.8, David: "i always want the choice").
                let noOffset = model.readyToSave.filter { $0.placement == .review(.offsetNotSet) }.count
                if noOffset > 0 {
                    Text(noOffset == 1 ? Words.t("1 photo has no camera time offset. It will be saved without a location.")
                         : Words.t("{0} photos have no camera time offset. They will be saved without a location.", noOffset.formatted()))
                        .foregroundStyle(.orange)
                }
                if let problem = model.savedListProblem {
                    Text(Words.t("The list of photos already saved couldn't be read: {0} Photos already saved on the Mac may be saved again.", problem))
                        .foregroundStyle(.orange)
                }
                VStack(spacing: 10) {
                    Button { model.saveAnyway() } label: {
                        Text(model.savedListProblem == nil ? Words.t("Save photos") : Words.t("Save anyway")).frame(maxWidth: .infinity)
                    }
                        .buttonStyle(.borderedProminent)
                    Button { model.checkTracksAgain() } label: { Text(Words.t("Check tracks again")).frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered)
                    Button { model.dontSave() } label: { Text(Words.t("Don't save")).frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered)
                }
                .controlSize(.large)
            }
        }
        .padding(24)
        .presentationDetents([.height(check == .checking ? 140 : 590)])
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
            // The wheel beside the first line (0.29.28).
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if busy { ProgressView().alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 } }
                Sentences(text: text).foregroundStyle(.secondary)
            }
            // The line under the row starts at the wheel, not at the words (0.29.29).
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
        }
    }
}

/// A message that fits stays on one line; one that does not starts each
/// sentence, and each soft break, on a new line, so the breaks look meant
/// (0.29.29, David, 17 November 2026).
struct Sentences: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, part in
                ViewThatFits(in: .horizontal) {
                    Text(LineBreaks.oneLine(part)).lineLimit(1)
                    Text(LineBreaks.broken(part))
                }
            }
        }
    }
}

/// A button half the width of its row, less the gap, in a pair side by
/// side (0.29.33, David, 17 November 2026). Remove and the like are red.
struct HalfButton: View {
    let title: String
    var role: ButtonRole?
    let action: () -> Void

    init(_ title: String, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.title = title
        self.role = role
        self.action = action
    }

    var body: some View {
        Button(role: role, action: action) {
            Text(title).lineLimit(1).minimumScaleFactor(0.8).frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(role == .destructive ? .red : nil)
    }
}

/// The empty half beside a button on its own, so it keeps half the width.
struct HalfSpace: View {
    var body: some View { Color.clear.frame(maxWidth: .infinity, maxHeight: 1) }
}

/// The page's title in the top row, on the left, level with the round
/// button on the right, smaller than the big title it replaces (0.29.29).
struct PageTitle: ToolbarContent {
    let title: String

    var body: some ToolbarContent {
        if #available(iOS 26, *) {
            ToolbarItem(placement: .topBarLeading) { label }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .topBarLeading) { label }
        }
    }

    var label: some View {
        Text(title).font(.title3.weight(.bold)).lineLimit(1).fixedSize()
    }
}

/// The newest JPG of the last card, filling the screen behind the tabs,
/// centred, under a dark layer in dark mode and a light one in light mode.
struct Backdrop: View {
    let image: UIImage?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { box in
            ZStack {
                Color(.systemGroupedBackground)
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: box.size.width, height: box.size.height)
                        .clipped()
                    (scheme == .dark ? Color.black : Color.white).opacity(scheme == .dark ? 0.6 : 0.65)
                }
            }
        }
        .ignoresSafeArea()
    }
}

/// Whether the iPhone keeps Geotag off mobile data with no Wi-Fi about, so
/// sending waits for Wi-Fi instead of failing (0.29.38).
@MainActor
final class NetworkWatch {
    private var monitor: NWPathMonitor?

    func start(model: AppModel) {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak model] path in
            let blocked = path.status != .satisfied && path.unsatisfiedReason == .cellularDenied
            Task { @MainActor in model?.mobileDataBlocked = blocked }
        }
        monitor.start(queue: .global())
        self.monitor = monitor
    }
}


/// A tap outside a text field closes the keyboard, anywhere in the app (0.29.36). A tap inside
/// one is left alone, so the field keeps the keyboard and shows Paste. Taps still reach buttons.
struct KeyboardCloser: UIViewRepresentable {
    func makeUIView(context: Context) -> Watcher { Watcher() }
    func updateUIView(_ view: Watcher, context: Context) {}

    final class Watcher: UIView, UIGestureRecognizerDelegate {
        private weak var watched: UIWindow?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let window, window !== watched else { return }
            watched = window
            let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
            tap.cancelsTouchesInView = false
            tap.delegate = self
            window.addGestureRecognizer(tap)
        }

        @objc private func tapped() { watched?.endEditing(true) }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var view = touch.view
            while let v = view {
                if v is UITextField || v is UITextView { return false }
                view = v.superview
            }
            return true
        }

        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}
