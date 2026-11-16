import GeotagCore
import GeotagUI
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// The card, chosen in the Files list once it is plugged in, and its photos.
struct PhotosTab: View {
    @ObservedObject var model: AppModel
    @State private var choosing = false
    @StateObject private var pictures = Pictures()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(model.syncActivity ?? QueueText.sync(model.lastSave, problem: model.sharedProblem))
                        .foregroundStyle(.secondary)
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
                    // Why photos wait: one line for each reason, with how many.
                    ForEach(reasons, id: \.self) { line in
                        Text(line).foregroundStyle(.secondary)
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
                            Button(Words.t("Save photos")) { Task { await model.checkTracksBeforeSave() } }
                                .disabled(!model.canSave)
                            Button(Words.t("Done with this card")) { model.letGo() }
                                .disabled(model.photosBusy)
                        }
                    }
                }
                // The photos to be saved, as squares (0.29.1, David, 16 November 2026).
                // Only while the card is in: once out, its pictures cannot be read (0.29.5).
                let waiting = shown
                if !waiting.isEmpty {
                    Section {
                        // Squares of one size, a small gap between them, corners rounded (0.29.9).
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 3), spacing: 3) {
                            ForEach(waiting) { row in
                                Square(image: pictures.made[model.pictureURL(row) ?? row.photo.url],
                                       saved: model.results[row.id]?.url != nil,
                                       failed: { if case .failed? = model.results[row.id] { return true }; return false }())
                            }
                        }
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                    }
                    .onAppear { pictures.make(waiting.map { model.pictureURL($0) ?? $0.photo.url }) }
                    // Made again when a picture's file changes: from the card to the copy once the card is out.
                    .onChange(of: waiting.map { model.pictureURL($0) ?? $0.photo.url }) { _, urls in pictures.make(urls) }
                }
            }
            .scrollContentBackground(.hidden)
            // The last card's photo behind every tab, veiled (0.29.5, David, 16 November 2026).
            .background(Backdrop(image: model.sidebarImage))
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

    /// The photos still to be saved, one square per frame: the JPG of a RAW+JPG pair.
    var shown: [ImportRow] {
        // Still to save while the card is in, and saved from this card: those keep their square,
        // from the copy on the phone once the card is out, with a check (0.29.12).
        let cardIn = model.source != nil
        let waiting = model.rows.filter { row in
            if let copy = model.results[row.id]?.url {
                // Card out: only a copy still on the phone has a picture; a raw sent to the server has none (0.29.14).
                return cardIn || FileManager.default.fileExists(atPath: copy.path)
            }
            if case .failed? = model.results[row.id] { return cardIn }
            return cardIn && row.willImport && model.results[row.id] == nil
        }
        var seen = Set<String>()
        let jpgFirst = waiting.sorted { a, b in
            let ja = ["jpg", "jpeg"].contains((a.photo.fileName as NSString).pathExtension.lowercased())
            let jb = ["jpg", "jpeg"].contains((b.photo.fileName as NSString).pathExtension.lowercased())
            return ja && !jb
        }
        var keep = Set<String>()
        for row in jpgFirst {
            let frame = (row.photo.fileName as NSString).deletingPathExtension + "|" + (row.photo.taken ?? "")
            if seen.insert(frame).inserted { keep.insert(row.id) }
        }
        return waiting.filter { keep.contains($0.id) }
    }

    /// "8 photos: Camera time offset not set".
    var reasons: [String] {
        guard !model.saving else { return [] }
        var counts: [String: Int] = [:]
        var order: [String] = []
        for row in model.rows where row.needsReview && row.status != .alreadyImported && model.results[row.id] == nil {
            let why = PhotoText.location(row, gap: model.maxGapSeconds)
            if counts[why] == nil { order.append(why) }
            counts[why, default: 0] += 1
        }
        return order.map { counts[$0] == 1 ? Words.t("1 photo: {0}", $0) : Words.t("{0} photos: {1}", counts[$0]!.formatted(), $0) }
    }

    /// "340 new, 12 already saved".
    var counts: String {
        // Updated after every photo saved (0.29.13): saved now counts with saved before.
        let before = model.rows.filter { $0.status == .alreadyImported || model.results[$0.id]?.url != nil }.count
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

/// The squares' pictures, made one after another in the photos' order, so
/// they appear from the first to the last (0.29.9), and kept while Geotag runs.
@MainActor
final class Pictures: ObservableObject {
    @Published private(set) var made: [URL: UIImage] = [:]
    private var queue: [URL] = []
    private var running = false

    func make(_ urls: [URL]) {
        queue = urls.filter { made[$0] == nil }
        guard !running else { return }
        running = true
        Task {
            while !queue.isEmpty {
                let url = queue.removeFirst()
                if made[url] != nil { continue }
                if let image = await Task.detached(priority: .userInitiated, operation: { Pictures.picture(url) }).value {
                    made[url] = image
                }
            }
            running = false
        }
    }

    /// A JPG's own picture, not the small preview inside it, which carries
    /// black bands; a raw's preview, which has none and is quick.
    nonisolated static func picture(_ url: URL) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let jpg = ["jpg", "jpeg"].contains(url.pathExtension.lowercased())
        let options: [CFString: Any] = [
            jpg ? kCGImageSourceCreateThumbnailFromImageAlways : kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 360,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map(UIImage.init(cgImage:))
    }
}

/// A photo as a square, filled to its edges, cropped from the middle.
struct Square: View {
    let image: UIImage?
    var saved = false
    var failed = false

    var body: some View {
        Color(.secondarySystemBackground)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(alignment: .bottomTrailing) {
                if saved || failed {
                    Image(systemName: saved ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.system(size: 18))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, saved ? Color.green : Color.red)
                        .padding(4)
                }
            }
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
