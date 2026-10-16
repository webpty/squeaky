import SwiftUI

struct SettingsScreen: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Style.gap) {
                ScreenTitle(text: "Settings")

                Card(title: "Appearance") {
                    Picker("", selection: Binding(
                        get: { model.appearance },
                        set: { model.setAppearance($0) }
                    )) {
                        ForEach(Appearance.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }
            .padding(Style.pad * 1.5)
            .frame(maxWidth: 720, alignment: .leading)
        }
    }
}
