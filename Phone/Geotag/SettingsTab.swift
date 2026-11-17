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
    @State private var nasName = PhoneFolders.savedPath(PhoneFolders.nasKey)
    /// Why the server folder cannot be opened, when it cannot (0.29.11).
    @State private var folderProblem: String?
    /// Offsets typed, by camera, until the checkmark saves them.
    @State private var offsets: [UUID: String] = [:]
    @State private var showingCode = false
    @State private var changing: AppModel.KnownCard?

    var owner: Person? { model.macOwner.flatMap { model.book.person($0) } }

    /// Something typed and not saved yet: the checkmark turns blue (0.29.25).
    var unsaved: Bool {
        model.serviceUnsaved || model.book.cameras.contains { camera in
            guard let text = offsets[camera.id] else { return false }
            return Int(text.trimmingCharacters(in: .whitespaces)) != camera.offsetSeconds
        }
    }

    var body: some View {
        NavigationStack {
            Form {
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
                // Each SD card read, and who it belongs to; changed only here (0.29.19).
                if !model.knownCards.isEmpty {
                    Section(Words.t("SD cards")) {
                        ForEach(model.knownCards) { card in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(card.name)
                                    Text(card.personId == PhoneFolders.othersId ? Words.t("Belongs to someone else") : Words.t("Belongs to you"))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button(Words.t("Change")) { changing = card }
                                    .buttonStyle(.bordered)
                            }
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
                    Toggle(Words.t("Allow backup over mobile data"),
                           isOn: Binding(get: { model.allowMobileData }, set: { model.setAllowMobileData($0) }))
                    LabeledContent(Words.t("Folder")) {
                        // The path being worked out: the wheel (0.29.26).
                        if nasName == nil, PhoneFolders.isChosen(PhoneFolders.nasKey), folderProblem == nil {
                            ProgressView()
                        } else {
                            Text(nasName ?? Words.t("Not chosen")).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    if let folderProblem {
                        Sentences(text: folderProblem).foregroundStyle(.orange)
                    }
                    Button(PhoneFolders.isChosen(PhoneFolders.nasKey) ? Words.t("Change") : Words.t("Choose")) {
                        problem = nil
                        choosing = true
                    }
                    if PhoneFolders.isChosen(PhoneFolders.nasKey) {
                        Button(Words.t("Remove"), role: .destructive) {
                            nasName = nil
                            folderProblem = nil
                            Task { await model.forgetNASFolder() }
                        }
                    }
                    StatusRow(text: model.nasLine, busy: model.nasBusy)
                    NavigationLink(Words.t("How to connect a file server")) { ConnectServer() }
                }
                if let problem {
                    Section { Sentences(text: problem).foregroundStyle(.secondary) }
                }
                Section {
                    LabeledContent(Words.t("Version"), value: appVersion)
                }
            }
            .scrollContentBackground(.hidden)
            // The last card's photo behind every tab, veiled (0.29.5, David, 16 November 2026).
            .background(Backdrop(image: model.sidebarImage))
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog(Words.t("Is this your card?"),
                                isPresented: Binding(get: { changing != nil }, set: { if !$0 { changing = nil } }),
                                titleVisibility: .visible) {
                Button(Words.t("Yes")) { if let card = changing, let me = model.macOwner { model.setOwner(of: card.id, to: me) } }
                Button(Words.t("No")) { if let card = changing { model.setOwner(of: card.id, to: PhoneFolders.othersId) } }
                Button(Words.t("Cancel"), role: .cancel) {}
            }
            .scrollDismissesKeyboard(.immediately)
            .toolbar {
                PageTitle(title: Words.t("Settings"))
                ToolbarItem(placement: .topBarTrailing) {
                    Button { saveAll() } label: {
                        Image(systemName: "checkmark").foregroundStyle(unsaved ? Color.blue : Color.secondary)
                    }
                        .accessibilityLabel(Words.t("Save"))
                        .disabled(model.settingsBusy)
                }
            }
            .task {
                // A folder chosen before 0.29.8 has no saved path: worked out once, in the background.
                // Every time Settings opens: the folder tried, in the background, and why not said.
                guard PhoneFolders.isChosen(PhoneFolders.nasKey) else { folderProblem = nil; return }
                switch await PhoneFolders.savePath(PhoneFolders.nasKey) {
                case .success(let path):
                    nasName = path
                    folderProblem = nil
                case .failure(let why):
                    folderProblem = why.localizedDescription
                }
            }
            // A tap outside the keyboard closes it (0.29.25).
            .simultaneousGesture(TapGesture().onEnded {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            })
            .onAppear {
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
        nasName = PhoneFolders.shownName(url)
        folderProblem = nil
        Task {
            switch await PhoneFolders.savePath(key) {
            case .success(let path): nasName = path
            case .failure(let why): folderProblem = why.localizedDescription
            }
        }
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
