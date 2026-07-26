import Foundation
import Network
import OSLog

private let companionBridgeLogger = Logger(subsystem: "be.zenjoy.zentty", category: "CompanionBridge")

/// Owns the companion bridge lifecycle: the WebSocket `NWListener`, Bonjour
/// advertising, and one `CompanionSession` per connection. It advertises and
/// listens **only** while at least one device is paired and the feature toggle
/// is on, so a Mac that has never paired opens no ports.
///
/// Also the production `CompanionSessionServicing`: it hands sessions the
/// pairing store, dashboard feed, and input router. Settings UI reaches it via
/// `CompanionBridgeServer.shared`, mirroring `AgentIPCServer.shared`.
@MainActor
final class CompanionBridgeServer: CompanionSessionServicing {
    /// Set by `AppDelegate` at launch; read by the settings UI.
    private(set) static var shared: CompanionBridgeServer?

    static let bonjourServiceType = "_zentty._tcp"

    /// Upper bound on concurrent live LAN sessions. Mirrors the relay path's
    /// `CompanionRelayTransport.maxPeerSessions` so a flood of TCP connects cannot
    /// make the Mac spawn unbounded sessions before each one's handshake deadline
    /// drops it. New connections past the cap are refused at accept time.
    static let maxLanSessions = CompanionRelayTransport.maxPeerSessions

    let identity: CompanionDeviceIdentity
    private let pairingStore: CompanionPairingStore
    private let dashboardFeed: CompanionDashboardFeed
    private let paneTextFeed: CompanionPaneTextFeed
    private let paneBytesFeed: CompanionPaneBytesFeed
    private let transcriptFeed: CompanionTranscriptFeed
    private let inputRouter: CompanionInputRouter
    private let leaseManager: CompanionLeaseManager
    private let isFeatureEnabled: () -> Bool
    private let relayUrlProvider: () -> String
    /// The pinned LAN port from config (`companion.listen_port`), or `nil` when
    /// none is stored yet. Paired phones reconnect via the host + port captured
    /// at pairing time — there is no runtime Bonjour re-resolution — so the
    /// listener must come back on the same port across relaunches.
    private let preferredListenPort: () -> UInt16?
    /// Persists the port the first ephemeral bind landed on, pinning it for
    /// every subsequent launch.
    private let persistListenPort: (UInt16) -> Void
    /// Gates real `NWListener` binding. Always on in the app; tests pass `false`
    /// so the run-state edge logic is exercisable without opening a socket (the
    /// firewall would otherwise prompt on a hosted test binary).
    private let lanListenerEnabled: () -> Bool
    private let pushCoordinator: CompanionPushCoordinator

    private let listenerQueue = DispatchQueue(label: "be.zenjoy.zentty.companion-bridge")
    private var listener: NWListener?
    private var activeSessions: [CompanionSession] = []
    private var advertisedPort: UInt16?
    /// True while the live listener was bound to the pinned port, so a bind
    /// failure (port momentarily held by another process, e.g. a second Zentty
    /// instance) can fall back to an ephemeral port exactly once. Sticky for the
    /// rest of the process so the fallback cannot loop; the pin itself is left
    /// untouched and is retried on the next launch.
    private var pinnedPortBindFailed = false
    /// Whether the in-flight bind should persist the port it lands on — set only
    /// when no pin exists yet, so an ephemeral fallback never overwrites the pin.
    private var persistPortOnReady = false
    /// Whether the live listener ever reached `.ready`. Distinguishes a bind-time
    /// conflict (fall back to ephemeral) from a later runtime failure (keep the
    /// pin; the old stop-and-wait behavior applies).
    private var listenerBecameReady = false

    private var relayTransport: CompanionRelayTransport?
    /// The relay URL the live transport was built for, so a settings change swaps
    /// transports instead of leaking the old one.
    private var relayTransportURL: String?

    /// Tracks the last `shouldRun` decision so the running → disabled transition is
    /// edge-triggered: sessions and leases are torn down once, on the flip, not on
    /// every config change that re-evaluates an already-disabled feature.
    private var isRunning = false

    /// Fired on the main actor whenever the paired-device set changes (pair /
    /// revoke), so the settings UI can refresh its list.
    var onPairedDevicesChanged: (([CompanionPairedDevice]) -> Void)?

