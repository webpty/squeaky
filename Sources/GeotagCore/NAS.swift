import CryptoKit
import Foundation
import NetFS

// MARK: - Sending one photo

public enum SendOutcome: Equatable, Sendable {
    /// Copied, read back from the NAS and found identical, under this name.
    case sent(URL)
    /// The very same file was there already; nothing written.
    case alreadyThere(URL)
    /// Geotag's own earlier copy of the same photo, replaced by the newer one
    /// (its location was written in after the first copy went).
    case replaced(URL)

    public var url: URL {
        switch self {
        case .sent(let u), .alreadyThere(let u), .replaced(let u): return u
        }
    }
}

public enum NASError: Error, LocalizedError, Equatable {
    /// The NAS can't be reached, or the connection broke off: try again later.
    case offline(String)
    /// The NAS has no room left.
    case full
    /// This photo can't be sent, and why.
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .offline(let why), .failed(let why): return why
        case .full: return "NAS full"
        }
    }

    /// Errors that mean the connection went, not the file.
    static let broken: Set<Int32> = [ENOTCONN, ENETDOWN, ENETUNREACH, ENETRESET, EHOSTDOWN, EHOSTUNREACH, ETIMEDOUT,
                                     ECONNRESET, ECONNABORTED, ECONNREFUSED, EPIPE, ENXIO, EIO, ESTALE]

    /// What a file error means for the queue: the connection went, the NAS is
    /// full, or this one photo failed.
    static func from(_ error: Error, doing: String) -> NASError {
        if let known = error as? NASError { return known }
        let ns = error as NSError
        let posix: Int32? = ns.domain == NSPOSIXErrorDomain ? Int32(ns.code)
            : (ns.userInfo[NSUnderlyingErrorKey] as? NSError).flatMap { $0.domain == NSPOSIXErrorDomain ? Int32($0.code) : nil }
        if let posix {
            if posix == ENOSPC || posix == EDQUOT { return .full }
            if broken.contains(posix) { return .offline("The connection to the NAS broke off.") }
            if posix == EACCES || posix == EPERM || posix == EROFS { return .failed("The NAS refused to write it.") }
        }
        if ns.domain == NSCocoaErrorDomain {
            if ns.code == NSFileWriteOutOfSpaceError { return .full }
            if [NSFileWriteNoPermissionError, NSFileReadNoPermissionError, NSFileWriteVolumeReadOnlyError].contains(ns.code) {
                return .failed("The NAS refused to write it.")
            }
        }
        return .failed("\(doing): \(error.localizedDescription)")
    }
}

/// Where someone's photos go on the NAS, as kept in People: "homes/david/Photos"
/// is the shared folder "homes" and the path "david/Photos" inside it.
public struct NASFolder: Equatable, Sendable {
    public var share: String
    public var path: String

    public init?(_ text: String?) {
        let parts = (text ?? "").split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let first = parts.first else { return nil }
        share = first
        path = parts.dropFirst().joined(separator: "/")
    }

    /// The folder itself, inside the shared folder open on this Mac.
    public func folder(in share: URL) -> URL {
        path.isEmpty ? share : share.appendingPathComponent(path, isDirectory: true)
    }
}

public enum NASSender {
    private static let naming = NSLock()

