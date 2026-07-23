import { connect } from 'node:http2';
import type { ApnsConfig } from '../config.js';
import type { Logger } from '../log.js';
import { signJwtES256 } from './signing.js';

// APNs HTTP/2 client built on node:http2 + an ES256 provider JWT — no `apn` npm
// dependency. Every credential comes from config (config.ts resolves the .p8).
// When unconfigured the client is a no-op: `isEnabled` is false and `send`
// returns a disabled result without touching the network or throwing.
//
// The HTTP/2 transport is a seam so tests assert the exact request shape
// (`:method`, `:path`, `apns-topic`, `authorization`, body) without ever reaching
// Apple. The default transport opens a short-lived session per send; APNs pushes
// are human-scale (attention events), so connection pooling is not worth the
// complexity for v1.

/** Generic fallback shown when the encrypted payload cannot be surfaced. */
export const GENERIC_ALERT = 'An agent needs your attention.';

export interface Http2Response {
  status: number;
  headers: Record<string, string | string[] | undefined>;
  body: string;
}

export interface Http2Transport {
  request(opts: {
    authority: string;
    headers: Record<string, string | number>;
    body: string;
  }): Promise<Http2Response>;
}

export interface ApnsSendResult {
  accepted: boolean;
  status: number;
  reason?: string;
}

/** Default transport: one node:http2 session per request, closed after the reply. */
export function defaultHttp2Transport(): Http2Transport {
  return {
    request({ authority, headers, body }) {
      return new Promise<Http2Response>((resolve, reject) => {
        const session = connect(authority);
        session.on('error', reject);
        const req = session.request({ ...headers });
        let status = 0;
        const chunks: Buffer[] = [];
        const responseHeaders: Record<string, string | string[] | undefined> = {};
        req.on('response', (h) => {
          status = Number(h[':status'] ?? 0);
          for (const [k, v] of Object.entries(h)) {
            responseHeaders[k] = v as string | string[] | undefined;
          }
        });
        req.on('data', (chunk: Buffer) => chunks.push(chunk));
        req.on('end', () => {
          session.close();
          resolve({
            status,
            headers: responseHeaders,
            body: Buffer.concat(chunks).toString('utf8'),
          });
        });
        req.on('error', (error) => {
          session.close();
          reject(error);
        });
        req.end(body);
      });
    },
  };
}

/** Provider tokens are valid up to 60 min; refresh a little early. */
const TOKEN_TTL_MS = 50 * 60 * 1000;

export class ApnsClient {
  private cachedToken?: { jwt: string; issuedAt: number };

  constructor(
    private readonly config: ApnsConfig | undefined,
    private readonly logger: Logger,
    private readonly transport: Http2Transport = defaultHttp2Transport(),
    private readonly now: () => number = Date.now,
  ) {}

  get isEnabled(): boolean {
    return this.config !== undefined;
  }

  private providerToken(config: ApnsConfig): string {
    const nowMs = this.now();
    if (
      this.cachedToken &&
      nowMs - this.cachedToken.issuedAt < TOKEN_TTL_MS
    ) {
      return this.cachedToken.jwt;
    }
    const iat = Math.floor(nowMs / 1000);
    const jwt = signJwtES256(
      { iss: config.teamId, iat },
      config.keyId,
      config.keyP8,
    );
    this.cachedToken = { jwt, issuedAt: nowMs };
    return jwt;
  }

  /**
   * Send an alert push carrying `sealedPayload` (E2E, decrypted in the iOS NSE).
   * A disabled client logs and returns `{accepted:false, status:0}` — never throws
   * for being unconfigured. Network/transport failures reject to the caller.
   */
  async send(deviceToken: string, sealedPayload: string): Promise<ApnsSendResult> {
    if (!this.config) {
      this.logger.info('apns disabled: dropping wake', { deviceToken: redact(deviceToken) });
      return { accepted: false, status: 0, reason: 'apns_disabled' };
    }
    const jwt = this.providerToken(this.config);
    const body = JSON.stringify({
      aps: {
        alert: { body: GENERIC_ALERT },
        sound: 'default',
        'mutable-content': 1,
      },
      sealed: sealedPayload,
    });
    const response = await this.transport.request({
      authority: `https://${this.config.host}`,
      headers: {
        ':method': 'POST',
        ':path': `/3/device/${deviceToken}`,
        'apns-topic': this.config.topic,
        'apns-push-type': 'alert',
        authorization: `bearer ${jwt}`,
        'content-type': 'application/json',
      },
      body,
    });
    const accepted = response.status === 200;
    const reason = accepted ? undefined : apnsReason(response.body);
    if (!accepted) {
      this.logger.warn('apns rejected wake', { status: response.status, reason });
    }
    return { accepted, status: response.status, ...(reason ? { reason } : {}) };
  }
}

function apnsReason(body: string): string | undefined {
  try {
    const parsed = JSON.parse(body) as { reason?: string };
    return typeof parsed.reason === 'string' ? parsed.reason : undefined;
  } catch {
    return undefined;
  }
}

function redact(token: string): string {
  return token.length <= 8 ? '***' : `${token.slice(0, 6)}…`;
}
