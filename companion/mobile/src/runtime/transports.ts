/**
 * Builds the direct / relay transport openers a {@link ConnectionManager} needs,
 * closing over one connection's identity + peer. The manager decides which to try
 * (direct first, relay fallback); these just turn a `lanHint` or `relayUrl` into a
 * live {@link TransportLike}.
 */
import {
  openRelayTransport,
  type PhoneDeviceIdentity,
  type SodiumLike,
  type TransportLike,
} from '@/core';

import { openByteSocket, openTextSocket } from './websocket';

export interface TransportOpenerParams {
  identity: PhoneDeviceIdentity;
  sodium: SodiumLike;
  /** The Mac we are routing to (relay addressing + direct-frame filtering). */
  macDeviceId: string;
  /** Relay peer-presence callback (online/offline), if the caller cares. */
  onPeerStatus?: (online: boolean) => void;
}

export interface TransportOpeners {
  openDirect: (lanHint: { host: string; port: number }) => Promise<TransportLike>;
  openRelay: (relayUrl: string) => Promise<TransportLike>;
}

export function makeTransportOpeners(params: TransportOpenerParams): TransportOpeners {
  const { identity, sodium, macDeviceId, onPeerStatus } = params;
  return {
    openDirect: (lanHint) => openByteSocket(`ws://${lanHint.host}:${lanHint.port}`),
    openRelay: async (relayUrl) => {
      const socket = await openTextSocket(relayUrl);
      return openRelayTransport({ socket, identity, sodium, macDeviceId, onPeerStatus });
    },
  };
}
