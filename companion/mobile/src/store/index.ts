export { useCompanionStore, type CompanionStore } from './useCompanionStore';
export { MacConnection, type MacConnectionState } from './macConnection';
export {
  PaneController,
  initialPaneRuntime,
  type PaneRuntimeState,
  type PaneTransport,
} from './paneController';
export {
  coalescePaneText,
  withScrollback,
  type PaneTextState,
} from './paneText';
export {
  LeaseController,
  idleLease,
  type LeaseSnapshot,
  type LeaseStatus,
  type LeaseGrantData,
} from './leaseController';
export {
  initialTranscript,
  loadingTranscript,
  applyTranscriptSnapshot,
  applyTranscriptDelta,
  applyTranscriptUnavailable,
  type TranscriptState,
  type TranscriptStatus,
} from './transcript';
export {
  availableTabs,
  resolveActiveTab,
  paneTabPreferenceKey,
  parsePaneTab,
  type PaneTab,
} from './paneTabs';
export {
  applySnapshot,
  applyDelta,
  orderPanes,
  orderWorklanes,
  countAttention,
  isStale,
  type Worklane,
  type ConnState,
  type DashboardSnapshotPayload,
  type DashboardDeltaPayload,
} from './dashboard';
export {
  parseOffer,
  pairWithOffer,
  PairingExpiredError,
  PairingParseError,
} from './pairing';
