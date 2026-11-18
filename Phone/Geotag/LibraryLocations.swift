import CoreLocation
import GeotagCore
import GeotagUI
import Photos
import SwiftUI

/// Locations added later, in Photos (0.31.8, David, 18 November 2026: "i
/// wanted my photos now, and loaded them without waiting for the tracks ...
/// but later want to fix it"). Photos in the Photos app with no location,
/// from a camera Geotag knows with its offset set, get the location their
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

    struct Found: Equatable {
        let id: String
        let position: Position
    }

    @Published private(set) var state = State.idle
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
            .appendingPathComponent("Geotag/libraryread.json")
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

        // The tracks' points, loaded when no card has needed them since Geotag opened.
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
        state = .added(done, problem)
    }
}

/// The Photos page's section for it.
struct LibraryLocationsSection: View {
    @ObservedObject var model: AppModel
    @ObservedObject var library: LibraryLocations

    var body: some View {
        switch library.state {
        case .idle:
            EmptyView()
        case .notAsked:
            Section {
                Button(Words.t("Add locations to photos in Photos")) { Task { await library.askAndLook(model) } }
                    .disabled(model.tracks.isEmpty)
            }
        case .refused:
            Section {
                Sentences(text: Words.t("Geotag has no full access to Photos, so it can't add locations there.")).foregroundStyle(.secondary)
                Button(Words.t("Open iPhone Settings")) {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            }
        case .looking(let n, let total):
            Section { StatusRow(text: Words.t("Looking through Photos: {0} of {1}", n.formatted(), total.formatted()), busy: true) }
        case .found(let found):
            if !found.isEmpty {
                Section {
                    Button(found.count == 1 ? Words.t("Add a location to 1 photo")
                           : Words.t("Add locations to {0} photos", found.count.formatted())) {
                        Task { await library.add(found) }
                    }
                    .disabled(model.saving)
                }
            }
        case .adding(let n, let total):
            Section { StatusRow(text: Words.t("Adding locations in Photos: {0} of {1}", n.formatted(), total.formatted()), busy: true) }
        case .added(let n, let problem):
            Section {
                if let problem {
                    Sentences(text: Words.t("Locations added to {0} photos in Photos, then stopped: {1}", n.formatted(), problem))
                        .foregroundStyle(.orange)
                } else {
                    Text(Words.t("Locations added to {0} photos in Photos", n.formatted()))
                }
            }
        }
    }
}