    /// Copies a photo saved on this Mac into a folder on the NAS. It goes up
    /// under a hidden working name, is read back from the NAS itself and
    /// compared with the Mac's copy, gets the Mac copy's dates, and only then
    /// takes its name. Nothing on the NAS is overwritten, except Geotag's own
    /// earlier copy of the same photo when `update` is set.
    public static func send(_ local: URL, as name: String, into folder: URL, update: Bool, clean: Bool,
                            exifTool: ExifTool?, progress: @escaping @Sendable (SendStep) -> Void) throws -> SendOutcome {
        let fm = FileManager.default
        progress(.looking)
        guard fm.fileExists(atPath: local.path) else { throw NASError.failed("The copy on this Mac is no longer there.") }
        // One handle for all of it: should the copy be swapped for a newer one
        // meanwhile, this send stays whole and the newer one goes next.
        let input: FileHandle
        let size: UInt64
        let localHash: String
        do {
            input = try FileHandle(forReadingFrom: local)
        } catch {
            throw NASError.failed("The copy on this Mac could not be read: \(error.localizedDescription)")
        }
        defer { try? input.close() }
        do {
            size = try input.seekToEnd()
            try input.seek(toOffset: 0)
            localHash = try hash(input)
        } catch {
            throw NASError.failed("The copy on this Mac could not be read: \(error.localizedDescription)")
        }

        // The day folder, and room in it.
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw NASError.from(error, doing: "Making the folder \(folder.lastPathComponent)")
        }
        if clean { clearLeftovers(in: folder) }
        if let free = (try? fm.attributesOfFileSystem(forPath: folder.path))?[.systemFreeSize] as? NSNumber,
           free.uint64Value < size + (64 << 20) {
            throw NASError.full
        }

        // Its name: its own, unless another photo has it.
        let samePhoto: (URL, URL) -> Bool = { a, b in
            exifTool.map { Saver(exifTool: $0, folder: folder).samePhoto(a, b) } ?? false
        }
        let sameLocation: (URL, URL) -> Bool = { a, b in
            exifTool.map { Saver(exifTool: $0, folder: folder).sameLocation(a, b) } ?? false
        }
        var n = 1
        var target = folder.appendingPathComponent(name)
        var replacing = false
        do {
            while fm.fileExists(atPath: target.path) {
                let there = (try fm.attributesOfItem(atPath: target.path)[.size] as? NSNumber)?.uint64Value
                if there == size, try hashOnNAS(target) == localHash { return .alreadyThere(target) }
                if samePhoto(target, local) {
                    if !update {
                        // The same photo at the same place, its details written
                        // a little differently (an older Geotag): it is there.
                        if sameLocation(target, local) { return .alreadyThere(target) }
                        throw NASError.failed("Already on the NAS with another location")
                    }
                    replacing = true
                    break
                }
                n += 1
                target = folder.appendingPathComponent(Saver.numbered(name, n))
            }
        } catch {
            throw NASError.from(error, doing: "Looking at \(target.lastPathComponent) on the NAS")
        }

