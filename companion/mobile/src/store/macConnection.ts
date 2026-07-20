/**
 * Per-Mac connection controller: owns the {@link ConnectionManager} +
 * {@link PhoneSession} lifecycle for one paired Mac, keeps a live worklane/pane
 * model from `dashboard.*` frames, and pushes a plain serializable state snapshot
 * to the store on every change.
 *
 * The controller lives outside React/zustand state (it holds sockets and crypto);
 * only its {@link MacConnectionState} snapshot enters the store, so components
 * re-render on data, not on the machinery.
 */
import type { ParsedMessage } from '@zentty/wire';

import {
  ConnectionManager,
  PhoneSession,
  type ActiveTransport,
  type ConnectionStatus,
  type PairedMac,
  type PhoneDeviceIdentity,
  type SessionState,
  type SodiumLike,
} from '@/core';
import { makeTransportOpeners } from '@/runtime/transports';

import {
  applyDelta,
  applySnapshot,
  type ConnState,
  type DashboardDeltaPayload,
  type DashboardSnapshotPayload,
  type Worklane,
} from './dashboard';

/** Serializable per-Mac state the store holds and screens render. */
export interface MacConnectionState {
  status: ConnState;
  /** Which transport carried the current/last connection. */
  transport?: 'direct' | 'relay';
  /** Relay-reported peer presence (Mac reachable), when known. */
  peerOnline?: boolean;
  worklanes: Worklane[];
  /** ms-epoch of the last successful connect. */
  lastConnectedAt?: number;
  /** ms-epoch of the last snapshot/delta applied. */
  lastSnapshotAt?: number;
}

export interface MacConnectionDeps {
  mac: PairedMac;
  identity: PhoneDeviceIdentity;
  sodium: SodiumLike;
  deviceName: string;
  appVersion: string;
  onChange: (state: MacConnectionState) => void;
  /** Injectable sleep for reconnect pacing (tests). */
  delay?: (ms: number) => Promise<void>;
  /** Pause before reconnecting after a session drop. Default 1500ms. */
  reconnectDelayMs?: number;
  /** Seed the model with cached worklanes (e.g. from a prior session). */
  initialWorklanes?: Worklane[];
}

export class MacConnection {
  private readonly deps: MacConnectionDeps;
  private readonly delay: (ms: number) => Promise<void>;
  private manager?: ConnectionManager;
  private session?: PhoneSession;
  private running = false;
  private stopped = false;
  private worklanes: Worklane[];
  state: MacConnectionState;

  constructor(deps: MacConnectionDeps) {
    this.deps = deps;
    this.delay = deps.delay ?? ((ms) => new Promise((r) => setTimeout(r, ms)));
    this.worklanes = deps.initialWorklanes ?? [];
    this.state = { status: 'connecting', worklanes: this.worklanes };
  }

  /** Start (or restart) the connect/session loop. Idempotent while running. */
  start(): void {
    if (this.running) {
      return;
    }
    this.running = true;
    this.stopped = false;
    void this.runLoop();
  }

  /** Force a reconnect (pull-to-refresh): drop the live session, keep cached data. */
  refresh(): void {
    if (!this.running) {
      this.start();
      return;
    }
    this.session?.close();
  }

  /** Tear down permanently: no further reconnects. */
  stop(): void {
    this.stopped = true;
    this.running = false;
    this.manager?.stop();
    this.session?.close();
  }

  private async runLoop(): Promise<void> {
    while (!this.stopped) {
      const openers = makeTransportOpeners({
        identity: this.deps.identity,
        sodium: this.deps.sodium,
        macDeviceId: this.deps.mac.macDeviceId,
        onPeerStatus: (online) => this.emit({ peerOnline: online }),
      });
      this.manager = new ConnectionManager({
        mac: this.deps.mac,
        openDirect: openers.openDirect,
        openRelay: openers.openRelay,
        onStatus: (status) => this.onManagerStatus(status),
      });

      let active: ActiveTransport;
      try {
        active = await this.manager.connectWithRetry();
      } catch {
        break; // stopped mid-retry
      }
      if (this.stopped) {
        active.transport.close();
        break;
      }

      await this.runSession(active);

      if (this.stopped) {
        break;
      }
      this.emit({ status: 'offline' });
      await this.delay(this.deps.reconnectDelayMs ?? 1500);
    }
    this.running = false;
  }

  private onManagerStatus(status: ConnectionStatus): void {
    if (status.state === 'connected') {
      this.emit({ status: 'connected', transport: status.transport, lastConnectedAt: Date.now() });
    } else if (status.state === 'connecting') {
      this.emit({ status: 'connecting' });
    } else {
      this.emit({ status: 'offline' });
    }
  }

  private runSession(active: ActiveTransport): Promise<void> {
    return new Promise<void>((resolve) => {
      const session = new PhoneSession({
        transport: active.transport,
        identity: this.deps.identity,
        mac: this.deps.mac,
        sodium: this.deps.sodium,
        deviceName: this.deps.deviceName,
        appVersion: this.deps.appVersion,
        onMessage: (message) => this.onMessage(message),
        onStateChange: (sessionState: SessionState) => {
          if (sessionState === 'closed') {
            resolve();
          }
        },
      });
      this.session = session;
      session
        .connect()
        .then(() => {
          // The Mac answers a subscribe with a fresh dashboard.snapshot, then
          // streams dashboard.delta frames (both routed via onMessage).
          session.send('dashboard.subscribe', {});
        })
        .catch(() => {
          session.close();
        });
    });
  }

  private onMessage(message: ParsedMessage): void {
    if (message.type === 'dashboard.snapshot') {
      this.worklanes = applySnapshot(message.payload as DashboardSnapshotPayload);
      this.emit({ worklanes: this.worklanes, lastSnapshotAt: Date.now() });
    } else if (message.type === 'dashboard.delta') {
      this.worklanes = applyDelta(this.worklanes, message.payload as DashboardDeltaPayload);
      this.emit({ worklanes: this.worklanes, lastSnapshotAt: Date.now() });
    }
  }

  private emit(patch: Partial<MacConnectionState>): void {
    this.state = { ...this.state, ...patch };
    this.deps.onChange(this.state);
  }
}
