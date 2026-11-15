import GeotagCore
import GeotagUI
import SwiftUI
import UniformTypeIdentifiers

/// The phone's own settings: its one person, their cameras, the track
/// service and the NAS. Each phone is on its own (David, 15 November 2026).
struct SettingsTab: View {
    @ObservedObject var model: AppModel
    @State private var choosing = false
    @State private var problem: String?
    @State private var nasName = PhoneFolders.name(PhoneFolders.nasKey)
    @State private var name = ""
    @State private var nasFolder = ""

    var owner: Person? { model.macOwner.flatMap { model.book.person($0) } }

    var personUnsaved: Bool {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines), f = nasFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return false }
        return n != owner?.name || f != (owner?.nasFolder ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Person") {
                    LabeledContent("Name") {
                        TextField("", text: $name)
                            .textContentType(.name)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("NAS folder") {
                        TextField("", text: $nasFolder)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                    }
                    if personUnsaved {
                        Button("Save") { model.setPhonePerson(name: name, nasFolder: nasFolder) }
                    }
                }
                if let owner, !model.book.cameras(of: owner.id).isEmpty {
                    Section("Cameras") {
                        ForEach(model.book.cameras(of: owner.id)) { camera in
                            CameraRow(model: model, camera: camera)
                        }
                    }
                }
                Section("Track service") {
                    LabeledContent("Address") {
                        TextField("", text: $model.serviceAddress)
                            .textContentType(.URL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Key") {
                        SecureField("", text: $model.serviceKey)
                            .multilineTextAlignment(.trailing)
                    }
                    if model.serviceUnsaved {
                        Button("Save") { Task { await model.saveService() } }
                            .disabled(model.settingsBusy)
                    }
                    StatusRow(text: model.settingsLine, busy: model.settingsBusy)
                }
                Section("NAS") {
                    LabeledContent("Folder", value: nasName ?? "Not chosen")
                    Button(nasName == nil ? "Choose" : "Change") {
                        problem = nil
                        choosing = true
                    }
                    if nasName != nil {
                        Button("Remove", role: .destructive) {
                            nasName = nil
                            Task { await model.forgetNASFolder() }
                        }
                    }
                    StatusRow(text: model.nasLine, busy: model.nasBusy)
                }
                if let problem {
                    Section { Text(problem).foregroundStyle(.secondary) }
                }
                Section {
                    LabeledContent("Version", value: appVersion)
                }
            }
            .navigationTitle("Settings")
            .onAppear {
                name = owner?.name ?? ""
                nasFolder = owner?.nasFolder ?? ""
            }
            .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
                switch result {
                case .success(let url): keepNAS(url)
                case .failure(let error): problem = error.localizedDescription
                }
            }
        }
    }

    /// The NAS folder kept for next time, and tried at once.
    func keepNAS(_ url: URL) {
        let key = PhoneFolders.nasKey
        PhoneFolders.forget(key)
        do {
            try PhoneFolders.remember(url, as: key)
        } catch {
            problem = "\(url.lastPathComponent) could not be kept: \(error.localizedDescription)"
            return
        }
        nasName = PhoneFolders.name(key)
        Task { await model.useNASFolder() }
    }
}

/// A camera and its clock offset, in seconds ahead (negative behind), set
/// by the offset code or typed here.
struct CameraRow: View {
    @ObservedObject var model: AppModel
    let camera: Camera
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(camera.model)
            HStack {
                Text("Offset").foregroundStyle(.secondary)
                TextField("Seconds", text: $text)
                    .keyboardType(.numbersAndPunctuation)
                    .multilineTextAlignment(.trailing)
                    .onSubmit(save)
            }
            Text(OffsetText.describe(camera.offsetSeconds)).font(.caption).foregroundStyle(.secondary)
            if typed != camera.offsetSeconds, typed != nil {
                Button("Save", action: save)
            }
        }
        .onAppear { text = camera.offsetSeconds.map(String.init) ?? "" }
        .onChange(of: camera.offsetSeconds) { _, now in text = now.map(String.init) ?? "" }
    }

    var typed: Int? { Int(text.trimmingCharacters(in: .whitespaces)) }

    func save() {
        guard let typed else { return }
        var changed = camera
        changed.offsetSeconds = typed
        model.save(changed)
    }
}