    /// Fired on the main actor whenever `advertisedPort` transitions — set when the
    /// listener reports `.ready`, cleared when it stops or fails. The listener
    /// reports its port asynchronously, so an offer minted before `.ready` carries
    /// no LAN hint; this lets an open pairing sheet re-mint and the settings status
    /// row refresh the moment the endpoint appears (or disappears).
    var onAdvertisingStateChanged: (() -> Void)?

    init(
        identity: CompanionDeviceIdentity,
        pairingStore: CompanionPairingStore,
        dashboardFeed: CompanionDashboardFeed,
        paneTextFeed: CompanionPaneTextFeed,
        paneBytesFeed: CompanionPaneBytesFeed = CompanionPaneBytesFeed(),
        transcriptFeed: CompanionTranscriptFeed,
        inputRouter: CompanionInputRouter,
        leaseManager: CompanionLeaseManager,
        isFeatureEnabled: @escaping () -> Bool,
        relayUrlProvider: @escaping () -> String = { "" },
        pushGatewayUrlProvider: @escaping () -> String = { "" },
        pushTransport: CompanionPushHTTPTransport = CompanionPushURLSessionTransport(),
        lanListenerEnabled: @escaping () -> Bool = { true },
        preferredListenPort: @escaping () -> UInt16? = { nil },
        persistListenPort: @escaping (UInt16) -> Void = { _ in }
    ) {
        self.identity = identity
        self.pairingStore = pairingStore
        self.dashboardFeed = dashboardFeed
        self.paneTextFeed = paneTextFeed
        self.paneBytesFeed = paneBytesFeed
        self.transcriptFeed = transcriptFeed
        self.inputRouter = inputRouter
        self.leaseManager = leaseManager
        self.isFeatureEnabled = isFeatureEnabled
        self.relayUrlProvider = relayUrlProvider
        self.lanListenerEnabled = lanListenerEnabled
        self.preferredListenPort = preferredListenPort
        self.persistListenPort = persistListenPort
        self.pushCoordinator = CompanionPushCoordinator(
            identity: identity,
            pairingStore: pairingStore,
            isFeatureEnabled: isFeatureEnabled,
            gatewayURLProvider: pushGatewayUrlProvider,
            transport: pushTransport
        )
    }

    /// Installs the process-wide accessor. Call once from `AppDelegate`.
    func installAsShared() {
        CompanionBridgeServer.shared = self
    }

    // MARK: - Lifecycle gating

    /// Starts or stops the listener + advertising based on the current pairing
    /// set and feature toggle. Idempotent; safe to call on any relevant change.
    func refreshAdvertisingState() {
        let shouldRun = isFeatureEnabled() && !pairingStore.devices().isEmpty
        if shouldRun {
            startListenerIfNeeded()
        } else {
            stopListener()
            // Edge-triggered: on the running → disabled flip (toggle off, or the
            // last device unpaired), stopping the listener is not enough — an
            // already-connected phone stays fully live (input, streaming, takeover
            // placeholder) until it disconnects. Force-close every live LAN session
            // and revoke all control leases so any takeover placeholder is restored
            // on the desktop. Relay peer sessions are torn down by stopRelay (below,
            // via refreshRelayState), so this only sweeps `activeSessions`.
            if isRunning {
                for session in activeSessions {
                    session.requestClose()
                }
                leaseManager.revokeAll()
            }
        }
        isRunning = shouldRun
        refreshRelayState(shouldRun: shouldRun)
    }

    func stop() {
        stopListener()
        stopRelay()
        // Nothing about leases is persisted; ending them here restores every pane
        // so a quit/relaunch starts with no stuck placeholders.
        leaseManager.revokeAll()
    }

    // MARK: - Relay transport gating

