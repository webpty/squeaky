import Foundation

#if os(macOS)

/// The ExifTool inside the app, run on the Mac's own Perl.
public struct ExifTool: Sendable {
    public let script: URL

    public init(script: URL) {
        self.script = script
    }

    /// Inside the app: Contents/Resources/ExifTool/exiftool.
    public static func bundled() -> ExifTool? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("ExifTool/exiftool"),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return ExifTool(script: url)
    }

    public struct Failure: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// Runs ExifTool with these arguments and returns what it printed.
    public func run(_ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [script.path] + arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let problem = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure(message: String(data: problem, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "ExifTool failed.")
        }
        return data
    }

    /// The named tags of one file, as text.
    public func read(_ tags: [String], from file: URL) throws -> [String: String] {
        let data = try run(["-j", "-q"] + tags.map { "-\($0)" } + [file.path])
        guard let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]], let first = list.first else { return [:] }
        var out: [String: String] = [:]
        for (key, value) in first where key != "SourceFile" { out[key] = "\(value)" }
        return out
    }
}

#endif
