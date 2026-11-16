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
    public static func name(_ key: String) -> String? { folder(key).map(shownName) }

    /// The path saved when the folder was chosen: shown at once, the NAS never
    /// asked (0.29.8, David, 16 November 2026: Settings froze while it was).
    public static func savedPath(_ key: String) -> String? {
        UserDefaults.standard.string(forKey: key + "Path")
    }

    /// Works the path out, off the main thread, and saves it.
    public static func savePath(_ key: String) async -> String? {
        let path = await Task.detached { PhoneFolders.path(key) }.value
        if let path { UserDefaults.standard.set(path, forKey: key + "Path") }
        return path
    }

    /// Whether a folder is kept under `key`, without opening it.
    public static func isChosen(_ key: String) -> Bool {
        UserDefaults.standard.data(forKey: key) != nil
    }

    /// The whole path of the folder kept under `key`, from the shared folder
    /// or drive down, as the Files app names them: "homes/david/Geotag" (0.29.5).
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
        guard let chosen = PhoneFolders.folder(PhoneFolders.nasKey) else {
            throw NASError.failed(Words.t("Choose the server in Settings."))
        }
        let answers = await Task.detached { (try? FileManager.default.contentsOfDirectory(atPath: chosen.path)) != nil }.value
        guard answers else { throw NASError.offline(Words.t("The server isn't answering.")) }
        return NASConnection(folder: chosen, address: PhoneFolders.shownName(chosen), ours: false)
    }

    public func disconnect(_ connection: NASConnection) async {}
}
#endif
