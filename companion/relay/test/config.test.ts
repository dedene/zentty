import { describe, expect, it } from 'vitest';
import { loadConfig } from '../src/config.js';

// Config knobs are bounded so a misconfigured 0 (which would silently disable a
// protection: MAX_CONNECTIONS=0 bricks the relay, RATE_MAX_FRAME_BYTES=0 removes
// the ws maxPayload guard, RATE_FRAMES_PER_SEC=0 rejects every frame) or an
// absurd value fails loudly at startup instead of degrading quietly.

describe('loadConfig — knob bounds', () => {
  it('applies defaults with an empty env', () => {
    const config = loadConfig({});
    expect(config.framesPerSec).toBe(50);
    expect(config.maxConnections).toBe(10_000);
    expect(config.maxMessagesPerSec).toBe(250);
    expect(config.maxDeviceLimiters).toBe(10_000);
  });

  it('rejects 0 for rate/size/cap knobs that must stay >= 1', () => {
    expect(() => loadConfig({ MAX_CONNECTIONS: '0' })).toThrow(/MAX_CONNECTIONS/);
    expect(() => loadConfig({ RATE_FRAMES_PER_SEC: '0' })).toThrow(
      /RATE_FRAMES_PER_SEC/,
    );
    expect(() => loadConfig({ RATE_MAX_FRAME_BYTES: '0' })).toThrow(
      /RATE_MAX_FRAME_BYTES/,
    );
    expect(() => loadConfig({ MAX_MESSAGES_PER_SEC: '0' })).toThrow(
      /MAX_MESSAGES_PER_SEC/,
    );
    expect(() => loadConfig({ MAX_DEVICE_LIMITERS: '0' })).toThrow(
      /MAX_DEVICE_LIMITERS/,
    );
  });

  it('rejects values above the sane maximum', () => {
    expect(() => loadConfig({ MAX_CONNECTIONS: '999999999' })).toThrow(
      /out of range/,
    );
    expect(() => loadConfig({ PORT: '70000' })).toThrow(/PORT/);
  });

  it('still allows PORT=0 (OS-assigned ephemeral port)', () => {
    expect(loadConfig({ PORT: '0' }).port).toBe(0);
  });

  it('accepts in-range overrides', () => {
    const config = loadConfig({
      RATE_FRAMES_PER_SEC: '10',
      MAX_MESSAGES_PER_SEC: '500',
      MAX_DEVICE_LIMITERS: '1',
    });
    expect(config.framesPerSec).toBe(10);
    expect(config.maxMessagesPerSec).toBe(500);
    expect(config.maxDeviceLimiters).toBe(1);
  });
});
