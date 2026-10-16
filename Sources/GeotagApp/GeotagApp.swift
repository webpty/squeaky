import SwiftUI
import GeotagUI

@main
struct GeotagApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .preferredColorScheme(model.appearance.colorScheme)
                .frame(minWidth: 940, minHeight: 620)
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
