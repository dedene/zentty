import AppKit
@testable import Zentty

@MainActor
enum HostedTestDisplay {
    static let environmentKey = "ZENTTY_TEST_SCREEN_NAME"

    static var screenNameFromEnvironment: String? {
        let value = ProcessInfo.processInfo.environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    static func screen(named screenName: String?) -> NSScreen? {
        guard let screenName else {
            return nil
        }
        return NSScreen.screens.first { Self.screenName($0.localizedName, matches: screenName) }
    }

    static func screenName(_ localizedName: String, matches requestedName: String) -> Bool {
        if localizedName == requestedName {
            return true
        }

        let suffixPrefix = requestedName + " ("
        guard localizedName.hasPrefix(suffixPrefix), localizedName.hasSuffix(")") else {
            return false
        }

        let suffixStart = localizedName.index(localizedName.startIndex, offsetBy: suffixPrefix.count)
        let suffix = localizedName[suffixStart..<localizedName.index(before: localizedName.endIndex)]
        return Int(suffix) != nil
    }

    static func centeredFrame(forWindowFrame windowFrame: NSRect, on screen: NSScreen) -> NSRect {
        let visibleFrame = screen.visibleFrame
        let horizontalInset = min(CGFloat(24), visibleFrame.width / 4)
        let verticalInset = min(CGFloat(24), visibleFrame.height / 4)
        let availableFrame = visibleFrame.insetBy(dx: horizontalInset, dy: verticalInset)
        let windowSize = windowFrame.size
        let targetSize = NSSize(
            width: min(max(windowSize.width, 1), availableFrame.width),
            height: min(max(windowSize.height, 1), availableFrame.height)
        )

        return NSRect(
            x: availableFrame.midX - targetSize.width / 2,
            y: availableFrame.midY - targetSize.height / 2,
            width: targetSize.width,
            height: targetSize.height
        ).integral
    }
}

@MainActor
extension NSWindow {
    @discardableResult
    func prepareForHostedTesting(
        onScreenNamed screenName: String? = nil
    ) -> Self {
        let actualScreenName = screenName ?? HostedTestDisplay.screenNameFromEnvironment
        isReleasedWhenClosed = false
        guard let screen = HostedTestDisplay.screen(named: actualScreenName) else {
            return self
        }

        animationBehavior = .none
        setFrame(HostedTestDisplay.centeredFrame(forWindowFrame: frame, on: screen), display: false)
        return self
    }

    func makeKeyAndOrderFrontForHostedTesting(_ sender: Any?) {
        prepareForHostedTesting()
        makeKeyAndOrderFront(sender)
    }
}

@MainActor
extension MainWindowController {
    @discardableResult
    func prepareForHostedTesting() -> Self {
        window.prepareForHostedTesting()
        return self
    }
}

@MainActor
extension NSWindowController {
    func showWindowForHostedTesting(_ sender: Any?) {
        window?.prepareForHostedTesting()
        showWindow(sender)
        window?.prepareForHostedTesting()
    }
}
