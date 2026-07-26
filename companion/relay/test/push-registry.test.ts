import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import { PushRegistry } from '../src/push/registry.js';

const dirs: string[] = [];
function tmpFile(name = 'store.json'): string {
  const dir = mkdtempSync(join(tmpdir(), 'zentty-push-'));
  dirs.push(dir);
  return join(dir, name);
}

afterEach(() => {
  for (const dir of dirs.splice(0)) {
    rmSync(dir, { recursive: true, force: true });
  }
});

describe('PushRegistry (in-memory)', () => {
  it('registers and looks up candidate macs by phone/token/platform', () => {
    const reg = PushRegistry.open();
    reg.register({
      macDeviceId: 'mac-A',
      phoneDeviceId: 'phone-1',
      platform: 'apns',
      token: 'tok-1',
    });
    reg.register({
      macDeviceId: 'mac-B',
      phoneDeviceId: 'phone-1',
      platform: 'apns',
      token: 'tok-1',
    });
    // Different token / platform must not match.
    reg.register({
      macDeviceId: 'mac-C',
      phoneDeviceId: 'phone-1',
      platform: 'fcm',
      token: 'tok-1',
    });

    expect(reg.macsForWake('phone-1', 'tok-1', 'apns').sort()).toEqual([
      'mac-A',
      'mac-B',
    ]);
    expect(reg.macsForWake('phone-1', 'tok-1', 'fcm')).toEqual(['mac-C']);
    expect(reg.macsForWake('phone-1', 'other', 'apns')).toEqual([]);
    expect(reg.macsForWake('phone-2', 'tok-1', 'apns')).toEqual([]);
  });

  it('upserts a re-registration for the same pairing', () => {
    const reg = PushRegistry.open();
    reg.register({
      macDeviceId: 'mac-A',
      phoneDeviceId: 'phone-1',
      platform: 'apns',
      token: 'old',
    });
    reg.register({
      macDeviceId: 'mac-A',
      phoneDeviceId: 'phone-1',
      platform: 'apns',
      token: 'new',
    });
    expect(reg.size()).toBe(1);
    expect(reg.macsForWake('phone-1', 'old', 'apns')).toEqual([]);
    expect(reg.macsForWake('phone-1', 'new', 'apns')).toEqual(['mac-A']);
  });
});

describe('PushRegistry (persisted)', () => {
  it('persists registrations across reopen', () => {
    const path = tmpFile();
    const first = PushRegistry.open(path);
    first.register({
      macDeviceId: 'mac-A',
      phoneDeviceId: 'phone-1',
      platform: 'fcm',
      token: 'tok-1',
    });

    const stored = JSON.parse(readFileSync(path, 'utf8'));
    expect(stored.version).toBe(1);
    expect(stored.registrations).toHaveLength(1);

    const reopened = PushRegistry.open(path);
    expect(reopened.macsForWake('phone-1', 'tok-1', 'fcm')).toEqual(['mac-A']);
  });

  it('starts empty when the file does not exist yet', () => {
    const reg = PushRegistry.open(tmpFile('does-not-exist.json'));
    expect(reg.size()).toBe(0);
  });

  it('rejects a malformed store file', () => {
    const path = tmpFile();
    writeFileSync(path, JSON.stringify({ version: 99 }), 'utf8');
    expect(() => PushRegistry.open(path)).toThrow(/format/);
  });
});
