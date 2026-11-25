import Foundation
import SqueakyCore
import UIKit
public typealias PlatformImage = UIImage

public extension PlatformImage {
    /// A picture from a file, on the Mac or the phone.
    static func load(_ url: URL) -> PlatformImage? {
        return UIImage(contentsOfFile: url.path)
    }
}

import Photos
import CoreLocation

/// The phone's Photos library (0.29.15): each JPG saved from a card is added
/// there, with its location and date, as a copy of its own.
public enum PhoneLibrary {
    /// Asks the first time; true when Squeaky may add photos.
    public static func allowed() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        return status == .authorized || status == .limited
    }

    public static func add(_ url: URL) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = url.lastPathComponent
            PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: url, options: options)
        }
    }

    public static func isJPG(_ url: URL) -> Bool { ["jpg", "jpeg"].contains(url.pathExtension.lowercased()) }

    /// What the Photos library already holds around some dates, by original
    /// file name and moment (0.34.4, David): a photo AirDropped or added
    /// before is not added again. Nil without full access to Photos.
    public struct Index: Sendable {
        var moments: [String: [Date]] = [:]

        static func key(_ name: String) -> String {
            let lower = name.lowercased()
            let ext = (lower as NSString).pathExtension
            let stem = (lower as NSString).deletingPathExtension
            return stem + "." + (ext == "jpeg" ? "jpg" : ext)
        }

        /// The same name, taken within two seconds; within a day when the camera gave no zone.
        public func contains(name: String, moment: Date?, zoneKnown: Bool) -> Bool {
            guard let list = moments[Self.key(name)] else { return false }
            guard let moment else { return true }
            let slack: TimeInterval = zoneKnown ? 2 : 14 * 3600
            return list.contains { abs($0.timeIntervalSince(moment)) <= slack }
        }
    }

    public static func index(around range: ClosedRange<Date>) async -> Index? {
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined { status = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
        guard status == .authorized || status == .limited else { return nil }
        return await Task.detached(priority: .userInitiated) {
            let options = PHFetchOptions()
            options.predicate = NSPredicate(format: "creationDate >= %@ AND creationDate <= %@",
                                            range.lowerBound as NSDate, range.upperBound as NSDate)
            var index = Index()
            PHAsset.fetchAssets(with: options).enumerateObjects { asset, _, _ in
                guard let date = asset.creationDate,
                      let name = PHAssetResource.assetResources(for: asset).first?.originalFilename else { return }
                index.moments[Index.key(name), default: []].append(date)
            }
            return index
        }.value
    }

    /// A file added as it is, its place and moment given to Photos alone (HIF, 0.29.28;
    /// videos, 0.33.0: Photos does not read Canon's location inside a video).
    public static func add(_ url: URL, at position: Position?, taken: Date?, video: Bool = false) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = url.lastPathComponent
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: video ? .video : .photo, fileURL: url, options: options)
            if let position {
                request.location = CLLocation(coordinate: CLLocationCoordinate2D(latitude: position.lat, longitude: position.lon),
                                              altitude: position.alt ?? 0, horizontalAccuracy: 10, verticalAccuracy: position.alt == nil ? -1 : 10,
                                              timestamp: position.moment)
            }
            if let taken { request.creationDate = taken }
        }
    }
}

