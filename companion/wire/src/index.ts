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

// Families.
export * from './families/pairing';
export * from './families/session';
export * from './families/dashboard';
export * from './families/pane';
export * from './families/input';
export * from './families/transcript';
export * from './families/lease';
export * from './families/push';
