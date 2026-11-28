import SqueakyCore
import SqueakyUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The phone's own settings: its one person, their cameras, the track
/// service and the server. Each phone is on its own (David, 15 November 2026).
struct SettingsTab: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var watch = WatchLink.shared
    @State private var showingCode = false
    @State private var changing: AppModel.KnownCard?
    /// The card whose Remove waits for its confirmation (1.0.2).
    @State private var removingCard: AppModel.KnownCard?
    /// The key panel open, for the track service or the buffer server (1.0.2, David).
    @State private var editing: KeyPanel.Kind?
    @State private var showingFormat = false

    var owner: Person? { model.macOwner.flatMap { model.book.person($0) } }

    /// "28 Nov 2026", in the phone's own order.
    static func day(_ date: Date) -> String {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("dMMMy")
        return f.string(from: date)
    }

    var body: some View {
        NavigationStack {
            Form {
                // Every error, in red, at the top, copied with one tap (1.0.3, David).
                let errors = model.settingsErrors + (watch.problem.map { [Words.t("Watch: {0}", $0)] } ?? [])
                if !errors.isEmpty {
                    ErrorsSection(lines: errors)
                }
                // One line per camera: its name, and whether its offset is set (0.29.30, David:
                // the figure itself tells nothing, and it drifts). Set by the offset code.
                Section(Words.t("Cameras")) {
                    if let owner {
                        ForEach(model.book.cameras(of: owner.id)) { CameraLine(camera: $0) }
                    }
                    Button(Words.t("Show offset code")) { showingCode = true }
                        .buttonStyle(WideButton(.grey)).buttonRow()
                }.cardRows()
                if !model.book.cameras(of: PhoneFolders.othersId).isEmpty {
                    Section(Words.t("Other cameras")) {
                        ForEach(model.book.cameras(of: PhoneFolders.othersId)) { CameraLine(camera: $0) }
                    }.cardRows()
                }
                // Each SD card read, and who it belongs to; changed only here (0.29.19).
                if !model.knownCards.isEmpty {
                    Section(Words.t("Cards")) {
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
                                    HalfButton(Words.t("Change")) { changing = card }
                                        // Opens from this button, not the top of the page (0.29.39).
                                        .confirmationDialog(Words.t("Is this your card?"),
                                                            isPresented: Binding(get: { changing?.id == card.id },
                                                                                 set: { if !$0 { changing = nil } }),
                                                            titleVisibility: .visible) {
                                            Button(Words.t("Yes")) { if let me = model.macOwner { model.setOwner(of: card.id, to: me) } }
                                            Button(Words.t("No")) { model.setOwner(of: card.id, to: PhoneFolders.othersId) }
                                            Button(Words.t("Cancel"), role: .cancel) {}
                                        }
                                    // Rename removed: the iPhone cannot rename a card (0.29.44, David).
                                    // Remove (0.34.18, David): for a folder opened as a card by mistake.
                                    // Asked first, from the button (1.0.2, David: "confirm everywhere").
                                    HalfButton(Words.t("Remove"), role: .destructive) { removingCard = card }
                                        .disabled(model.saving && model.source?.id == card.id)
                                        .confirmationDialog(Words.t("Remove {0}?", card.name),
                                                            isPresented: Binding(get: { removingCard?.id == card.id },
                                                                                 set: { if !$0 { removingCard = nil } }),
                                                            titleVisibility: .visible) {
                                            Button(Words.t("Remove"), role: .destructive) { CardWatch.remove(card.id, model: model) }
                                            Button(Words.t("Cancel"), role: .cancel) {}
                                        }
                                }
                            }
                        }
                    }.cardRows()
                }
                Section {
                    Toggle(Words.t("Use Geotrac's tracks"), isOn: Binding(
                        get: { model.useGeotracTracks },
                        set: { on in Task { await model.setUseGeotracTracks(on) } }))
                    // Address and key, with an edit icon opening their panel (1.0.2, David).
                    KeyRows(address: model.serviceKeySaved ? model.serviceAddress : nil,
                            saved: model.serviceKeySaved) { editing = .service }
                    StatusRow(text: model.settingsLine, busy: model.settingsBusy)
                } header: {
                    InfoHeader(title: Words.t("GPS tracks service")) { showingFormat = true }
                }.cardRows()
                // Photos go to the buffer server, the NAS fetches them; no direct
                // access to the server (1.0.2, David).
                Section(Words.t("Buffer server")) {
                    KeyRows(address: model.bufferKeySaved ? model.bufferAddress : nil,
                            saved: model.bufferKeySaved) { editing = .buffer }
                    StatusRow(text: model.bufferLine, busy: model.bufferBusy)
                    // The sync line (0.34.9); the wheel while it works.
                    // The sync list in two rows (1.0.5, David): how many items, photos and
                    // videos alike, and the day of the last update. A failure shows in red at the top.
                    if let activity = model.syncActivity {
                        StatusRow(text: activity, busy: true)
                    }
                    LabeledContent(Words.t("Sync list")) {
                        Text(model.lastSave.map { $0.count == 1 ? Words.t("1 item") : Words.t("{0} items", $0.count.formatted()) }
                             ?? Words.t("Not synced yet"))
                    }
                    if let last = model.lastSave {
                        LabeledContent(Words.t("Last update")) { Text(Self.day(last.at)) }
                    }
                }.cardRows()
                // The Geotrac app on a Garmin watch, picked once in Garmin Connect (0.32.0).
                Section(Words.t("Watch")) {
                    LabeledContent(Words.t("Watch")) {
                        Text(watch.watchName ?? Words.t("Not chosen")).lineLimit(1).truncationMode(.middle)
                    }
                    HStack(spacing: 12) {
                        HalfButton(watch.watchName == nil ? Words.t("Choose watch") : Words.t("Change")) { watch.choose() }
                        HalfSpace()
                    }
                    if let line = watch.problem {
                        StatusRow(text: line, busy: false)
                    }
                }.cardRows()
                // What the iPhone keeps for Squeaky, one tap away (0.29.38, David).
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Button(Words.t("Open iPhone Settings for Squeaky")) {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }
                        .buttonStyle(WideButton(.grey))
                        Text(Words.t("Language, access to Photos, notifications and mobile data"))
                            .font(.footnote).foregroundStyle(Color(uiColor: .secondaryLabel))
                    }
                }.cardRows()
                Section {
                    LabeledContent(Words.t("Version"), value: appVersion)
                }.cardRows()
            }
            .scrollContentBackground(.hidden)
            // The last card's photo behind every tab, veiled (0.29.5, David, 16 November 2026).
            .background(Backdrop(image: model.sidebarImage))
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $showingFormat) { ServiceFormat() }
            // No save at the top (1.0.2, David): the key panels save.
            .toolbar { PageTitle(title: Words.t("Settings")) }
            .sheet(item: $editing) { kind in KeyPanel(model: model, kind: kind) }
            .onAppear {
                #if DEBUG
                if CommandLine.arguments.contains("--offset-code") { showingCode = true }
                if CommandLine.arguments.contains("--service-format") { showingFormat = true }
                if CommandLine.arguments.contains("--ask-card"), let card = model.knownCards.first {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { changing = card }
                }
                #endif
            }
        }
        // Apart from the Files list: two on one view and neither opens.
        .fullScreenCover(isPresented: $showingCode) { OffsetCodeScreen() }
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


/// The errors at the top of Settings, in red, with a copy icon in the
/// corner that copies them all at once (1.0.3, David).
struct ErrorsSection: View {
    let lines: [String]
    @State private var copied = false

    var body: some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(lines, id: \.self) { Sentences(text: $0) }
                }
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    UIPasteboard.general.string = lines.joined(separator: "\n")
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        copied = false
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Words.t("Copy"))
            }
        }
        .listRowBackground(Color.red.opacity(0.15))
    }
}
