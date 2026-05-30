import AVFoundation
import UserNotifications
import XCTest
@testable import Zentty

final class NotificationSoundManagerTests: XCTestCase {
    private var originalOverride: URL?
    private var originalLibraryDirectoryOverride: URL?
    private var originalConverterOverride: NotificationSoundManager.SoundConverter?
    private var tempSoundsDir: URL!
    private var tempHomeDir: URL!

    override func setUpWithError() throws {
        originalOverride = NotificationSoundManager.soundsDirectoryOverride
        originalLibraryDirectoryOverride = NotificationSoundManager.libraryDirectoryOverride
        originalConverterOverride = NotificationSoundManager.converterOverride
        tempSoundsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZenttyTests.NotificationSoundManager.\(UUID().uuidString)", isDirectory: true)
        tempHomeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZenttyTests.NotificationSoundManager.Home.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempSoundsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tempHomeDir, withIntermediateDirectories: true)
        NotificationSoundManager.soundsDirectoryOverride = tempSoundsDir
        NotificationSoundManager.libraryDirectoryOverride = nil
        NotificationSoundManager.converterOverride = nil
    }

    override func tearDownWithError() throws {
        NotificationSoundManager.soundsDirectoryOverride = originalOverride
        NotificationSoundManager.libraryDirectoryOverride = originalLibraryDirectoryOverride
        NotificationSoundManager.converterOverride = originalConverterOverride
        if let tempSoundsDir {
            try? FileManager.default.removeItem(at: tempSoundsDir)
        }
        if let tempHomeDir {
            try? FileManager.default.removeItem(at: tempHomeDir)
        }
    }

    func test_soundsDirectory_uses_override() {
        XCTAssertEqual(NotificationSoundManager.soundsDirectory, tempSoundsDir)
    }

    func test_soundsDirectory_defaultsToCurrentUserLibrarySoundsDirectory() {
        NotificationSoundManager.soundsDirectoryOverride = nil
        let libraryDirectory = tempHomeDir.appendingPathComponent("Library", isDirectory: true)
        NotificationSoundManager.libraryDirectoryOverride = libraryDirectory

        let expected = libraryDirectory
            .appendingPathComponent("Sounds", isDirectory: true)

        XCTAssertEqual(NotificationSoundManager.soundsDirectory, expected)
    }

    func test_isCustomSoundName_matchesPrefixAndExtension() {
        XCTAssertTrue(NotificationSoundManager.isCustomSoundName("zentty-custom-\(UUID().uuidString).caf"))
        // Legacy fixed name from before rotation still matches the prefix.
        XCTAssertTrue(NotificationSoundManager.isCustomSoundName("zentty-custom-notification.caf"))
        XCTAssertFalse(NotificationSoundManager.isCustomSoundName("Glass"))
        XCTAssertFalse(NotificationSoundManager.isCustomSoundName(""))
        XCTAssertFalse(NotificationSoundManager.isCustomSoundName("zentty-custom-abc.mp3"))
        XCTAssertFalse(NotificationSoundManager.isCustomSoundName("other-custom-abc.caf"))
    }

    func test_installCustomSound_convertsSystemAiff_andProvidesPreviewURL() throws {
        let source = URL(fileURLWithPath: "/System/Library/Sounds/Glass.aiff")
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw XCTSkip("No Glass.aiff available for test")
        }

        let result = try NotificationSoundManager.installCustomSound(from: source)
        XCTAssertTrue(NotificationSoundManager.isCustomSoundName(result.internalName))
        XCTAssertFalse(result.displayName.isEmpty)

        let installed = tempSoundsDir.appendingPathComponent(result.internalName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: installed.path))

        let previewURL = NotificationSoundManager.urlForPreview(soundName: result.internalName)
        XCTAssertEqual(previewURL, installed)
    }

    func test_installCustomSound_mintsUniqueInternalNamePerInstall() throws {
        let source = try makeConvertibleSource(named: "source.input")
        NotificationSoundManager.converterOverride = { _, destinationURL in
            try Self.writeSilentAudio(duration: 1, to: destinationURL)
        }

        let first = try NotificationSoundManager.installCustomSound(from: source)
        let second = try NotificationSoundManager.installCustomSound(from: source)

        XCTAssertTrue(NotificationSoundManager.isCustomSoundName(first.internalName))
        XCTAssertTrue(NotificationSoundManager.isCustomSoundName(second.internalName))
        XCTAssertNotEqual(first.internalName, second.internalName)
    }

    func test_installCustomSound_convertsToCustomCafAndPreservesDisplayName() throws {
        let source = try makeValidAudioSource(named: "Chime-日本語.aiff")
        var conversion: (source: URL, destination: URL)?
        NotificationSoundManager.converterOverride = { sourceURL, destinationURL in
            conversion = (sourceURL, destinationURL)
            try Self.writeSilentAudio(duration: 1, to: destinationURL)
        }

        let result = try NotificationSoundManager.installCustomSound(from: source)

        XCTAssertTrue(NotificationSoundManager.isCustomSoundName(result.internalName))
        XCTAssertEqual(result.displayName, "Chime-日本語.aiff")
        XCTAssertEqual(conversion?.source, source)
        XCTAssertEqual(conversion?.destination.lastPathComponent, result.internalName)
        let installed = tempSoundsDir.appendingPathComponent(result.internalName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: installed.path))
    }

    func test_installCustomSound_removesPartialDestinationWhenConversionFails() throws {
        let source = try makeValidAudioSource(named: "Broken.aiff")
        NotificationSoundManager.converterOverride = { _, destinationURL in
            try Data("partial".utf8).write(to: destinationURL)
            throw NotificationSoundInstallError.conversionFailed("bad codec")
        }

        XCTAssertThrowsError(try NotificationSoundManager.installCustomSound(from: source))

        XCTAssertEqual(try customSoundFiles(), [])
    }

    func test_installCustomSound_prunesPreviousCustomFileOnSuccessfulInstall() throws {
        let source = try makeConvertibleSource(named: "source.input")
        NotificationSoundManager.converterOverride = { _, destinationURL in
            try Self.writeSilentAudio(duration: 1, to: destinationURL)
        }

        let first = try NotificationSoundManager.installCustomSound(from: source)
        XCTAssertEqual(try customSoundFiles(), [first.internalName])

        let second = try NotificationSoundManager.installCustomSound(from: source)

        // The first file is pruned; only the freshly installed one remains.
        XCTAssertEqual(try customSoundFiles(), [second.internalName])
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: tempSoundsDir.appendingPathComponent(first.internalName).path)
        )
    }

    func test_installCustomSound_keepsPreviousFileWhenPersistSelectionFails() throws {
        enum TestError: Error {
            case persistence
        }

        let existingName = "zentty-custom-existing.caf"
        let existing = tempSoundsDir.appendingPathComponent(existingName)
        try Data("previous-caf".utf8).write(to: existing)
        let source = try makeConvertibleSource(named: "source.input")
        NotificationSoundManager.converterOverride = { _, destinationURL in
            try Self.writeSilentAudio(duration: 1, to: destinationURL)
        }

        XCTAssertThrowsError(
            try NotificationSoundManager.installCustomSound(from: source) { _, _ in
                throw TestError.persistence
            }
        )

        // The previously installed file is untouched and the aborted install left nothing behind.
        XCTAssertEqual(try Data(contentsOf: existing), Data("previous-caf".utf8))
        XCTAssertEqual(try customSoundFiles(), [existingName])
    }

    func test_installCustomSoundAsync_runsConversionOffMainAndPersistsOnMainThread() async throws {
        let source = try makeConvertibleSource(named: "source.input")
        final class ThreadCapture: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var converterRanOnMainThread: Bool?
            private(set) var persistenceRanOnMainThread: Bool?

            func recordConverterThread() {
                lock.lock()
                converterRanOnMainThread = Thread.isMainThread
                lock.unlock()
            }

            func recordPersistenceThread() {
                lock.lock()
                persistenceRanOnMainThread = Thread.isMainThread
                lock.unlock()
            }
        }

        let capture = ThreadCapture()
        NotificationSoundManager.converterOverride = { _, destinationURL in
            capture.recordConverterThread()
            try Self.writeSilentAudio(duration: 1, to: destinationURL)
        }

        let result = try await NotificationSoundManager.installCustomSound(from: source) { _, _ in
            capture.recordPersistenceThread()
        }

        XCTAssertTrue(NotificationSoundManager.isCustomSoundName(result.internalName))
        XCTAssertEqual(capture.converterRanOnMainThread, false)
        XCTAssertEqual(capture.persistenceRanOnMainThread, true)
    }

    func test_installCustomSoundAsync_keepsPreviousFileWhenPersistSelectionFails() async throws {
        enum TestError: Error {
            case persistence
        }

        let existingName = "zentty-custom-existing.caf"
        let existing = tempSoundsDir.appendingPathComponent(existingName)
        try Data("previous-caf".utf8).write(to: existing)
        let source = try makeConvertibleSource(named: "source.input")
        NotificationSoundManager.converterOverride = { _, destinationURL in
            try Self.writeSilentAudio(duration: 1, to: destinationURL)
        }

        do {
            _ = try await NotificationSoundManager.installCustomSound(from: source) { _, _ in
                throw TestError.persistence
            }
            XCTFail("Expected persistence failure")
        } catch TestError.persistence {
            XCTAssertEqual(try Data(contentsOf: existing), Data("previous-caf".utf8))
            XCTAssertEqual(try customSoundFiles(), [existingName])
        } catch {
            XCTFail("Expected persistence failure, got \(error)")
        }
    }

    func test_pruneCustomSounds_removesAllCustomFilesWhenKeepingNil() throws {
        let names = ["zentty-custom-a.caf", "zentty-custom-b.caf"]
        for name in names {
            try Data("x".utf8).write(to: tempSoundsDir.appendingPathComponent(name))
        }
        // A non-custom file must survive pruning.
        let keeper = tempSoundsDir.appendingPathComponent("Glass.aiff")
        try Data("keep".utf8).write(to: keeper)

        NotificationSoundManager.pruneCustomSounds(keeping: nil)

        XCTAssertEqual(try customSoundFiles(), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: keeper.path))
    }

    func test_installCustomSound_rejectsConvertedSoundLongerThanThirtySecondsWhenSourceDurationIsUnreadable() throws {
        let source = tempSoundsDir.appendingPathComponent("SourceWithUnreadableDuration.zenttytest")
        try Data("not actually audio but converter accepts it".utf8).write(to: source)
        NotificationSoundManager.converterOverride = { _, destinationURL in
            try Self.writeSilentAudio(duration: 31, to: destinationURL)
        }

        XCTAssertThrowsError(try NotificationSoundManager.installCustomSound(from: source)) { error in
            guard case NotificationSoundInstallError.tooLong = error else {
                return XCTFail("Expected tooLong, got \(error)")
            }
        }

        XCTAssertEqual(try customSoundFiles(), [])
    }

    func test_installCustomSound_rejectsConvertedSoundWhenDurationCannotBeDetermined() throws {
        let source = try makeValidAudioSource(named: "ReadableSource.aiff")
        NotificationSoundManager.converterOverride = { _, destinationURL in
            try Data("not a readable converted sound".utf8).write(to: destinationURL)
        }

        XCTAssertThrowsError(try NotificationSoundManager.installCustomSound(from: source)) { error in
            guard case NotificationSoundInstallError.conversionFailed(let reason) = error else {
                return XCTFail("Expected conversionFailed, got \(error)")
            }
            XCTAssertTrue(reason.localizedCaseInsensitiveContains("duration"))
        }

        XCTAssertEqual(try customSoundFiles(), [])
    }

    func test_installCustomSound_reportsAfconvertStderrWithoutNestedLocalizedError() throws {
        let source = tempSoundsDir.appendingPathComponent("NotAudio.aiff")
        try Data("not audio".utf8).write(to: source)

        XCTAssertThrowsError(try NotificationSoundManager.installCustomSound(from: source)) { error in
            guard case NotificationSoundInstallError.conversionFailed(let reason) = error else {
                return XCTFail("Expected conversionFailed, got \(error)")
            }
            XCTAssertFalse(reason.contains("Could not convert the audio file"))
            XCTAssertTrue(reason.localizedCaseInsensitiveContains("afconvert"))
            XCTAssertTrue(reason.localizedCaseInsensitiveContains("input file"))
        }
    }

    func test_playPreview_returnsFalse_forUnknownSound() {
        let played = NotificationSoundManager.playPreview(for: "NonExistentSoundName")
        XCTAssertFalse(played)
    }

    func test_installCustomSound_createsDirectoryIfMissing() throws {
        let nested = tempSoundsDir.appendingPathComponent("NestedCustomSounds", isDirectory: true)
        NotificationSoundManager.soundsDirectoryOverride = nested
        XCTAssertFalse(FileManager.default.fileExists(atPath: nested.path))

        let source = URL(fileURLWithPath: "/System/Library/Sounds/Ping.aiff")
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw XCTSkip("No Ping.aiff for test")
        }

        let result = try NotificationSoundManager.installCustomSound(from: source)
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.appendingPathComponent(result.internalName).path))
    }

    func test_resolvedNotificationSoundName_usesCustomFileNameForDeliveredNotifications() {
        let customName = "zentty-custom-\(UUID().uuidString).caf"
        let soundName = resolvedNotificationSoundName(for: customName)

        XCTAssertEqual(soundName?.rawValue, customName)
        XCTAssertNil(resolvedNotificationSoundName(for: ""))
    }

    func test_urlForPreview_returnsNil_forMissingCustomFile() {
        // Covers plan edge "missing custom file"
        let url = NotificationSoundManager.urlForPreview(
            soundName: "zentty-custom-\(UUID().uuidString).caf"
        )
        XCTAssertNil(url)
    }

    func test_installCustomSound_preservesNonAsciiDisplayName() throws {
        let source = try makeValidAudioSource(named: "Chime-日本語.aiff")
        NotificationSoundManager.converterOverride = { _, destinationURL in
            try Self.writeSilentAudio(duration: 1, to: destinationURL)
        }

        let result = try NotificationSoundManager.installCustomSound(from: source)

        XCTAssertEqual(result.displayName, "Chime-日本語.aiff")
    }

    func test_notificationSoundInstallError_localizedDescriptions() {
        let tooLong = NotificationSoundInstallError.tooLong(42)
        XCTAssertTrue(tooLong.errorDescription?.contains("42") ?? false)
        XCTAssertTrue(tooLong.errorDescription?.contains("30") ?? false)

        let conv = NotificationSoundInstallError.conversionFailed("afconvert missing")
        XCTAssertTrue(conv.errorDescription?.contains("afconvert") ?? false)

        let fileOp = NotificationSoundInstallError.fileOperationFailed("perm denied")
        XCTAssertTrue(fileOp.errorDescription?.contains("perm") ?? false)
    }

    // MARK: - Helpers

    /// Custom sound files currently present in the overridden sounds directory, sorted.
    private func customSoundFiles() throws -> [String] {
        guard FileManager.default.fileExists(atPath: tempSoundsDir.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: tempSoundsDir.path)
            .filter { NotificationSoundManager.isCustomSoundName($0) }
            .sorted()
    }

    /// A real AIFF copied from the system so `audioDuration(of:)` succeeds on the source.
    private func makeValidAudioSource(named fileName: String) throws -> URL {
        let source = URL(fileURLWithPath: "/System/Library/Sounds/Glass.aiff")
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw XCTSkip("No Glass.aiff available for test")
        }
        let destination = tempSoundsDir.appendingPathComponent(fileName)
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    /// A non-audio source file. `audioDuration(of:)` returns nil for it, so the install relies
    /// on the converter override (no system audio dependency, never an XCTSkip).
    private func makeConvertibleSource(named fileName: String) throws -> URL {
        let source = tempSoundsDir.appendingPathComponent(fileName)
        try Data("source".utf8).write(to: source)
        return source
    }

    private static func writeSilentAudio(duration: TimeInterval, to destination: URL) throws {
        let sampleRate = 8_000.0
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let file = try AVAudioFile(forWriting: destination, settings: format.settings)
        let frameCount = AVAudioFrameCount((duration * sampleRate).rounded(.up))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        try file.write(from: buffer)
    }
}
