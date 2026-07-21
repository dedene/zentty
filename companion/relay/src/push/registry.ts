import { mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';
import type { PushPlatform } from '@zentty/wire';

// Push token registry: maps a (macDeviceId, phoneDeviceId) pairing to the phone's
// current {platform, token}. Registration is Mac-authenticated at the gateway (see
// gateway.ts); this module only stores and looks up.
//
// Persistence is an optional JSON file. With no path it stays in memory — the
// default for tests and for a relay that has not been told where to persist. When
// a path is given, every mutation is written atomically (temp file + rename) so a
// crash mid-write cannot corrupt the store.

export interface Registration {
  macDeviceId: string;
  phoneDeviceId: string;
  platform: PushPlatform;
  token: string;
}

interface StoreFile {
  version: 1;
  registrations: Registration[];
}

function pairKey(macDeviceId: string, phoneDeviceId: string): string {
  // deviceIds are base64url (no '\n'), so this join is unambiguous.
  return `${macDeviceId}\n${phoneDeviceId}`;
}

export class PushRegistry {
  private readonly byPair = new Map<string, Registration>();

  private constructor(private readonly filePath?: string) {}

  /** Load a registry, reading `filePath` if provided and present. Never throws on a
   * missing file; a malformed file is a hard error the operator must resolve. */
  static open(filePath?: string): PushRegistry {
    const registry = new PushRegistry(filePath);
    if (filePath !== undefined) {
      registry.load();
    }
    return registry;
  }

  private load(): void {
    let raw: string;
    try {
      raw = readFileSync(this.filePath as string, 'utf8');
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === 'ENOENT') {
        return; // first run: empty registry
      }
      throw error;
    }
    const parsed = JSON.parse(raw) as StoreFile;
    if (parsed.version !== 1 || !Array.isArray(parsed.registrations)) {
      throw new Error('push token store: unrecognized format');
    }
    for (const reg of parsed.registrations) {
      this.byPair.set(pairKey(reg.macDeviceId, reg.phoneDeviceId), reg);
    }
  }

  private persist(): void {
    if (this.filePath === undefined) {
      return;
    }
    const data: StoreFile = {
      version: 1,
      registrations: [...this.byPair.values()],
    };
    const dir = dirname(this.filePath);
    mkdirSync(dir, { recursive: true });
    const tmp = `${this.filePath}.tmp`;
    writeFileSync(tmp, JSON.stringify(data, null, 2), 'utf8');
    renameSync(tmp, this.filePath);
  }

  /** Upsert a phone's token for a pairing (a re-register replaces platform/token). */
  register(reg: Registration): void {
    this.byPair.set(pairKey(reg.macDeviceId, reg.phoneDeviceId), reg);
    this.persist();
  }

  /**
   * Candidate mac device ids paired to (`phoneDeviceId`, `token`, `platform`).
   * A wake request carries only the phone side; the gateway verifies the Mac
   * signature against each returned id. Usually one, but a phone can be paired to
   * several Macs with the same token.
   */
  macsForWake(
    phoneDeviceId: string,
    token: string,
    platform: PushPlatform,
  ): string[] {
    const out: string[] = [];
    for (const reg of this.byPair.values()) {
      if (
        reg.phoneDeviceId === phoneDeviceId &&
        reg.token === token &&
        reg.platform === platform
      ) {
        out.push(reg.macDeviceId);
      }
    }
    return out;
  }

  /** Total stored registrations (diagnostics/tests). */
  size(): number {
    return this.byPair.size;
  }
}
