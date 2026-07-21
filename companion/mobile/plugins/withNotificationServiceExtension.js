/**
 * Local Expo config plugin: adds an iOS Notification Service Extension (NSE) that
 * decrypts Zentty wake payloads on-device and rewrites the notification banner to
 * the real content (see plugins/notification-service/NotificationService.swift).
 *
 * Why local instead of `expo-notification-service-extension-plugin`: that package
 * (1.0.2, last touched 2025-01) pins `@expo/image-utils@^0.3.22`, far behind
 * SDK 57, and does not apply cleanly to a 57 prebuild. This plugin depends only on
 * @expo/config-plugins (57.x) and does exactly what we need — one NSE target, one
 * App Group shared between the app and the extension, no extra surface.
 *
 * What it does:
 *   1. Adds the App Group `group.<bundleId>` to the main app's entitlements.
 *   2. Copies the NSE sources (Swift + Info.plist + entitlements) into the
 *      generated `ios/<name>/` folder.
 *   3. Registers the NSE as an app-extension target, embeds it in the app, and
 *      sets its build settings (bundle id, deployment target, Swift version,
 *      Info.plist, entitlements).
 *
 * The NSE falls back to the generic alert until the app mirrors its X25519 key
 * material into the App Group (the documented keys-later follow-up), so enabling
 * this plugin is always safe: worst case the banner stays generic.
 */
const {
  withEntitlementsPlist,
  withXcodeProject,
  withDangerousMod,
} = require('@expo/config-plugins');
const fs = require('fs');
const path = require('path');

const TARGET_NAME = 'NotificationService';
const APP_GROUP = 'group.be.zenjoy.zentty.mobile';
const SOURCE_DIR = path.join(__dirname, 'notification-service');
const FILES = ['NotificationService.swift', 'Info.plist', 'NotificationService.entitlements'];
const DEPLOYMENT_TARGET = '15.1';
const SWIFT_VERSION = '5.0';

/** Add the App Group to the main app so it shares storage with the extension. */
function withAppGroup(config) {
  return withEntitlementsPlist(config, (cfg) => {
    const key = 'com.apple.security.application-groups';
    const groups = new Set(cfg.modResults[key] ?? []);
    groups.add(APP_GROUP);
    cfg.modResults[key] = Array.from(groups);
    return cfg;
  });
}

/** Copy the NSE sources into ios/<TARGET_NAME>/. */
function withNSESources(config) {
  return withDangerousMod(config, [
    'ios',
    (cfg) => {
      const destDir = path.join(cfg.modRequest.platformProjectRoot, TARGET_NAME);
      fs.mkdirSync(destDir, { recursive: true });
      for (const file of FILES) {
        fs.copyFileSync(path.join(SOURCE_DIR, file), path.join(destDir, file));
      }
      return cfg;
    },
  ]);
}

/** Register the NSE target in the Xcode project and embed it in the app. */
function withNSETarget(config) {
  return withXcodeProject(config, (cfg) => {
    const project = cfg.modResults;
    const bundleId = `${cfg.ios.bundleIdentifier}.${TARGET_NAME}`;

    // Idempotency: bail if the target already exists (re-run of prebuild).
    if (project.pbxTargetByName(TARGET_NAME)) {
      return cfg;
    }

    // Group holding the extension's files.
    const group = project.addPbxGroup(FILES, TARGET_NAME, TARGET_NAME);
    // Nest it under the top-level project group.
    const groups = project.hash.project.objects.PBXGroup;
    for (const key of Object.keys(groups)) {
      if (groups[key].name === undefined && groups[key].path === undefined && groups[key].isa) {
        project.addToPbxGroup(group.uuid, key);
        break;
      }
    }

    const target = project.addTarget(TARGET_NAME, 'app_extension', TARGET_NAME, bundleId);

    project.addBuildPhase(
      ['NotificationService.swift'],
      'PBXSourcesBuildPhase',
      'Sources',
      target.uuid,
    );
    project.addBuildPhase([], 'PBXResourcesBuildPhase', 'Resources', target.uuid);
    project.addBuildPhase([], 'PBXFrameworksBuildPhase', 'Frameworks', target.uuid);

    // Embed the extension into the main app ("Embed App Extensions").
    const mainTargetUuid = project.getFirstTarget().uuid;
    project.addBuildPhase(
      [`${TARGET_NAME}.appex`],
      'PBXCopyFilesBuildPhase',
      'Embed App Extensions',
      mainTargetUuid,
      'app_extension',
    );
    project.addTargetDependency(mainTargetUuid, [target.uuid]);

    // Per-configuration build settings for the extension.
    const configurations = project.pbxXCBuildConfigurationSection();
    for (const key of Object.keys(configurations)) {
      const buildSettings = configurations[key].buildSettings;
      if (!buildSettings || buildSettings.PRODUCT_NAME !== `"${TARGET_NAME}"`) {
        continue;
      }
      buildSettings.PRODUCT_BUNDLE_IDENTIFIER = `"${bundleId}"`;
      buildSettings.INFOPLIST_FILE = `"${TARGET_NAME}/Info.plist"`;
      buildSettings.CODE_SIGN_ENTITLEMENTS = `"${TARGET_NAME}/${TARGET_NAME}.entitlements"`;
      buildSettings.IPHONEOS_DEPLOYMENT_TARGET = DEPLOYMENT_TARGET;
      buildSettings.SWIFT_VERSION = SWIFT_VERSION;
      buildSettings.TARGETED_DEVICE_FAMILY = '"1,2"';
      buildSettings.CODE_SIGN_STYLE = 'Automatic';
      buildSettings.CLANG_ENABLE_MODULES = 'YES';
      buildSettings.SWIFT_EMIT_LOC_STRINGS = 'YES';
    }

    return cfg;
  });
}

/** @param {import('@expo/config-plugins').ExpoConfig} config */
module.exports = function withNotificationServiceExtension(config) {
  config = withAppGroup(config);
  config = withNSESources(config);
  config = withNSETarget(config);
  return config;
};
