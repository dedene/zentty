import { request as httpsRequest } from 'node:https';
import type { FcmConfig } from '../config.js';
import type { Logger } from '../log.js';
import { signJwtRS256 } from './signing.js';
import { GENERIC_ALERT } from './apns.js';

// FCM HTTP v1 client: mint a short-lived OAuth2 access token from the service
// account (RS256 JWT bearer grant), then POST the message with that bearer. Built
// on node:https + node:crypto — no `firebase-admin` dependency. Config-gated the
// same way as APNs: unconfigured -> `isEnabled` false and `send` is a logged
// no-op that never throws.
//
// The HTTPS transport is a seam: tests assert both request shapes (the token
// exchange and the send) and inject responses, so no Google endpoint is contacted.

const FIREBASE_SCOPE = 'https://www.googleapis.com/auth/firebase.messaging';

export interface HttpsResponse {
  status: number;
  body: string;
}

export interface HttpsTransport {
  request(opts: {
    url: string;
    method: string;
    headers: Record<string, string>;
    body: string;
  }): Promise<HttpsResponse>;
}

export interface FcmSendResult {
  accepted: boolean;
  status: number;
  reason?: string;
}

/** Default transport: a single node:https request per call. */
export function defaultHttpsTransport(): HttpsTransport {
  return {
    request({ url, method, headers, body }) {
      return new Promise<HttpsResponse>((resolve, reject) => {
        const req = httpsRequest(url, { method, headers }, (res) => {
          const chunks: Buffer[] = [];
          res.on('data', (chunk: Buffer) => chunks.push(chunk));
          res.on('end', () =>
            resolve({
              status: res.statusCode ?? 0,
              body: Buffer.concat(chunks).toString('utf8'),
            }),
          );
        });
        req.on('error', reject);
        req.end(body);
      });
    },
  };
}

/** Access tokens last ~1h; refresh a little early. */
const TOKEN_TTL_MS = 50 * 60 * 1000;

export class FcmClient {
  private cachedToken?: { accessToken: string; issuedAt: number };

  constructor(
    private readonly config: FcmConfig | undefined,
    private readonly logger: Logger,
    private readonly transport: HttpsTransport = defaultHttpsTransport(),
    private readonly now: () => number = Date.now,
  ) {}

  get isEnabled(): boolean {
    return this.config !== undefined;
  }

  private async accessToken(config: FcmConfig): Promise<string> {
    const nowMs = this.now();
    if (this.cachedToken && nowMs - this.cachedToken.issuedAt < TOKEN_TTL_MS) {
      return this.cachedToken.accessToken;
    }
    const iat = Math.floor(nowMs / 1000);
    const assertion = signJwtRS256(
      {
        iss: config.clientEmail,
        scope: FIREBASE_SCOPE,
        aud: config.tokenUri,
        iat,
        exp: iat + 3600,
      },
      config.privateKey,
    );
    const form = new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion,
    }).toString();
    const response = await this.transport.request({
      url: config.tokenUri,
      method: 'POST',
      headers: { 'content-type': 'application/x-www-form-urlencoded' },
      body: form,
    });
    if (response.status !== 200) {
      throw new Error(`fcm token exchange failed: ${response.status}`);
    }
    const parsed = JSON.parse(response.body) as { access_token?: string };
    if (!parsed.access_token) {
      throw new Error('fcm token exchange returned no access_token');
    }
    this.cachedToken = { accessToken: parsed.access_token, issuedAt: nowMs };
    return parsed.access_token;
  }

  /**
   * Send a data+notification message carrying `sealedPayload` (E2E, decrypted in
   * the Android handler). Disabled -> logged no-op. Transport failures reject.
   */
  async send(token: string, sealedPayload: string): Promise<FcmSendResult> {
    if (!this.config) {
      this.logger.info('fcm disabled: dropping wake', { token: redact(token) });
      return { accepted: false, status: 0, reason: 'fcm_disabled' };
    }
    const accessToken = await this.accessToken(this.config);
    const body = JSON.stringify({
      message: {
        token,
        notification: { body: GENERIC_ALERT },
        data: { sealed: sealedPayload },
        android: { priority: 'high' },
      },
    });
    const response = await this.transport.request({
      url: `https://fcm.googleapis.com/v1/projects/${this.config.projectId}/messages:send`,
      method: 'POST',
      headers: {
        authorization: `Bearer ${accessToken}`,
        'content-type': 'application/json',
      },
      body,
    });
    const accepted = response.status === 200;
    const reason = accepted ? undefined : fcmReason(response.body);
    if (!accepted) {
      this.logger.warn('fcm rejected wake', { status: response.status, reason });
    }
    return { accepted, status: response.status, ...(reason ? { reason } : {}) };
  }
}

function fcmReason(body: string): string | undefined {
  try {
    const parsed = JSON.parse(body) as { error?: { status?: string; message?: string } };
    return parsed.error?.status ?? parsed.error?.message;
  } catch {
    return undefined;
  }
}

function redact(token: string): string {
  return token.length <= 8 ? '***' : `${token.slice(0, 6)}…`;
}
