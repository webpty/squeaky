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
                        LabeledContent("Person", value: person.name)
                    }
                    if !model.rows.isEmpty {
                        LabeledContent("Photos", value: counts)
                    }
                }
                Section {
                    if model.saving {
                        Button("Stop") { model.stopSaving() }
                    } else {
                        Button("Choose card") { choosing = true }
                            .disabled(model.photosBusy)
                        if model.source != nil {
                            Button("Save photos") { Task { await model.savePhotos() } }
                                .disabled(!model.canSave)
                            Button("Done with this card") { model.letGo() }
                                .disabled(model.photosBusy)
                        } else if !model.rows.isEmpty {
                            Button("Clear photos") { model.clearPhotos() }
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
            .navigationTitle("Photos")
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
        return before == 0 ? new.formatted() : "\(new.formatted()) new, \(before.formatted()) already saved"
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
            .navigationTitle("Whose card is \(model.askingWhose?.name ?? "it")?")
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
            case .saved: return "Saved"
            case .alreadyThere: return "Already saved"
            case .failed(let why): return "Not saved: \(why)"
            }
        }
        return row.status == .alreadyImported ? PhotoText.status(row.status) : PhotoText.location(row, gap: model.maxGapSeconds)
    }
}
