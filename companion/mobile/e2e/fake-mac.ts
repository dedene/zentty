/**
 * fake-mac — a Node stand-in for the Zentty Mac bridge, for end-to-end testing
 * the mobile companion app against a real (non-mocked) server on a LAN
 * WebSocket. It speaks the exact same wire contract as the real Mac by REUSING
 * the app's own TypeScript crypto core (../src/core) with `role: 'mac'` — no
 * reimplementation of the handshake, AEAD, or HKDF.
 *
 * What it does:
 *  1. Mints an Ed25519 Mac identity and a pairing offer, and prints the offer
 *     JSON to stdout — this is exactly the string the app's manual-entry field
 *     accepts (scan.tsx → parsePairingOffer → PairingOffer.parse(JSON.parse(x))).
 *  2. Serves ws://0.0.0.0:8787. Each phone connection is dispatched by its first
 *     frame:
 *       - a `pairing.request` envelope → verify the HMAC proof, reply
 *         `pairing.confirm`.
 *       - a bare handshake frame `{deviceId, ephemeralPublicKey}` → run the
 *         X25519/Ed25519 handshake (role mac), exchange sealed session.hello /
 *         session.ready, answer `dashboard.subscribe` with a scripted
 *         `dashboard.snapshot`, then after 10s push a `dashboard.delta` that
 *         flips the Claude pane from a pending approval to running.
 *
 * Run:  cd companion/mobile && node_modules/.bin/tsx e2e/fake-mac.ts
 * (or `pnpm --filter @zentty/mobile exec tsx e2e/fake-mac.ts`)
 */
import { randomUUID } from 'node:crypto';

import _sodium from 'libsodium-wrappers';
import { WebSocketServer, type WebSocket } from 'ws';

import { encodeBase64Url, decodeBase64Url } from '../src/core/base64url';
import {
  CompanionSessionCrypto,
  establishSession,
  localHandshakeSignature,
} from '../src/core/crypto';
import { hmacSha256 } from '../src/core/hkdf';
import { createSodium, type RawLibsodium, type SodiumLike } from '../src/core/sodium';

const PROTOCOL_VERSION = 1;
const MIN_SUPPORTED = 1;
const PORT = 8787;
const DELTA_DELAY_MS = 10_000;
// Long enough that a full manual E2E pass (build + drive + inspect) never races
// the expiry; override with FAKE_MAC_TTL_MS if you want a short-lived code.
const OFFER_TTL_MS = Number(process.env.FAKE_MAC_TTL_MS ?? 60 * 60_000); // 60 minutes

const utf8Encoder = new TextEncoder();
const utf8Decoder = new TextDecoder();

function log(...args: unknown[]): void {
  const ts = new Date().toISOString().slice(11, 23);
  // eslint-disable-next-line no-console
  console.log(`[fake-mac ${ts}]`, ...args);
}

function encodeEnvelope(type: string, payload: unknown, replyTo?: string): Uint8Array {
  const envelope: Record<string, unknown> = { v: PROTOCOL_VERSION, id: randomUUID(), type, payload };
  if (replyTo !== undefined) {
    envelope.replyTo = replyTo;
  }
  return utf8Encoder.encode(JSON.stringify(envelope));
}

interface Envelope {
  v?: number;
  id?: string;
  type?: string;
  replyTo?: string;
  payload?: unknown;
}

function decodeEnvelope(bytes: Uint8Array): Envelope {
  return JSON.parse(utf8Decoder.decode(bytes)) as Envelope;
}

/** Turns a ws socket into a pull-based queue of binary frames (Uint8Array). */
class FrameReader {
  private readonly buffer: Uint8Array[] = [];
  private readonly waiters: Array<(v: Uint8Array | null) => void> = [];
  private closed = false;

  constructor(ws: WebSocket) {
    ws.on('message', (data: Buffer, isBinary: boolean) => {
      // The phone sends the direct-LAN leg as binary WebSocket messages; JSON
      // handshake/pairing frames also arrive as binary (ws.send(Uint8Array)).
      const bytes = new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
      void isBinary;
      const waiter = this.waiters.shift();
      if (waiter) waiter(bytes);
      else this.buffer.push(bytes);
    });
    const end = () => {
      this.closed = true;
      let w = this.waiters.shift();
      while (w) {
        w(null);
        w = this.waiters.shift();
      }
    };
    ws.on('close', end);
    ws.on('error', end);
  }

  receive(): Promise<Uint8Array | null> {
    const next = this.buffer.shift();
    if (next !== undefined) return Promise.resolve(next);
    if (this.closed) return Promise.resolve(null);
    return new Promise((resolve) => this.waiters.push(resolve));
  }
}

// MARK: - Scripted dashboard data

interface PaneSummary {
  paneId: string;
  worklaneId: string;
  title: string;
  tool?: string;
  state: string;
  interactionKind: string;
  requiresHumanAttention: boolean;
  workingDirectory: string;
  sessionId?: string;
  hasTranscript: boolean;
  taskProgress?: { completed: number; total: number };
}

