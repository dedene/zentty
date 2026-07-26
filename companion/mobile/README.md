# Zentty Mobile Companion

Expo / React Native companion app for [Zentty](../../README.md): pair with Zentty
running on your Mac (QR code or pasted code), then see live terminal panes and
agent status on your phone, with push wake notifications.

Part of the pnpm workspace rooted at `companion/` (with `@zentty/wire` and
`@zentty/relay`). Run commands from this directory unless noted.

## Commands

```bash
pnpm install      # from companion/ (workspace root)
pnpm typecheck    # tsc --noEmit
pnpm test         # jest
pnpm start        # expo start (dev client required; not Expo Go)
```

## Native module

`modules/push-key-mirror` is a local Expo module (autolinked) that mirrors
push-seal key material into the iOS App Group so the Notification Service
Extension can unseal wake banners. After any native-affecting change (native
module code, app.json plugins/entitlements, native deps), regenerate the native
projects:

```bash
npx expo prebuild
cd ios && pod install
```
