# @zentty/relay

Zero-knowledge WebSocket relay **and** push gateway for the Zentty mobile
companion, in one deployable. The relay forwards opaque end-to-end-encrypted
frames between paired devices (it never sees plaintext); the push gateway wakes a
phone through APNs/FCM when its Mac signs a wake request.

Both live in the same Node service and the same HTTP server:

| Path        | Method | Who    | Purpose                                                   |
|-------------|--------|--------|-----------------------------------------------------------|
| `/healthz`  | GET    | infra  | Liveness probe.                                           |
| `/register` | POST   | Mac    | Register a phone's push token for a pairing (Mac-signed). |
| `/wake`     | POST   | Mac    | Wake a paired phone via APNs/FCM (Mac-signed).            |
| WebSocket   | —      | device | Relay transport (challenge → auth → frame routing).       |

## Push is optional — no keys, no problem

The gateway is **config-gated**. With no APNs and no FCM credentials set, both
platforms report disabled: `/wake` returns `503 platform_unconfigured` and the
service logs a no-op instead of trying to reach Apple/Google. **The relay itself
is unaffected** — pairing, session forwarding, and live dashboard/pane updates
keep working, so a foregrounded app still gets everything in real time. Push only
adds the *background wake*. This is the intended self-host default: run the Docker
image with zero push env and you have a working relay; supply your own APNs/FCM
keys later to light up background notifications.

## Signing contract

`/register` and `/wake` bodies are Ed25519-signed by the Mac's device identity
key. `deviceId` values are `base64url(pubkey)`, so the gateway derives the
verifying key from the id it already knows for the pairing. The exact bytes signed
are defined once in `@zentty/wire` (`pushRegisterSigningString`,
`pushWakeSigningString`) — the Mac signer and this verifier share that definition
so they cannot drift. `/wake` carries only the phone side; the gateway looks up
every Mac paired to `(deviceId, token, platform)` and accepts if any candidate
key verifies the signature.

Status codes: `202` wake accepted · `200` registered · `400` bad body · `401`
signature failed · `404` no matching registration · `429` per-device rate limit ·
`502` APNs/FCM rejected the push · `503` that platform is unconfigured.

## Configuration

All configuration is environment-driven; every knob has a safe default.

### Relay transport

| Env                              | Default    | Meaning                                  |
|----------------------------------|------------|------------------------------------------|
| `PORT`                           | `8080`     | HTTP/WebSocket listener port.            |
| `RATE_FRAMES_PER_SEC`            | `50`       | Per-device sustained frame rate.         |
| `RATE_BYTES_PER_SEC`             | `262144`   | Per-device sustained byte rate.          |
| `RATE_PAIRING_PER_MIN`           | `5`        | Per-device pairing-frame window.         |
| `RATE_MAX_FRAME_BYTES`           | `262144`   | Hard per-frame size cap.                 |
| `RATE_MAX_PAIRING_SEALED_BYTES`  | `4096`     | Hard cap on a plaintext pairing payload. |
| `LOG_LEVEL`                      | `info`     | `debug\|info\|warn\|error\|silent`.      |

### Push gateway (all optional)

| Env                        | Default                        | Meaning                                                   |
|----------------------------|--------------------------------|-----------------------------------------------------------|
| `APNS_KEY_P8`              | —                              | APNs auth key: a file path **or** an inline `.p8` PEM.    |
| `APNS_KEY_ID`              | —                              | APNs key id (10 chars).                                   |
| `APNS_TEAM_ID`             | —                              | Apple Developer team id.                                  |
| `APNS_TOPIC`               | `be.zenjoy.zentty.mobile`      | APNs topic == the iOS bundle id.                          |
| `APNS_HOST`                | `api.push.apple.com`           | Use `api.sandbox.push.apple.com` for debug builds.        |
| `FCM_SERVICE_ACCOUNT_JSON` | —                              | FCM service account: a file path **or** inline JSON.      |
| `PUSH_TOKEN_STORE`         | — (in-memory)                  | JSON token-store path; omit to keep the registry in RAM.  |
| `PUSH_RATE_BURST`          | `5`                            | Per-device immediate wake burst.                          |
| `PUSH_RATE_PER_MIN`        | `10`                           | Per-device sustained wakes per minute.                    |

APNs is enabled only when **all** of `APNS_KEY_P8`, `APNS_KEY_ID`, `APNS_TEAM_ID`
are set; a partial set is a loud startup error, never a silent half-enable. FCM is
enabled when `FCM_SERVICE_ACCOUNT_JSON` is set and parses.

No `apn`, `firebase-admin`, or other push SDK is used: APNs speaks HTTP/2 via
`node:http2` with an ES256 provider JWT; FCM uses HTTP v1 via `node:https` with an
RS256 service-account OAuth2 token. Both build their credentials with `node:crypto`
only.

## Develop

```
pnpm --filter @zentty/relay typecheck
pnpm --filter @zentty/relay test
```

Push tests generate throwaway EC/RSA/Ed25519 keys and inject the HTTP/2 and HTTPS
transports as seams — they assert the exact request shape and never contact Apple
or Google.

## Run

```
# self-host, push disabled (relay only)
docker build -f relay/Dockerfile -t zentty-relay .
docker run -p 8080:8080 zentty-relay

# with push enabled
docker run -p 8080:8080 \
  -e APNS_KEY_P8=/keys/AuthKey.p8 -e APNS_KEY_ID=XXXXXXXXXX -e APNS_TEAM_ID=YYYYYYYYYY \
  -e FCM_SERVICE_ACCOUNT_JSON=/keys/fcm.json \
  -e PUSH_TOKEN_STORE=/data/push-tokens.json \
  -v /path/to/keys:/keys:ro -v /path/to/data:/data \
  zentty-relay
```
