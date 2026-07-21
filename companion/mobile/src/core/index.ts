/**
 * @zentty/mobile core — the UI-free protocol layer that talks to the Mac bridge.
 *
 * Nothing here imports React or any Expo UI module; it is pure TypeScript with an
 * injectable native-crypto adapter ({@link SodiumLike}), a byte transport
 * ({@link TransportLike}), and a key/value store ({@link KVStore}). Screens wire
 * these to react-native-libsodium, WebSockets, and expo-secure-store.
 */

export { encodeBase64Url, decodeBase64Url, isValidUnpaddedBase64Url } from './base64url';
export { sha256, hmacSha256, hkdfSha256, hkdfExtract, hkdfExpand } from './hkdf';
export { createSodium } from './sodium';
export type { SodiumLike, RawLibsodium } from './sodium';

export {
  CompanionSessionCrypto,
  CompanionCryptoError,
  establishSession,
  localHandshakeSignature,
  handshakeTranscript,
  sealFrameAt,
  utf8Bytes,
  HANDSHAKE_LABEL,
  MAC_TO_PHONE_INFO,
  PHONE_TO_MAC_INFO,
  MAC_TO_PHONE_SALT,
  PHONE_TO_MAC_SALT,
} from './crypto';
export type { EndpointRole, CompanionCryptoErrorCode } from './crypto';

export {
  PhoneSession,
  runPairing,
  parsePairingOffer,
  computePairingProof,
  PairingRejectedError,
  HandshakeError,
  SessionClosedError,
  VersionMismatchError,
  RemoteSessionError,
} from './session';
export type {
  TransportLike,
  SessionState,
  PhoneSessionOptions,
  PairingOfferData,
} from './session';

export {
  ConnectionManager,
  ConnectionFailedError,
  Backoff,
  RelayAuthError,
  openRelayTransport,
  RELAY_AUTH_PREFIX,
} from './connection';
export type {
  TextSocket,
  ConnectionStatus,
  ConnectionManagerOptions,
  ActiveTransport,
  TransportKind,
  BackoffOptions,
} from './connection';

export {
  CompanionStorage,
  InMemoryKVStore,
  secureStoreKV,
} from './storage';
export type { KVStore, SecureStoreLike, PhoneDeviceIdentity, PairedMac } from './storage';

export { PushRegistrar } from './pushRegistration';
export type { PushToken, PushRegistrationState, RegistrarSession } from './pushRegistration';

export {
  PUSH_SEAL_LABEL,
  derivePushKey,
  unsealPush,
  sealPush,
} from './pushCrypto';
export {
  parsePushWakeEnvelope,
  parsePushWakeContent,
  resolvePushDeepLink,
} from './pushWake';
export type { PushWakeEnvelope, PushWakeContent, PushDeepLink } from './pushWake';