    /// Starts, stops, or swaps the outbound relay transport under the same
    /// paired-device + feature gating as the listener, plus a configured relay
    /// URL. Idempotent; a URL change tears down the old transport and dials anew.
    private func refreshRelayState(shouldRun: Bool) {
        let urlString = relayUrlProvider()
        guard
            shouldRun,
            !urlString.isEmpty,
            let url = URL(string: urlString),
            url.scheme == "ws" || url.scheme == "wss"
        else {
            if !urlString.isEmpty, relayTransport == nil {
                companionBridgeLogger.error(
                    "Ignoring companion relay URL (must be ws:// or wss://): \(urlString, privacy: .public)"
                )
            }
            stopRelay()
            return
        }

        if relayTransportURL == urlString, relayTransport != nil { return }

        stopRelay()
        let transport = CompanionRelayTransport(url: url, services: self)
        transport.onPeerStatus = { deviceId, online in
            companionBridgeLogger.info(
                "Relay peer \(deviceId, privacy: .public) online=\(online, privacy: .public)"
            )
        }
        transport.start()
        relayTransport = transport
        relayTransportURL = urlString
        companionBridgeLogger.info("Companion relay transport starting")
    }

    private func stopRelay() {
        guard let relayTransport else { return }
        relayTransport.stop()
        self.relayTransport = nil
        relayTransportURL = nil
        companionBridgeLogger.info("Companion relay transport stopped")
    }

    private func startListenerIfNeeded() {
        guard lanListenerEnabled() else { return }
        guard listener == nil else { return }
        do {
            let parameters = NWParameters.tcp
            // Rebinding the pinned port right after a relaunch must not fail on
            // the previous process's TIME_WAIT sockets.
            parameters.allowLocalEndpointReuse = true
            let webSocketOptions = NWProtocolWebSocket.Options()
            webSocketOptions.autoReplyPing = true
            parameters.defaultProtocolStack.applicationProtocols.insert(webSocketOptions, at: 0)

            let pinnedPort = pinnedPortBindFailed ? nil : preferredListenPort()
            persistPortOnReady = preferredListenPort() == nil
            listenerBecameReady = false
            let listener: NWListener
            if let pinnedPort, let port = NWEndpoint.Port(rawValue: pinnedPort) {
                listener = try NWListener(using: parameters, on: port)
            } else {
                listener = try NWListener(using: parameters)
            }
            let txtRecord = NWTXTRecord(["deviceId": identity.deviceId])
            listener.service = NWListener.Service(
                type: CompanionBridgeServer.bonjourServiceType,
                txtRecord: txtRecord.data
            )
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in self?.handleListenerState(state) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.start(queue: listenerQueue)
            self.listener = listener
            companionBridgeLogger.info("Companion bridge listener starting")
        } catch {
            companionBridgeLogger.error(
                "Failed to start companion listener: \(String(describing: error), privacy: .public)"
            )
        }
    }

