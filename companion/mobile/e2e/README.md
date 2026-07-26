# Mobile companion E2E harness

Dev tooling for exercising the Zentty mobile app against a **real, non-mocked
server** — no live Mac required. The centrepiece is `fake-mac.ts`, a Node
stand-in for the Mac bridge that speaks the exact wire contract by **reusing the
app's own crypto core** (`../src/core`) with `role: 'mac'`.

## fake-mac.ts

Impersonates the Mac side of pairing + an encrypted session on a LAN WebSocket:

- Mints an Ed25519 Mac identity and a pairing offer, and prints the offer JSON to
  stdout. That printed string is exactly what the app's **manual-entry** field
  accepts (`scan.tsx` → `parsePairingOffer` → `PairingOffer.parse(JSON.parse(x))`),
  and is also what a QR would encode.
- Serves `ws://0.0.0.0:8787`. Each phone connection is dispatched by its first
  frame:
  - `pairing.request` envelope → verifies the HMAC proof, replies `pairing.confirm`
    (`macName: "Fake Mac"`).
  - bare handshake frame `{deviceId, ephemeralPublicKey}` → runs the
    X25519/Ed25519 handshake (role `mac`), exchanges sealed `session.hello` /
    `session.ready`, answers `dashboard.subscribe` with a scripted
    `dashboard.snapshot`, then after 10s pushes a `dashboard.delta` that flips the
    Claude pane from a pending approval to `running`.

### Scripted dashboard

- Worklane **zentty** (attention):
  - **Claude Code** — `needsInput`, `approval`, requires attention, taskProgress 3/7.
  - **codex** — `running`.
- Worklane **side-project**:
  - **zsh** — `idle` shell pane.

After 10s a delta flips **Claude Code** to `running` and clears its attention, so
a live UI update is observable.

### Run it

```sh
cd companion/mobile
node_modules/.bin/tsx e2e/fake-mac.ts
# or: pnpm --filter @zentty/mobile exec tsx e2e/fake-mac.ts
```

Copy the printed pairing-code JSON and paste it into the app's
**Enter code instead** field. The simulator shares the Mac's network, so the
offer's `127.0.0.1:8787` LAN hint resolves directly (relay is left empty).

## Notes

- `fake-mac.ts` intentionally imports only the wire-free core modules
  (`crypto`, `hkdf`, `base64url`, `sodium`) so it needs no `@zentty/wire` build.
- Requires the `ws`, `tsx`, and `libsodium-wrappers` dev dependencies (already in
  `package.json`).
- The offer TTL is 10 minutes (vs. the Mac's short-lived codes) so an E2E run has
  time to paste and connect.
