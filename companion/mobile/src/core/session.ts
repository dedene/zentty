/**
 * Phone-side session state machine, driven over a byte-level {@link TransportLike}
 * (a direct-LAN WebSocket or a relay virtual channel — connection.ts picks one).
 *
 * Two entry points mirror the Mac's `CompanionSession` opening-frame dispatch
 * (Zentty/Companion/Bridge/CompanionConnectionSession.swift):
 *
 * - {@link runPairing}: the one-time plaintext bootstrap. Sends `pairing.request`
 *   with an HMAC proof of the QR secret and resolves on `pairing.confirm`.
 * - {@link PhoneSession}: an already-paired connection. Runs the X25519/Ed25519
 *   crypto handshake, exchanges the sealed `session.hello` / `session.ready`, then
 *   routes typed traffic. Fresh ephemeral keys per connection (reconnect-safe).
 */

import { MIN_SUPPORTED, PROTOCOL_VERSION, PairingOffer, parseMessage } from '@zentty/wire';
import type { ParsedMessage } from '@zentty/wire';

import { decodeBase64Url, encodeBase64Url } from './base64url';
import {
  CompanionSessionCrypto,
  establishSession,
  localHandshakeSignature,
  utf8Bytes,
} from './crypto';
import { hmacSha256 } from './hkdf';
import type { SodiumLike } from './sodium';
import type { PairedMac, PhoneDeviceIdentity } from './storage';

// MARK: - Transport seam

/** A full-duplex byte channel. `receive()` resolves `null` once the peer closes. */
export interface TransportLike {
  send(frame: Uint8Array): Promise<void>;
  receive(): Promise<Uint8Array | null>;
  close(): void;
}

// MARK: - Errors

export class PairingRejectedError extends Error {
  readonly reason: string;
  constructor(reason: string) {
    super(`pairing rejected: ${reason}`);
    this.name = 'PairingRejectedError';
    this.reason = reason;
  }
}

export class HandshakeError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'HandshakeError';
  }
}

export class SessionClosedError extends Error {
  constructor(message = 'session closed') {
    super(message);
    this.name = 'SessionClosedError';
  }
}

export class VersionMismatchError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'VersionMismatchError';
  }
}

/** Wraps a fatal `session.error` frame received from the Mac. */
export class RemoteSessionError extends Error {
  readonly code: string;
  constructor(code: string, message: string) {
    super(`${code}: ${message}`);
    this.name = 'RemoteSessionError';
    this.code = code;
  }
}

// MARK: - Envelope framing

const utf8Decoder = new TextDecoder();

function uuidV4(sodium: SodiumLike): string {
  const b = sodium.randomBytes(16);
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  const hex: string[] = [];
  for (let i = 0; i < 16; i += 1) {
    hex.push(b[i].toString(16).padStart(2, '0'));
  }
  const s = hex.join('');
  return `${s.slice(0, 8)}-${s.slice(8, 12)}-${s.slice(12, 16)}-${s.slice(16, 20)}-${s.slice(20)}`;
}

function encodeEnvelope(
  id: string,
  type: string,
  payload: unknown,
  replyTo?: string,
): Uint8Array {
  const envelope: Record<string, unknown> = { v: PROTOCOL_VERSION, id, type, payload };
  if (replyTo !== undefined) {
    envelope.replyTo = replyTo;
  }
  return utf8Bytes(JSON.stringify(envelope));
}

function decodeEnvelope(bytes: Uint8Array): ParsedMessage {
  return parseMessage(utf8Decoder.decode(bytes));
}

// MARK: - Pairing (plaintext bootstrap)

export type PairingOfferData = ReturnType<typeof PairingOffer.parse>;

/** Parse and validate a QR-carried pairing offer (JSON string) against the wire schema. */
export function parsePairingOffer(qr: string): PairingOfferData {
  return PairingOffer.parse(JSON.parse(qr));
}

/**
 * Compute the pairing proof exactly as the Mac's `CompanionPairingStore`
 * verifies it: `HMAC-SHA256(key = raw secret bytes, message = raw phone Ed25519
 * public key bytes)`. The secret arrives base64url in the offer; the phone public
 * key is the identity key. The result is sent base64url. (Read from
 * CompanionPairingStore.verifyPairingProof: it decodes both the wire pubKey and
 * proof from base64url, then checks HMAC over the raw key bytes.)
 */
export function computePairingProof(
  secretBase64Url: string,
  phonePublicKey: Uint8Array,
): string {
  const secret = decodeBase64Url(secretBase64Url);
  return encodeBase64Url(hmacSha256(secret, phonePublicKey));
}

/**
 * Run the one-time pairing handshake over a fresh transport. Sends the
 * `pairing.request` envelope and resolves the resulting {@link PairedMac} on
 * `pairing.confirm`; throws {@link PairingRejectedError} on `pairing.reject`.
 */