    private func stopListener() {
        guard let listener else { return }
        listener.cancel()
        self.listener = nil
        setAdvertisedPort(nil)
        companionBridgeLogger.info("Companion bridge listener stopped")
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            listenerBecameReady = true
            let port = listener?.port?.rawValue
            setAdvertisedPort(port)
            // First-ever bind (no pin stored): pin the ephemeral port the OS
            // picked so it survives relaunches — the paired phone reconnects to
            // exactly this host + port and has no way to discover a new one.
            if persistPortOnReady, let port {
                persistPortOnReady = false
                persistListenPort(port)
                companionBridgeLogger.info(
                    "Pinned companion listen port \(port, privacy: .public)"
                )
            }
        case .failed(let error):
            companionBridgeLogger.error(
                "Companion listener failed: \(String(describing: error), privacy: .public)"
            )
            let wasPinnedBind = !listenerBecameReady
                && !pinnedPortBindFailed
                && preferredListenPort() != nil
            stopListener()
            // The pinned port can be transiently unavailable (typically another
            // Zentty instance from a parallel worktree holding it). Fall back to
            // an ephemeral port once — without overwriting the pin, so the next
            // launch tries the phone-known port again.
            if wasPinnedBind {
                pinnedPortBindFailed = true
                companionBridgeLogger.error(
                    "Pinned companion port unavailable; falling back to an ephemeral port"
                )
                startListenerIfNeeded()
            }
        default:
            break
        }
    }

    /// Updates `advertisedPort` and, on a real change, fires
    /// `onAdvertisingStateChanged` so the settings UI can react to the listener
    /// coming up (or going away). Edge-triggered to avoid redundant re-renders.
    private func setAdvertisedPort(_ newValue: UInt16?) {
        guard advertisedPort != newValue else { return }
        advertisedPort = newValue
        onAdvertisingStateChanged?()
    }

    private func accept(_ connection: NWConnection) {
        // Bound concurrent LAN sessions (DoS guard): refuse the connect outright
        // rather than spawning a session that would sit blocked in receive() until
        // its handshake deadline. Mirrors the relay peer cap.
        guard activeSessions.count < Self.maxLanSessions else {
            companionBridgeLogger.error(
                "Refusing companion LAN connection: at session cap (\(Self.maxLanSessions, privacy: .public))"
            )
            connection.cancel()
            return
        }
        let transport = CompanionNetworkConnection(connection: connection, queue: listenerQueue)
        trackSession(CompanionSession(connection: transport, services: self))
    }

    /// Runs a live LAN session to completion, dropping it from `activeSessions`
    /// when its connection ends. Split from `accept` so the socket-accept path and
    /// tests share one lifecycle; returns the run task for callers that await it.
    @discardableResult
    func trackSession(_ session: CompanionSession) -> Task<Void, Never> {
        activeSessions.append(session)
        return Task { @MainActor [weak self] in
            await session.run()
            self?.activeSessions.removeAll { $0 === session }
        }
    }

    // MARK: - Status change signal

    /// Forwarded from the app's agent-status fan-out. Nudges the debounced
    /// dashboard recompute; the feed only does work when a session is subscribed.
    func ingestAgentStatusChange() {
        dashboardFeed.scheduleRecompute()
    }

    // MARK: - Pane text lane signals

    /// Forwarded from the terminal render path (`RootViewController`) whenever a
    /// watched surface reported new content. Debounced + deduped inside the feed;
    /// a no-op when no session is watching the pane.
    func ingestPaneContentChange(paneID: String) {
        paneTextFeed.handleContentChanged(paneId: paneID)
    }

    /// Forwarded on pane close (shell exit) so the feed drops any watch before the
    /// runtime is torn down, and any lease on the pane is revoked (`pane_closed`).
    func ingestPaneClosed(paneID: String) {
        paneTextFeed.handlePaneClosed(paneId: paneID)
        paneBytesFeed.handlePaneClosed(paneId: paneID)
        transcriptFeed.handlePaneClosed(paneId: paneID)
        leaseManager.handlePaneClosed(paneId: paneID)
        // Plain (agent-less) panes emit no agent-status change on close, so the
        // dashboard would otherwise keep listing them until the next recompute.
        dashboardFeed.scheduleRecompute()
    }

    // MARK: - Pane bytes lane signals

    /// Forward raw PTY output into the byte ring + live fan-out. The feed installs
    /// the libghostty tee itself on the first attach, so in production this is
    /// reached from that tee's drain; unit tests inject synthetic bytes.
    /// `seq` is the producer's absolute offset within `epoch` (see
    /// `CompanionPaneBytesFeed.ingest`).
    func ingestPaneBytes(paneID: String, epoch: String, seq: Int, bytes: Data) {
        paneBytesFeed.ingest(paneId: paneID, epoch: epoch, seq: seq, bytes: bytes)
    }

    // MARK: - Pairing offer (settings UI)

    /// Mints a one-time pairing offer for a QR code. The listener is started so a
    /// LAN hint (host + live port) can be included even before the first device
    /// is paired.
    /// - Parameter relayURL: overrides the configured relay URL for the offer;
    ///   defaults to `companion.relayUrl`, so a configured relay is advertised to
    ///   the phone automatically and LAN-only Macs mint an empty `relayUrl`.
    func makePairingOffer(
        relayURL: String? = nil,
        ttl: TimeInterval = CompanionPairingStore.defaultOfferTTL
    ) -> CompanionPairingOffer {
        startListenerIfNeeded()
        let relayURL = relayURL ?? relayUrlProvider()
        let minted = pairingStore.mintOffer(ttl: ttl)
        let lanHint = currentLanHint
        return CompanionPairingOffer(
            relayUrl: relayURL,
            lanHint: lanHint,
            macDeviceId: identity.deviceId,
            macPubKey: identity.deviceId,
            secret: minted.secretBase64URL,
            expiresAt: Int(minted.expiresAt.timeIntervalSince1970 * 1000)
        )
    }

    /// Cancels any outstanding offers (pairing sheet dismissed) and re-evaluates
    /// whether the listener should stay up.
    func cancelPairingOffers() {
        pairingStore.clearOffers()
        refreshAdvertisingState()
    }

    // MARK: - Device list (settings UI)

    func pairedDevices() -> [CompanionPairedDevice] {
        pairingStore.devices()
    }

    /// Revokes a device (delete-key revocation), drops any live session it holds,
    /// and stops advertising if that was the last one.
    func revokeDevice(deviceId: String) {
        do {
            try pairingStore.remove(deviceId: deviceId)
        } catch {
            companionBridgeLogger.error(
                "Failed to revoke device: \(String(describing: error), privacy: .public)"
            )
        }
        for session in activeSessions where session.pairedDeviceId == deviceId {
            session.requestClose()
        }
        relayTransport?.closePeerSession(deviceId: deviceId)
        onPairedDevicesChanged?(pairingStore.devices())
        refreshAdvertisingState()
    }

    // MARK: - Status (settings UI)

    /// A snapshot of the listener/advertising state for the Settings status row.
    struct Status: Equatable, Sendable {
        var isAdvertising: Bool
        var port: Int?
        var bonjourName: String
        var bonjourServiceType: String
        var pairedDeviceCount: Int
    }

    func currentStatus() -> Status {
        Status(
            isAdvertising: listener != nil,
            port: advertisedPort.map(Int.init),
            bonjourName: localDeviceName,
            bonjourServiceType: CompanionBridgeServer.bonjourServiceType,
            pairedDeviceCount: pairingStore.devices().count
        )
    }

    // MARK: - CompanionSessionServicing

    var localDeviceName: String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// The endpoint a phone should dial for a direct connection, or `nil` while no
    /// listener is bound.
    ///
    /// `hostName` is the Bonjour `.local` name rather than an address, so it
    /// re-resolves on every connect and already survives a DHCP change. What it
    /// does not survive is a rename or a different port — which is why this is
    /// restated in every `session.ready`.
    var currentLanHint: CompanionLanHint? {
        advertisedPort.map {
            CompanionLanHint(host: ProcessInfo.processInfo.hostName, port: Int($0))
        }
    }

    func pairedDevice(withId deviceId: String) -> CompanionPairedDevice? {
        pairingStore.device(withId: deviceId)
    }

    func verifyPairingProof(phonePublicKey: String, proof: String) -> Bool {
        pairingStore.verifyPairingProof(phonePublicKey: phonePublicKey, proof: proof)
    }

    func recordPairing(_ device: CompanionPairedDevice) {
        do {
            try pairingStore.add(device)
        } catch {
            companionBridgeLogger.error(
                "Failed to persist paired device: \(String(describing: error), privacy: .public)"
            )
        }
        onPairedDevicesChanged?(pairingStore.devices())
        refreshAdvertisingState()
    }

    func markDeviceSeen(deviceId: String) {
        try? pairingStore.updateLastSeen(deviceId: deviceId, at: Date())
    }

    func dashboardSnapshot() -> CompanionDashboardSnapshot {
        dashboardFeed.makeSnapshot()
    }

    func addDashboardSubscriber(
        _ handler: @escaping (CompanionDashboardDelta) -> Void
    ) -> CompanionDashboardSubscriptionToken {
        dashboardFeed.addSubscriber(handler)
    }

    func removeDashboardSubscriber(_ token: CompanionDashboardSubscriptionToken) {
        dashboardFeed.removeSubscriber(token)
    }

    func routeInput(_ message: CompanionMessage, fromDeviceId deviceId: String?) -> CompanionInputAck {
        inputRouter.handle(message, fromDeviceId: deviceId) ?? CompanionInputAck(ok: false, error: "unsupported")
    }

    func addPaneTextWatcher(_ send: @escaping (CompanionPaneText) -> Void) -> CompanionPaneWatchToken {
        paneTextFeed.addWatcher(send)
    }

    func removePaneTextWatcher(_ token: CompanionPaneWatchToken) {
        paneTextFeed.removeWatcher(token)
    }

    func watchPane(token: CompanionPaneWatchToken, paneId: String) {
        paneTextFeed.watch(token: token, paneId: paneId)
    }

    func unwatchPane(token: CompanionPaneWatchToken, paneId: String) {
        paneTextFeed.unwatch(token: token, paneId: paneId)
    }

    func paneScrollback(paneId: String, lineLimit: Int?) -> CompanionPaneScrollback {
        paneTextFeed.scrollback(paneId: paneId, lineLimit: lineLimit)
    }

    // MARK: Pane bytes lane

    func addPaneBytesWatcher(
        _ send: @escaping (CompanionPaneBytesChunk) -> Void
    ) -> CompanionPaneBytesToken {
        paneBytesFeed.addWatcher(sendChunk: send)
    }

    func removePaneBytesWatcher(_ token: CompanionPaneBytesToken) {
        paneBytesFeed.removeWatcher(token)
    }

    func attachPaneBytes(
        token: CompanionPaneBytesToken,
        paneId: String,
        lastSeq: Int?,
        epoch: String?
    ) -> CompanionPaneBytesAttached {
        paneBytesFeed.attach(token: token, paneId: paneId, lastSeq: lastSeq, epoch: epoch)
    }

    func detachPaneBytes(token: CompanionPaneBytesToken, paneId: String) {
        paneBytesFeed.detach(token: token, paneId: paneId)
    }

    // MARK: Transcript lane

    func addTranscriptSubscriber(
        _ send: @escaping (CompanionTranscriptEvent) -> Void
    ) -> CompanionTranscriptSubscriberToken {
        transcriptFeed.addSubscriber(send)
    }

    func removeTranscriptSubscriber(_ token: CompanionTranscriptSubscriberToken) {
        transcriptFeed.removeSubscriber(token)
    }

    func subscribeTranscript(
        token: CompanionTranscriptSubscriberToken,
        paneId: String
    ) -> CompanionTranscriptSubscribeReply {
        transcriptFeed.subscribe(token: token, paneId: paneId)
    }

    // MARK: Control lease

    func addLeaseClient(_ send: @escaping (CompanionLeaseRevoked) -> Void) -> CompanionLeaseClientToken {
        leaseManager.addClient(send)
    }

    func removeLeaseClient(_ token: CompanionLeaseClientToken) {
        leaseManager.removeClient(token)
    }

    func leaseRequest(
        token: CompanionLeaseClientToken,
        paneId: String,
        cols: Int,
        rows: Int,
        deviceName: String
    ) -> CompanionLeaseGrant {
        let grant = leaseManager.request(token: token, paneId: paneId, cols: cols, rows: rows, deviceName: deviceName)
        // Belt-and-braces: the takeover reflows the surface to the phone's grid
        // (e.g. 51×28). The un-occluded surface repaints and pushes a fresh frame on
        // its own, but nudge the feed too so the phone reliably gets a `pane.text`
        // stamped with the new grid even if the reflow's render pulse is missed.
        // A no-op when the pane isn't watched; the feed's readout-level dedupe keeps
        // it from double-sending when the natural pulse already landed.
        paneTextFeed.handleContentChanged(paneId: paneId)
        return grant
    }

    func leaseHeartbeat(token: CompanionLeaseClientToken, leaseId: String) {
        leaseManager.heartbeat(token: token, leaseId: leaseId)
    }

    func leaseResize(token: CompanionLeaseClientToken, leaseId: String, cols: Int, rows: Int) {
        leaseManager.resize(token: token, leaseId: leaseId, cols: cols, rows: rows)
    }

    func leaseRelease(token: CompanionLeaseClientToken, leaseId: String) {
        leaseManager.release(token: token, leaseId: leaseId)
    }

    // MARK: Push

    func registerPush(phoneDeviceId: String, platform: CompanionPushPlatform, token: String) {
        pushCoordinator.registerPush(phoneDeviceId: phoneDeviceId, platform: platform, token: token)
        onPairedDevicesChanged?(pairingStore.devices())
    }

    func sendTestPush(phoneDeviceId: String) {
        pushCoordinator.sendTestPush(phoneDeviceId: phoneDeviceId)
    }

    /// Fans a local attention notification out to every paired phone with a
    /// registered push token. Called from `WorklaneAttentionNotificationCoordinator`
    /// on the same debounced transition as the local `UNUserNotification`, so the
    /// two never double-fire.
    func fanOutAttentionPush(_ push: CompanionAttentionPush) {
        pushCoordinator.fanOutAttention(push)
    }
}
