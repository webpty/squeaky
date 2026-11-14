import Foundation
import GeotagCore
#if os(macOS)
import AppKit
public typealias PlatformImage = NSImage
#else
import UIKit
public typealias PlatformImage = UIImage
#endif

public extension PlatformImage {
    /// A picture from a file, on the Mac or the phone.
    static func load(_ url: URL) -> PlatformImage? {
        #if os(macOS)
        return NSImage(contentsOf: url)
        #else
        return UIImage(contentsOfFile: url.path)
        #endif
    }
}

#if os(iOS)
/// Where things are on the iPhone (14 November 2026). Each person's copies
/// go in Geotag's own folder, which shows in the Files app under On My
/// iPhone. The card, the NAS folder and Geotag's folder in iCloud Drive are
/// folders chosen in the Files list, kept as bookmarks.
public enum PhoneFolders {
    public static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// "Documents/David", made when first needed.
    public static func saveFolder(for person: Person) -> URL {
        let name = person.name.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
        let url = documents.appendingPathComponent(name.isEmpty ? person.id.uuidString : name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

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
        opened[key] = nil
    }

    /// The folders opened so far, held open while Geotag runs.
    nonisolated(unsafe) private static var opened: [String: URL] = [:]
    private static let lock = NSLock()

    /// The folder kept under `key`, opened for Geotag; nil when none was chosen.
    public static func folder(_ key: String) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        if let url = opened[key] { return url }
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        _ = url.startAccessingSecurityScopedResource()
        if stale, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: key)
        }
        opened[key] = url
        return url
    }

    /// The name of the folder kept under `key`, for Settings.
    public static func name(_ key: String) -> String? { folder(key)?.lastPathComponent }

    /// Geotag's folder in iCloud Drive, as chosen in Settings.
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

    /// A card let go of: Geotag stops reading it.
    public static func release(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
    }

    /// The app's own folders move when the phone reinstalls it (every week
    /// with a free Apple ID): a path kept from an earlier install is moved to
    /// this one's. Anything else stays as it is.
    public static func current(_ path: String) -> String {
        let home = NSHomeDirectory()
        guard !path.hasPrefix(home + "/"),
              let range = path.range(of: #"^/(private/)?var/mobile/Containers/Data/Application/[0-9A-F-]{36}"#, options: .regularExpression)
        else { return path }
        return home + path[range.upperBound...]
    }
}

/// The NAS on the iPhone: its shared folder, connected in the Files app and
/// chosen once in Settings. The Files app keeps the address and password.
public struct NASThroughFiles: NASPort {
    public init() {}

    /// The chosen folder's name stands for the address; none chosen, none.
    public var addresses: [String] { PhoneFolders.name(PhoneFolders.nasKey).map { [$0] } ?? [] }

    public func connect(share: String) async throws -> NASConnection {
        guard let chosen = PhoneFolders.folder(PhoneFolders.nasKey) else {
            throw NASError.failed("Choose the NAS in Settings.")
        }
        // The shared folder itself was chosen, or the NAS above it.
        let folder = chosen.lastPathComponent.caseInsensitiveCompare(share) == .orderedSame
            ? chosen : chosen.appendingPathComponent(share, isDirectory: true)
        let answers = await Task.detached { () -> Bool in
            var isFolder: ObjCBool = false
            return FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder) && isFolder.boolValue
                && (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) != nil
        }.value
        guard answers else {
            if (try? FileManager.default.contentsOfDirectory(atPath: chosen.path)) == nil {
                throw NASError.offline("The NAS isn't answering.")
            }
            throw NASError.failed("The NAS folder chosen in Settings has no shared folder called \(share).")
        }
        return NASConnection(folder: folder, address: chosen.lastPathComponent, ours: false)
    }

    public func disconnect(_ connection: NASConnection) async {}
}
#endif
