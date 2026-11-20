#if os(macOS)
import Foundation
import Security
import SqueakyCore

/// Squeaky was Geotag until 0.34.0 (David, 20 November 2026: "nothing stays
/// geotag"). On a Mac's first Squeaky launch, everything Geotag kept is taken
/// over: its folder of records, its settings, the saved track service key, the
/// photo folder in Pictures, the folder in iCloud Drive, and opening on a card.
/// Each part is moved only when Squeaky has none of its own, so it runs once.
public enum FromGeotag {
    static let oldName = "Geotag"
    static let oldBundle = "com.webpty.geotag"

    public static func run() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let newSupport = support.appendingPathComponent(appName, isDirectory: true)
        move(support.appendingPathComponent(oldName, isDirectory: true), to: newSupport)

        // The photo folder in Pictures, and every record that names it.
        let oldPictures = home.appendingPathComponent("Pictures/\(oldName)", isDirectory: true)
        let newPictures = home.appendingPathComponent("Pictures/\(appName)", isDirectory: true)
        if move(oldPictures, to: newPictures) {
            rewrite(in: newSupport, from: oldPictures.path, to: newPictures.path)
        }

        if let mine = CloudCopy.standardFolder {
            move(mine.deletingLastPathComponent().appendingPathComponent(oldName, isDirectory: true), to: mine)
        }

        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "tookOverGeotag") {
            for (key, value) in defaults.persistentDomain(forName: oldBundle) ?? [:] where defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
            // Geotag opened on a card: Squeaky does now.
            if defaults.object(forKey: "openOnCard") as? Bool ?? true { try? LoginItem.set(true) }
            defaults.set(true, forKey: "tookOverGeotag")
        }

        // The track service key: the Mac asks once for the password to read Geotag's.
        let mine = Keychain()
        let old = Keychain(service: oldBundle)
        for account in old.accounts() where mine.read(account) == nil {
            if let value = old.read(account) { try? mine.write(account, value) }
        }
    }

    /// Moved when only the old one is there. True when it was moved.
    @discardableResult
    static func move(_ old: URL, to new: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) else { return false }
        return (try? fm.moveItem(at: old, to: new)) != nil
    }

    /// Every record file that names the old folder made to name the new one.
    static func rewrite(in folder: URL, from old: String, to new: String) {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: folder, includingPropertiesForKeys: nil) else { return }
        for case let url as URL in walker where ["json", "jsonl"].contains(url.pathExtension) {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            // As written in JSON, where "/" may be escaped.
            let escapedOld = old.replacingOccurrences(of: "/", with: "\\/")
            let escapedNew = new.replacingOccurrences(of: "/", with: "\\/")
            let changed = text.replacingOccurrences(of: old + "/", with: new + "/")
                .replacingOccurrences(of: "\"" + old + "\"", with: "\"" + new + "\"")
                .replacingOccurrences(of: escapedOld + "\\/", with: escapedNew + "\\/")
                .replacingOccurrences(of: "\"" + escapedOld + "\"", with: "\"" + escapedNew + "\"")
            if changed != text { try? changed.write(to: url, atomically: true, encoding: .utf8) }
        }
    }
}
#endif
