import AppKit
import DiskArbitration
import GeotagCore

/// Holds camera cards for Geotag alone. A card going in is stopped before the
/// Mac opens it for everyone, then opened by Geotag hidden and read-only, so
/// Finder, Photos, Lightroom and Spotlight never see it and nothing can write
/// to it. A disk that turns out to hold no camera folder is let through as
/// usual. Only external FAT and exFAT disks are looked at at all.
@MainActor
public final class CardGuard {
    public var onHeld: (PhotoSource) -> Void = { _ in }
    public var onGone: (String) -> Void = { _ in }
    public var onProblem: (String) -> Void = { _ in }

    /// The folder that makes a disk a camera card.
    let marker: String
    /// Which disks to look at; every external FAT or exFAT disk by default.
    let accepts: @Sendable ([String: Any]) -> Bool

    private var session: DASession?
    /// Disks Geotag is opening itself, hidden.
    private var opening: Set<String> = []
    /// Disks with no camera folder, let through to open as usual.
    private var letThrough: Set<String> = []
    private var attemptsStarted: Set<String> = []
    private(set) public var held: [String: PhotoSource] = [:]

    public init(marker: String = "DCIM", accepts: (@Sendable ([String: Any]) -> Bool)? = nil) {
        self.marker = marker
        self.accepts = accepts ?? CardGuard.cardLike
    }

    /// External, removable or ejectable, FAT or exFAT: what a camera card is.
    public nonisolated static func cardLike(_ d: [String: Any]) -> Bool {
        let kind = (d[kDADiskDescriptionVolumeKindKey as String] as? String)?.lowercased() ?? ""
        guard ["msdos", "exfat"].contains(kind) else { return false }
        if d[kDADiskDescriptionDeviceInternalKey as String] as? Bool == true { return false }
        return d[kDADiskDescriptionMediaRemovableKey as String] as? Bool == true
            || d[kDADiskDescriptionMediaEjectableKey as String] as? Bool == true
    }

    private static func description(_ disk: DADisk) -> [String: Any] {
        (DADiskCopyDescription(disk) as? [String: Any]) ?? [:]
    }

    private static func bsdName(_ disk: DADisk) -> String? {
        DADiskGetBSDName(disk).map { String(cString: $0) }
    }

    public func start() {
        guard session == nil, let session = DASessionCreate(kCFAllocatorDefault) else { return }
        self.session = session
        DASessionSetDispatchQueue(session, DispatchQueue.main)
        let me = Unmanaged.passUnretained(self).toOpaque()

        DARegisterDiskMountApprovalCallback(session, nil, { disk, context in
            let guardian = Unmanaged<CardGuard>.fromOpaque(context!).takeUnretainedValue()
            return MainActor.assumeIsolated { guardian.approve(disk) }
        }, me)
        DARegisterDiskDisappearedCallback(session, nil, { disk, context in
            let guardian = Unmanaged<CardGuard>.fromOpaque(context!).takeUnretainedValue()
            MainActor.assumeIsolated { guardian.disappeared(disk) }
        }, me)
        let watch = [kDADiskDescriptionVolumePathKey] as CFArray
        DARegisterDiskDescriptionChangedCallback(session, nil, watch, { disk, _, context in
            let guardian = Unmanaged<CardGuard>.fromOpaque(context!).takeUnretainedValue()
            MainActor.assumeIsolated { guardian.pathChanged(disk) }
        }, me)
        takeOverMounted()
    }

    // MARK: Going in

    private func approve(_ disk: DADisk) -> Unmanaged<DADissenter>? {
        guard let bsd = Self.bsdName(disk), accepts(Self.description(disk)) else { return nil }
        if opening.contains(bsd) || letThrough.contains(bsd) { return nil }
        DispatchQueue.main.async { [weak self] in self?.openHidden(disk) }
        return Unmanaged.passRetained(DADissenterCreate(kCFAllocatorDefault, DAReturn(kDAReturnNotPermitted), "Held by Geotag" as CFString))
    }

