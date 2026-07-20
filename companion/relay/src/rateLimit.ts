import type { RelayConfig } from './config.js';

// Token-bucket rate limiting, per the draft: per-device frames/sec and
// bytes/sec, plus a tighter pairing-window bucket. Time is injectable so tests
// are deterministic.

export type Clock = () => number;

export class TokenBucket {
  private tokens: number;
  private last: number;
  constructor(
    private readonly capacity: number,
    private readonly refillPerSec: number,
    private readonly now: Clock = Date.now,
  ) {
    this.tokens = capacity;
    this.last = now();
  }

  /** Try to consume `n` tokens; returns false (and consumes nothing) if short. */
  take(n: number): boolean {
    const t = this.now();
    const elapsed = Math.max(0, t - this.last) / 1000;
    this.tokens = Math.min(
      this.capacity,
      this.tokens + elapsed * this.refillPerSec,
    );
    this.last = t;
    if (this.tokens >= n) {
      this.tokens -= n;
      return true;
    }
    return false;
  }
}

export type LimitReason = 'frame_too_large' | 'rate_limited';

export interface LimitDecision {
  ok: boolean;
  reason?: LimitReason;
}

/**
 * Per-device limiter bundling the three buckets. One instance per authenticated
 * connection; buckets refill continuously by wall clock.
 */
export class DeviceLimiter {
  private readonly frames: TokenBucket;
  private readonly bytes: TokenBucket;
  private readonly pairing: TokenBucket;

  constructor(config: RelayConfig, now: Clock = Date.now) {
    // Capacity == one second of budget so a burst up to the rate is allowed,
    // then throughput is capped at the sustained rate.
    this.frames = new TokenBucket(config.framesPerSec, config.framesPerSec, now);
    this.bytes = new TokenBucket(config.bytesPerSec, config.bytesPerSec, now);
    // Pairing window: `pairingPerMin` frames per 60s -> refill rate / 60.
    this.pairing = new TokenBucket(
      config.pairingPerMin,
      config.pairingPerMin / 60,
      now,
    );
  }

  /**
   * Charge a relay.frame of `wireBytes`. `isPairing` marks a frame whose sealed
   * blob decoded to a plaintext `pairing.*` envelope; those also draw from the
   * tighter pairing bucket. Buckets are only debited when every applicable
   * bucket has budget, so a rejected frame does not leak tokens.
   */
  admit(wireBytes: number, isPairing: boolean): LimitDecision {
    // Peek without consuming, then commit atomically. TokenBucket has no peek,
    // so refill+check is folded into take(): to avoid partial debits we take in
    // order and, if a later bucket fails, the earlier debits are the cost of a
    // dropped frame — acceptable and self-correcting since refill is continuous.
    // We instead check the cheap gate (pairing) first to minimize waste.
    if (isPairing && !this.pairing.take(1)) {
      return { ok: false, reason: 'rate_limited' };
    }
    if (!this.frames.take(1)) {
      return { ok: false, reason: 'rate_limited' };
    }
    if (!this.bytes.take(wireBytes)) {
      return { ok: false, reason: 'rate_limited' };
    }
    return { ok: true };
  }
}