        // Up under a working name, a piece at a time.
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        func hidden(_ kind: String) -> URL {
            folder.appendingPathComponent(".\(stem).geotag-\(kind)-\(UUID().uuidString.prefix(8))" + (ext.isEmpty ? "" : ".\(ext)"))
        }
        let work = hidden("up")
        func drop() { try? fm.removeItem(at: work) }
        do {
            let fd = open(work.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
            guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            // Not kept by this Mac, and pushed out every 2 MB: the share said
            // is what has reached the NAS, not what the Mac has taken in. It
            // used to reach 100% at once, then wait half a minute (David, 2 November 2026).
            _ = fcntl(fd, F_NOCACHE, 1)
            try input.seek(toOffset: 0)
            var done: UInt64 = 0
            progress(.sending(0))
            while let chunk = try input.read(upToCount: 2 << 20), !chunk.isEmpty {
                try output.write(contentsOf: chunk)
                try output.synchronize()
                done += UInt64(chunk.count)
                progress(.sending(size == 0 ? 1 : Double(done) / Double(size)))
            }
            try output.close()
        } catch {
            drop()
            throw NASError.from(error, doing: "Copying \(name) to the NAS")
        }

        // Read back from the NAS itself, and compared.
        let arrived: String
        do {
            progress(.checking(0))
            arrived = try hashOnNAS(work) { progress(.checking($0)) }
        } catch {
            drop()
            throw NASError.from(error, doing: "Reading \(name) back from the NAS")
        }
        guard arrived == localHash else {
            drop()
            throw NASError.failed("It arrived on the NAS different from the Mac's copy.")
        }

        // The Mac copy's own dates, given once it has its name: a working
        // file with an old date looks like a leftover, and another photo
        // starting in the same folder cleared it away (David, 2 November 2026).
        progress(.naming)
        let attributes = (try? fm.attributesOfItem(atPath: local.path)) ?? [:]
        var dates: [FileAttributeKey: Any] = [:]
        if let c = attributes[.creationDate] { dates[.creationDate] = c }
        if let m = attributes[.modificationDate] { dates[.modificationDate] = m }
        func dated(_ url: URL) -> URL {
            if !dates.isEmpty { try? fm.setAttributes(dates, ofItemAtPath: url.path) }
            return url
        }

        // One photo names itself at a time: several go up at once.
        naming.lock()
        defer { naming.unlock() }
        if replacing {
            let old = hidden("old")
            do {
                try fm.moveItem(at: target, to: old)
            } catch {
                drop()
                throw NASError.from(error, doing: "Setting aside the earlier \(target.lastPathComponent)")
            }
            do {
                try fm.moveItem(at: work, to: target)
            } catch {
                try? fm.moveItem(at: old, to: target)
                drop()
                throw NASError.from(error, doing: "Naming \(target.lastPathComponent) on the NAS")
            }
            try? fm.removeItem(at: old)
            return .replaced(dated(target))
        }

        // A move never replaces: if the name was taken meanwhile, the next one.
        var final = target
        while true {
            if fm.fileExists(atPath: final.path) {
                n += 1
                final = folder.appendingPathComponent(Saver.numbered(name, n))
                continue
            }
            do {
                try fm.moveItem(at: work, to: final)
                return .sent(dated(final))
            } catch CocoaError.fileWriteFileExists {
                n += 1
                final = folder.appendingPathComponent(Saver.numbered(name, n))
            } catch {
                drop()
                throw NASError.from(error, doing: "Naming \(final.lastPathComponent) on the NAS")
            }
        }
    }

    /// Geotag's own unfinished uploads in a NAS folder, left by a connection
    /// that broke off: hidden files named ".<photo>.geotag-up-<id>.<ext>",
    /// untouched for an hour (another Mac may be sending one right now). Only
    /// these are removed, never anything else.
    public static func clearLeftovers(in folder: URL, olderThan age: TimeInterval = 3600) {
        let fm = FileManager.default
        let now = Date()
        for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        where name.hasPrefix(".") && name.range(of: #"\.geotag-up-[0-9A-F]{8}(\.[^.]+)?$"#, options: .regularExpression) != nil {
            let url = folder.appendingPathComponent(name)
            guard let changed = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
                  now.timeIntervalSince(changed) > age else { continue }
            try? fm.removeItem(at: url)
        }
    }

    static func hash(_ handle: FileHandle, read: ((Double) -> Void)? = nil) throws -> String {
        var hasher = SHA256()
        let size = read == nil ? 0 : (try? handle.seekToEnd()) ?? 0
        if read != nil { try handle.seek(toOffset: 0) }
        var done: UInt64 = 0
        while let chunk = try handle.read(upToCount: read == nil ? 4 << 20 : 2 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
            done += UInt64(chunk.count)
            if size > 0 { read?(Double(done) / Double(size)) }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Read from the NAS itself, not from what this Mac kept of it.
    static func hashOnNAS(_ url: URL, read: ((Double) -> Void)? = nil) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        _ = fcntl(handle.fileDescriptor, F_NOCACHE, 1)
        return try hash(handle, read: read)
    }
}

/// Where one photo's send has got, as the Queue page says it.
public enum SendStep: Equatable, Sendable {
    /// Seeing whether it is on the NAS already, and under which name it goes.
    case looking
    /// Its share that has reached the NAS.
    case sending(Double)
    /// Its share read back from the NAS and compared.
    case checking(Double)
    /// Its dates and final name.
    case naming

    public var text: String {
        switch self {
        case .looking: return "Looking"
        case .sending(let f): return "Sending \(Int((f * 100).rounded(.down)))%"
        case .checking(let f): return "Checking \(Int((f * 100).rounded(.down)))%"
        case .naming: return "Naming"
        }
    }

