import XCTest

/// Base class for tests that create real AppKit views (`NSView`, `NSViewController`,
/// `LibghosttyView`, etc). Wraps each test invocation in an `autoreleasepool` so AppKit
/// state is drained before the next test runs.
///
/// Why this exists: in a plain `XCTestCase`, the autorelease pool isn't drained until
/// the test method returns to XCTest infrastructure. When AppKit views created in the
/// test fall out of scope but remain in the autorelease pool, their CA transaction /
/// `NSPointerArray` state accumulates across tests. On macOS 26 Tahoe, a subsequent
/// test that pumps the run loop (via `Task.sleep`, `await fulfillment(of:)`, etc.) can
/// crash inside `CA::Transaction::commit` → `-[NSConcretePointerArray dealloc]` when it
/// drains that stale state.
///
/// Wrapping `invokeTest()` in `autoreleasepool` forces the stale state to drain within
/// the test's own scope — so it never leaks into subsequent tests.
class AppKitTestCase: XCTestCase {
    override func invokeTest() {
        autoreleasepool {
            super.invokeTest()
        }
    }
}
