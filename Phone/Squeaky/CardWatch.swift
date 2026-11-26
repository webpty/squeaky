import Foundation
import SqueakyCore
import SqueakyUI
import UIKit

/// Cards opened once are remembered (David, 16 November 2026): plugged in
/// again while Squeaky is open, or when it opens, a remembered card is read
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

    /// A remembered folder no longer to be opened.
    static func forget(_ id: String) {
        var all = UserDefaults.standard.dictionary(forKey: key) as? [String: Data] ?? [:]
        all[id] = nil
        UserDefaults.standard.set(all, forKey: key)
    }

    /// Not an SD card (0.34.14): forgotten.
    private func dropNotACard(_ id: String) {
        Self.forget(id)
        letGo.remove(id)
        model.forgetNotACard(id: id)
    }

    private func look() {
        // A card the list was showing and is now let go of stays let go of while it is in.
        if let id = lastSource, model.source == nil { letGo.insert(id) }
        lastSource = model.source?.id
        // The card in use, taken out: noticed here, since the phone says nothing (0.29.37).
        if let card = model.source, card.isCard, !model.photosBusy, !model.saving {
            let there = (try? card.url.checkResourceIsReachable()) == true
                && (try? FileManager.default.contentsOfDirectory(atPath: card.url.path)) != nil
            if !there {
                model.cardTakenOut()
                letGo.remove(card.id)
                lastSource = nil
            } else if SDCard.surelyNotACard(card.url) {
                // Present, and no DCIM folder: a folder opened as a card before
                // 0.34.14, let go of. A card taken out is never taken for one
                // (0.34.15: 0.34.14 forgot cards that way, and whose they were).
                dropNotACard(card.id)
                lastSource = nil
            }
            return
        }
        guard model.source == nil, !model.photosBusy, !model.saving, model.macOwner != nil else { return }
        let all = UserDefaults.standard.dictionary(forKey: Self.key) as? [String: Data] ?? [:]
        // Whether a card let go of is still in, for "Copy done. Remove the card." (0.29.40).
        var stillIn = false
        defer { if model.cardStillIn != stillIn { model.cardStillIn = stillIn } }
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
            if SDCard.surelyNotACard(url) {
                if access { url.stopAccessingSecurityScopedResource() }
                dropNotACard(id)
                continue
            }
            if letGo.contains(id) {
                if access { url.stopAccessingSecurityScopedResource() }
                stillIn = true
                continue
            }
            if stale { Self.remember(url, id: id) }
            model.choose(PhotosTab.source(url, id: id))
            lastSource = id
            return
        }
    }
}
