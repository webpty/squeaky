import GeotagCore
import GeotagUI
import SwiftUI
import UniformTypeIdentifiers

/// What the phone needs of its own: the track service key, Geotag's folder in
/// iCloud Drive (people, cameras and settings from the Macs) and the NAS.
struct SettingsTab: View {
    @ObservedObject var model: AppModel
    @State private var choosing = false
    @State private var choice = Choice.cloud
    @State private var problem: String?
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
                    Button("Choose") { choose(.cloud) }
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
                    Button("Choose") { choose(.nas) }
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
                if let problem {
                    Section { Text(problem).foregroundStyle(.secondary) }
                }
                Section {
                    LabeledContent("Version", value: appVersion)
                }
            }
            .navigationTitle("Settings")
            .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
                switch result {
                case .success(let url): keep(url, as: choice)
                case .failure(let error): problem = error.localizedDescription
                }
            }
        }
    }

    func choose(_ which: Choice) {
        choice = which
        problem = nil
        choosing = true
    }

    /// The folder kept for next time, and put to use at once.
    func keep(_ url: URL, as which: Choice) {
        let key = which == .cloud ? PhoneFolders.cloudKey : PhoneFolders.nasKey
        PhoneFolders.forget(key)
        do {
            try PhoneFolders.remember(url, as: key)
        } catch {
            problem = "\(url.lastPathComponent) could not be kept: \(error.localizedDescription)"
            return
        }
        switch which {
        case .cloud:
            cloudName = PhoneFolders.name(key)
            if let folder = PhoneFolders.cloud() { Task { await model.useCloudFolder(folder) } }
        case .nas:
            nasName = PhoneFolders.name(key)
            Task { await model.useNASFolder() }
        }
    }
}
