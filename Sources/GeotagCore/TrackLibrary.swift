import Foundation

/// How a refresh went, in words the Tracks screen can show.
public struct RefreshReport: Equatable, Sendable {
    public var added = 0
    public var uploaded = 0
    public var problems: [String] = []
    public var offline = false

    public var line: String {
        if offline { return Words.t("Offline. Showing the tracks on this Mac.") }
        if let first = problems.first { return first }
        var parts: [String] = []
        parts.append(added == 0 ? Words.t("No new tracks.") : added == 1 ? Words.t("1 new track.") : Words.t("{0} new tracks.", added))
        if uploaded > 0 { parts.append(uploaded == 1 ? Words.t("1 track uploaded.") : Words.t("{0} tracks uploaded.", uploaded)) }
        return parts.joined(separator: " ")
    }
}

public enum ImportResult: Equatable, Sendable {
    case added(Track)
    case alreadyHere(Track)
}

/// The tracks on this Mac, kept in step with the track service.
public actor TrackLibrary {
    let store: TrackStorePort
    private var all: [Track]

    public init(store: TrackStorePort) {
        self.store = store
        self.all = (try? store.loadIndex()) ?? []
    }

    /// The tracks to show, newest first.
    public func listed() -> [Track] {
        all.filter(\.isListed).sorted { $0.start > $1.start }
    }

    public func points(_ id: String) -> TrackPoints? {
        try? store.loadPoints(id)
    }

    private func save() throws {
        try store.saveIndex(all)
    }

    private func startingNear(_ date: Date) -> Track? {
        all.filter(\.isListed).first { abs($0.start.timeIntervalSince(date)) <= sameStartSeconds }
    }

    /// A GPX or FIT file into the library. On the owner's Mac it then waits
    /// for upload; on a Mac whose key only reads, it stays here.
    public func importFile(_ url: URL, role: KeyRole?) throws -> ImportResult {
        let imported = try TrackFiles.read(url)
        let start = Date(timeIntervalSince1970: TimeInterval(imported.points.t[0]))
        if let existing = startingNear(start) { return .alreadyHere(existing) }
        let track = Track(
            id: "local-\(UUID().uuidString.lowercased())",
            source: .file,
            name: imported.name,
            sport: nil,
            fileName: imported.fileName,
            start: start,
            end: Date(timeIntervalSince1970: TimeInterval(imported.points.t[imported.points.count - 1])),
            timeZone: nil,
            pointCount: imported.points.count,
            distance: Geo.distance(imported.points),
            bounds: Geo.bounds(imported.points),
            status: role == .reader ? .thisMacOnly : .waitingToUpload
        )
        try store.savePoints(track.id, imported.points)
        all.append(track)
        try save()
        return .added(track)
    }

    /// Uploads what waits, asks the service for a Strava pull when told to and
    /// this Mac is the owner's, and brings in every track the service has that
    /// this Mac does not. The service pulls by itself all day; asking is for
    /// the Refresh button.
    /// `loading` hears how many new tracks have come in of how many, before
    /// each one and once at the end.
    public func refresh(service: TrackServicePort, role: KeyRole, pullStrava: Bool = false,
                        loading: (@Sendable (_ done: Int, _ total: Int) async -> Void)? = nil) async -> RefreshReport {
        var report = RefreshReport()

        // A key that only reads cannot upload: what waited stays here.
        if role == .reader {
            for i in all.indices where all[i].status == .waitingToUpload { all[i].status = .thisMacOnly }
        }

        do {
            if role == .owner {
                report.uploaded = try await uploadWaiting(service)
                if pullStrava, let problem = try? await service.sync(), problem.hasPrefix("Strava") {
                    report.problems.append(problem)
                }
            }
            let remote = try await service.tracks()
            let known = Set(all.map(\.id))
            let total = remote.filter { !known.contains($0.id) }.count
            for item in remote {
                if known.contains(item.id) {
                    // Names and details can change on the service; keep them in step.
                    if let i = all.firstIndex(where: { $0.id == item.id }) {
                        let status = all[i].status
                        all[i] = item.track
                        all[i].status = status
                    }
                    continue
                }
                await loading?(report.added, total)
                let points = try await service.points(item.id)
                try store.savePoints(item.id, points)
                all.append(item.track)
                try save()
                report.added += 1
            }
            if total > 0 { await loading?(report.added, total) }
            try save()
        } catch ServiceError.offline {
            report.offline = true
        } catch {
            report.problems.append(error.localizedDescription)
        }
        try? save()
        return report
    }

    private func uploadWaiting(_ service: TrackServicePort) async throws -> Int {
        var count = 0
        for i in all.indices where all[i].status == .waitingToUpload {
            guard let points = try store.loadPoints(all[i].id) else { continue }
            let answer = try await service.upload(name: all[i].name, fileName: all[i].fileName, points: points)
            all[i].status = .uploaded
            all[i].serviceId = answer.track.id
            try save()
            if answer.added { count += 1 }
        }
        return count
    }

    public var waitingCount: Int {
        all.filter { $0.status == .waitingToUpload }.count
    }
}
