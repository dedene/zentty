import ExpoModulesCore

/// Writes the push-seal X25519 key material into the App Group `UserDefaults`
/// suite that the Notification Service Extension reads to unseal wake banners
/// offline. The suite id and storage key must stay in sync with
/// `plugins/notification-service/NotificationService.swift`
/// (`NotificationService.appGroupId` / `KeyMaterial.storageKey`), and the JSON
/// shape with `KeyMaterial.load` there / `buildPushKeyMaterial` in
/// src/core/pushKeyMaterial.ts.
public class PushKeyMirrorModule: Module {
  private static let appGroupId = "group.be.zenjoy.zentty.mobile"
  private static let storageKey = "zentty.push.keyMaterial"

  public func definition() -> ModuleDefinition {
    Name("PushKeyMirror")

    /// Full-replace mirror: `json` is the serialized key-material blob; `nil`
    /// removes it entirely (no Macs paired — the NSE keeps generic banners).
    Function("setKeyMaterial") { (json: String?) in
      guard let defaults = UserDefaults(suiteName: Self.appGroupId) else {
        return
      }
      if let json {
        defaults.set(json, forKey: Self.storageKey)
      } else {
        defaults.removeObject(forKey: Self.storageKey)
      }
    }
  }
}
