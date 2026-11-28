import SqueakyCore
import SqueakyUI
import SwiftUI
import UIKit

/// The address and the key of a service on the Settings page, with an edit
/// icon at the end of the key's row opening its panel (1.0.2, David).
struct KeyRows: View {
    /// The saved address, nil with no key saved.
    let address: String?
    let saved: Bool
    let edit: () -> Void

    var body: some View {
        if let address {
            LabeledContent(Words.t("Address")) {
                Text(address).lineLimit(1).truncationMode(.middle)
            }
        }
        // "Key saved", the tick and Edit; or "Key" and Add (1.0.5, David).
        HStack(spacing: 8) {
            Text(saved ? Words.t("Key saved") : Words.t("Key"))
            if saved {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            Spacer()
            Button(saved ? Words.t("Edit") : Words.t("Add"), action: edit)
                .buttonStyle(.borderless)
        }
    }
}

/// A new key pasted or typed, with its address (1.0.2, David): Apple's own
/// Paste button while something is on the clipboard, a bin in the corner that
/// asks before removing the key, Cancel and Save at the bottom.
struct KeyPanel: View {
    enum Kind: String, Identifiable {
        case service, buffer
        var id: String { rawValue }
    }

    @ObservedObject var model: AppModel
    let kind: Kind
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var key = ""
    @State private var canPaste = UIPasteboard.general.hasStrings
    @State private var confirmingRemove = false
    @FocusState private var typing: Bool

    var title: String { kind == .service ? Words.t("GPS tracks service") : Words.t("Buffer server") }
    var saved: Bool { kind == .service ? model.serviceKeySaved : model.bufferKeySaved }
    var trimmedKey: String { key.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedAddress: String { address.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent(Words.t("Address")) {
                        TextField("", text: $address)
                            .textContentType(.URL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent(Words.t("Key")) {
                        HStack(spacing: 10) {
                            SecureField("", text: $key)
                                .focused($typing)
                                .multilineTextAlignment(.trailing)
                            if canPaste {
                                PasteButton(payloadType: String.self) { strings in
                                    if let first = strings.first { key = first.trimmingCharacters(in: .whitespacesAndNewlines) }
                                }
                                .labelStyle(.iconOnly)
                                .buttonBorderShape(.capsule)
                            }
                        }
                    }
                }.cardRows()
                Section {
                    HStack(spacing: 12) {
                        HalfButton(Words.t("Cancel")) { dismiss() }
                        Button(Words.t("Save")) { save() }
                            .buttonStyle(WideButton(.blue))
                            .disabled(trimmedKey.isEmpty || trimmedAddress.isEmpty)
                    }
                    .buttonRow()
                }.cardRows()
            }
            .scrollContentBackground(.hidden)
            .background(Palette.page)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // The bin, only with a key to remove; asked first (1.0.2, David: "confirm everywhere").
                if saved {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(role: .destructive) { confirmingRemove = true } label: { Image(systemName: "trash") }
                            .tint(.red)
                            .accessibilityLabel(Words.t("Remove"))
                            .confirmationDialog(Words.t("Remove the key?"), isPresented: $confirmingRemove,
                                                titleVisibility: .visible) {
                                Button(Words.t("Remove"), role: .destructive) { remove() }
                                Button(Words.t("Cancel"), role: .cancel) {}
                            }
                    }
                }
            }
        }
        .presentationDetents([.medium])
        .onAppear {
            let current = kind == .service ? model.serviceAddress : model.bufferAddress
            address = current.isEmpty ? (kind == .service ? "https://geotrac.cc" : "https://bufr.cc") : current
            canPaste = UIPasteboard.general.hasStrings
        }
        .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in
            canPaste = UIPasteboard.general.hasStrings
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            canPaste = UIPasteboard.general.hasStrings
        }
    }

    func save() {
        switch kind {
        case .service:
            model.serviceAddress = trimmedAddress
            model.serviceKey = trimmedKey
            Task { await model.saveService() }
        case .buffer:
            model.bufferAddress = trimmedAddress
            model.bufferKey = trimmedKey
            Task {
                await model.saveBuffer()
                await model.shareWithServer()
            }
        }
        dismiss()
    }

    func remove() {
        switch kind {
        case .service: Task { await model.removeService() }
        case .buffer: Task { await model.removeBuffer() }
        }
        dismiss()
    }
}
