import Foundation
import GeotagCore
import GeotagUI
import UIKit

/// Cards opened once are remembered (David, 16 November 2026): plugged in
/// again while Geotag is open, or when it opens, a remembered card is read
/// by itself. The phone lets an app into a card only after it is chosen once
/// in the Files list, so each new card still takes Open card the first time.
@MainActor
final class CardWatch {
    private let model: AppModel
    private var timer: Timer?
    /// Cards let go of while still plugged in: not read again until taken out.
    private var letGo: Set<String> = []
    private var lastSource: String?
    static let key = "cardBookmarks"

    init(model: AppModel) {
        self.model = model
    }

    func start() {
        guard timer == nil else { return }
        look()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.look() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// A card opened in the Files list, kept for next time.
    static func remember(_ url: URL, id: String) {
        guard let data = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else { return }
        var all = UserDefaults.standard.dictionary(forKey: key) as? [String: Data] ?? [:]
        all[id] = data
        UserDefaults.standard.set(all, forKey: key)
    }

    private func look() {
        // A card the list was showing and is now let go of stays let go of while it is in.
        if let id = lastSource, model.source == nil { letGo.insert(id) }
        lastSource = model.source?.id
        guard model.source == nil, !model.photosBusy, !model.saving, model.macOwner != nil else { return }
        let all = UserDefaults.standard.dictionary(forKey: Self.key) as? [String: Data] ?? [:]
        for (id, data) in all {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else {
                letGo.remove(id)
                continue
            }
            let access = url.startAccessingSecurityScopedResource()
            let there = (try? url.checkResourceIsReachable()) == true
                && (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil
            guard there else {
                if access { url.stopAccessingSecurityScopedResource() }
                letGo.remove(id)
                continue
            }
            if letGo.contains(id) {
                if access { url.stopAccessingSecurityScopedResource() }
                continue
            }
            if stale { Self.remember(url, id: id) }
            model.choose(PhotosTab.source(url, id: id))
            lastSource = id
            return
        }
    }
}
