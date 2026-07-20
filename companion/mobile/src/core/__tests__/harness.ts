/**
 * Test harness: an in-memory transport pipe and a faithful "fake Mac" that speaks
 * the server side of the pairing + crypto handshake + session protocol using the
 * SAME crypto primitives (role 'mac') the phone core uses.
 *
 * Because the interop vector proves those primitives are byte-identical to the
 * Mac's CryptoKit implementation, driving the phone against this fake Mac is a
 * true end-to-end exercise of the wire contract, not a mock.
 *
 * Not a test file (excluded by testMatch), so it holds no `it()` blocks.
 */
import { PROTOCOL_VERSION } from '@zentty/wire';

import { decodeBase64Url, encodeBase64Url } from '../base64url';
import {
  CompanionSessionCrypto,
  establishSession,
  localHandshakeSignature,
  utf8Bytes,
} from '../crypto';
import type { SodiumLike } from '../sodium';
import type { TransportLike } from '../session';
import type { PairedMac, PhoneDeviceIdentity } from '../storage';

const decoder = new TextDecoder();

// MARK: - In-memory pipe

interface Endpoint {
  inbox: Uint8Array[];
  waiters: ((frame: Uint8Array | null) => void)[];
  closed: boolean;
}

function makeEndpoint(): Endpoint {
  return { inbox: [], waiters: [], closed: false };
}

/** Create a connected pair of {@link TransportLike} endpoints. */
export function makePipe(): [TransportLike, TransportLike] {
  const a = makeEndpoint();
  const b = makeEndpoint();

  const deliver = (target: Endpoint, frame: Uint8Array): void => {
    const waiter = target.waiters.shift();
    if (waiter) {
      waiter(frame);
    } else {
      target.inbox.push(frame);
    }
  };

  const closeBoth = (): void => {
    for (const ep of [a, b]) {
      if (ep.closed) {
        continue;
      }
      ep.closed = true;
      for (const w of ep.waiters.splice(0)) {
        w(null);
      }
    }
  };

  const endpoint = (self: Endpoint, peer: Endpoint): TransportLike => ({
    async send(frame: Uint8Array): Promise<void> {
      if (self.closed) {
        throw new Error('transport closed');
      }
      deliver(peer, frame.slice());
    },
    receive(): Promise<Uint8Array | null> {
      if (self.inbox.length > 0) {
        return Promise.resolve(self.inbox.shift() as Uint8Array);
      }
      if (self.closed) {
        return Promise.resolve(null);
      }
      return new Promise((resolve) => self.waiters.push(resolve));
    },
    close(): void {
      closeBoth();
    },
  });

  return [endpoint(a, b), endpoint(b, a)];
}

// MARK: - Identity helpers

export function makePhoneIdentity(sodium: SodiumLike, seed?: Uint8Array): PhoneDeviceIdentity {
  const s = seed ?? sodium.randomBytes(32);
  const keypair = sodium.signSeedKeypair(s);
  return { seed: s, publicKey: keypair.publicKey, deviceId: encodeBase64Url(keypair.publicKey) };
}

export interface FakeMacOptions {
  transport: TransportLike;
  sodium: SodiumLike;
  /** Mac's Ed25519 identity seed. */
  macIdentitySeed: Uint8Array;
  /** The phone identity the Mac pinned at pairing (its public key). */
  phoneIdentityPublicKey: Uint8Array;
  /** Reply to session.hello with an incompatible_version error instead of ready. */
  versionMismatch?: boolean;
  macName?: string;
  onMessage?: (message: { type: string; id: string; payload: unknown }) => void;
  /** Invoked once, right after `session.ready` is sent. */
  afterReady?: (mac: FakeMac) => void | Promise<void>;
}

/** The Mac-side counterpart used to drive the phone core in tests. */
export class FakeMac {
  readonly deviceId: string;
  readonly macPublicKey: Uint8Array;
  private crypto: CompanionSessionCrypto | null = null;
  private readonly opts: FakeMacOptions;

  constructor(opts: FakeMacOptions) {
    this.opts = opts;
    const keypair = opts.sodium.signSeedKeypair(opts.macIdentitySeed);
    this.macPublicKey = keypair.publicKey;
    this.deviceId = encodeBase64Url(keypair.publicKey);
  }

  /** A PairedMac record the phone would hold for this Mac. */
  pairedRecord(extra?: Partial<PairedMac>): PairedMac {
    return {
      macDeviceId: this.deviceId,
      macPubKey: encodeBase64Url(this.macPublicKey),
      macName: this.opts.macName ?? 'Test Mac',
      pairedAt: 0,
      ...extra,
    };
  }

