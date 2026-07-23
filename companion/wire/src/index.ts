// @zentty/wire — the shared wire protocol contract (zod schemas + helpers).
// Source of truth for both the TS relay/mobile packages and the Swift
// conformance suite (via vectors/*.json).

export {
  PROTOCOL_VERSION,
  MIN_SUPPORTED,
  EnvelopeSchema,
  type Envelope,
} from './envelope';

export { negotiateVersion } from './negotiate';
export { canonicalize, canonicalStringify } from './canonical';

export {
  MESSAGE_SCHEMAS,
  MESSAGE_TYPES,
  type MessageType,
  UnknownTypeError,
  getSchema,
  parseMessage,
  safeParseMessage,
  type ParsedMessage,
  type SafeParseResult,
} from './registry';

// Shared value types.
export {
  VersionRange,
  LanHint,
  ViewportSize,
  PaneState,
  InteractionKind,
  TaskProgress,
  PaneSummary,
  TranscriptRole,
  TranscriptEntry,
} from './types';

// Relay transport framing (device <-> relay; not the E2E envelope layer).
export {
  Base64Url,
  RelayChallenge,
  RelayAuth,
  RelayReady,
  RelayDenied,
  RelayFrame,
  RelayPeerStatus,
  RelayWatch,
  RelayErrorCode,
  RELAY_ERROR_CODES,
  RelayError,
  RELAY_FRAME,
  RELAY_FRAME_TYPES,
  type RelayFrameType,
  RelayFrameSchema,
  type AnyRelayFrame,
  UnknownRelayFrameError,
  parseRelayFrame,
  safeParseRelayFrame,
  type SafeRelayFrameResult,
} from './relay';

// Families.
export * from './families/pairing';
export * from './families/session';
export * from './families/dashboard';
export * from './families/pane';
export * from './families/input';
export * from './families/transcript';
export * from './families/lease';
// push uses explicit named re-exports (not `export *`) so nodenext consumers such
// as the relay's push gateway can resolve the gateway REST contract + signing
// helpers, which live in a subdirectory module.
export {
  PushPlatform,
  PushRegister,
  PushTest,
  pushMessages,
  PUSH_WAKE_SIGN_PREFIX,
  PUSH_REGISTER_SIGN_PREFIX,
  PushRegisterRequest,
  type PushRegisterSignFields,
  PushWakeRequest,
  type PushWakeSignFields,
  pushWakeSigningString,
  pushRegisterSigningString,
} from './families/push';
