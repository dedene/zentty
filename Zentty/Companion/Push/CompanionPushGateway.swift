import CryptoKit
import Foundation
import OSLog

private let companionPushLogger = Logger(subsystem: "be.zenjoy.zentty", category: "CompanionPush")

// MARK: - Push gateway REST client
//
// The Mac's outbound leg to the push gateway (`companion/relay/src/push`). Two
// Mac-authenticated endpoints, each Ed25519-signed by this Mac's identity key over
// a canonical string shared with `@zentty/wire` (`pushWakeSigningString` /
// `pushRegisterSigningString`) so the signer and the gateway verifier cannot drift:
//
//   POST /register  {macDeviceId, phoneDeviceId, platform, token, sig}
//   POST /wake      {deviceId, token, platform, sealedPayload, sig}
//
// The HTTP layer is a seam (`CompanionPushHTTPTransport`) so tests assert the exact
// request body + signature without ever reaching the network. With no gateway URL
// configured the whole path is disabled and foreground dashboard updates keep
// working — real APNs/FCM delivery is verified separately once keys are provisioned.

/// Domain-separated signing prefixes, mirroring `PUSH_*_SIGN_PREFIX` in the wire.
enum CompanionPushSigning {
    static let wakePrefix = "zentty-push-wake:v1"
    static let registerPrefix = "zentty-push-register:v1"

    /// Canonical bytes-to-sign for `POST /wake`: the prefix line, then the fields
    /// in alphabetical order as `key=value` lines joined by `\n`, no trailing
    /// newline. Reproduces `pushWakeSigningString` byte-for-byte.
    static func wakeSigningString(
        deviceId: String,
        platform: String,
        sealedPayload: String,
        token: String
    ) -> String {
        [
            wakePrefix,
            "deviceId=\(deviceId)",
            "platform=\(platform)",
            "sealedPayload=\(sealedPayload)",
            "token=\(token)",
        ].joined(separator: "\n")
    }

    /// Canonical bytes-to-sign for `POST /register`; mirrors `pushRegisterSigningString`.
    static func registerSigningString(
        macDeviceId: String,
        phoneDeviceId: String,
        platform: String,
        token: String
    ) -> String {
        [
            registerPrefix,
            "macDeviceId=\(macDeviceId)",
            "phoneDeviceId=\(phoneDeviceId)",
            "platform=\(platform)",
            "token=\(token)",
        ].joined(separator: "\n")
    }
}

// MARK: - Transport seam

/// One request/response against the gateway. Injected so tests assert the request
/// shape offline; the production value dials the configured URL over `URLSession`.
protocol CompanionPushHTTPTransport: Sendable {
    func post(url: URL, body: Data) async throws -> Int
}

/// Default transport: a plain JSON POST over `URLSession`, returning the status code.
struct CompanionPushURLSessionTransport: CompanionPushHTTPTransport {
    let session: URLSession

    init(session: URLSession = URLSession(configuration: .default)) {
        self.session = session
    }

    func post(url: URL, body: Data) async throws -> Int {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (_, response) = try await session.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }
}

// MARK: - Request bodies (mirror the wire zod schemas)

private struct CompanionPushRegisterRequestBody: Codable {
    var macDeviceId: String
    var phoneDeviceId: String
    var platform: String
    var token: String
    var sig: String
}

private struct CompanionPushWakeRequestBody: Codable {
    var deviceId: String
    var token: String
    var platform: String
    var sealedPayload: String
    var sig: String
}

// MARK: - Client

/// Signs and posts `/register` and `/wake` for one gateway base URL.
struct CompanionPushGatewayClient: Sendable {
    let baseURL: URL
    private let macIdentity: Curve25519.Signing.PrivateKey
    private let macDeviceId: String
    private let transport: CompanionPushHTTPTransport

    init(
        baseURL: URL,
        identity: CompanionDeviceIdentity,
        transport: CompanionPushHTTPTransport = CompanionPushURLSessionTransport()
    ) {
        self.baseURL = baseURL
        self.macIdentity = identity.signingPrivateKey
        self.macDeviceId = identity.deviceId
        self.transport = transport
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private func sign(_ signingString: String) throws -> String {
        let signature = try macIdentity.signature(for: Data(signingString.utf8))
        return CompanionBase64URL.encode(signature)
    }

    // MARK: Registration

    /// Builds the signed `POST /register` request (exposed for tests to assert
    /// body + signature without networking).
    func makeRegisterRequest(
        phoneDeviceId: String,
        platform: CompanionPushPlatform,
        token: String
    ) throws -> (url: URL, body: Data) {
        let sig = try sign(CompanionPushSigning.registerSigningString(
            macDeviceId: macDeviceId,
            phoneDeviceId: phoneDeviceId,
            platform: platform.rawValue,
            token: token
        ))
        let body = try Self.encoder.encode(CompanionPushRegisterRequestBody(
            macDeviceId: macDeviceId,
            phoneDeviceId: phoneDeviceId,
            platform: platform.rawValue,
            token: token,
            sig: sig
        ))
        return (baseURL.appendingPathComponent("register"), body)
    }

    @discardableResult
    func register(
        phoneDeviceId: String,
        platform: CompanionPushPlatform,
        token: String
    ) async throws -> Int {
        let request = try makeRegisterRequest(phoneDeviceId: phoneDeviceId, platform: platform, token: token)
        return try await transport.post(url: request.url, body: request.body)
    }

    // MARK: Wake

    /// Builds the signed `POST /wake` request. `phoneDeviceId` is the wake target;
    /// the gateway resolves the paired Mac keys and verifies `sig` against them.
    func makeWakeRequest(
        phoneDeviceId: String,
        platform: CompanionPushPlatform,
        token: String,
        sealedPayload: String
    ) throws -> (url: URL, body: Data) {
        let sig = try sign(CompanionPushSigning.wakeSigningString(
            deviceId: phoneDeviceId,
            platform: platform.rawValue,
            sealedPayload: sealedPayload,
            token: token
        ))
        let body = try Self.encoder.encode(CompanionPushWakeRequestBody(
            deviceId: phoneDeviceId,
            token: token,
            platform: platform.rawValue,
            sealedPayload: sealedPayload,
            sig: sig
        ))
        return (baseURL.appendingPathComponent("wake"), body)
    }

    @discardableResult
    func wake(
        phoneDeviceId: String,
        platform: CompanionPushPlatform,
        token: String,
        sealedPayload: String
    ) async throws -> Int {
        let request = try makeWakeRequest(
            phoneDeviceId: phoneDeviceId,
            platform: platform,
            token: token,
            sealedPayload: sealedPayload
        )
        return try await transport.post(url: request.url, body: request.body)
    }
}
