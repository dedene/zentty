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
import type { LeaseRevokedReason, ParsedMessage, TranscriptEntry, TranscriptUnavailableReason } from '@zentty/wire';

import {
  Backoff,
  ConnectionManager,
  PhoneSession,
  PushRegistrar,
  type ActiveTransport,
  type BackoffOptions,
  type ConnectionStatus,
  type PairedMac,
  type PhoneDeviceIdentity,
  type PushRegistrationState,
  type PushToken,
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
import type { PaneTextFrame } from './paneText';
import { PaneController, type PaneRuntimeState, type PaneTransport } from './paneController';

/** Serializable per-Mac state the store holds and screens render. */
export interface MacConnectionState {
  status: ConnState;
  /** Which transport carried the current/last connection. */
  transport?: 'direct' | 'relay';
  /** Relay-reported peer presence (Mac reachable), when known. */
  peerOnline?: boolean;
  worklanes: Worklane[];
  /** Live per-pane runtime (terminal text, lease, transcript), keyed by paneId. */
  panes: Record<string, PaneRuntimeState>;
  /** ms-epoch of the last successful connect. */
  lastConnectedAt?: number;
  /** ms-epoch of the last snapshot/delta applied. */
  lastSnapshotAt?: number;
  /** What this phone last registered with the Mac for push, if anything. */
  pushRegistration?: PushRegistrationState;
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
  /** Exponential-backoff config for session-drop reconnects. Default: Backoff defaults. */
  reconnectBackoff?: BackoffOptions;
  /** A session that stays ready at least this long resets the reconnect backoff. Default 30000ms. */
  sessionUpThresholdMs?: number;
  /** Injectable clock for measuring session uptime (tests). Default Date.now. */
  now?: () => number;
  /** Seed the model with cached worklanes (e.g. from a prior session). */
  initialWorklanes?: Worklane[];
  /** Current native push token, read on every session-ready to register with the Mac. */
  pushToken?: () => PushToken | undefined;
}

/** A session that stays ready at least this long is treated as healthy, resetting backoff. */
const DEFAULT_SESSION_UP_THRESHOLD_MS = 30_000;

export class MacConnection {
  private readonly deps: MacConnectionDeps;
  private readonly delay: (ms: number) => Promise<void>;
  private readonly now: () => number;
  private readonly reconnectBackoff: Backoff;
  private readonly sessionUpThresholdMs: number;
  /** ms-epoch the current session reached `ready`, or undefined if it never did. */
  private sessionReadyAt?: number;
  private manager?: ConnectionManager;
  private session?: PhoneSession;
  private running = false;
  private stopped = false;
  private worklanes: Worklane[];
  private readonly panes = new Map<string, PaneController>();
  /** Stable transport seam handed to every {@link PaneController}; reads the
   * current session on each call so a reconnect is transparent. */
  private readonly paneTransport: PaneTransport;
  private readonly registrar: PushRegistrar;
  state: MacConnectionState;

  constructor(deps: MacConnectionDeps) {
    this.deps = deps;
    this.delay = deps.delay ?? ((ms) => new Promise((r) => setTimeout(r, ms)));
    this.now = deps.now ?? Date.now;
    this.reconnectBackoff = new Backoff(deps.reconnectBackoff);
    this.sessionUpThresholdMs = deps.sessionUpThresholdMs ?? DEFAULT_SESSION_UP_THRESHOLD_MS;
    this.worklanes = deps.initialWorklanes ?? [];
    this.registrar = new PushRegistrar(deps.identity.deviceId);
    this.state = { status: 'connecting', worklanes: this.worklanes, panes: {} };
    this.paneTransport = {
      send: (type, payload) => {
        if (this.session?.state === 'ready') {
          this.session.send(type, payload);
        }
      },
      request: (type, payload) => {
        if (this.session?.state !== 'ready') {
          return Promise.reject(new Error('session not ready'));
        }
        return this.session.request(type, payload);
      },
      isReady: () => this.session?.state === 'ready',
    };
  }

  /** Get (or lazily create) the runtime controller for a pane. */
  paneController(paneId: string): PaneController {
    let controller = this.panes.get(paneId);
    if (!controller) {
      controller = new PaneController(paneId, this.paneTransport, (state) => {
        this.emit({ panes: { ...this.state.panes, [paneId]: state } });
      });
      this.panes.set(paneId, controller);
      this.emit({ panes: { ...this.state.panes, [paneId]: controller.state } });
    }
    return controller;
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

  /**
   * Send this phone's current push token to the Mac when it first arrives or
   * rotates while a session is already live. Only sends when the token changed;
   * the session-ready path re-registers unconditionally.
   */
  registerPush(): void {
    this.sendRegistration(this.registrar.registerIfChanged.bind(this.registrar));
  }

  private sendRegistration(
    apply: (session: { send: (type: string, payload: unknown) => void }, token: PushToken | undefined) => PushRegistrationState | undefined,
  ): void {
    if (this.session?.state !== 'ready') {
      return;
    }
    const session = this.session;
    const registration = apply({ send: (t, p) => session.send(t, p) }, this.deps.pushToken?.());
    if (registration) {
      this.emit({ pushRegistration: registration });
    }
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
    for (const controller of this.panes.values()) {
      controller.dispose();
    }
  }

  private async runLoop(): Promise<void> {
    while (!this.stopped) {
      const openers = makeTransportOpeners({
        identity: this.deps.identity,
        sodium: this.deps.sodium,
        macDeviceId: this.deps.mac.macDeviceId,
        onPeerStatus: (online) => this.onPeerStatus(online),
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

      this.sessionReadyAt = undefined;
      await this.runSession(active);

      if (this.stopped) {
        break;
      }
      this.emit({ status: 'offline' });
      // A session that stayed ready past the threshold was healthy; a fresh drop
      // shouldn't inherit accumulated backoff. Otherwise back off exponentially so
      // a Mac that accepts + handshakes then instantly drops can't trigger a storm.
      const uptime =
        this.sessionReadyAt !== undefined ? this.now() - this.sessionReadyAt : 0;
      if (uptime >= this.sessionUpThresholdMs) {
        this.reconnectBackoff.reset();
      }
      await this.delay(this.reconnectBackoff.next());
    }
    this.running = false;
  }

  /** Relay-reported peer presence. If the Mac goes unreachable while a session is
   * still mid-handshake (not yet ready), abort it so the run loop reconnects with
   * backoff instead of hanging on a dead peer until the handshake timeout. */
  private onPeerStatus(online: boolean): void {
    this.emit({ peerOnline: online });
    if (!online && this.session && this.session.state !== 'ready') {
      this.session.close();
    }
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
          this.sessionReadyAt = this.now();
          // The Mac answers a subscribe with a fresh dashboard.snapshot, then
          // streams dashboard.delta frames (both routed via onMessage).
          session.send('dashboard.subscribe', {});
          // Hand the Mac this phone's push token (if any) so it can register with
          // the gateway. A fresh session means the Mac lost its in-memory binding,
          // so always re-send. A no-op when push is unavailable; foreground updates
          // still flow over this same session.
          this.sendRegistration(this.registrar.register.bind(this.registrar));
          // Re-issue any pane watches/transcript subscriptions from before a drop.
          for (const controller of this.panes.values()) {
            controller.resync();
          }
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
    } else if (message.type === 'pane.text') {
      const payload = message.payload as PaneTextFrame;
      this.panes.get(payload.paneId)?.onPaneText(payload);
    } else if (message.type === 'lease.revoked') {
      const payload = message.payload as { leaseId: string; reason: LeaseRevokedReason };
      // A revoked frame carries no paneId; the holder recognizes its own leaseId.
      for (const controller of this.panes.values()) {
        controller.handleLeaseRevoked(payload.leaseId, payload.reason);
      }
    } else if (message.type === 'transcript.delta') {
      const payload = message.payload as { paneId: string; entries: TranscriptEntry[] };
      this.panes.get(payload.paneId)?.onTranscriptDelta(payload);
    } else if (message.type === 'transcript.unavailable') {
      const payload = message.payload as { paneId: string; reason: TranscriptUnavailableReason };
      this.panes.get(payload.paneId)?.onTranscriptUnavailable(payload.reason);
    }
  }

  private emit(patch: Partial<MacConnectionState>): void {
    this.state = { ...this.state, ...patch };
    this.deps.onChange(this.state);
  }
}
