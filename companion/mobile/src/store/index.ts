export { useCompanionStore, type CompanionStore } from './useCompanionStore';
export { MacConnection, type MacConnectionState } from './macConnection';
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
