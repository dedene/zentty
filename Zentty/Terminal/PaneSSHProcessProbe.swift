import Darwin
import Foundation
import os

protocol PaneSSHProcessTreeProviding: Sendable {
    func treePIDs(rootPID: Int32) -> [Int32]
    func processName(pid: Int32) -> String?
}

protocol PaneSSHProcessArgvProviding: Sendable {
    func argv(pid: Int32) -> [String]?
}

struct PaneSSHProcessProbe: Sendable {
    private let processTreeProvider: any PaneSSHProcessTreeProviding
    private let argvProvider: any PaneSSHProcessArgvProviding

    init(
        processTreeProvider: any PaneSSHProcessTreeProviding = DarwinPaneSSHProcessTreeProvider(),
        argvProvider: any PaneSSHProcessArgvProviding = DarwinPaneSSHProcessArgvProvider()
    ) {
        self.processTreeProvider = processTreeProvider
        self.argvProvider = argvProvider
    }

    func scan(rootPID: Int32) -> SSHDestination? {
        guard rootPID > 0 else {
            return nil
        }

        let pids = processTreeProvider.treePIDs(rootPID: rootPID)
        for pid in pids.reversed() {
            guard WorklaneContextFormatter.isSSHProcess(processTreeProvider.processName(pid: pid)),
                  let argv = argvProvider.argv(pid: pid),
                  let destination = Self.destination(fromArgv: argv) else {
                continue
            }

            return destination
        }

        return nil
    }

    func hasSSH(rootPID: Int32) -> Bool {
        scan(rootPID: rootPID) != nil
    }

    static func destination(fromArgv argv: [String]) -> SSHDestination? {
        guard argv.count > 1 else {
            return nil
        }

        let args = Array(argv.dropFirst())
        var index = 0
        var explicitUser: String?
        var port: Int?
        var rawTarget: String?

        while index < args.count {
            let token = args[index]
            if token == "--" {
                rawTarget = index + 1 < args.count ? args[index + 1] : nil
                break
            }

            if token == "-l" {
                explicitUser = index + 1 < args.count
                    ? WorklaneContextFormatter.trimmed(args[index + 1])
                    : nil
                index += 2
                continue
            }

            if token.hasPrefix("-l"), token.count > 2 {
                explicitUser = WorklaneContextFormatter.trimmed(String(token.dropFirst(2)))
                index += 1
                continue
            }

            if token == "-p" {
                port = index + 1 < args.count ? Int(args[index + 1]) : nil
                index += 2
                continue
            }

            if token.hasPrefix("-p"), token.count > 2 {
                port = Int(String(token.dropFirst(2)))
                index += 1
                continue
            }

            if token.hasPrefix("-") {
                index += sshOptionConsumesNextToken(token) ? 2 : 1
                continue
            }

            rawTarget = token
            break
        }

        guard let normalizedTarget = rawTarget.map(normalizeSSHTarget),
              !normalizedTarget.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let parsedUser = sshUser(fromTarget: normalizedTarget)
        let user = parsedUser ?? explicitUser
        let host = sshHost(fromTarget: normalizedTarget)
        let target = user.map { "\($0)@\(host)" } ?? normalizedTarget

        return SSHDestination(target: target, user: user, host: host, port: port)
    }

    private static func normalizeSSHTarget(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func sshUser(fromTarget target: String) -> String? {
        let components = target.split(separator: "@", maxSplits: 1).map(String.init)
        guard components.count == 2 else {
            return nil
        }

        return WorklaneContextFormatter.trimmed(components[0])
    }

    private static func sshHost(fromTarget target: String) -> String {
        target.split(separator: "@", maxSplits: 1).last.map(String.init) ?? target
    }

    private static func sshOptionConsumesNextToken(_ token: String) -> Bool {
        sshOptionsRequiringValues.contains(token)
    }

    private static let sshOptionsRequiringValues: Set<String> = [
        "-B", "-b", "-c", "-D", "-E", "-e", "-F", "-I", "-i", "-J", "-L",
        "-l", "-m", "-O", "-o", "-p", "-Q", "-R", "-S", "-W", "-w"
    ]
}

struct DarwinPaneSSHProcessTreeProvider: PaneSSHProcessTreeProviding {
    func treePIDs(rootPID: Int32) -> [Int32] {
        DarwinProcessProbe().treePIDs(rootPID: rootPID)
    }

    func processName(pid: Int32) -> String? {
        // proc_name requires >= 2*MAXCOMLEN or it fails with ENOMEM.
        var buffer = [CChar](repeating: 0, count: 2 * Int(MAXCOMLEN))
        let result = proc_name(pid, &buffer, UInt32(buffer.count))
        guard result > 0 else {
            return nil
        }

        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

struct DarwinPaneSSHProcessArgvProvider: PaneSSHProcessArgvProviding {
    private static let logger = Logger(subsystem: "be.zenjoy.zentty", category: "PaneSSHProcessProbe")

    func argv(pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else {
            Self.logger.debug("Could not read process argv size pid=\(pid, privacy: .public) errno=\(errno, privacy: .public)")
            return nil
        }

        var buffer = [UInt8](repeating: 0, count: size)
        let result = buffer.withUnsafeMutableBytes { rawBuffer in
            sysctl(&mib, u_int(mib.count), rawBuffer.baseAddress, &size, nil, 0)
        }
        guard result == 0, size > MemoryLayout<Int32>.size else {
            Self.logger.debug("Could not read process argv pid=\(pid, privacy: .public) errno=\(errno, privacy: .public)")
            return nil
        }

        return parseProcArgsBuffer(Array(buffer.prefix(size)))
    }

    private func parseProcArgsBuffer(_ buffer: [UInt8]) -> [String]? {
        guard buffer.count > MemoryLayout<Int32>.size else {
            return nil
        }

        let argc = buffer.withUnsafeBytes { rawBuffer in
            rawBuffer.loadUnaligned(fromByteOffset: 0, as: Int32.self)
        }
        guard argc > 0 else {
            return nil
        }

        var cursor = MemoryLayout<Int32>.size
        while cursor < buffer.count, buffer[cursor] != 0 {
            cursor += 1
        }
        while cursor < buffer.count, buffer[cursor] == 0 {
            cursor += 1
        }

        var arguments: [String] = []
        while cursor < buffer.count, arguments.count < Int(argc) {
            let start = cursor
            while cursor < buffer.count, buffer[cursor] != 0 {
                cursor += 1
            }

            if cursor > start,
               let argument = String(bytes: buffer[start..<cursor], encoding: .utf8) {
                arguments.append(argument)
            }
            cursor += 1
        }

        return arguments.isEmpty ? nil : arguments
    }
}
