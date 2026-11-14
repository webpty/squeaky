import GeotagCore
import GeotagUI
import SwiftUI
import UniformTypeIdentifiers

/// What the phone needs of its own: the track service key, Geotag's folder in
/// iCloud Drive (people, cameras and settings from the Macs) and the NAS.
struct SettingsTab: View {
    @ObservedObject var model: AppModel
    @State private var choosing: Choice?
    @State private var cloudName = PhoneFolders.name(PhoneFolders.cloudKey)
    @State private var nasName = PhoneFolders.name(PhoneFolders.nasKey)

    enum Choice: Identifiable {
        case cloud, nas
        var id: Self { self }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("iCloud Drive") {
                    LabeledContent("Geotag folder", value: cloudName ?? "Not chosen")
                    Button("Choose") { choosing = .cloud }
                    if let problem = model.cloudProblem, cloudName != nil {
                        Text(problem).foregroundStyle(.secondary)
                    }
                }
                Section("Track service") {
                    TextField("Address", text: $model.serviceAddress)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Key", text: $model.serviceKey)
                    Button("Save") { Task { await model.saveService() } }
                        .disabled(model.settingsBusy)
                    StatusRow(text: model.settingsLine, busy: model.settingsBusy)
                }
                Section("NAS") {
                    LabeledContent("Folder", value: nasName ?? "Not chosen")
                    Button("Choose") { choosing = .nas }
                    StatusRow(text: model.nasLine, busy: model.nasBusy)
                }
                Section("People") {
                    ForEach(model.book.people) { person in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(person.name)
                            if let nas = person.nasFolder {
                                Text(nas).font(.caption).foregroundStyle(.secondary)
                            }
                            ForEach(model.book.cameras(of: person.id)) { camera in
                                Text("\(camera.model): \(OffsetText.describe(camera.offsetSeconds))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section {
                    LabeledContent("Version", value: appVersion)
                }
            }
            .navigationTitle("Settings")
            .fileImporter(isPresented: Binding(get: { choosing != nil }, set: { if !$0 { choosing = nil } }),
                          allowedContentTypes: [.folder]) { result in
                let which = choosing
                choosing = nil
                guard case .success(let url) = result, let which else { return }
                switch which {
                case .cloud:
                    PhoneFolders.forget(PhoneFolders.cloudKey)
                    try? PhoneFolders.remember(url, as: PhoneFolders.cloudKey)
                    cloudName = PhoneFolders.name(PhoneFolders.cloudKey)
                    if let folder = PhoneFolders.cloud() { Task { await model.useCloudFolder(folder) } }
                case .nas:
                    PhoneFolders.forget(PhoneFolders.nasKey)
                    try? PhoneFolders.remember(url, as: PhoneFolders.nasKey)
                    nasName = PhoneFolders.name(PhoneFolders.nasKey)
                    Task { await model.useNASFolder() }
                }
            }
        }
    }
}