    /// Disks being opened for the second time.
    fileprivate var retried: Set<String> = []

    private func openHidden(_ disk: DADisk) {
        guard let bsd = Self.bsdName(disk) else { return }
        if opening.contains(bsd) { return }
        if attemptsStarted.contains(bsd) { retried.insert(bsd) } else { attemptsStarted.insert(bsd) }
        opening.insert(bsd)
        let options = ["rdonly", "nobrowse"].map { Unmanaged.passRetained($0 as CFString) }
        var list: [Unmanaged<CFString>?] = options + [nil]
        let me = Unmanaged.passUnretained(self).toOpaque()
        list.withUnsafeMutableBufferPointer { buffer in
            let arguments = buffer.baseAddress!
            DADiskMountWithArguments(disk, nil, DADiskMountOptions(kDADiskMountOptionDefault), { disk, dissenter, context in
                let guardian = Unmanaged<CardGuard>.fromOpaque(context!).takeUnretainedValue()
                let status = dissenter.map { DADissenterGetStatus($0) }
                MainActor.assumeIsolated { guardian.opened(disk, status: status, attempt: guardian.retried.contains(DADiskGetBSDName(disk).map { String(cString: $0) } ?? "") ? 2 : 1) }
            }, me, arguments)
        }
        options.forEach { $0.release() }
    }