/// Where things are on the iPhone (14 November 2026). Each person's copies
/// go in Squeaky's own folder, which shows in the Files app under On My
/// iPhone. The card, the NAS folder and Squeaky's folder in iCloud Drive are
/// folders chosen in the Files list, kept as bookmarks.
public enum PhoneFolders {
    public static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// "Documents/David", made when first needed.
    public static func saveFolder(for person: Person) -> URL {
        let name = person.name.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
        let url = copies.appendingPathComponent(name.isEmpty ? person.id.uuidString : name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Squeaky's working copies (0.29.15, David, 16 November 2026: the photos
    /// belong in the Photos library, not in Files): hidden, left out of the
    /// phone's backup, each removed once it is on the server.
    public static var copies: URL {
        var url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Squeaky/Copies", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return url
    }

    /// Someone else's cards (David, 15 November 2026): their photos are
    /// saved on the phone under this person, never sent to the server.
    public static let othersId = UUID(uuidString: "0BE5A1D0-0000-4000-8000-000000000001")!

    public static let nasKey = "nasBookmark"
    public static let cloudKey = "cloudBookmark"

    /// Keeps a folder chosen in the Files list, for use after a restart.
    public static func remember(_ url: URL, as key: String) throws {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(data, forKey: key)
    }

    public static func forget(_ key: String) {
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.removeObject(forKey: key + "Path")
        opened[key] = nil
    }

    /// The folders opened so far, held open while Squeaky runs.
    nonisolated(unsafe) private static var opened: [String: URL] = [:]
    private static let lock = NSLock()

    /// The folder kept under `key`, opened for Squeaky; nil when none was chosen.
    public static func folder(_ key: String) -> URL? { try? open(key) }

    /// Why a chosen folder cannot be had (0.29.11, David: "dont fail silently").
    public enum Problem: Error, LocalizedError {
        case notChosen
        case gone(String)
        public var errorDescription: String? {
            switch self {
            case .notChosen: return Words.t("No server folder chosen.")
            case .gone(let why): return Words.t("The folder chosen can't be found any more. Choose it again.") + (why.isEmpty ? "" : " " + why)
            }
        }
    }

    /// The folder kept under `key`, opened for Squeaky, or why it cannot be.
    public static func open(_ key: String) throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        if let url = opened[key] { return url }
        guard let data = UserDefaults.standard.data(forKey: key) else { throw Problem.notChosen }
        var stale = false
        let url: URL
        do {
            url = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        } catch {
            throw Problem.gone(error.localizedDescription)
        }
        _ = url.startAccessingSecurityScopedResource()
        if stale, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: key)
        }
        opened[key] = url
        return url
    }

    /// The name of the folder kept under `key`, for Settings.
    public static func name(_ key: String) -> String? { folder(key).map(shownName) }

    /// The path saved when the folder was chosen: shown at once, the NAS never
    /// asked (0.29.8, David, 16 November 2026: Settings froze while it was).
    public static func savedPath(_ key: String) -> String? {
        UserDefaults.standard.string(forKey: key + "Path")
    }

    /// Works the path out, off the main thread, and saves it; or why it cannot
    /// be: the folder gone, the server not answering, or no answer in 15 s.
    public static func savePath(_ key: String) async -> Result<String, Error> {
        let found = await withTaskGroup(of: Result<String, Error>?.self) { group in
            group.addTask {
                await Task.detached { () -> Result<String, Error> in
                    do {
                        let url = try PhoneFolders.open(key)
                        do {
                            _ = try FileManager.default.contentsOfDirectory(atPath: url.path)
                        } catch {
                            return .failure(NASError.offline(Words.t("The NAS isn't answering. Check that the Files app is still connected to it.")
                                                             + " " + error.localizedDescription))
                        }
                        guard let path = PhoneFolders.path(key), !path.isEmpty else {
                            return .failure(NASError.failed(Words.t("The folder's name can't be read:") + " " + url.path))
                        }
                        return .success(path)
                    } catch {
                        return .failure(error)
                    }
                }.value
            }
            group.addTask { try? await Task.sleep(for: .seconds(15)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? .failure(NASError.offline(Words.t("No answer from the NAS within 15 seconds.")))
        }
        if case .success(let path) = found { UserDefaults.standard.set(path, forKey: key + "Path") }
        return found
    }

    /// Whether a folder is kept under `key`, without opening it.
    public static func isChosen(_ key: String) -> Bool {
        UserDefaults.standard.data(forKey: key) != nil
    }

    /// The whole path of the folder kept under `key`, from the shared folder
    /// or drive down, as the Files app names them: "homes/david/Squeaky" (0.29.5).
    public static func path(_ key: String) -> String? {
        guard let url = folder(key) else { return nil }
        var names: [String] = []
        var at = url
        // Up through the folders the Files app shows, to the provider's own root.
        for _ in 0..<12 {
            let parent = at.deletingLastPathComponent()
            names.insert(shownName(at), at: 0)
            let up = parent.lastPathComponent
            if parent.path == at.path || up.isEmpty || up == "/" || parent.path.hasSuffix("/LiveFiles")
                || up.hasPrefix("com.apple.") || up == "File Provider Storage" || up == "Mobile Documents" { break }
            // A provider's root folder is named by an id; the shared folder below it is the top.
            if up.range(of: #"^[0-9A-Fa-f-]{20,}$"#, options: .regularExpression) != nil { break }
            at = parent
        }
        return names.joined(separator: "/")
    }

    /// A folder's name as the Files app shows it: a shared folder on the NAS
    /// comes with an internal name of its own ("Nm3Lvwhomes" for homes).
    public static func shownName(_ url: URL) -> String {
        (try? url.resourceValues(forKeys: [.localizedNameKey]).localizedName) ?? url.lastPathComponent
    }

    /// Squeaky's folder in iCloud Drive, as chosen in Settings.
    public static func cloud() -> URL? { folder(cloudKey) }

    /// Every file in a folder in iCloud Drive brought onto the phone, so it
    /// can be read; waits up to a minute for those still coming.
    public static func bringDown(_ folder: URL) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .ubiquitousItemDownloadingStatusKey]
        guard let walker = fm.enumerator(at: folder, includingPropertiesForKeys: keys) else { return }
        var files: [URL] = []
        for case let url as URL in walker {
            var file = url
            // An older iCloud Drive shows a file not on the phone as ".name.icloud".
            let name = url.lastPathComponent
            if name.hasPrefix("."), name.hasSuffix(".icloud") {
                file = url.deletingLastPathComponent().appendingPathComponent(String(name.dropFirst().dropLast(7)))
            } else if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) != true {
                continue
            }
            try? fm.startDownloadingUbiquitousItem(at: file)
            files.append(file)
        }
        let coordinator = NSFileCoordinator()
        let until = Date().addingTimeInterval(60)
        for file in files {
            // A coordinated read waits for the file to arrive.
            var error: NSError?
            coordinator.coordinate(readingItemAt: file, options: [], error: &error) { _ in }
            while Date() < until, !fm.fileExists(atPath: file.path) { Thread.sleep(forTimeInterval: 0.2) }
        }
    }

    /// A card let go of: Squeaky stops reading it.
    public static func release(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
    }

    /// The app's own folders move when the phone reinstalls it (every week
    /// with a free Apple ID): a path kept from an earlier install is moved to
    /// this one's. Anything else stays as it is.
    public static func current(_ path: String) -> String {
        let home = NSHomeDirectory()
        // The phone's folders and the simulator's alike: whatever comes before
        // "Containers/Data/Application/<id>" is this install's own (0.29.14).
        guard !path.hasPrefix(home + "/"),
              let range = path.range(of: #"/Containers/Data/Application/[0-9A-F-]{36}"#, options: .regularExpression)
        else { return path }
        return home + path[range.upperBound...]
    }
}

