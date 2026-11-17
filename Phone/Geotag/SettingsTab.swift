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
    @State private var showingCode = false
    @State private var changing: AppModel.KnownCard?
    /// The card being renamed, and the name typed (0.29.30).
    @State private var renaming: AppModel.KnownCard?
    @State private var newName = ""
    /// The track service's address and key open for editing (0.29.30).
    @State private var editingService = false
    @State private var showingFormat = false
    @State private var showingHowTo = false
    /// A field being typed in: only then does a tap anywhere close the keyboard (0.29.33).
    @FocusState private var typing: Bool

    var owner: Person? { model.macOwner.flatMap { model.book.person($0) } }

    /// Something typed and not saved yet: the checkmark turns blue (0.29.25).
    var unsaved: Bool { model.serviceUnsaved }

    /// The address and key as fields: none saved yet, or Change tapped.
    var serviceFields: Bool { editingService || !model.serviceKeySaved }

    var body: some View {
        NavigationStack {
            Form {
                // One line per camera: its name, and whether its offset is set (0.29.30, David:
                // the figure itself tells nothing, and it drifts). Set by the offset code.
                Section(Words.t("Cameras")) {
                    if let owner {
                        ForEach(model.book.cameras(of: owner.id)) { CameraLine(camera: $0) }
                    }
                    Button(Words.t("Show offset code")) { showingCode = true }
                }
                if !model.book.cameras(of: PhoneFolders.othersId).isEmpty {
                    Section(Words.t("Other cameras")) {
                        ForEach(model.book.cameras(of: PhoneFolders.othersId)) { CameraLine(camera: $0) }
                    }
                }
                // Each SD card read, and who it belongs to; changed only here (0.29.19).
                if !model.knownCards.isEmpty {
                    Section(Words.t("SD cards")) {
                        ForEach(model.knownCards) { card in
                            VStack(alignment: .leading, spacing: 8) {
                                // Name and owner on one line (0.29.33).
                                HStack {
                                    Text(card.name).lineLimit(1)
                                    Spacer()
                                    Text(card.personId == PhoneFolders.othersId ? Words.t("Belongs to someone else") : Words.t("Belongs to you"))
                                        .foregroundStyle(.secondary).lineLimit(1)
                                }
                                HStack(spacing: 12) {
                                    // Renamed only while that card is in (0.29.33).
                                    HalfButton(Words.t("Rename")) { newName = card.name; renaming = card }
                                        .disabled(model.source?.id != card.id)
                                    HalfButton(Words.t("Change")) { changing = card }
                                }
                            }
                        }
                    }
                }
                Section {
                    if serviceFields {
                        LabeledContent(Words.t("Address")) {
                            TextField("", text: $model.serviceAddress)
                                .focused($typing)
                                .textContentType(.URL)
                                .keyboardType(.URL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .multilineTextAlignment(.trailing)
                        }
                        LabeledContent(Words.t("Key")) {
                            SecureField("", text: $model.serviceKey)
                                .focused($typing)
                                .multilineTextAlignment(.trailing)
                        }
                        if editingService, model.serviceKeySaved {
                            Button(Words.t("Cancel")) { model.revertService(); editingService = false }
                                .buttonStyle(.bordered)
                        }
                    } else {
                        LabeledContent(Words.t("Address")) {
                            Text(model.serviceAddress).lineLimit(1).truncationMode(.middle)
                        }
                        // A key saved: a green check, not its dots (0.29.30).
                        LabeledContent(Words.t("Key")) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                .accessibilityLabel(Words.t("Saved"))
                        }
                        HStack(spacing: 12) {
                            HalfButton(Words.t("Change")) { editingService = true }
                            HalfButton(Words.t("Remove"), role: .destructive) {
                                editingService = false
                                Task { await model.removeService() }
                            }
                        }
                    }
                    StatusRow(text: model.settingsLine, busy: model.settingsBusy)
                } header: {
                    InfoHeader(title: Words.t("GPS tracks service")) { showingFormat = true }
                }
                Section {
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
                    // Change and Remove side by side, as buttons (0.29.30).
                    HStack(spacing: 12) {
                        HalfButton(PhoneFolders.isChosen(PhoneFolders.nasKey) ? Words.t("Change") : Words.t("Choose")) {
                            problem = nil
                            choosing = true
                        }
                        if PhoneFolders.isChosen(PhoneFolders.nasKey) {
                            HalfButton(Words.t("Remove"), role: .destructive) {
                                nasName = nil
                                folderProblem = nil
                                Task { await model.forgetNASFolder() }
                            }
                        } else {
                            HalfSpace()
                        }
                    }
                    StatusRow(text: model.nasLine, busy: model.nasBusy)
                } header: {
                    // The steps to connect a file server, behind the i (0.29.30).
                    InfoHeader(title: Words.t("Server")) { showingHowTo = true }
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
            .navigationDestination(isPresented: $showingFormat) { ServiceFormat() }
            .navigationDestination(isPresented: $showingHowTo) { ConnectServer() }
            .confirmationDialog(Words.t("Is this your card?"),
                                isPresented: Binding(get: { changing != nil }, set: { if !$0 { changing = nil } }),
                                titleVisibility: .visible) {
                Button(Words.t("Yes")) { if let card = changing, let me = model.macOwner { model.setOwner(of: card.id, to: me) } }
                Button(Words.t("No")) { if let card = changing { model.setOwner(of: card.id, to: PhoneFolders.othersId) } }
                Button(Words.t("Cancel"), role: .cancel) {}
            }
            // The name Geotag shows for a card; the card itself is never changed (0.29.30).
            .alert(Words.t("Rename SD card"),
                   isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField(Words.t("Name"), text: $newName)
                Button(Words.t("Save")) { if let card = renaming { model.rename(card: card.id, to: newName) } }
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
            // A tap outside the keyboard closes it (0.29.25), only while typing: always on, it
            // caught the taps on plain buttons such as Show offset code (0.29.33).
            .simultaneousGesture(TapGesture().onEnded { typing = false }, including: typing ? .all : .subviews)
            .onAppear {
                #if DEBUG
                if CommandLine.arguments.contains("--offset-code") { showingCode = true }
                if CommandLine.arguments.contains("--service-format") { showingFormat = true }
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

    /// The checkmark (David, 16 November 2026): everything typed is saved,
    /// and the keyboard closes.
    func saveAll() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        if model.serviceUnsaved {
            editingService = false
            Task { await model.saveService() }
        } else if editingService {
            editingService = false
        }
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

/// A camera on one line: its name, and "Offset" with a small green check
/// once its offset is set, else "Not set" (0.29.30, David, 17 November 2026).
struct CameraLine: View {
    let camera: Camera

    var body: some View {
        HStack {
            Text(camera.model)
            Spacer()
            if camera.offsetSeconds != nil {
                Text(Words.t("Offset")).foregroundStyle(.secondary)
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).imageScale(.small)
            } else {
                Text(Words.t("Not set")).foregroundStyle(.secondary)
            }
        }
    }
}

/// A section heading with a small i on the right that opens its page (0.29.30).
struct InfoHeader: View {
    let title: String
    let open: () -> Void

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Button(action: open) { Image(systemName: "info.circle") }
                .accessibilityLabel(Words.t("About {0}", title))
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
