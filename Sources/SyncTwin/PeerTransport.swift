@preconcurrency import MultipeerConnectivity
import Foundation

enum PeerConnectionState {
    case notConnected
    case connecting
    case connected
}

@MainActor
protocol PeerTransportDelegate: AnyObject {
    func peerTransport(_ transport: PeerTransport, didUpdate discoveredPeers: [DiscoveredPeer])
    func peerTransport(_ transport: PeerTransport, didChange state: PeerConnectionState, for peerDisplayName: String)
    func peerTransport(_ transport: PeerTransport, didReceive data: Data, from peerDisplayName: String)
    func peerTransport(_ transport: PeerTransport, didReport errorMessage: String)
}

final class PeerTransport: NSObject {
    weak var delegate: PeerTransportDelegate?

    private(set) var localPeerID: MCPeerID
    private var session: MCSession
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var discoveredPeerIDs: [String: MCPeerID] = [:]

    init(displayName: String) {
        localPeerID = MCPeerID(displayName: displayName)
        session = MCSession(peer: localPeerID, securityIdentity: nil, encryptionPreference: .required)
        super.init()
        session.delegate = self
    }

    func start() {
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()

        let advertiser = MCNearbyServiceAdvertiser(peer: localPeerID, discoveryInfo: nil, serviceType: AppConstants.serviceType)
        advertiser.delegate = self
        advertiser.startAdvertisingPeer()
        self.advertiser = advertiser

        let browser = MCNearbyServiceBrowser(peer: localPeerID, serviceType: AppConstants.serviceType)
        browser.delegate = self
        browser.startBrowsingForPeers()
        self.browser = browser
    }

    func stop() {
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        session.disconnect()
        discoveredPeerIDs.removeAll()
        DispatchQueue.main.async {
            self.delegate?.peerTransport(self, didUpdate: [])
        }
    }

    func disconnect() {
        session.disconnect()
    }

    func connectedPeerDisplayName() -> String? {
        session.connectedPeers.first?.displayName
    }

    func invite(peerNamed displayName: String) {
        guard let peer = discoveredPeerIDs[displayName] else {
            DispatchQueue.main.async {
                self.delegate?.peerTransport(self, didReport: "找不到对端 \(displayName)。")
            }
            return
        }
        browser?.invitePeer(peer, to: session, withContext: nil, timeout: 12)
    }

    func sendPayload<T: Codable>(_ payload: T, kind: TransportMessageKind, to displayName: String? = nil) throws {
        let data = try SyncMessageCodec.encode(payload, kind: kind)
        let peers: [MCPeerID]
        if let displayName {
            guard let peer = session.connectedPeers.first(where: { $0.displayName == displayName }) else {
                throw NSError(domain: AppConstants.appName, code: 1, userInfo: [NSLocalizedDescriptionKey: "连接已断开。"])
            }
            peers = [peer]
        } else {
            peers = session.connectedPeers
        }
        guard !peers.isEmpty else {
            throw NSError(domain: AppConstants.appName, code: 2, userInfo: [NSLocalizedDescriptionKey: "当前没有已连接的电脑。"])
        }
        try session.send(data, toPeers: peers, with: .reliable)
    }

    private func publishDiscoveredPeers() {
        let peers = discoveredPeerIDs.keys
            .sorted()
            .map { DiscoveredPeer(id: $0, displayName: $0) }
        DispatchQueue.main.async {
            self.delegate?.peerTransport(self, didUpdate: peers)
        }
    }
}

extension PeerTransport: MCNearbyServiceAdvertiserDelegate {
    func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didReceiveInvitationFromPeer peerID: MCPeerID,
        withContext context: Data?,
        invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
        if session.connectedPeers.isEmpty || session.connectedPeers.contains(peerID) {
            invitationHandler(true, session)
        } else {
            invitationHandler(false, nil)
        }
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        DispatchQueue.main.async {
            self.delegate?.peerTransport(self, didReport: "启动广播失败：\(error.localizedDescription)")
        }
    }
}

extension PeerTransport: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String : String]?) {
        discoveredPeerIDs[peerID.displayName] = peerID
        publishDiscoveredPeers()
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        discoveredPeerIDs.removeValue(forKey: peerID.displayName)
        publishDiscoveredPeers()
    }

    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        DispatchQueue.main.async {
            self.delegate?.peerTransport(self, didReport: "启动发现失败：\(error.localizedDescription)")
        }
    }
}

extension PeerTransport: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        let mappedState: PeerConnectionState
        switch state {
        case .notConnected:
            mappedState = .notConnected
        case .connecting:
            mappedState = .connecting
        case .connected:
            mappedState = .connected
        @unknown default:
            mappedState = .notConnected
        }
        DispatchQueue.main.async {
            self.delegate?.peerTransport(self, didChange: mappedState, for: peerID.displayName)
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        DispatchQueue.main.async {
            self.delegate?.peerTransport(self, didReceive: data, from: peerID.displayName)
        }
    }

    func session(
        _ session: MCSession,
        didReceive stream: InputStream,
        withName streamName: String,
        fromPeer peerID: MCPeerID
    ) {}

    func session(
        _ session: MCSession,
        didStartReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        with progress: Progress
    ) {}

    func session(
        _ session: MCSession,
        didFinishReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        at localURL: URL?,
        withError error: Error?
    ) {}

    func session(
        _ session: MCSession,
        didReceiveCertificate certificate: [Any]?,
        fromPeer peerID: MCPeerID,
        certificateHandler: @escaping (Bool) -> Void
    ) {
        certificateHandler(true)
    }
}
