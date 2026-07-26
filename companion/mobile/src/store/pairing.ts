/**
 * One-shot pairing flow: parse a scanned/pasted offer, open a transport to the
 * offering Mac (direct first, relay fallback), and run the plaintext
 * `pairing.request` → `pairing.confirm` exchange. Returns the {@link PairedMac} to
 * persist; the caller decides when to store + connect.
 */
import {
  ConnectionManager,
  PairingTimeoutError,
  parsePairingOffer,
  runPairing,
  type PairedMac,
  type PairingOfferData,
} from '@/core';
import { phoneName } from '@/runtime/device';
import { getSodium } from '@/runtime/sodium';
import { getStorage } from '@/runtime/storage';
import { makeTransportOpeners } from '@/runtime/transports';

export class PairingExpiredError extends Error {
  constructor() {
    super('This pairing code has expired. Generate a fresh one on your Mac.');
    this.name = 'PairingExpiredError';
  }
}

export class PairingParseError extends Error {
  constructor() {
    super("That code isn't a Zentty pairing code.");
    this.name = 'PairingParseError';
  }
}

/**
 * Thrown when a successfully-parsed offer carries no usable endpoint (no
 * `lanHint` and an empty `relayUrl`) — a known Mac-side race where the offer
 * is minted before the relay URL / LAN hint are available. Failing fast here
 * avoids the misleading "Couldn't reach your Mac" network-failure message,
 * since no connection was ever attempted.
 */
export class PairingNoEndpointError extends Error {
  constructor() {
    super(
      'Generate a new code on your Mac — make sure the mobile companion is enabled and the listener is running (Zentty → Settings → Mobile Devices).',
    );
    this.name = 'PairingNoEndpointError';
  }
}

/** Parse an offer string (QR payload or pasted code), throwing {@link PairingParseError}. */
export function parseOffer(raw: string): PairingOfferData {
  try {
    return parsePairingOffer(raw.trim());
  } catch {
    throw new PairingParseError();
  }
}

/**
 * Backstop ceiling on the whole connect + pairing exchange. The legs are
 * individually bounded (direct connect 3s in ConnectionManager, socket connect
 * and the pairing reply 10s each), so 30s covers the worst-case direct-then-
 * relay path with headroom — this only trips when something in between hangs
 * (e.g. a relay that accepts the socket but never answers the auth exchange).
 */
const DEFAULT_PAIRING_OVERALL_TIMEOUT_MS = 30_000;

/**
 * Run the pairing handshake for an already-parsed offer. Validates expiry against
 * `now`, opens a transport, and resolves the paired Mac. Surfaces
 * {@link PairingExpiredError} and propagates connection / rejection errors from
 * the core. Rejects with {@link PairingTimeoutError} if the whole flow does not
 * finish within `timeoutMs` so the scan screen can never wedge on "Pairing…".
 */
export async function pairWithOffer(
  offer: PairingOfferData,
  now: number = Date.now(),
  timeoutMs: number = DEFAULT_PAIRING_OVERALL_TIMEOUT_MS,
): Promise<PairedMac> {
  if (offer.expiresAt <= now) {
    throw new PairingExpiredError();
  }
  if (!offer.lanHint && !offer.relayUrl) {
    throw new PairingNoEndpointError();
  }

  const storage = await getStorage();
  const sodium = await getSodium();
  const identity = await storage.loadOrCreateIdentity();

  const openers = makeTransportOpeners({
    identity,
    sodium,
    macDeviceId: offer.macDeviceId,
  });
  const manager = new ConnectionManager({
    mac: {
      macDeviceId: offer.macDeviceId,
      macPubKey: offer.macPubKey,
      macName: '',
      lanHint: offer.lanHint,
      relayUrl: offer.relayUrl,
      pairedAt: 0,
    },
    openDirect: openers.openDirect,
    openRelay: openers.openRelay,
  });

  const attempt = (async (): Promise<PairedMac> => {
    const active = await manager.connectOnce();
    try {
      return await runPairing({
        transport: active.transport,
        offer,
        identity,
        phoneName: phoneName(),
        sodium,
      });
    } finally {
      active.transport.close();
    }
  })();

  if (timeoutMs <= 0) {
    return attempt;
  }
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    return await Promise.race([
      attempt,
      new Promise<never>((_, reject) => {
        timer = setTimeout(() => reject(new PairingTimeoutError()), timeoutMs);
      }),
    ]);
  } catch (error) {
    // If the attempt settles after we gave up, swallow its late result; its
    // transport still closes via the finally above (runPairing is bounded).
    void attempt.then(
      () => undefined,
      () => undefined,
    );
    throw error;
  } finally {
    if (timer) {
      clearTimeout(timer);
    }
  }
}