    /// The step alone, without its share.
    public var word: String {
        switch self {
        case .looking: return "Looking"
        case .sending: return "Sending"
        case .checking: return "Checking"
        case .naming: return "Naming"
        }
    }

    /// The step's own share, for the bar behind it in a list: nil for the
    /// steps that have none.
    public var share: Double? {
        switch self {
        case .sending(let f), .checking(let f): return f
        case .looking, .naming: return nil
        }
    }

    /// "42%", or nothing.
    public var percent: String {
        share.map { "\(Int(($0 * 100).rounded(.down)))%" } ?? ""
    }

    /// How far the whole send has got, for a bar: sending is the first
    /// half, checking the second.
    public var fraction: Double {
        switch self {
        case .looking: return 0
        case .sending(let f): return f / 2
        case .checking(let f): return 0.5 + f / 2
        case .naming: return 1
        }
    }
}

// MARK: - Reaching the NAS

/// A shared folder of the NAS, open on this Mac.
public struct NASConnection: Equatable, Sendable {
    /// Where the shared folder is on this Mac.
    public var folder: URL
    /// The address that answered.
    public var address: String
    /// Opened by Geotag, and closed again when nothing is waiting; a shared
    /// folder Finder opened is left alone.
    public var ours: Bool

    public init(folder: URL, address: String, ours: Bool) {
        self.folder = folder
        self.address = address
        self.ours = ours
    }
}

/// What the queue needs from the NAS.
public protocol NASPort: Sendable {
    /// The shared folder, open, from the first address that answers.
    func connect(share: String) async throws -> NASConnection
    func disconnect(_ connection: NASConnection) async
}

/// The real NAS, over the Mac's own file sharing. A shared folder already open
/// (by Finder, or earlier by Geotag) is used where it is. Geotag opens one
/// hidden from Finder, and so that a lost connection gives up instead of
/// hanging.
public struct NASOverSMB: NASPort {
    public var addresses: [String]
    public var user: String?
    public var password: String?

    public init(addresses: [String], user: String?, password: String?) {
        self.addresses = addresses.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let user = user?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.user = user?.isEmpty == false ? user : nil
        self.password = password?.isEmpty == false ? password : nil
    }

    /// "10.0.10.10" from "smb://10.0.10.10", "10.0.10.10" or "smb://10.0.10.10/".
    public static func host(_ address: String) -> String? {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "smb://" + text }
        guard let host = URL(string: text)?.host, !host.isEmpty else { return nil }
        return host
    }

    public func connect(share: String) async throws -> NASConnection {
        var tried: [String] = []
        for address in addresses {
            guard let host = Self.host(address) else { continue }
            tried.append(host)
            if let open = Self.mounted(host: host, share: share) {
                if await Self.alive(open) { return NASConnection(folder: open, address: address, ours: false) }
                continue // open but not answering: the next address
            }
            switch await Self.mount(host: host, share: share, user: user, password: password, timeout: 30) {
            case .success(let opened):
                return NASConnection(folder: opened.folder, address: address, ours: opened.ours)
            case .failure(.failed(let why)):
                throw NASError.failed(why) // it answered and refused: the other address would too
            case .failure:
                continue
            }
        }
        throw NASError.offline(tried.isEmpty ? "No NAS address is set in Settings."
                                              : "The NAS can't be reached at \(tried.joined(separator: " or ")).")
    }

    public func disconnect(_ connection: NASConnection) async {
        guard connection.ours else { return }
        let path = connection.folder.path
        _ = await Blocking.within(20) { unmount(path, 0) }
    }

