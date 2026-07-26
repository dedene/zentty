import Foundation
import OSLog

private let companionPushCoordinatorLogger = Logger(subsystem: "be.zenjoy.zentty", category: "CompanionPush")

// MARK: - Attention push

/// The content of an attention push: what the phone shows, plus where to deep-link.
/// Built beside the local `UNUserNotification` so the two paths stay in lock-step.
struct CompanionAttentionPush: Equatable, Sendable {
    var title: String
    var body: String
    var paneId: String
    var worklaneId: String
}

// MARK: - Coordinator

/// The Mac side of the push pipeline: routes `push.register` (store on the pairing
/// + forward a signed `/register` to the gateway) and fans an attention event out
/// to every paired phone that has a registered token (a signed, sealed `/wake`).
///
/// Everything is gated so it degrades cleanly with no configuration: with the
/// feature disabled, no gateway URL, or no registered token, `fanOutAttention` is a
/// no-op and foreground dashboard updates keep working. Delivery over the network
/// is fire-and-forget — an attention event must never block the local notification.
@MainActor
final class CompanionPushCoordinator {
    private let identity: CompanionDeviceIdentity
    private let pairingStore: CompanionPairingStore
    private let isFeatureEnabled: () -> Bool
    private let gatewayURLProvider: () -> String
    private let transport: CompanionPushHTTPTransport

    init(
        identity: CompanionDeviceIdentity,
        pairingStore: CompanionPairingStore,
        isFeatureEnabled: @escaping () -> Bool,
        gatewayURLProvider: @escaping () -> String,
        transport: CompanionPushHTTPTransport = CompanionPushURLSessionTransport()
    ) {
        self.identity = identity
        self.pairingStore = pairingStore
        self.isFeatureEnabled = isFeatureEnabled
        self.gatewayURLProvider = gatewayURLProvider
        self.transport = transport
    }

    /// The gateway client for the configured URL, or `nil` when push is disabled
    /// (feature off or no/invalid gateway URL).
    private func makeClient() -> CompanionPushGatewayClient? {
        guard isFeatureEnabled() else { return nil }
        let urlString = gatewayURLProvider()
        guard
            !urlString.isEmpty,
            let url = URL(string: urlString),
            url.scheme == "http" || url.scheme == "https"
        else {
            return nil
        }
        return CompanionPushGatewayClient(baseURL: url, identity: identity, transport: transport)
    }

    // MARK: push.register

    /// Handles a `push.register` from a paired phone: persists the token on the
    /// pairing (so wakes survive across sessions and app restarts) and, when a
    /// gateway is configured, forwards a signed `/register`.
    func registerPush(phoneDeviceId: String, platform: CompanionPushPlatform, token: String) {
        do {
            try pairingStore.setPushRegistration(deviceId: phoneDeviceId, platform: platform, token: token)
        } catch {
            companionPushCoordinatorLogger.error(
                "Failed to persist push registration: \(String(describing: error), privacy: .public)"
            )
        }

        guard let client = makeClient() else { return }
        Task {
            do {
                let status = try await client.register(
                    phoneDeviceId: phoneDeviceId,
                    platform: platform,
                    token: token
                )
                companionPushCoordinatorLogger.info("Push register status \(status, privacy: .public)")
            } catch {
                companionPushCoordinatorLogger.error(
                    "Push register failed: \(String(describing: error), privacy: .public)"
                )
            }
        }
    }

    /// Sends a single test wake (from `push.test`) to one device, if it has a
    /// registered token and push is configured. A no-op otherwise.
    func sendTestPush(phoneDeviceId: String) {
        fanOutAttention(
            CompanionAttentionPush(
                title: "Zentty",
                body: "Test notification — your phone can receive alerts.",
                paneId: "",
                worklaneId: ""
            ),
            onlyDeviceId: phoneDeviceId
        )
    }

    // MARK: Fan-out

    /// Fans an attention event out to every paired phone with a registered token:
    /// seals `{title, body, paneId, worklaneId}` to each phone's identity and posts
    /// a signed `/wake`. A no-op when disabled, unconfigured, or no phone has a
    /// token — the caller's local notification is unaffected either way.
    func fanOutAttention(_ push: CompanionAttentionPush, onlyDeviceId: String? = nil) {
        guard let client = makeClient() else { return }

        let content = CompanionPushSeal.Content(
            title: push.title,
            body: push.body,
            paneId: push.paneId,
            worklaneId: push.worklaneId
        )

        for device in pairingStore.devices() {
            if let onlyDeviceId, device.deviceId != onlyDeviceId { continue }
            guard let platform = device.pushPlatform, let token = device.pushToken else { continue }
            guard let publicKey = CompanionBase64URL.decode(device.publicKey) else {
                companionPushCoordinatorLogger.error("Skipping wake: undecodable device key")
                continue
            }

            let sealedPayload: String
            do {
                sealedPayload = try CompanionPushSeal.sealedPayload(
                    content: content,
                    macIdentity: identity.signingPrivateKey,
                    phoneIdentityPublicKey: publicKey
                )
            } catch {
                companionPushCoordinatorLogger.error(
                    "Failed to seal push payload: \(String(describing: error), privacy: .public)"
                )
                continue
            }

            let phoneDeviceId = device.deviceId
            Task {
                do {
                    let status = try await client.wake(
                        phoneDeviceId: phoneDeviceId,
                        platform: platform,
                        token: token,
                        sealedPayload: sealedPayload
                    )
                    companionPushCoordinatorLogger.info("Push wake status \(status, privacy: .public)")
                } catch {
                    companionPushCoordinatorLogger.error(
                        "Push wake failed: \(String(describing: error), privacy: .public)"
                    )
                }
            }
        }
    }
}
