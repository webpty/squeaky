import Foundation

/// The disk image that puts Geotag on another Mac: the Geotag that is
/// running, beside a shortcut to Applications, made when asked for, so it
/// works the same on every Mac (David, 17 October 2026).
public enum Installer {
    public struct Failure: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// Makes "Geotag <version>.dmg" in that folder from the app at `app`,
    /// replacing one of the same name already there (David, 17 October 2026).
    /// The folder never holds half a disk image.
    public static func save(app: URL, version: String, into folder: URL) throws -> URL {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("geotag-download-\(UUID().uuidString)", isDirectory: true)
        let stage = work.appendingPathComponent("stage", isDirectory: true)
        let image = work.appendingPathComponent("Geotag.dmg")
        // Geotag's own working folder, gone again once the disk image is made.
        defer { try? fm.removeItem(at: work) }
        do {
            try fm.createDirectory(at: stage, withIntermediateDirectories: true)
            try fm.copyItem(at: app, to: stage.appendingPathComponent("Geotag.app"))
            try fm.createSymbolicLink(atPath: stage.appendingPathComponent("Applications").path, withDestinationPath: "/Applications")
        } catch {
            throw Failure(message: "Geotag could not be copied: \(error.localizedDescription)")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["create", "-quiet", "-volname", "Geotag", "-srcfolder", stage.path, "-format", "UDZO", image.path]
        let err = Pipe()
        process.standardError = err
        process.standardOutput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw Failure(message: "The disk image could not be made: \(error.localizedDescription)")
        }
        let problem = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, fm.fileExists(atPath: image.path) else {
            let why = String(decoding: problem, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure(message: "The disk image could not be made" + (why.isEmpty ? "." : ": \(why)"))
        }

        // In its place, over the one of the same name if there is one.
        let target = folder.appendingPathComponent("Geotag \(version).dmg")
        do {
            if fm.fileExists(atPath: target.path) {
                do {
                    _ = try fm.replaceItemAt(target, withItemAt: image)
                } catch {
                    try fm.removeItem(at: target)
                    try fm.moveItem(at: image, to: target)
                }
            } else {
                try fm.moveItem(at: image, to: target)
            }
            return target
        } catch {
            throw Failure(message: "The disk image could not be put in \(folder.lastPathComponent): \(error.localizedDescription)")
        }
    }
}
