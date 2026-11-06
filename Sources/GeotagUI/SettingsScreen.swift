import SwiftUI
import GeotagCore

struct SettingsScreen: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Style.gap) {
                ScreenTitle(text: "Settings")
                TrackServiceCard()
                NASCard()
                PeopleCard()
                CamerasCard()
                if !model.book.lenses.isEmpty { LensesCard() }
                MatchingCard()
                PhotosListCard()
                CardsCard()
                DatesCard()
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

struct TrackServiceCard: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmDisconnect = false

    var body: some View {
        Card(title: "Track service") {
            Grid(alignment: .leading, horizontalSpacing: Style.gap, verticalSpacing: Style.gap) {
                GridRow {
                    Text("Address").lineLimit(1).frame(width: Style.labelWidth, alignment: .leading)
                    TextField("", text: $model.serviceAddress)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Key").lineLimit(1).frame(width: Style.labelWidth, alignment: .leading)
                    SecureField("", text: $model.serviceKey)
                        .textFieldStyle(.roundedBorder)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: Style.gap) {
                Button {
                    Task { await model.saveService() }
                } label: {
                    Text("Save").buttonLabel()
                }
                .keyboardShortcut(.defaultAction)
                // Greyed out until the address or key changes.
                .disabled(!model.serviceUnsaved)
                Button {
                    Task { await model.testService() }
                } label: {
                    Text("Test").buttonLabel()
                }
                StatusLine(text: model.settingsLine, lines: 2, busy: model.settingsBusy)
            }
            .disabled(model.settingsBusy)

            if model.role == .owner {
                Divider()
                HStack(spacing: Style.gap) {
                    Text(stravaLine)
                        .lineLimit(1)
                    Spacer()
                    if model.serviceStatus?.strava.connected == true {
                        Button {
                            confirmDisconnect = true
                        } label: {
                            Text("Disconnect").buttonLabel()
                        }
                    } else {
                        Button {
                            Task { await model.connectStrava() }
                        } label: {
                            Text("Connect Strava").buttonLabel()
                        }
                        .disabled(!model.hasService)
                    }
                }
                .disabled(model.settingsBusy)
            }
        }
        .alert("Disconnect Strava?", isPresented: $confirmDisconnect) {
            Button("Disconnect", role: .destructive) {
                Task { await model.disconnectStrava() }
            }
            Button("Cancel", role: .cancel) {}
        }
        .task {
            if model.serviceStatus == nil, !model.serviceAddress.isEmpty { await model.testService() }
        }
    }

    private var stravaLine: String {
        guard let strava = model.serviceStatus?.strava else { return "Strava" }
        if strava.connected {
            return strava.athlete.map { "Strava: connected as \($0)" } ?? "Strava: connected"
        }
        return "Strava: not connected"
    }
}
