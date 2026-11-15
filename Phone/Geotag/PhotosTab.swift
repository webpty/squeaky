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
                switch result {
                case .success(let url): model.choose(Self.source(url))
                case .failure(let error): model.tell(error.localizedDescription)
                }
            }
            #if DEBUG
            .onAppear { if CommandLine.arguments.contains("--choose-card") { choosing = true } }
            #endif
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