const claudePaneApproval: PaneSummary = {
  paneId: 'pane-claude',
  worklaneId: 'wl-zentty',
  title: 'Claude Code',
  tool: 'claude',
  state: 'needsInput',
  interactionKind: 'approval',
  requiresHumanAttention: true,
  workingDirectory: '/Users/peter/dev/zentty',
  sessionId: 'sess-claude-1',
  hasTranscript: true,
  taskProgress: { completed: 3, total: 7 },
};

const claudePaneRunning: PaneSummary = {
  ...claudePaneApproval,
  state: 'running',
  interactionKind: 'none',
  requiresHumanAttention: false,
  taskProgress: { completed: 4, total: 7 },
};

const snapshotPayload = {
  worklanes: [
    {
      id: 'wl-zentty',
      title: 'zentty',
      windowId: 1,
      attention: true,
      panes: [
        claudePaneApproval,
        {
          paneId: 'pane-codex',
          worklaneId: 'wl-zentty',
          title: 'codex',
          tool: 'codex',
          state: 'running',
          interactionKind: 'none',
          requiresHumanAttention: false,
          workingDirectory: '/Users/peter/dev/zentty',
          sessionId: 'sess-codex-1',
          hasTranscript: true,
        } satisfies PaneSummary,
      ],
    },
    {
      id: 'wl-side',
      title: 'side-project',
      windowId: 2,
      attention: false,
      panes: [
        {
          paneId: 'pane-shell',
          worklaneId: 'wl-side',
          title: 'zsh',
          state: 'idle',
          interactionKind: 'none',
          requiresHumanAttention: false,
          workingDirectory: '/Users/peter/dev/side-project',
          hasTranscript: false,
        } satisfies PaneSummary,
      ],
    },
  ],
};

const deltaPayload = {
  updated: [claudePaneRunning],
  removedPaneIds: [] as string[],
};

// MARK: - Main

async function main(): Promise<void> {
  await _sodium.ready;
  const sodium: SodiumLike = createSodium(_sodium as unknown as RawLibsodium);

  // Mac identity (Ed25519). macDeviceId == macPubKey == base64url(publicKey).
  const macSeed = sodium.randomBytes(32);
  const macKeypair = sodium.signSeedKeypair(macSeed);
  const macDeviceId = encodeBase64Url(macKeypair.publicKey);

  const secret = sodium.randomBytes(32);
  const offer = {
    relayUrl: '',
    lanHint: { host: '127.0.0.1', port: PORT },
    macDeviceId,
    macPubKey: macDeviceId,
    secret: encodeBase64Url(secret),
    expiresAt: Date.now() + OFFER_TTL_MS,
  };
  const offerCode = JSON.stringify(offer);

  const server = new WebSocketServer({ host: '0.0.0.0', port: PORT });
  server.on('listening', () => {
    log(`listening on ws://0.0.0.0:${PORT}  (macName "Fake Mac")`);
    log('macDeviceId:', macDeviceId);
    // eslint-disable-next-line no-console
    console.log('\n================ PAIRING CODE (paste into the app) ================\n');
    // eslint-disable-next-line no-console
    console.log(offerCode);
    // eslint-disable-next-line no-console
    console.log('\n===================================================================\n');
  });

  server.on('connection', (ws, req) => {
    log('connection opened from', req.socket.remoteAddress);
    const reader = new FrameReader(ws);
    void handleConnection(ws, reader, { sodium, macSeed, macKeypair, macDeviceId, secret }).catch(
      (err) => log('connection error:', err instanceof Error ? err.message : err),
    );
  });

  process.on('SIGINT', () => {
    log('shutting down');
    server.close();
    process.exit(0);
  });
}

interface MacContext {
  sodium: SodiumLike;
  macSeed: Uint8Array;
  macKeypair: { publicKey: Uint8Array; secretKey: Uint8Array };
  macDeviceId: string;
  secret: Uint8Array;
}

async function handleConnection(ws: WebSocket, reader: FrameReader, ctx: MacContext): Promise<void> {
  const first = await reader.receive();
  if (first === null) {
    return;
  }

  let asEnvelope: Envelope | undefined;
  try {
    asEnvelope = decodeEnvelope(first);
  } catch {
    asEnvelope = undefined;
  }

  if (asEnvelope?.type === 'pairing.request') {
    handlePairing(ws, asEnvelope, ctx);
    return;
  }
  // Otherwise the first frame is a bare handshake frame1.
  await handleSession(ws, reader, first, ctx);
}

// MARK: - Pairing

function handlePairing(ws: WebSocket, request: Envelope, ctx: MacContext): void {
  const payload = request.payload as {
    phoneDeviceId: string;
    phonePubKey: string;
    phoneName: string;
    proof: string;
  };
  log('pairing.request from', payload.phoneName, `(${payload.phoneDeviceId.slice(0, 12)}…)`);

  const phonePub = decodeBase64Url(payload.phonePubKey);
  const expectedProof = encodeBase64Url(hmacSha256(ctx.secret, phonePub));
  if (expectedProof !== payload.proof) {
    log('pairing proof MISMATCH — rejecting');
    ws.send(encodeEnvelope('pairing.reject', { reason: 'invalid_proof' }, request.id));
    return;
  }
  log('pairing proof OK — confirming');
  ws.send(encodeEnvelope('pairing.confirm', { macName: 'Fake Mac', paired: true }, request.id));
}

