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

    let identity: CompanionDeviceIdentity
    private let pairingStore: CompanionPairingStore
    private let dashboardFeed: CompanionDashboardFeed
    private let inputRouter: CompanionInputRouter
    private let isFeatureEnabled: () -> Bool

    private let listenerQueue = DispatchQueue(label: "be.zenjoy.zentty.companion-bridge")
    private var listener: NWListener?
    private var activeSessions: [CompanionSession] = []
    private var advertisedPort: UInt16?

    /// Fired on the main actor whenever the paired-device set changes (pair /
    /// revoke), so the settings UI can refresh its list.
    var onPairedDevicesChanged: (([CompanionPairedDevice]) -> Void)?

    init(
        identity: CompanionDeviceIdentity,
        pairingStore: CompanionPairingStore,
        dashboardFeed: CompanionDashboardFeed,
        inputRouter: CompanionInputRouter,
        isFeatureEnabled: @escaping () -> Bool
    ) {
        self.identity = identity
        self.pairingStore = pairingStore
        self.dashboardFeed = dashboardFeed
        self.inputRouter = inputRouter
        self.isFeatureEnabled = isFeatureEnabled
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
        }
    }

    func stop() {
        stopListener()
    }

    private func startListenerIfNeeded() {
        guard listener == nil else { return }
        do {
            let parameters = NWParameters.tcp
            let webSocketOptions = NWProtocolWebSocket.Options()
            webSocketOptions.autoReplyPing = true
            parameters.defaultProtocolStack.applicationProtocols.insert(webSocketOptions, at: 0)

            let listener = try NWListener(using: parameters)
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
        advertisedPort = nil
        companionBridgeLogger.info("Companion bridge listener stopped")
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            advertisedPort = listener?.port?.rawValue
        case .failed(let error):
            companionBridgeLogger.error(
                "Companion listener failed: \(String(describing: error), privacy: .public)"
            )
            stopListener()
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        let transport = CompanionNetworkConnection(connection: connection, queue: listenerQueue)
        let session = CompanionSession(connection: transport, services: self)
        activeSessions.append(session)
        Task { @MainActor [weak self] in
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

    // MARK: - Pairing offer (settings UI)

    /// Mints a one-time pairing offer for a QR code. The listener is started so a
    /// LAN hint (host + live port) can be included even before the first device
    /// is paired.
    func makePairingOffer(relayURL: String, ttl: TimeInterval = CompanionPairingStore.defaultOfferTTL) -> CompanionPairingOffer {
        startListenerIfNeeded()
        let minted = pairingStore.mintOffer(ttl: ttl)
        let lanHint = advertisedPort.map {
            CompanionLanHint(host: ProcessInfo.processInfo.hostName, port: Int($0))
        }
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

    func routeInput(_ message: CompanionMessage) -> CompanionInputAck {
        inputRouter.handle(message) ?? CompanionInputAck(ok: false, error: "unsupported")
    }
}
