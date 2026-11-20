import CoreLocation
import SqueakyCore
import SqueakyUI
import Photos
import SwiftUI

/// Locations added later, in Photos (0.31.8, David, 18 November 2026: "i
/// wanted my photos now, and loaded them without waiting for the tracks ...
/// but later want to fix it"). Photos in the Photos app with no location,
/// from a camera Squeaky knows with its offset set, get the location their
/// time falls on along the tracks: set on the photo already there, so
/// nothing is duplicated and the person's favourites, edits and albums stay.
/// Photos keeps it in its own record of the photo; the file inside is not
/// rewritten (Photos lets no app do that).
@MainActor
final class LibraryLocations: ObservableObject {
    enum State: Equatable {
        case idle
        /// Full access to Photos not given yet: the button asks for it.
        case notAsked
        case refused
        case looking(Int, Int)
        case found([Found])
        case adding(Int, Int)
        case added(Int, String?)
    }

    struct Found: Equatable, Codable, Identifiable {
        let id: String
        let position: Position
    }

    @Published private(set) var state = State.idle
    /// The photos given a location by the last batch, to see which they were
    /// (0.31.11, David: "i've no idea which ones they were"); kept until the next.
    @Published private(set) var lastAdded: [Found] = {
        (UserDefaults.standard.data(forKey: "libraryAdded")).flatMap { try? JSONDecoder().decode([Found].self, from: $0) } ?? []
    }()
    private var lookedFor = ""

    /// What was read from each photo once, kept so a photo is read only once
    /// ever: its camera's clock reading, or nothing usable (not a JPG, no
    /// camera named).
    private struct Read: Codable {
        var model: String?
        var taken: String?
        var subSeconds: String?
        var zone: String?
    }

