import SwiftUI
import GeotagCore

public struct RootView: View {
    @EnvironmentObject var model: AppModel

    public init() {}

    public var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 210, max: 240)
        } detail: {
            ScreenView(screen: model.screen)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .navigationTitle(appName)
        .toolbar {
            ToolbarItem(placement: .primaryAction) { CloudMacs() }
        }
        .task { EscapeCloses.start(model) }
        .sheet(isPresented: $model.settingUp) {
            SetupView()
                .textSelection(.enabled)
        }
        // Every word in Geotag can be selected and copied.
        .textSelection(.enabled)
    }
}

/// In the header: each Mac that has copied its settings to iCloud, and when
/// (0.20.0, David, 5 November 2026).
struct CloudMacs: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: 14) {
                if let problem = model.cloudProblem {
                    Label(problem, systemImage: "icloud.slash")
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                } else {
                    ForEach(model.cloudMacs, id: \.name) { mac in
                        Label("\(mac.name), \(Self.ago(mac.copied, now: context.date))", systemImage: "icloud")
                            .lineLimit(1)
                    }
                }
            }
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 8)
        }
    }

    /// "just now", "2 min ago", "3 h ago", then the day and time.
    static func ago(_ date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3600)) h ago" }
        return When.current.dayAndTime(date)
    }
}

/// A photo from the last card inserted, centred, with a band of the
/// window's own colour behind the menu fading out over it (0.23.0, David,
/// 5 November 2026). Orange, with white words, until a card has had a JPEG.
struct Sidebar: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var scheme
    /// Where the menu ends, from the top of the sidebar.
    @State private var menuBottom: CGFloat = 200
    /// How far below the menu the band fades to nothing.
    static let fade: CGFloat = 160

    private var gradient: LinearGradient {
        let colours: [Color] = scheme == .dark
            ? [Color(red: 0.722, green: 0.263, blue: 0.059), Color(red: 0.431, green: 0.145, blue: 0.035)]
            : [Color(red: 0.949, green: 0.443, blue: 0.110), Color(red: 0.851, green: 0.282, blue: 0.059)]
        return LinearGradient(colors: colours, startPoint: .top, endPoint: .bottom)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(Screen.sidebar) { screen in
                        item(screen.title, screen.symbol, chosen: model.screen == screen) {
                            model.screen = screen
                        }
                    }
                    // What used to be menus at the top of the screen.
                    Rectangle()
                        .fill(Color.primary.opacity(0.2))
                        .frame(height: 1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                    ForEach(Tool.allCases) { tool in
                        item(tool.title, tool.symbol, chosen: false, busy: tool == .download && model.makingDownload) {
                            tool.run(model, openWindow)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named("sidebar")).maxY } action: { menuBottom = $0 }
            }

            Text("\(appName) \(appVersion)")
                .font(.caption)
                .opacity(0.85)
                .lineLimit(1)
                .padding(12)
                .frame(maxWidth: .infinity)
                .background(alignment: .bottom) {
                    // The version line stays readable over the photo too.
                    if model.sidebarImage != nil {
                        LinearGradient(colors: [window.opacity(0), window], startPoint: .top, endPoint: .bottom)
                            .frame(height: 60)
                            .ignoresSafeArea()
                    }
                }
        }
        .foregroundStyle(model.sidebarImage == nil ? Color.white : Color.primary)
        .coordinateSpace(name: "sidebar")
        .background(alignment: .top) {
            if model.sidebarImage != nil {
                // Solid behind the menu and the title area above it, then fading.
                VStack(spacing: 0) {
                    window.frame(height: max(0, menuBottom))
                        .background(alignment: .bottom) { window.ignoresSafeArea(edges: .top) }
                    LinearGradient(colors: [window, window.opacity(0)], startPoint: .top, endPoint: .bottom)
                        .frame(height: Self.fade)
                    Spacer(minLength: 0)
                }
            }
        }
        .background { backdrop.ignoresSafeArea() }
    }

    private var window: Color { Color(nsColor: .windowBackgroundColor) }

    private func item(_ title: String, _ symbol: String, chosen: Bool, busy: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .frame(width: 20)
                Text(title)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if busy { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: Style.radius)
                    .fill((model.sidebarImage == nil ? Color.white.opacity(0.24) : Color.primary.opacity(0.12))
                        .opacity(chosen ? 1 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .handCursor()
        .disabled(busy)
    }

    @ViewBuilder private var backdrop: some View {
        if let image = model.sidebarImage {
            // The photo's centre on the sidebar's, cropped evenly.
            GeometryReader { box in
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: box.size.width, height: box.size.height)
                    .clipped()
            }
        } else {
            gradient
        }
    }
}

struct ScreenView: View {
    let screen: Screen

    var body: some View {
        switch screen {
        case .tracks:
            TracksScreen()
        case .photos:
            PhotosScreen()
        case .queue:
            QueueScreen()
        case .history:
            HistoryScreen()
        case .settings:
            SettingsScreen()
        }
    }
}