/// The server on the iPhone (David, 15 November 2026): any folder the Files
/// app reaches, chosen in Settings: a file server such as the NAS, a USB
/// drive, or a storage app. The photos' day folders go straight into it.
public struct NASThroughFiles: NASPort {
    /// What the phone's person keeps as their server folder: the chosen one.
    public static let share = "server"

    public init() {}

    /// The chosen folder's name stands for the address; none chosen, none.
    public var addresses: [String] {
        // Never opens the folder: asked on the main thread, and the NAS may be slow to answer.
        PhoneFolders.isChosen(PhoneFolders.nasKey) ? [PhoneFolders.savedPath(PhoneFolders.nasKey) ?? NASThroughFiles.share] : []
    }

    public func connect(share: String) async throws -> NASConnection {
        let chosen: URL
        do {
            chosen = try PhoneFolders.open(PhoneFolders.nasKey)
        } catch {
            throw NASError.failed(error.localizedDescription)
        }
        let problem = await Task.detached { () -> String? in
            do {
                _ = try FileManager.default.contentsOfDirectory(atPath: chosen.path)
                return nil
            } catch {
                return error.localizedDescription
            }
        }.value
        if let problem {
            throw NASError.offline(Words.t("The NAS isn't answering. Check that the Files app is still connected to it.") + " " + problem)
        }
        return NASConnection(folder: chosen, address: PhoneFolders.shownName(chosen), ours: false)
    }

    public func disconnect(_ connection: NASConnection) async {}
}
