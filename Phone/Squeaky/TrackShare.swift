import CryptoKit
import Foundation
import SqueakyCore
import SqueakyUI
import MultipeerConnectivity

/// Tracks from the watch pass between family phones with Squeaky open nearby,
/// phone to phone with no internet, as the countries app does (0.32.0).
/// Only phones using the same track service find each other. Each tells the
/// other which watch tracks it has; each sends the ones the other lacks.
@MainActor
final class TrackShare: NSObject {
    static let shared = TrackShare()
    private static let service = "squeaky-trk"

    private var model: AppModel?
    private var me: MCPeerID?
    private var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var family = ""

    private struct Message: Codable {
        var kind: String
        var from: String
        var ids: [String]?
        var track: Track?
        var points: TrackPoints?
    }

    /// This install's own name among the phones, kept for good.
    private static var phoneId: String {
        if let id = UserDefaults.standard.string(forKey: "sharePhoneId") { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "sharePhoneId")
        return id
    }

    func start(model: AppModel) {
        self.model = model
        let address = model.serviceAddress.trimmingCharacters(in: .whitespaces).lowercased()
        guard !address.isEmpty else { return }
        let tag = SHA256.hash(data: Data(address.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        if session != nil, tag == family { return }
        stop()
        family = tag
        let peer = MCPeerID(displayName: Self.phoneId)
        let s = MCSession(peer: peer, securityIdentity: nil, encryptionPreference: .required)
        s.delegate = self
        let a = MCNearbyServiceAdvertiser(peer: peer, discoveryInfo: ["f": tag], serviceType: Self.service)
        a.delegate = self
        let b = MCNearbyServiceBrowser(peer: peer, serviceType: Self.service)
        b.delegate = self
        me = peer; session = s; advertiser = a; browser = b
        a.startAdvertisingPeer()
        b.startBrowsingForPeers()
    }

    func stop() {
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        session?.disconnect()
        advertiser = nil; browser = nil; session = nil; me = nil
    }

    /// A new watch track here: the phones already connected get it now.
    func offer() {
        guard let session, !session.connectedPeers.isEmpty else { return }
        Task { await sendHave(to: session.connectedPeers) }
    }

    private var myName: String { model?.ownerName ?? "" }

    private func sendHave(to peers: [MCPeerID]) async {
        guard let model, let session else { return }
        let ids = await model.library.watchTracks().map(\.id)
        send(Message(kind: "have", from: myName, ids: ids), to: peers, in: session)
    }

    private func send(_ message: Message, to peers: [MCPeerID], in session: MCSession) {
        guard let data = try? JSONEncoder().encode(message) else { return }
        try? session.send(data, toPeers: peers, with: .reliable)
    }

    private func receive(_ data: Data, from peer: MCPeerID) async {
        guard let model, let session, let message = try? JSONDecoder().decode(Message.self, from: data) else { return }
        switch message.kind {
        case "have":
            let theirs = Set(message.ids ?? [])
            for track in await model.library.watchTracks() where !theirs.contains(track.id) {
                guard let points = await model.library.points(track.id) else { continue }
                send(Message(kind: "track", from: myName, track: track, points: points), to: [peer], in: session)
            }
        case "track":
            guard let track = message.track, let points = message.points else { return }
            let from = message.from.isEmpty ? Words.t("a family phone") : message.from
            if await model.addSharedTrack(track, points: points, from: from) {
                // Passed on to any other phone here that lacks it.
                let others = session.connectedPeers.filter { $0 != peer }
                if !others.isEmpty { await sendHave(to: others) }
            }
        default:
            break
        }
    }
}

extension TrackShare: MCSessionDelegate, MCNearbyServiceAdvertiserDelegate, MCNearbyServiceBrowserDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        guard state == .connected else { return }
        Task { @MainActor in await self.sendHave(to: [peerID]) }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        Task { @MainActor in await self.receive(data, from: peerID) }
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                                withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        let family = context.flatMap { String(data: $0, encoding: .utf8) }
        MainActor.assumeIsolated {
            invitationHandler(family == self.family && self.session != nil, self.session)
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        MainActor.assumeIsolated {
            // Same track service only, and only one of the two phones invites.
            guard let session = self.session, let me = self.me, info?["f"] == self.family,
                  me.displayName < peerID.displayName else { return }
            browser.invitePeer(peerID, to: session, withContext: Data(self.family.utf8), timeout: 20)
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}
}