    private func opened(_ disk: DADisk, status: DAReturn?, attempt: Int = 1) {
        guard let bsd = Self.bsdName(disk) else { return }
        let d = Self.description(disk)
        let name = d[kDADiskDescriptionVolumeNameKey as String] as? String ?? bsd
        let url = d[kDADiskDescriptionVolumePathKey as String] as? URL
        // The Mac can answer "busy" while the program that attached the disk
        // is still at it, and open it all the same: what counts is whether it
        // is open. If not, try once more a moment later.
        if status != nil, url == nil {
            if attempt == 1 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self else { return }
                    if (Self.description(disk)[kDADiskDescriptionVolumePathKey as String] as? URL) != nil {
                        self.opened(disk, status: nil, attempt: 2)
                    } else {
                        self.opening.remove(bsd)
                        self.openHidden(disk)
                    }
                }
                return
            }
            opening.remove(bsd)
            onProblem("\(name) could not be opened (\(Self.words(status!))).")
            return
        }
        opening.remove(bsd)
        guard let url else { return }
        if hasMarker(url) {
            hold(disk, at: url)
        } else {
            // Not a camera card: close it and let the Mac open it as usual.
            letThrough.insert(bsd)
            DADiskUnmount(disk, DADiskUnmountOptions(kDADiskUnmountOptionDefault), { disk, _, _ in
                DADiskMount(disk, nil, DADiskMountOptions(kDADiskMountOptionDefault), nil, nil)
            }, nil)
        }
    }

    private func hasMarker(_ volume: URL) -> Bool {
        var folder: ObjCBool = false
        return FileManager.default.fileExists(atPath: volume.appendingPathComponent(marker).path, isDirectory: &folder) && folder.boolValue
    }

    private func hold(_ disk: DADisk, at url: URL) {
        guard let bsd = Self.bsdName(disk) else { return }
        let d = Self.description(disk)
        let id = (d[kDADiskDescriptionVolumeUUIDKey as String]).map { CFUUIDCreateString(nil, ($0 as! CFUUID)) as String } ?? bsd
        let source = PhotoSource(id: id, name: d[kDADiskDescriptionVolumeNameKey as String] as? String ?? url.lastPathComponent,
                                 url: url, isCard: true, bsd: bsd)
        held[bsd] = source
        onHeld(source)
    }

    /// Cards already open when Geotag starts are closed and opened again,
    /// hidden. One another app will not let go of is used as it is.
    private func takeOverMounted() {
        guard let session else { return }
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? []
        for url in volumes {
            guard let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL),
                  let bsd = Self.bsdName(disk), accepts(Self.description(disk)), hasMarker(url) else { continue }
            let values = try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey, .volumeIsBrowsableKey])
            if values?.volumeIsReadOnly == true, values?.volumeIsBrowsable == false {
                hold(disk, at: url)
                continue
            }
            let me = Unmanaged.passUnretained(self).toOpaque()
            opening.insert(bsd)
            DADiskUnmount(disk, DADiskUnmountOptions(kDADiskUnmountOptionDefault), { disk, dissenter, context in
                let guardian = Unmanaged<CardGuard>.fromOpaque(context!).takeUnretainedValue()
                let busy = dissenter != nil
                MainActor.assumeIsolated {
                    if busy {
                        guardian.opening.remove(DADiskGetBSDName(disk).map { String(cString: $0) } ?? "")
                        if let url = (DADiskCopyDescription(disk) as? [String: Any])?[kDADiskDescriptionVolumePathKey as String] as? URL {
                            guardian.hold(disk, at: url)
                        }
                    } else {
                        guardian.openHidden(disk)
                    }
                }
            }, me)
        }
    }

    // MARK: Coming out

    private func pathChanged(_ disk: DADisk) {
        guard let bsd = Self.bsdName(disk), held[bsd] != nil else { return }
        if Self.description(disk)[kDADiskDescriptionVolumePathKey as String] == nil { gone(bsd) }
    }

    private func disappeared(_ disk: DADisk) {
        guard let bsd = Self.bsdName(disk) else { return }
        letThrough.remove(bsd)
        attemptsStarted.remove(bsd)
        retried.remove(bsd)
        if held[bsd] != nil { gone(bsd) }
    }

    private func gone(_ bsd: String) {
        held[bsd] = nil
        onGone(bsd)
    }

    /// Forces the card off now, open files or not, then ejects it. Answers nil
    /// when it is out, or what went wrong.
    public func eject(_ bsd: String, done: @escaping @MainActor (String?) -> Void) {
        guard let session, let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsd) else {
            done("The card is no longer there.")
            return
        }
        final class Box { let done: @MainActor (String?) -> Void; init(_ d: @escaping @MainActor (String?) -> Void) { done = d } }
        let box = Unmanaged.passRetained(Box(done)).toOpaque()
        // Every volume on the card is closed by asking the whole disk.
        let whole = DADiskCopyWholeDisk(disk) ?? disk
        DADiskUnmount(whole, DADiskUnmountOptions(kDADiskUnmountOptionForce | kDADiskUnmountOptionWhole), { disk, dissenter, context in
            if let dissenter {
                let words = CardGuard.words(DADissenterGetStatus(dissenter))
                let box = Unmanaged<Box>.fromOpaque(context!).takeRetainedValue()
                MainActor.assumeIsolated { box.done("It could not be closed: \(words).") }
                return
            }
            DADiskEject(disk, DADiskEjectOptions(kDADiskEjectOptionDefault), { _, dissenter, context in
                let words = dissenter.map { CardGuard.words(DADissenterGetStatus($0)) }
                let box = Unmanaged<Box>.fromOpaque(context!).takeRetainedValue()
                MainActor.assumeIsolated { box.done(words.map { "It was closed but not ejected: \($0)." }) }
            }, context)
        }, box)
    }

    nonisolated static func words(_ status: DAReturn) -> String {
        switch Int(status) {
        case Int(kDAReturnBusy): return "another app is using it"
        case Int(kDAReturnNotPermitted), Int(kDAReturnNotPrivileged): return "the Mac did not allow it"
        case Int(kDAReturnNotFound): return "it is no longer there"
        case Int(kDAReturnNotReady): return "it is not ready"
        case Int(kDAReturnUnsupported): return "the Mac does not support that for this disk"
        default: return String(format: "error 0x%08X", UInt32(bitPattern: status))
        }
    }
}
