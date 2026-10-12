import XCTest
@testable import Zentty

/// config.toml names a custom sound by file name, but macOS only plays it from
/// ~/Library/Sounds. A copy in the config dir lets a second Mac that shares
/// config.toml install the same sound.
final class NotificationSoundSharingTests: XCTestCase {
    private var temporaryDirectoryURL: URL!
    private var librarySoundsURL: URL!
    private var sharedSoundsURL: URL!
    private var originalSoundsOverride: URL?
    private var originalSharedOverride: URL?
    private var originalConverterOverride: NotificationSoundManager.SoundConverter?

    override func setUpWithError() throws {
        temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZenttyTests.NotificationSoundSharing.\(UUID().uuidString)", isDirectory: true)
        librarySoundsURL = temporaryDirectoryURL.appendingPathComponent("Library/Sounds", isDirectory: true)
        sharedSoundsURL = temporaryDirectoryURL.appendingPathComponent("config/sounds", isDirectory: true)
        try FileManager.default.createDirectory(at: librarySoundsURL, withIntermediateDirectories: true)

        originalSoundsOverride = NotificationSoundManager.soundsDirectoryOverride
        originalSharedOverride = NotificationSoundManager.sharedSoundsDirectoryOverride
        originalConverterOverride = NotificationSoundManager.converterOverride
        NotificationSoundManager.soundsDirectoryOverride = librarySoundsURL
        NotificationSoundManager.sharedSoundsDirectoryOverride = sharedSoundsURL
        // Real afconvert on a short system sound, like the install tests.
        NotificationSoundManager.converterOverride = nil
    }

    override func tearDownWithError() throws {
        NotificationSoundManager.soundsDirectoryOverride = originalSoundsOverride
        NotificationSoundManager.sharedSoundsDirectoryOverride = originalSharedOverride
        NotificationSoundManager.converterOverride = originalConverterOverride
        if let temporaryDirectoryURL {
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        }
    }

    func test_install_keeps_a_copy_in_the_shared_sounds_directory() throws {
        let (name, _) = try NotificationSoundManager.installCustomSound(from: try makeSourceSound())

        XCTAssertTrue(FileManager.default.fileExists(atPath: sharedSoundsURL.appendingPathComponent(name).path))
    }

    func test_new_install_and_switching_away_prune_the_shared_copy() throws {
        let (first, _) = try NotificationSoundManager.installCustomSound(from: try makeSourceSound())
        let (second, _) = try NotificationSoundManager.installCustomSound(from: try makeSourceSound())

        XCTAssertEqual(try sharedContents(), [second])
        XCTAssertNotEqual(first, second)

        NotificationSoundManager.pruneCustomSounds(keeping: nil)
        XCTAssertEqual(try sharedContents(), [])
    }

    func test_missing_sound_is_installed_from_the_shared_copy() throws {
        let name = "\(NotificationSoundManager.customFilePrefix)\(UUID().uuidString).caf"
        try FileManager.default.createDirectory(at: sharedSoundsURL, withIntermediateDirectories: true)
        try Data("synced".utf8).write(to: sharedSoundsURL.appendingPathComponent(name))

        XCTAssertTrue(NotificationSoundManager.installSharedSoundIfMissing(named: name))

        XCTAssertEqual(
            try Data(contentsOf: librarySoundsURL.appendingPathComponent(name)),
            Data("synced".utf8)
        )
        XCTAssertNotNil(NotificationSoundManager.urlForPreview(soundName: name))
    }

    func test_system_sounds_and_unknown_names_are_left_alone() {
        XCTAssertFalse(NotificationSoundManager.installSharedSoundIfMissing(named: "Glass"))
        XCTAssertFalse(NotificationSoundManager.installSharedSoundIfMissing(named: "zentty-custom-missing.caf"))
    }

    func test_overridden_sounds_directory_without_shared_override_never_touches_the_real_config_dir() {
        NotificationSoundManager.sharedSoundsDirectoryOverride = nil

        XCTAssertNil(NotificationSoundManager.sharedSoundsDirectory)
    }

    // MARK: - Helpers

    private func makeSourceSound() throws -> URL {
        let url = temporaryDirectoryURL.appendingPathComponent("source-\(UUID().uuidString).aiff")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/System/Library/Sounds/Tink.aiff"), to: url)
        return url
    }

    private func sharedContents() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: sharedSoundsURL.path).sorted()
    }
}
