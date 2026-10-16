import SwiftUI
import GeotagCore

public struct RootView: View {
    @EnvironmentObject var model: AppModel

    public init() {}

    public var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                List(selection: Binding(
                    get: { model.screen },
                    set: { if let screen = $0 { model.screen = screen } }
                )) {
                    ForEach(Screen.allCases) { screen in
                        Label(screen.title, systemImage: screen.symbol)
                            .lineLimit(1)
                            .tag(screen)
                    }
                }
                .listStyle(.sidebar)

                Divider()

                Text("\(appName) \(appVersion)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(12)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 210, max: 240)
        } detail: {
            ScreenView(screen: model.screen)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .navigationTitle(appName)
    }
}

struct ScreenView: View {
    let screen: Screen

    var body: some View {
        switch screen {
        case .tracks:
            TracksScreen()
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