export async function runPairing(params: {
  transport: TransportLike;
  offer: PairingOfferData;
  identity: PhoneDeviceIdentity;
  phoneName: string;
  sodium: SodiumLike;
  now?: () => number;
}): Promise<PairedMac> {
  const { transport, offer, identity, phoneName, sodium } = params;
  const now = params.now ?? Date.now;

  const proof = computePairingProof(offer.secret, identity.publicKey);
  const id = uuidV4(sodium);
  await transport.send(
    encodeEnvelope(id, 'pairing.request', {
      phoneDeviceId: identity.deviceId,
      phonePubKey: encodeBase64Url(identity.publicKey),
      phoneName,
      proof,
    }),
  );

  const reply = await transport.receive();
  if (reply === null) {
    throw new SessionClosedError('connection closed during pairing');
  }
  const message = decodeEnvelope(reply);
  if (message.type === 'pairing.confirm') {
    const payload = message.payload as { macName: string };
    return {
      macDeviceId: offer.macDeviceId,
      macPubKey: offer.macPubKey,
      macName: payload.macName,
      lanHint: offer.lanHint,
      relayUrl: offer.relayUrl,
      pairedAt: now(),
    };
  }
  if (message.type === 'pairing.reject') {
    throw new PairingRejectedError((message.payload as { reason: string }).reason);
  }
  throw new HandshakeError(`unexpected pairing reply: ${message.type}`);
}

// MARK: - Encrypted session

/** Bare crypto-handshake frame (not a `{v,id,type,payload}` envelope). */
interface HandshakeFrame {
  deviceId?: string;
  ephemeralPublicKey?: string;
  signature?: string;
}

export type SessionState = 'idle' | 'handshaking' | 'ready' | 'closed';

export interface PhoneSessionOptions {
  transport: TransportLike;
  identity: PhoneDeviceIdentity;
  mac: PairedMac;
  sodium: SodiumLike;
  deviceName: string;
  appVersion: string;
  /** Fired for every routed message that is not a correlated reply. */
  onMessage?: (message: ParsedMessage) => void;
  onStateChange?: (state: SessionState) => void;
  /** Fired for a dropped/undecryptable frame (e.g. replay); non-fatal. */
  onFrameError?: (error: Error) => void;
}

interface PendingRequest {
  resolve: (message: ParsedMessage) => void;
  reject: (error: Error) => void;
}

/**
 * One encrypted connection to a paired Mac. Call {@link connect} once; it runs
 * the handshake, exchanges hello/ready, and starts the receive loop. Reusing a
 * closed session is not supported — reconnect with a new instance (and a new
 * transport), which mints fresh ephemeral keys.
 */
export class PhoneSession {
  private readonly opts: PhoneSessionOptions;
  private crypto: CompanionSessionCrypto | null = null;
  private _state: SessionState = 'idle';
  private _version: number | undefined;
  private readonly pending = new Map<string, PendingRequest>();
  private ready?: { resolve: () => void; reject: (error: Error) => void };
  private receiveLoop?: Promise<void>;

  constructor(options: PhoneSessionOptions) {
    this.opts = options;
  }

  get state(): SessionState {
    return this._state;
  }

  get negotiatedVersion(): number | undefined {
    return this._version;
  }

  /**
   * Perform the crypto handshake and hello/ready exchange, then start routing.
   * Resolves once `session.ready` arrives; rejects on a fatal handshake or
   * version error, or if the connection closes first.
   */
  async connect(): Promise<void> {
    if (this._state !== 'idle') {
      throw new HandshakeError(`cannot connect from state ${this._state}`);
    }
    this.setState('handshaking');
    const { sodium, identity, mac, transport } = this.opts;

    const ephemeralPrivateKey = sodium.randomBytes(32);
    const ephemeralPublicKey = sodium.scalarMultBase(ephemeralPrivateKey);

    // 1. phone -> mac: {deviceId, ephemeralPublicKey}
    await transport.send(
      this.encodeHandshake({
        deviceId: identity.deviceId,
        ephemeralPublicKey: encodeBase64Url(ephemeralPublicKey),
      }),
    );

    // 2. mac -> phone: {deviceId, ephemeralPublicKey, signature}
    const serverFrame = await transport.receive();
    if (serverFrame === null) {
      throw new SessionClosedError('connection closed during handshake');
    }
    const serverHello = this.decodeHandshake(serverFrame);
    if (
      serverHello.deviceId === undefined ||
      serverHello.ephemeralPublicKey === undefined ||
      serverHello.signature === undefined
    ) {
      throw new HandshakeError('malformed server hello');
    }
    if (serverHello.deviceId !== mac.macDeviceId) {
      throw new HandshakeError('server identity does not match pinned Mac');
    }

    const macIdentityPublicKey = decodeBase64Url(mac.macPubKey);
    const macEphemeralPublicKey = decodeBase64Url(serverHello.ephemeralPublicKey);
    const macSignature = decodeBase64Url(serverHello.signature);

    // 3. verify + derive keys (throws on a bad Mac signature).
    this.crypto = establishSession(sodium, {
      role: 'phone',
      localIdentitySeed: identity.seed,
      localEphemeralPrivateKey: ephemeralPrivateKey,
      localEphemeralPublicKey: ephemeralPublicKey,
      peerIdentityPublicKey: macIdentityPublicKey,
      peerEphemeralPublicKey: macEphemeralPublicKey,
      peerSignature: macSignature,
    });

    // 4. phone -> mac: {signature}
    const phoneSignature = localHandshakeSignature(sodium, {
      role: 'phone',
      localIdentitySeed: identity.seed,
      localEphemeralPublicKey: ephemeralPublicKey,
      peerIdentityPublicKey: macIdentityPublicKey,
      peerEphemeralPublicKey: macEphemeralPublicKey,
    });
    await transport.send(this.encodeHandshake({ signature: encodeBase64Url(phoneSignature) }));

    // 5. first sealed frame: session.hello -> await session.ready.
    const readyPromise = new Promise<void>((resolve, reject) => {
      this.ready = { resolve, reject };
    });
    this.sendSealed(uuidV4(sodium), 'session.hello', {
      supported: { min: MIN_SUPPORTED, max: PROTOCOL_VERSION },
      deviceName: this.opts.deviceName,
      appVersion: this.opts.appVersion,
    });

    this.receiveLoop = this.runReceiveLoop();
    await readyPromise;
  }