    private static var readFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Squeaky/libraryread.json")
    }

    private func loadRead() -> [String: Read] {
        (try? Data(contentsOf: Self.readFile)).flatMap { try? JSONDecoder().decode([String: Read].self, from: $0) } ?? [:]
    }

    private func saveRead(_ read: [String: Read]) {
        try? FileManager.default.createDirectory(at: Self.readFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(read).write(to: Self.readFile, options: .atomic)
    }

    var busy: Bool {
        switch state {
        case .looking, .adding: return true
        default: return false
        }
    }

    /// Looked for by itself once access is given, whenever the tracks or the
    /// cameras' offsets change; asked for only from the button.
    func lookIfAllowed(_ model: AppModel) async {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized, .limited: await look(model)
        case .notDetermined: state = .notAsked
        default: state = .refused
        }
    }

    func askAndLook(_ model: AppModel) async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            state = .refused
            return
        }
        lookedFor = ""
        await look(model)
    }

    private func look(_ model: AppModel) async {
        guard !busy else { return }
        guard let owner = model.macOwner, let first = model.tracks.map(\.start).min() else {
            state = .idle
            return
        }
        // Looked through again only when something that decides it changed.
        let offsets = model.book.people.flatMap { model.book.cameras(of: $0.id) }
            .map { "\($0.model)\($0.offsetSeconds ?? -1)" }.sorted().joined()
        let key = "\(model.tracks.count)|\(model.tracks.map(\.end).max()?.timeIntervalSince1970 ?? 0)|\(offsets)|\(model.maxGapSeconds)"
        if key == lookedFor, case .found = state { return }

        // The tracks' points, loaded when no card has needed them since Squeaky opened.
        if model.timeline.pieces.isEmpty { await model.loadTimeline() }
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "creationDate >= %@", first.addingTimeInterval(-2 * 86_400) as NSDate)
        let fetched = PHAsset.fetchAssets(with: .image, options: options)
        var assets: [PHAsset] = []
        fetched.enumerateObjects { asset, _, _ in if asset.location == nil { assets.append(asset) } }

        var read = loadRead()
        var found: [Found] = []
        let unread = assets.filter { read[$0.localIdentifier] == nil }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("libraryread", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        for (i, asset) in unread.enumerated() {
            state = .looking(i + 1, unread.count)
            read[asset.localIdentifier] = await Self.read(asset, into: scratch)
            if i % 50 == 49 { saveRead(read) }
        }
        saveRead(read)

        for asset in assets {
            guard let r = read[asset.localIdentifier], let model_ = r.model, r.taken != nil else { continue }
            let photo = ScannedPhoto(url: URL(fileURLWithPath: "/"), fileName: "", size: 0, taken: r.taken,
                                     subSeconds: r.subSeconds, zone: r.zone, model: model_)
            // The phone's person's camera first, then the same model as someone else's.
            let camera = model.book.camera(personId: owner, model: model_)
                ?? model.book.camera(personId: PhoneFolders.othersId, model: model_)
            guard let camera, camera.offsetSeconds != nil else { continue }
            if case .matched(let position) = Matcher.place(photo, camera: camera, timeline: model.timeline, gap: model.maxGapSeconds) {
                found.append(Found(id: asset.localIdentifier, position: position))
            }
        }
        lookedFor = key
        state = .found(found)
    }

    /// The camera's clock reading from the photo's original file, read
    /// without fetching it from iCloud; nothing usable when it is not a JPG.
    private static func read(_ asset: PHAsset, into scratch: URL) async -> Read {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let original = resources.first(where: { $0.type == .photo }) ?? resources.first,
              ["jpg", "jpeg"].contains((original.originalFilename as NSString).pathExtension.lowercased()) else { return Read() }
        let file = scratch.appendingPathComponent(UUID().uuidString + ".jpg")
        defer { try? FileManager.default.removeItem(at: file) }
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false
        do {
            try await PHAssetResourceManager.default().writeData(for: original, toFile: file, options: options)
        } catch {
            return Read()
        }
        guard let photo = NativeMetadata.scan([file], progress: { _ in }).first else { return Read() }
        return Read(model: photo.model, taken: photo.taken, subSeconds: photo.subSeconds, zone: photo.zone)
    }

    /// Each location set on the photo already in Photos, a hundred at a time;
    /// the iPhone asks to allow each batch.
    func add(_ found: [Found]) async {
        var done = 0
        var problem: String?
        state = .adding(0, found.count)
        for start in stride(from: 0, to: found.count, by: 100) {
            let batch = Array(found[start..<min(start + 100, found.count)])
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: batch.map(\.id), options: nil)
            var byId: [String: PHAsset] = [:]
            assets.enumerateObjects { a, _, _ in byId[a.localIdentifier] = a }
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    for f in batch {
                        guard let asset = byId[f.id] else { continue }
                        let p = f.position
                        PHAssetChangeRequest(for: asset).location = CLLocation(
                            coordinate: CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon),
                            altitude: p.alt ?? 0, horizontalAccuracy: 10, verticalAccuracy: p.alt == nil ? -1 : 10,
                            timestamp: p.moment)
                    }
                }
                done += batch.count
                state = .adding(done, found.count)
            } catch {
                problem = error.localizedDescription
                break
            }
        }
        lookedFor = ""
        lastAdded = Array(found.prefix(done))
        UserDefaults.standard.set(try? JSONEncoder().encode(lastAdded), forKey: "libraryAdded")
        state = .added(done, problem)
    }
}

/// The Photos page's section for it.
struct LibraryLocationsSection: View {
    @ObservedObject var model: AppModel
    @ObservedObject var library: LibraryLocations
    @State private var showing: LibraryShowing?

    var body: some View {
        content
            .sheet(item: $showing) { which in LibraryPhotosPage(model: model, library: library, showing: which) }
    }