    /// The shared folder of that address, already open on this Mac.
    static func mounted(host: String, share: String) -> URL? {
        let keys: [URLResourceKey] = [.volumeURLForRemountingKey]
        for volume in FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: []) ?? [] {
            guard let remote = (try? volume.resourceValues(forKeys: Set(keys)))?.volumeURLForRemounting,
                  remote.host?.lowercased() == host.lowercased() else { continue }
            if remote.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased() == share.lowercased() {
                return volume
            }
        }
        return nil
    }

    /// Answers within a few seconds. A shared folder whose server went away
    /// can hang a question for minutes: while one still hangs, it counts as
    /// not answering, and no second question is stacked behind it.
    static func alive(_ folder: URL) async -> Bool {
        let path = folder.path
        guard asking.begin(path) else { return false }
        return await Blocking.within(5) {
            defer { asking.end(path) }
            return (try? FileManager.default.attributesOfFileSystem(forPath: path)) != nil
        } ?? false
    }

    static let asking = InFlight()

    static func mount(host: String, share: String, user: String?, password: String?,
                      timeout: Double) async -> Result<(folder: URL, ours: Bool), NASError> {
        var parts = URLComponents()
        parts.scheme = "smb"
        parts.host = host
        parts.path = "/" + share
        guard let url = parts.url else { return .failure(.failed("The NAS address is not valid.")) }
        // Never a window asking for a password: what Settings holds, or nothing.
        let open = NSMutableDictionary()
        open["UIOption"] = "NoUI"
        let options = NSMutableDictionary()
        options["SoftMount"] = true
        options["MountFlags"] = NSNumber(value: MNT_DONTBROWSE)
        return await withCheckedContinuation { done in
            let once = Once()
            let request = RequestBox()
            let status = NetFSMountURLAsync(url as CFURL, nil, user.map { $0 as CFString }, password.map { $0 as CFString },
                                            open, options, &request.id, DispatchQueue.global()) { status, _, points in
                guard once.first() else { return }
                let list = (points as NSArray?)?.compactMap { $0 as? String } ?? []
                done.resume(returning: outcome(status, list, host: host, share: share, user: user))
            }
            if status != 0 {
                if once.first() { done.resume(returning: outcome(status, [], host: host, share: share, user: user)) }
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard once.first() else { return }
                if let id = request.id { NetFSMountURLCancel(id) }
                done.resume(returning: .failure(.offline("The NAS did not answer at \(host).")))
            }
        }
    }

    static func outcome(_ status: Int32, _ points: [String], host: String, share: String,
                        user: String?) -> Result<(folder: URL, ours: Bool), NASError> {
        if status == 0 || status == EEXIST {
            if let path = points.first { return .success((URL(fileURLWithPath: path, isDirectory: true), status == 0)) }
            if let open = mounted(host: host, share: share) { return .success((open, false)) }
        }
        switch status {
        case EAUTH, EACCES, EPERM, -5045, -5046, -5999:
            return .failure(.failed(user == nil ? "The NAS wants a user name and password: set them in Settings."
                                                : "The NAS refused the user name or password in Settings."))
        case ENOENT, -5998, -6003:
            return .failure(.failed("The NAS has no shared folder called \(share)."))
        default:
            return .failure(.offline("The NAS did not open \(share) at \(host) (\(status))."))
        }
    }
}

private final class RequestBox: @unchecked Sendable {
    var id: AsyncRequestID?
}

/// Questions still waiting for an answer, by folder.
final class InFlight: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: Set<String> = []

    func begin(_ path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return paths.insert(path).inserted
    }

    func end(_ path: String) {
        lock.lock()
        defer { lock.unlock() }
        paths.remove(path)
    }
}

final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func first() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

enum Blocking {
    /// Work that may hang on a lost connection, run on another thread; nil
    /// when it takes longer than that (it is left to finish on its own).
    static func within<T: Sendable>(_ seconds: Double, _ work: @escaping @Sendable () -> T) async -> T? {
        await withCheckedContinuation { (done: CheckedContinuation<T?, Never>) in
            let once = Once()
            DispatchQueue.global().async {
                let result = work()
                if once.first() { done.resume(returning: result) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                if once.first() { done.resume(returning: nil) }
            }
        }
    }
}
