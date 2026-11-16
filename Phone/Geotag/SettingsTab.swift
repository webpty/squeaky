import GeotagCore
import GeotagUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The phone's own settings: its one person, their cameras, the track
/// service and the server. Each phone is on its own (David, 15 November 2026).
struct SettingsTab: View {
    @ObservedObject var model: AppModel
    @State private var choosing = false
    @State private var problem: String?
    @State private var nasName = PhoneFolders.name(PhoneFolders.nasKey)
    @State private var name = ""
    /// Offsets typed, by camera, until the checkmark saves them.
    @State private var offsets: [UUID: String] = [:]
    @State private var showingCode = false

    var owner: Person? { model.macOwner.flatMap { model.book.person($0) } }

    var personUnsaved: Bool {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !n.isEmpty && n != owner?.name
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(Words.t("Person")) {
                    LabeledContent(Words.t("Name")) {
                        TextField("", text: $name)
                            .textContentType(.name)
                            .multilineTextAlignment(.trailing)
                    }
                }
                Section(Words.t("Cameras")) {
                    if let owner {
                        ForEach(model.book.cameras(of: owner.id)) { camera in
                            CameraRow(camera: camera, text: offset(camera))
                        }
                    }
                    Button(Words.t("Show offset code")) { showingCode = true }
                }
                if !model.book.cameras(of: PhoneFolders.othersId).isEmpty {
                    Section(Words.t("Other cameras")) {
                        ForEach(model.book.cameras(of: PhoneFolders.othersId)) { camera in
                            CameraRow(camera: camera, text: offset(camera))
                        }
                    }
                }
                Section(Words.t("Track service")) {
                    LabeledContent(Words.t("Address")) {
                        TextField("", text: $model.serviceAddress)
                            .textContentType(.URL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent(Words.t("Key")) {
                        SecureField("", text: $model.serviceKey)
                            .multilineTextAlignment(.trailing)
                    }
                    StatusRow(text: model.settingsLine, busy: model.settingsBusy)
                }
                Section(Words.t("Server")) {
                    LabeledContent(Words.t("Folder"), value: nasName ?? Words.t("Not chosen"))
                    Button(nasName == nil ? Words.t("Choose") : Words.t("Change")) {
                        problem = nil
                        choosing = true
                    }
                    if nasName != nil {
                        Button(Words.t("Remove"), role: .destructive) {
                            nasName = nil
                            Task { await model.forgetNASFolder() }
                        }
                    }
                    StatusRow(text: model.nasLine, busy: model.nasBusy)
                    NavigationLink(Words.t("How to connect a file server")) { ConnectServer() }
                }
                if let problem {
                    Section { Text(problem).foregroundStyle(.secondary) }
                }
                Section {
                    LabeledContent(Words.t("Version"), value: appVersion)
                }
            }
            .navigationTitle(Words.t("Settings"))
            .scrollDismissesKeyboard(.immediately)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { saveAll() } label: { Image(systemName: "checkmark") }
                        .accessibilityLabel(Words.t("Save"))
                        .disabled(model.settingsBusy)
                }
            }
            .onAppear {
                name = owner?.name ?? ""
                #if DEBUG
                if CommandLine.arguments.contains("--offset-code") { showingCode = true }
                #endif
            }
            .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
                switch result {
                case .success(let url): keepNAS(url)
                case .failure(let error): problem = error.localizedDescription
                }
            }
        }
        // Apart from the Files list: two on one view and neither opens.
        .fullScreenCover(isPresented: $showingCode) { OffsetCodeScreen() }
    }

    /// What is typed for a camera's offset: its saved offset until changed.
    func offset(_ camera: Camera) -> Binding<String> {
        Binding(get: { offsets[camera.id] ?? camera.offsetSeconds.map(String.init) ?? "" },
                set: { offsets[camera.id] = $0 })
    }

    /// The checkmark (David, 16 November 2026): everything typed is saved,
    /// and the keyboard closes.
    func saveAll() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        if personUnsaved { model.setPhonePerson(name: name) }
        for camera in model.book.cameras {
            guard let text = offsets[camera.id] else { continue }
            let typed = Int(text.trimmingCharacters(in: .whitespaces))
            if let typed, typed != camera.offsetSeconds {
                var changed = camera
                changed.offsetSeconds = typed
                model.save(changed)
            }
        }
        offsets = [:]
        if model.serviceUnsaved { Task { await model.saveService() } }
    }

    /// The NAS folder kept for next time, and tried at once.
    func keepNAS(_ url: URL) {
        let key = PhoneFolders.nasKey
        PhoneFolders.forget(key)
        do {
            try PhoneFolders.remember(url, as: key)
        } catch {
            problem = Words.t("{0} could not be kept: {1}", PhoneFolders.shownName(url), error.localizedDescription)
            return
        }
        nasName = PhoneFolders.name(key)
        Task { await model.useNASFolder() }
    }
}

/// A camera and its clock offset, in seconds ahead (negative behind), set
/// by the offset code or typed here and saved with the checkmark.
struct CameraRow: View {
    let camera: Camera
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(camera.model)
            HStack {
                Text(Words.t("Offset")).foregroundStyle(.secondary)
                TextField(Words.t("Seconds"), text: $text)
                    .keyboardType(.numbersAndPunctuation)
                    .multilineTextAlignment(.trailing)
            }
            Text(OffsetText.describe(camera.offsetSeconds)).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// How to connect a file server, such as a NAS, so its folder can be chosen
/// (David, 15 November 2026).
struct ConnectServer: View {
    var body: some View {
        List {
            ForEach(Array(Self.steps.enumerated()), id: \.offset) { i, step in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("\(i + 1)").foregroundStyle(.secondary).monospacedDigit()
                    Text(Words.t(step))
                }
            }
        }
        .navigationTitle(Words.t("Connect a file server"))
        .navigationBarTitleDisplayMode(.inline)
    }

    static let steps = [
        "Open the Files app and tap Browse.",
        "Tap the three dots at the top right, then Connect to Server.",
        "Type the server's address, such as smb://10.0.10.10, and tap Connect.",
        "Choose Registered User, enter the user name and password, and tap Next.",
        "Come back to Geotag and tap Choose under Server.",
        "Open the server, open the folder the photos go into, and tap Open.",
    ]
}
