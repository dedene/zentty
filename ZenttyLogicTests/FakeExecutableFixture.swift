import Darwin
import XCTest
@testable import Zentty

/// Per-test directory of fake executables (bash scripts). Processes whose pid
/// a fake writes to a tracked pid file are `SIGKILL`ed in `tearDown`, so a
/// failing assertion never leaks them.
final class FakeExecutableFixture {
    let directory: URL
    private let createdAt = Date()
    private var pidFiles: [URL] = []

    init(name: String) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func makeExecutable(body: String) throws -> URL {
        let url = directory.appendingPathComponent("fake-\(UUID().uuidString)")
        let script = "#!/bin/bash\n[ -n \"$ZENTTY_FAKE_WARMUP\" ] && exit 0\n\(body)\n"
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// The first exec of a fresh script can take seconds on a loaded machine
    /// (system policy assessment). Run it once, as a no-op, before a test that
    /// depends on a short timeout firing only after the script started.
    func prewarm(_ executable: URL) throws {
        _ = try SubprocessRunner.run(
            executableURL: executable,
            arguments: [],
            environment: ["ZENTTY_FAKE_WARMUP": "1"],
            timeout: 30
        )
    }

    func trackPIDFile(named name: String) -> URL {
        let url = directory.appendingPathComponent(name)
        pidFiles.append(url)
        return url
    }

    /// Asserts the process recorded in `pidFile` is gone. Once that is proven
    /// the pid file is no longer tracked, so `tearDown` never signals the pid
    /// after it may have been recycled; on failure it stays tracked and dies there.
    func assertProcessReaped(
        pidFile: URL,
        _ message: @autoclosure () -> String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let pid = try XCTUnwrap(Self.readPID(from: pidFile), "no pid in \(pidFile.lastPathComponent)", file: file, line: line)
        guard !Self.isProcessAlive(pid) else {
            return XCTFail("\(message()) (pid \(pid))", file: file, line: line)
        }
        pidFiles.removeAll { $0 == pidFile }
        try? FileManager.default.removeItem(at: pidFile)
    }

    func tearDown() {
        for pidFile in pidFiles {
            if let pid = Self.readPID(from: pidFile), isOwnFakeProcess(pid) {
                kill(pid, SIGKILL)
            }
        }
        pidFiles = []
        try? FileManager.default.removeItem(at: directory)
    }

    static func readPID(from url: URL) -> pid_t? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// `kill(pid, 0)` also succeeds for a zombie, so `false` proves the process
    /// is gone and was reaped.
    static func isProcessAlive(_ pid: pid_t) -> Bool {
        if kill(pid, 0) == 0 {
            return true
        }
        return errno != ESRCH
    }

    /// A pid this fixture's fakes recorded is only trusted while the process
    /// behind it started after the fixture was created; an older process owns
    /// a recycled pid. This cannot rule out every recycle, but it rules out
    /// signalling anything that was already running when the test began.
    private func isOwnFakeProcess(_ pid: pid_t) -> Bool {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.stride
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == Int32(size) else {
            return false
        }
        let startedAt = TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000
        // Start times have microsecond resolution; allow a little clock slack.
        return startedAt >= createdAt.timeIntervalSince1970 - 1
    }
}