    @ViewBuilder
    private var content: some View {
        switch library.state {
        case .idle:
            EmptyView()
        case .notAsked:
            Section {
                Button(Words.t("Add locations to photos in Photos")) { Task { await library.askAndLook(model) } }
                    .buttonStyle(WideButton(.blue)).buttonRow()
                    .disabled(model.tracks.isEmpty)
            }.cardRows()
        case .refused:
            Section {
                Sentences(text: Words.t("Squeaky has no full access to Photos, so it can't add locations there.")).foregroundStyle(.secondary)
                Button(Words.t("Open iPhone Settings")) {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .buttonStyle(WideButton(.grey)).buttonRow()
            }.cardRows()
        case .looking(let n, let total):
            Section { StatusRow(text: Words.t("Looking through Photos: {0} of {1}", n.formatted(), total.formatted()), busy: true) }.cardRows()
        case .found(let found):
            if !found.isEmpty {
                Section {
                    // The photos shown first, then added from there (0.31.11, David).
                    Button(found.count == 1 ? Words.t("Add a location to 1 photo")
                           : Words.t("Add locations to {0} photos", found.count.formatted())) {
                        showing = .toAdd(found)
                    }
                    .buttonStyle(WideButton(.blue)).buttonRow()
                    .disabled(model.saving)
                }.cardRows()
            } else if !library.lastAdded.isEmpty {
                Section { addedButton(library.lastAdded.count, problem: nil) }.cardRows()
            }
        case .adding(let n, let total):
            Section { StatusRow(text: Words.t("Adding locations in Photos: {0} of {1}", n.formatted(), total.formatted()), busy: true) }.cardRows()
        case .added(let n, let problem):
            Section { addedButton(n, problem: problem) }.cardRows()
        }
    }

    /// Opens the photos the last batch changed.
    @ViewBuilder
    private func addedButton(_ n: Int, problem: String?) -> some View {
        Button {
            showing = .added(library.lastAdded)
        } label: {
            if let problem {
                Sentences(text: Words.t("Locations added to {0} photos in Photos, then stopped: {1}", n.formatted(), problem))
                    .foregroundStyle(.orange)
            } else {
                Text(Words.t("Locations added to {0} photos in Photos", n.formatted()))
            }
        }
        .disabled(library.lastAdded.isEmpty)
    }
}

/// Which photos: those about to get a location, or those the last batch changed.
enum LibraryShowing: Identifiable {
    case toAdd([LibraryLocations.Found])
    case added([LibraryLocations.Found])
    var id: String {
        switch self {
        case .toAdd: return "add"
        case .added: return "added"
        }
    }
    var photos: [LibraryLocations.Found] {
        switch self {
        case .toAdd(let f), .added(let f): return f
        }
    }
}

/// The photos, each with its date and time and its place (0.31.11).
struct LibraryPhotosPage: View {
    @ObservedObject var model: AppModel
    @ObservedObject var library: LibraryLocations
    let showing: LibraryShowing
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(showing.photos.sorted { $0.position.moment < $1.position.moment }) { photo in
                LibraryPhotoRow(model: model, photo: photo)
            }
            .navigationTitle(showing.photos.count == 1 ? Words.t("1 photo") : Words.t("{0} photos", showing.photos.count.formatted()))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Words.t("Close")) { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if case .toAdd(let found) = showing {
                    Button {
                        dismiss()
                        Task { await library.add(found) }
                    } label: {
                        Text(Words.t("Add locations")).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(16)
                    .background(.bar)
                }
            }
        }
    }
}

struct LibraryPhotoRow: View {
    @ObservedObject var model: AppModel
    let photo: LibraryLocations.Found
    @State private var image: UIImage?
    @State private var place: String?

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Color(.secondarySystemBackground)
                if let image { Image(uiImage: image).resizable().scaledToFill() }
            }
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 4) {
                Text(When.current.dayAndTime(photo.position.moment)).lineLimit(1)
                Text(place ?? " ").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .task {
            if let asset = PHAsset.fetchAssets(withLocalIdentifiers: [photo.id], options: nil).firstObject {
                let options = PHImageRequestOptions()
                options.deliveryMode = .highQualityFormat
                options.isNetworkAccessAllowed = true
                PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 192, height: 192),
                                                      contentMode: .aspectFill, options: options) { picture, _ in
                    if let picture { Task { @MainActor in image = picture } }
                }
            }
            place = await model.placeName(lat: photo.position.lat, lon: photo.position.lon)
                ?? String(format: "%.4f, %.4f", photo.position.lat, photo.position.lon)
        }
    }
}
