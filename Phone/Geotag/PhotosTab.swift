import GeotagCore
import GeotagUI
import ImageIO
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
                    Text(QueueText.sync(model.lastSave, problem: model.sharedProblem))
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
                            Button(Words.t("Save photos")) { Task { await model.savePhotos() } }
                                .disabled(!model.canSave)
                            Button(Words.t("Done with this card")) { model.letGo() }
                                .disabled(model.photosBusy)
                        }
                    }
                }
                // The photos to be saved, as squares (0.29.1, David, 16 November 2026).
                let waiting = model.rows.filter { $0.willImport && model.results[$0.id] == nil }
                if !waiting.isEmpty {
                    Section {
                        // Exact squares of one size, edge to edge (0.29.4).
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 3), spacing: 0) {
                            ForEach(waiting) { row in
                                Square(url: model.pictureURL(row))
                            }
                        }
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
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

/// A photo as a square picture, made from its own file and kept while
/// Geotag runs.
struct Square: View {
    let url: URL?
    @State private var image: UIImage?
    static let made = NSCache<NSURL, UIImage>()

    var body: some View {
        Color(.secondarySystemBackground)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    GeometryReader { box in
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: box.size.width, height: box.size.height)
                            .clipped()
                    }
                }
            }
            .clipped()
            .task(id: url) {
                guard let url else { return }
                if let known = Self.made.object(forKey: url as NSURL) { image = known; return }
                let picture = await Task.detached { Self.picture(url) }.value
                if let picture { Self.made.setObject(picture, forKey: url as NSURL) }
                image = picture
            }
    }

    nonisolated static func picture(_ url: URL) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                                                                       kCGImageSourceCreateThumbnailWithTransform: true,
                                                                       kCGImageSourceThumbnailMaxPixelSize: 360] as CFDictionary)
        else { return nil }
        return UIImage(cgImage: cg)
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
