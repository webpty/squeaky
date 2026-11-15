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
                    if let id = model.importPerson, let person = model.book.person(id) {
                        LabeledContent(Words.t("Person"), value: person.name)
                    }
                    if !model.rows.isEmpty {
                        LabeledContent(Words.t("Photos"), value: counts)
                    }
                }
                Section {
                    if model.saving {
                        Button(Words.t("Stop")) { model.stopSaving() }
                    } else {
                        Button(Words.t("Choose card")) { choosing = true }
                            .disabled(model.photosBusy || model.macOwner == nil)
                        if model.source != nil {
                            Button(Words.t("Save photos")) { Task { await model.savePhotos() } }
                                .disabled(!model.canSave)
                            Button(Words.t("Done with this card")) { model.letGo() }
                                .disabled(model.photosBusy)
                        } else if !model.rows.isEmpty {
                            Button(Words.t("Clear photos")) { model.clearPhotos() }
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
                guard case .success(let url) = result else { return }
                model.choose(Self.source(url))
            }
            .sheet(isPresented: Binding(get: { model.askingWhose != nil }, set: { if !$0 { model.askingWhose = nil } })) {
                WhoseCard(model: model)
            }
        }
    }

    /// "340 new, 12 already saved".
    var counts: String {
        let before = model.rows.filter { $0.status == .alreadyImported }.count
        let new = model.rows.count - before
        return before == 0 ? new.formatted() : Words.t("{0} new, {1} already saved", new.formatted(), before.formatted())
    }

    /// The card, or a folder on it: known again next time by the card's own id.
    static func source(_ url: URL) -> PhotoSource {
        _ = url.startAccessingSecurityScopedResource()
        let values = try? url.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeNameKey])
        let name = values?.volumeName ?? (url.lastPathComponent == "DCIM" ? url.deletingLastPathComponent().lastPathComponent : url.lastPathComponent)
        let id = values?.volumeUUIDString ?? values?.volumeName ?? url.path
        return PhotoSource(id: id, name: name, url: url, isCard: true)
    }
}

/// Whose card it is, asked the first time a card is seen.
struct WhoseCard: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(model.book.people) { person in
                Button(person.name) {
                    guard let source = model.askingWhose else { return }
                    Task { await model.read(source, for: person.id) }
                }
            }
            .navigationTitle(Words.t("Whose card is {0}?", model.askingWhose?.name ?? ""))
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
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
