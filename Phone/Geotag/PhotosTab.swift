import GeotagCore
import GeotagUI
import SwiftUI
import UniformTypeIdentifiers

/// The card, chosen in the Files list once it is plugged in, and its photos.
struct PhotosTab: View {
    @ObservedObject var model: AppModel
    @State private var choosing = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    StatusRow(text: model.photosLine, busy: model.photosBusy || model.saving)
                    if let id = model.importPerson, model.book.person(id) != nil {
                        // Tapped: the card is the other side's, and is read again for it.
                        Button {
                            guard let source = model.source, !model.saving else { return }
                            let other = id == PhoneFolders.othersId ? model.macOwner : PhoneFolders.othersId
                            if let other { Task { await model.read(source, for: other) } }
                        } label: {
                            LabeledContent(Words.t("Card"), value: id == PhoneFolders.othersId ? Words.t("Someone else's") : Words.t("Mine"))
                        }
                        .disabled(model.source == nil || model.saving || model.photosBusy)
                    }
                    if !model.rows.isEmpty {
                        LabeledContent(Words.t("Photos"), value: counts)
                    }
                }
                Section {
                    if model.saving {
                        Button(Words.t("Stop")) { model.stopSaving() }
                    } else {
                        if model.source == nil {
                            Button(Words.t("Open card")) { choosing = true }
                                .disabled(model.photosBusy || model.macOwner == nil)
                            if !model.rows.isEmpty {
                                Button(Words.t("Clear photos")) { model.clearPhotos() }
                            }
                        } else {
                            Button(Words.t("Save photos")) { Task { await model.savePhotos() } }
                                .disabled(!model.canSave)
                            Button(Words.t("Done with this card")) { model.letGo() }
                                .disabled(model.photosBusy)
                        }
                    }
                }
                if !model.rows.isEmpty {
                    Section {
                        ForEach(model.rows) { row in
                            PhotoRow(model: model, row: row)
                        }
                    }
                }
            }
            .navigationTitle(Words.t("Photos"))
            .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
                switch result {
                case .success(let url):
                    let source = Self.source(url)
                    CardWatch.remember(url, id: source.id)
                    model.choose(source)
                case .failure(let error): model.tell(error.localizedDescription)
                }
            }
            #if DEBUG
            .onAppear {
                if CommandLine.arguments.contains("--choose-card") { choosing = true }
                if CommandLine.arguments.contains("--ask-whose") {
                    model.askingWhose = PhotoSource(id: "debug", name: "EOS_DIGITAL", url: URL(fileURLWithPath: "/"), isCard: true)
                }
            }
            #endif
        }
        // Apart from the Files list above: two on one view and neither opens.
        .sheet(isPresented: Binding(get: { model.askingWhose != nil }, set: { if !$0 { model.askingWhose = nil } })) {
            WhoseCard(model: model)
        }
    }

    /// "340 new, 12 already saved".
    var counts: String {
        let before = model.rows.filter { $0.status == .alreadyImported }.count
        let new = model.rows.count - before
        return before == 0 ? new.formatted() : Words.t("{0} new, {1} already saved", new.formatted(), before.formatted())
    }

    /// The card, or a folder on it: known again next time by the card's own id.
    static func source(_ url: URL, id known: String? = nil) -> PhotoSource {
        _ = url.startAccessingSecurityScopedResource()
        let values = try? url.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeNameKey])
        let name = values?.volumeName ?? (url.lastPathComponent == "DCIM" ? url.deletingLastPathComponent().lastPathComponent : url.lastPathComponent)
        let id = known ?? values?.volumeUUIDString ?? values?.volumeName ?? url.path
        return PhotoSource(id: id, name: name, url: url, isCard: true)
    }
}

/// One photo: its name, when it was taken, and where it stands.
struct PhotoRow: View {
    @ObservedObject var model: AppModel
    let row: ImportRow

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(row.photo.fileName)
            Text(PhotoText.taken(row.photo)).font(.caption).foregroundStyle(.secondary)
            Text(status).font(.caption).foregroundStyle(.secondary)
        }
        .lineLimit(1)
    }

    var status: String {
        if let result = model.results[row.id] {
            if let url = result.url, let entry = model.queueEntry(for: url.path) {
                let why = row.needsReview ? " · " + PhotoText.location(row, gap: model.maxGapSeconds) : ""
                return QueueText.photo(entry) + why
            }
            switch result {
            case .saved: return Words.t("Saved")
            case .alreadyThere: return Words.t("Already saved")
            case .failed(let why): return Words.t("Not saved: {0}", Words.t(why))
            }
        }
        return row.status == .alreadyImported ? PhotoText.status(row.status) : PhotoText.location(row, gap: model.maxGapSeconds)
    }
}

/// Whose card it is, asked the first time a card is chosen and remembered.
struct WhoseCard: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(Words.t("Whose card is this?")).font(.headline)
            VStack(spacing: 10) {
                Button { pick(model.macOwner) } label: { Text(Words.t("Mine")).frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                Button { pick(PhoneFolders.othersId) } label: { Text(Words.t("Someone else's")).frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered)
            }
            .controlSize(.large)
        }
        .padding(24)
        .presentationDetents([.height(200)])
    }

    func pick(_ id: UUID?) {
        guard let id, let source = model.askingWhose else { return }
        Task { await model.read(source, for: id) }
    }
}
