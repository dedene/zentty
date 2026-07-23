/**
 * One-shot pairing flow: parse a scanned/pasted offer, open a transport to the
 * offering Mac (direct first, relay fallback), and run the plaintext
 * `pairing.request` → `pairing.confirm` exchange. Returns the {@link PairedMac} to
 * persist; the caller decides when to store + connect.
 */
import {
  ConnectionManager,
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

/** Parse an offer string (QR payload or pasted code), throwing {@link PairingParseError}. */
export function parseOffer(raw: string): PairingOfferData {
  try {
    return parsePairingOffer(raw.trim());
  } catch {
    throw new PairingParseError();
  }
}

/**
 * Run the pairing handshake for an already-parsed offer. Validates expiry against
 * `now`, opens a transport, and resolves the paired Mac. Surfaces
 * {@link PairingExpiredError} and propagates connection / rejection errors from
 * the core.
 */
export async function pairWithOffer(
  offer: PairingOfferData,
  now: number = Date.now(),
): Promise<PairedMac> {
  if (offer.expiresAt <= now) {
    throw new PairingExpiredError();
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
}