  /** Seal and send a message. Returns the envelope id. */
  send(type: string, payload: unknown, replyTo?: string): string {
    const id = uuidV4(this.opts.sodium);
    this.sendSealed(id, type, payload, replyTo);
    return id;
  }

  /** Send a message and resolve with the reply correlated by `replyTo`. */
  request(type: string, payload: unknown): Promise<ParsedMessage> {
    const id = uuidV4(this.opts.sodium);
    return new Promise<ParsedMessage>((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      try {
        this.sendSealed(id, type, payload);
      } catch (error) {
        this.pending.delete(id);
        reject(error instanceof Error ? error : new Error(String(error)));
      }
    });
  }

  close(): void {
    if (this._state === 'closed') {
      return;
    }
    this.setState('closed');
    this.opts.transport.close();
    this.failPending(new SessionClosedError());
    this.ready?.reject(new SessionClosedError('connection closed before ready'));
    this.ready = undefined;
  }

  // MARK: internals

  private sendSealed(id: string, type: string, payload: unknown, replyTo?: string): void {
    if (this.crypto === null) {
      throw new SessionClosedError('no session key');
    }
    const sealed = this.crypto.seal(encodeEnvelope(id, type, payload, replyTo));
    void this.opts.transport.send(sealed);
  }

  private async runReceiveLoop(): Promise<void> {
    const { transport } = this.opts;
    for (;;) {
      let frame: Uint8Array | null;
      try {
        frame = await transport.receive();
      } catch (error) {
        this.handleClose(error instanceof Error ? error : new Error(String(error)));
        return;
      }
      if (frame === null) {
        this.handleClose(new SessionClosedError());
        return;
      }
      if (this.crypto === null) {
        continue;
      }
      let plaintext: Uint8Array;
      try {
        plaintext = this.crypto.open(frame);
      } catch (error) {
        // Replay / malformed / auth failure: drop the frame, keep the session.
        this.opts.onFrameError?.(error instanceof Error ? error : new Error(String(error)));
        continue;
      }
      let message: ParsedMessage;
      try {
        message = decodeEnvelope(plaintext);
      } catch (error) {
        this.opts.onFrameError?.(error instanceof Error ? error : new Error(String(error)));
        continue;
      }
      this.dispatch(message);
    }
  }

  private dispatch(message: ParsedMessage): void {
    if (this._state === 'handshaking') {
      if (message.type === 'session.ready') {
        this._version = (message.payload as { v: number }).v;
        this.setState('ready');
        this.ready?.resolve();
        this.ready = undefined;
        return;
      }
      if (message.type === 'session.error') {
        const payload = message.payload as { code: string; message: string; fatal: boolean };
        const error =
          payload.code === 'incompatible_version'
            ? new VersionMismatchError(payload.message)
            : new RemoteSessionError(payload.code, payload.message);
        this.ready?.reject(error);
        this.ready = undefined;
        this.close();
        return;
      }
      // Ignore anything else until ready.
      return;
    }

    if (message.replyTo !== undefined) {
      const waiter = this.pending.get(message.replyTo);
      if (waiter) {
        this.pending.delete(message.replyTo);
        waiter.resolve(message);
        return;
      }
    }
    this.opts.onMessage?.(message);
  }

  private handleClose(error: Error): void {
    if (this._state === 'closed') {
      return;
    }
    this.setState('closed');
    this.failPending(error);
    this.ready?.reject(error);
    this.ready = undefined;
  }

  private failPending(error: Error): void {
    for (const waiter of this.pending.values()) {
      waiter.reject(error);
    }
    this.pending.clear();
  }

  private setState(state: SessionState): void {
    if (this._state === state) {
      return;
    }
    this._state = state;
    this.opts.onStateChange?.(state);
  }

  private encodeHandshake(frame: HandshakeFrame): Uint8Array {
    return utf8Bytes(JSON.stringify(frame));
  }

  private decodeHandshake(bytes: Uint8Array): HandshakeFrame {
    return JSON.parse(utf8Decoder.decode(bytes)) as HandshakeFrame;
  }
}