  /** Run the full server side: handshake, then the encrypted routing loop. */
  async run(): Promise<void> {
    await this.handshake();
    await this.encryptedLoop();
  }

  /** Seal and send an envelope to the phone (advances the Mac send counter). */
  sendSealed(type: string, payload: unknown, replyTo?: string): void {
    void this.opts.transport.send(this.seal(type, payload, replyTo));
  }

  /** Seal an envelope and return the raw bytes without sending. */
  seal(type: string, payload: unknown, replyTo?: string): Uint8Array {
    if (this.crypto === null) {
      throw new Error('no crypto yet');
    }
    const env: Record<string, unknown> = { v: PROTOCOL_VERSION, id: 'mac-' + type, type, payload };
    if (replyTo !== undefined) {
      env.replyTo = replyTo;
    }
    return this.crypto.seal(utf8Bytes(JSON.stringify(env)));
  }

  /** Send raw bytes straight down the transport (used to inject a replayed frame). */
  sendRaw(bytes: Uint8Array): void {
    void this.opts.transport.send(bytes);
  }

  private async handshake(): Promise<void> {
    const { transport, sodium, macIdentitySeed, phoneIdentityPublicKey } = this.opts;

    const frame1 = await transport.receive();
    if (frame1 === null) {
      throw new Error('closed before client hello');
    }
    const clientHello = JSON.parse(decoder.decode(frame1)) as {
      deviceId?: string;
      ephemeralPublicKey?: string;
    };
    if (!clientHello.ephemeralPublicKey) {
      throw new Error('missing phone ephemeral');
    }
    const phoneEphemeralPublicKey = decodeBase64Url(clientHello.ephemeralPublicKey);

    const macEphemeralPrivateKey = sodium.randomBytes(32);
    const macEphemeralPublicKey = sodium.scalarMultBase(macEphemeralPrivateKey);

    const macSignature = localHandshakeSignature(sodium, {
      role: 'mac',
      localIdentitySeed: macIdentitySeed,
      localEphemeralPublicKey: macEphemeralPublicKey,
      peerIdentityPublicKey: phoneIdentityPublicKey,
      peerEphemeralPublicKey: phoneEphemeralPublicKey,
    });
    await transport.send(
      utf8Bytes(
        JSON.stringify({
          deviceId: this.deviceId,
          ephemeralPublicKey: encodeBase64Url(macEphemeralPublicKey),
          signature: encodeBase64Url(macSignature),
        }),
      ),
    );

    const frame3 = await transport.receive();
    if (frame3 === null) {
      throw new Error('closed before phone signature');
    }
    const auth = JSON.parse(decoder.decode(frame3)) as { signature?: string };
    if (!auth.signature) {
      throw new Error('missing phone signature');
    }

    this.crypto = establishSession(sodium, {
      role: 'mac',
      localIdentitySeed: macIdentitySeed,
      localEphemeralPrivateKey: macEphemeralPrivateKey,
      localEphemeralPublicKey: macEphemeralPublicKey,
      peerIdentityPublicKey: phoneIdentityPublicKey,
      peerEphemeralPublicKey: phoneEphemeralPublicKey,
      peerSignature: decodeBase64Url(auth.signature),
    });
  }

  private async encryptedLoop(): Promise<void> {
    const { transport } = this.opts;
    for (;;) {
      const frame = await transport.receive();
      if (frame === null || this.crypto === null) {
        return;
      }
      let message: { type: string; id: string; payload: unknown; replyTo?: string };
      try {
        message = JSON.parse(decoder.decode(this.crypto.open(frame))) as typeof message;
      } catch {
        continue;
      }
      await this.route(message);
    }
  }

  private async route(message: {
    type: string;
    id: string;
    payload: unknown;
  }): Promise<void> {
    if (message.type === 'session.hello') {
      if (this.opts.versionMismatch) {
        this.sendSealed(
          'session.error',
          { code: 'incompatible_version', message: 'No shared protocol version', fatal: true },
          message.id,
        );
        return;
      }
      this.sendSealed('session.ready', { v: PROTOCOL_VERSION }, message.id);
      await this.opts.afterReady?.(this);
      return;
    }
    if (message.type === 'session.ping') {
      this.sendSealed('session.pong', { ts: (message.payload as { ts: number }).ts }, message.id);
      return;
    }
    this.opts.onMessage?.(message);
  }
}
