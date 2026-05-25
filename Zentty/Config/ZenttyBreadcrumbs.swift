import Foundation
import Sentry

enum ZenttyBreadcrumbScrubber {
    private static let sensitiveKeyFragments = [
        "url",
        "query",
        "fragment",
        "path",
        "cwd",
        "directory",
        "command",
        "title",
        "text",
    ]
    private static let maxStringLength = 160

    static func filter(_ breadcrumb: Breadcrumb) -> Breadcrumb? {
        let category = breadcrumb.category.lowercased()
        if breadcrumb.type?.lowercased() == "http" || category.contains("http") || category.contains("network") {
            return nil
        }

        if let data = breadcrumb.data {
            breadcrumb.data = scrub(data: data)
        }
        breadcrumb.message = truncated(breadcrumb.message)
        return breadcrumb
    }

    private static func scrub(data: [String: Any]) -> [String: Any] {
        data.reduce(into: [:]) { result, entry in
            let normalizedKey = entry.key.lowercased()
            guard !sensitiveKeyFragments.contains(where: normalizedKey.contains) else {
                return
            }

            if let stringValue = entry.value as? String {
                result[entry.key] = truncated(stringValue)
            } else if entry.value is NSNumber || entry.value is Bool || entry.value is NSNull {
                result[entry.key] = entry.value
            }
        }
    }

    private static func truncated(_ value: String?) -> String? {
        guard let value, value.count > maxStringLength else {
            return value
        }
        return String(value.prefix(maxStringLength))
    }
}

final class ZenttyBreadcrumbRateLimiter: @unchecked Sendable {
    private let lock = NSLock()
    private var lastRecordedAt: [String: Date] = [:]

    func shouldRecord(category: String, minInterval: TimeInterval, now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if let previous = lastRecordedAt[category], now.timeIntervalSince(previous) < minInterval {
            return false
        }

        lastRecordedAt[category] = now
        return true
    }
}

@MainActor
final class TerminalInputBreadcrumbThrottler {
    private let minInterval: TimeInterval
    private var lastRecordedAt: Date?

    init(minInterval: TimeInterval = 10) {
        self.minInterval = minInterval
    }

    func shouldRecord(now: Date = Date()) -> Bool {
        if let lastRecordedAt, now.timeIntervalSince(lastRecordedAt) < minInterval {
            return false
        }

        lastRecordedAt = now
        return true
    }
}

enum ZenttyBreadcrumbs {
    private static let rateLimiter = ZenttyBreadcrumbRateLimiter()
    private static let defaultHighFrequencyInterval: TimeInterval = 10
    private static let highFrequencyCategories: Set<String> = [
        "zentty.input.terminal",
        "zentty.passive-server.scan",
        "zentty.render.sidebar",
    ]

    static func record(
        category: String,
        message: String? = nil,
        data: [String: Any] = [:],
        now: Date = Date()
    ) {
        guard ErrorReportingRuntimeState.isEnabledForCurrentProcess else {
            return
        }

        if highFrequencyCategories.contains(category),
           !rateLimiter.shouldRecord(category: category, minInterval: defaultHighFrequencyInterval, now: now) {
            return
        }

        let breadcrumb = Breadcrumb(level: .info, category: category)
        breadcrumb.message = message
        breadcrumb.data = data
        SentrySDK.addBreadcrumb(breadcrumb)
    }
}