// MARK: - Encrypted session

interface HandshakeFrame {
  deviceId?: string;
  ephemeralPublicKey?: string;
  signature?: string;
}

async function handleSession(
  ws: WebSocket,
  reader: FrameReader,
  firstFrame: Uint8Array,
  ctx: MacContext,
): Promise<void> {
  const { sodium } = ctx;

  const clientHello = JSON.parse(utf8Decoder.decode(firstFrame)) as HandshakeFrame;
  if (!clientHello.deviceId || !clientHello.ephemeralPublicKey) {
    log('malformed client hello, dropping session');
    ws.close();
    return;
  }
  log('session: handshake from phone', `${clientHello.deviceId.slice(0, 12)}…`);

  const phoneIdentityPub = decodeBase64Url(clientHello.deviceId);
  const phoneEphemeralPub = decodeBase64Url(clientHello.ephemeralPublicKey);

  const macEphemeralPriv = sodium.randomBytes(32);
  const macEphemeralPub = sodium.scalarMultBase(macEphemeralPriv);

  // mac -> phone: {deviceId, ephemeralPublicKey, signature}
  const macSignature = localHandshakeSignature(sodium, {
    role: 'mac',
    localIdentitySeed: ctx.macSeed,
    localEphemeralPublicKey: macEphemeralPub,
    peerIdentityPublicKey: phoneIdentityPub,
    peerEphemeralPublicKey: phoneEphemeralPub,
  });
  const serverHello: HandshakeFrame = {
    deviceId: ctx.macDeviceId,
    ephemeralPublicKey: encodeBase64Url(macEphemeralPub),
    signature: encodeBase64Url(macSignature),
  };
  ws.send(utf8Encoder.encode(JSON.stringify(serverHello)));

  // phone -> mac: {signature}
  const sigFrame = await reader.receive();
  if (sigFrame === null) {
    log('session: closed before phone signature');
    return;
  }
  const phoneSigMsg = JSON.parse(utf8Decoder.decode(sigFrame)) as HandshakeFrame;
  if (!phoneSigMsg.signature) {
    log('session: missing phone signature');
    ws.close();
    return;
  }

  let crypto: CompanionSessionCrypto;
  try {
    crypto = establishSession(sodium, {
      role: 'mac',
      localIdentitySeed: ctx.macSeed,
      localEphemeralPrivateKey: macEphemeralPriv,
      localEphemeralPublicKey: macEphemeralPub,
      peerIdentityPublicKey: phoneIdentityPub,
      peerEphemeralPublicKey: phoneEphemeralPub,
      peerSignature: decodeBase64Url(phoneSigMsg.signature),
    });
  } catch (err) {
    log('session: handshake verification failed:', err instanceof Error ? err.message : err);
    ws.close();
    return;
  }
  log('session: keys established');

  const sendSealed = (type: string, payload: unknown, replyTo?: string): void => {
    ws.send(crypto.seal(encodeEnvelope(type, payload, replyTo)));
  };

  // First sealed frame from phone: session.hello
  const helloFrame = await reader.receive();
  if (helloFrame === null) return;
  const hello = decodeEnvelope(crypto.open(helloFrame));
  log('session: sealed', hello.type, 'received; sending session.ready');
  sendSealed('session.ready', { v: PROTOCOL_VERSION }, hello.id);
  void MIN_SUPPORTED;

  let deltaTimer: ReturnType<typeof setTimeout> | undefined;

  // Receive loop for the live session.
  for (;;) {
    const frame = await reader.receive();
    if (frame === null) {
      log('session: phone disconnected');
      if (deltaTimer) clearTimeout(deltaTimer);
      return;
    }
    let msg: Envelope;
    try {
      msg = decodeEnvelope(crypto.open(frame));
    } catch (err) {
      log('session: dropped undecryptable frame:', err instanceof Error ? err.message : err);
      continue;
    }

    if (msg.type === 'dashboard.subscribe') {
      log('session: dashboard.subscribe → sending snapshot (2 worklanes, Claude approval pending)');
      sendSealed('dashboard.snapshot', snapshotPayload);
      deltaTimer = setTimeout(() => {
        log('session: pushing dashboard.delta → Claude pane flips to running');
        sendSealed('dashboard.delta', deltaPayload);
      }, DELTA_DELAY_MS);
    } else if (msg.type === 'session.ping') {
      sendSealed('session.pong', { ts: Date.now() }, msg.id);
    } else {
      log('session: received', msg.type);
    }
  }
}

main().catch((err) => {
  log('fatal:', err instanceof Error ? err.stack : err);
  process.exit(1);
});
