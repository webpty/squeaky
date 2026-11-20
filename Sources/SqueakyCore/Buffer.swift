import CryptoKit
import Foundation

/// The buffer server, bufr.cc (0.30.0, David, 17 November 2026): away from
/// home photos go there, fast, and a container on the NAS fetches them home.
/// At home they go straight to the NAS as before.
public struct BufferStatus: Decodable, Equatable, Sendable {
    public var role: String
    public var name: String
    public var waiting: Int
    public var waitingBytes: Int64
    /// This device is on the home's connection: the NAS fetches from the same address.
    public var atHome: Bool
}

public enum BufferError: LocalizedError, Equatable {
    case notSetUp
    case refusedKey
    case unreachable(String)
    case answered(Int, String)

    public var errorDescription: String? {
        switch self {
        case .notSetUp: return Words.t("The buffer server isn't set up.")
        case .refusedKey: return Words.t("The buffer server doesn't know this key.")
        case .unreachable(let why): return Words.t("The buffer server isn't answering: {0}", why)
        case .answered(_, let why): return why
        }
    }
}

public struct BufferClient: Sendable {
    public let address: URL
    public let key: String

    public init?(address: String, key: String) {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, let url = URL(string: trimmed.hasPrefix("http") ? trimmed : "https://" + trimmed),
              url.host != nil else { return nil }
        self.address = url
        self.key = key
    }

    private func request(_ path: String) -> URLRequest {
        var request = URLRequest(url: address.appendingPathComponent(path))
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20
        return request
    }

    public func status() async throws -> BufferStatus {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request("v1/status"))
            NetHealth.shared.through()
        } catch {
            NetHealth.shared.failed(error)
            throw BufferError.unreachable(error.localizedDescription)
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 || code == 403 { throw BufferError.refusedKey }
        guard code == 200, let status = try? JSONDecoder().decode(BufferStatus.self, from: data) else {
            throw BufferError.answered(code, Words.t("The buffer server gave an answer Squeaky doesn't understand."))
        }
        return status
    }

    /// The request that sends one photo: its place on the NAS, its
    /// fingerprint and its date go with it; the body is the file itself.
    public func upload(path: String, sha256: String, size: Int64, modified: Date?, update: Bool) -> URLRequest {
        var request = request("v1/photos")
        request.httpMethod = "PUT"
        request.timeoutInterval = 600
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        request.setValue(path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path, forHTTPHeaderField: "X-Path")
        request.setValue(sha256, forHTTPHeaderField: "X-Sha256")
        request.setValue(String(size), forHTTPHeaderField: "Content-Length")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        if let modified {
            let iso = ISO8601DateFormatter()
            request.setValue(iso.string(from: modified), forHTTPHeaderField: "X-Modified")
        }
        if update { request.setValue("1", forHTTPHeaderField: "X-Update") }
        return request
    }

    /// A sync list kept at the buffer server (0.31.8), by the path it has on
    /// the NAS ("home/Squeaky/~Squeaky/saved.json"); nil when none was written yet.
    public func readList(_ path: String) async throws -> Data? {
        var request = request("v1/lists")
        request.setValue(Self.encoded(path), forHTTPHeaderField: "X-Path")
        let (data, code) = try await send(request)
        if code == 204 { return nil }
        guard code == 200 else { throw Self.problem(code, data) }
        return data
    }

    /// The whole list, written over the one kept there.
    public func writeList(_ path: String, _ bytes: Data) async throws {
        var request = request("v1/lists")
        request.httpMethod = "PUT"
        request.timeoutInterval = 60
        request.setValue(Self.encoded(path), forHTTPHeaderField: "X-Path")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bytes
        let (data, code) = try await send(request)
        guard code == 204 || code == 200 else { throw Self.problem(code, data) }
    }

    private func send(_ request: URLRequest) async throws -> (Data, Int) {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            NetHealth.shared.through()
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch {
            NetHealth.shared.failed(error)
            throw BufferError.unreachable(error.localizedDescription)
        }
    }

    private static func problem(_ code: Int, _ data: Data) -> BufferError {
        if code == 404 || code == 403 { return .refusedKey }
        let said = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
        return .answered(code, said ?? Words.t("The buffer server answered {0}.", code))
    }

    static func encoded(_ path: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
    }

    /// The SHA-256 of a file, read a piece at a time.
    public static func fingerprint(of url: URL) throws -> (sha256: String, size: Int64) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var size: Int64 = 0
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
            size += Int64(chunk.count)
        }
        return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), size)
    }
}
