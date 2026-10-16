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
        .overlay {
            if let id = model.viewing {
                TrackViewer(trackId: id)
                    .transition(.opacity)
            }
        }
    }
}

/// Orange, so Geotag stands out from every other window. White words on it.
struct Sidebar: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.colorScheme) private var scheme

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
                    ForEach(Screen.allCases) { screen in
                        Button {
                            model.screen = screen
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: screen.symbol)
                                    .frame(width: 20)
                                Text(screen.title)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10)
                            .frame(height: 32)
                            .background(
                                RoundedRectangle(cornerRadius: Style.radius)
                                    .fill(Color.white.opacity(model.screen == screen ? 0.24 : 0))
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)
            }

            Text("\(appName) \(appVersion)")
                .font(.caption)
                .opacity(0.85)
                .lineLimit(1)
                .padding(12)
        }
        .foregroundStyle(.white)
        .background(gradient.ignoresSafeArea())
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
        case .history:
            HistoryScreen()
        case .settings:
            SettingsScreen()
        default:
            EmptyScreen(title: screen.title)
        }
    }
}

/// A section not built yet: its title and nothing else.
struct EmptyScreen: View {
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: Style.gap) {
            ScreenTitle(text: title)
            Spacer()
        }
        .padding(Style.pad * 1.5)
    }
}
