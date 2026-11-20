import Foundation

#if os(macOS)

/// The disk image that puts Squeaky on another Mac: the Squeaky that is
/// running, beside a shortcut to Applications, made when asked for, so it
/// works the same on every Mac (David, 17 October 2026).
public enum Installer {
    public struct Failure: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// The two kinds of Mac (0.25.0, David, 6 November 2026, bringing the
    /// Intel version back after removing it on 17 October).
    public enum Chip: String, CaseIterable, Sendable {
        case appleSilicon, intel

        public var title: String { self == .appleSilicon ? "Apple silicon" : "Intel" }
        /// The processor as a Mach-O file names it.
        var cpuType: UInt32 { self == .appleSilicon ? 0x0100_000C : 0x0100_0007 }
    }

    /// Makes "Squeaky <version> <chip>.dmg" in that folder from the app at
    /// `app`, carrying only that kind of Mac's version, replacing one of the
    /// same name already there (David, 17 October 2026). The folder never
    /// holds half a disk image.
    public static func save(app: URL, version: String, chip: Chip = .appleSilicon, into folder: URL) throws -> URL {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("squeaky-download-\(UUID().uuidString)", isDirectory: true)
        let stage = work.appendingPathComponent("stage", isDirectory: true)
        let image = work.appendingPathComponent("Squeaky.dmg")
        // Squeaky's own working folder, gone again once the disk image is made.
        defer { try? fm.removeItem(at: work) }
        do {
            try fm.createDirectory(at: stage, withIntermediateDirectories: true)
            try fm.copyItem(at: app, to: stage.appendingPathComponent("Squeaky.app"))
            try fm.createSymbolicLink(atPath: stage.appendingPathComponent("Applications").path, withDestinationPath: "/Applications")
        } catch {
            throw Failure(message: "Squeaky could not be copied: \(error.localizedDescription)")
        }
        try only(chip, in: stage.appendingPathComponent("Squeaky.app/Contents/MacOS/Squeaky"))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["create", "-quiet", "-volname", "Squeaky", "-srcfolder", stage.path, "-format", "UDZO", image.path]
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
        let target = folder.appendingPathComponent("Squeaky \(version) \(chip.title).dmg")
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

    /// Keeps only that kind of Mac's part of a program built for both, as
    /// it was signed. A program for one kind only must be for that one.
    public static func only(_ chip: Chip, in program: URL) throws {
        guard let data = try? Data(contentsOf: program), data.count >= 8 else { return }
        func be32(_ at: Int) -> UInt32 { data[at..<at + 4].reduce(0) { $0 << 8 | UInt32($1) } }
        func le32(_ at: Int) -> UInt32 { data[at..<at + 4].reversed().reduce(0) { $0 << 8 | UInt32($1) } }
        let missing = Failure(message: "This Squeaky has no \(chip.title) version.")
        switch be32(0) {
        case 0xCAFE_BABE:
            for i in 0..<Int(be32(4)) {
                let entry = 8 + i * 20
                guard entry + 20 <= data.count else { break }
                guard be32(entry) == chip.cpuType else { continue }
                let offset = Int(be32(entry + 8)), size = Int(be32(entry + 12))
                guard offset + size <= data.count else { break }
                do {
                    try data[offset..<offset + size].write(to: program, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)
                } catch {
                    throw Failure(message: "Squeaky could not be copied: \(error.localizedDescription)")
                }
                return
            }
            throw missing
        case 0xCFFA_EDFE:
            // One kind only, in the Mac's own byte order.
            guard le32(4) == chip.cpuType else { throw missing }
        default:
            return
        }
    }
}

#endif
