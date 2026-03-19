# Architecture Refactor Spec

**Date:** 2026-03-19
**Scope:** Comprehensive single-pass refactor addressing all findings from architectural review
**Approach:** Bottom-up state first — each layer stabilizes before the next builds on it

## Context

Zentty is a macOS terminal multiplexer (~15,700 LOC, 61 Swift files) built on pure AppKit with a value-based state machine architecture. An architectural review identified issues in state model design, change notification granularity, concurrency model, file size / responsibility distribution, error handling, and code hygiene. This spec addresses all findings in a single coordinated refactor.

## Section 1: State Model Consolidation

### Problem

`WorkspaceState` carries five parallel `[PaneID: X]` dictionaries:

```swift
var metadataByPaneID: [PaneID: TerminalMetadata]
var paneContextByPaneID: [PaneID: PaneShellContext]
var agentStatusByPaneID: [PaneID: PaneAgentStatus]
var inferredArtifactByPaneID: [PaneID: WorkspaceArtifactLink]
var reviewStateByPaneID: [PaneID: WorkspaceReviewState]
```

Adding or removing a pane requires updating up to five dictionaries. `clearPaneState` handles cleanup, but missing one dictionary is an easy mistake. Additionally, `typealias PaneStripStore = WorkspaceStore` creates naming confusion.

### Design

**1a. Introduce `PaneAuxiliaryState`:**

```swift
struct PaneAuxiliaryState: Equatable, Sendable {
    var metadata: TerminalMetadata?
    var shellContext: PaneShellContext?
    var agentStatus: PaneAgentStatus?
    var inferredArtifact: WorkspaceArtifactLink?
    var reviewState: WorkspaceReviewState?
}
```

**1b. Replace five dictionaries with one:**

```swift
struct WorkspaceState: Equatable, Sendable {
    let id: WorkspaceID
    var title: String
    var paneStripState: PaneStripState
    var nextPaneNumber: Int
    var auxiliaryStateByPaneID: [PaneID: PaneAuxiliaryState]
}
```

**1c. Simplify cleanup.** `clearPaneState` becomes `auxiliaryStateByPaneID.removeValue(forKey:)`. Sub-clearing (e.g., branch-derived state only) becomes mutations on the `PaneAuxiliaryState` struct's fields.

**1d. Remove `typealias PaneStripStore = WorkspaceStore`.** Rename all references to `WorkspaceStore` consistently.

**1e. Add `@MainActor` to `WorkspaceStore`.** It is already implicitly main-actor-bound through usage. Making it explicit prepares for Swift 6 strict concurrency and makes the contract visible.

### Files affected

- `Zentty/AppState/PaneStripStore.swift` — core changes
- `Zentty/AppState/WorkspaceStore+AgentStatus.swift` — update dictionary access
- `Zentty/AppState/WorkspaceStore+Metadata.swift` — update dictionary access
- `Zentty/AppState/WorkspaceStore+ReviewState.swift` — update dictionary access
- `Zentty/UI/RootViewController.swift` — update workspace state reads
- `Zentty/UI/AppCanvasView.swift` — update render method signature
- All test files referencing `PaneStripStore` or the old dictionary names

### Success criteria

- All five dictionaries replaced by single `auxiliaryStateByPaneID`
- Zero references to `PaneStripStore` remain
- `WorkspaceStore` annotated `@MainActor`
- All existing tests pass with updated access patterns

---

## Section 2: Granular Change Notifications

### Problem

`WorkspaceStore` has a single `onChange: ((PaneStripState) -> Void)?` callback. Every state change triggers a full re-render. The consumer cannot distinguish between a focus change (cheap to handle) and a structural change (requires full reconciliation).

### Design

**2a. Introduce `WorkspaceChange` enum:**

```swift
enum WorkspaceChange: Equatable, Sendable {
    case paneStructure(WorkspaceID)
    case focusChanged(WorkspaceID)
    case layoutResized(WorkspaceID)
    case auxiliaryStateUpdated(WorkspaceID, PaneID)
    case activeWorkspaceChanged
    case workspaceListChanged
}
```

**2b. Replace callback signature:**

```swift
var onChange: ((WorkspaceChange) -> Void)?
```

**2c. Emit specific changes at each mutation site:**

| Mutation | Change emitted |
|----------|---------------|
| `focusPane`, `moveFocusLeft/Right/Up/Down` | `.focusChanged(workspaceID)` |
| `send(.split*)`, `send(.closeFocusedPane)` | `.paneStructure(workspaceID)` |
| `updateLayoutContext`, `scalePaneWidths` | `.layoutResized(workspaceID)` |
| `updateMetadata`, `applyAgentStatusPayload` | `.auxiliaryStateUpdated(workspaceID, paneID)` |
| `selectWorkspace` | `.activeWorkspaceChanged` |
| `createWorkspace`, workspace removal | `.workspaceListChanged` |

**2d. Handle changes by type in `RootViewController`.** A `.focusChanged` updates canvas focus + chrome header. A `.auxiliaryStateUpdated` refreshes the affected pane's chrome and sidebar summary. A `.paneStructure` triggers full canvas reconciliation.

**2e. Batch support.** Operations producing multiple changes (e.g., closing last pane in workspace) emit changes sequentially. The consumer batches UI work within a single `CATransaction` or `NSAnimationContext`.

### Files affected

- `Zentty/AppState/PaneStripStore.swift` — new enum, updated emit sites
- `Zentty/AppState/WorkspaceStore+AgentStatus.swift` — specific change emission
- `Zentty/AppState/WorkspaceStore+Metadata.swift` — specific change emission
- `Zentty/AppState/WorkspaceStore+ReviewState.swift` — specific change emission
- `Zentty/UI/RootViewController.swift` — change-type-specific render paths

### Success criteria

- `notifyStateChanged()` replaced by `notify(_ change:)` everywhere
- `RootViewController` has distinct handlers per `WorkspaceChange` case
- No regressions in render behavior (visual output identical)
- Tests verify correct change types emitted for each mutation

---

## Section 3: Concurrency Consolidation

### Problem

Three concurrency mechanisms coexist: raw GCD, `Task { @MainActor }`, and `withCheckedContinuation` bridging. Most UI types lack explicit `@MainActor` annotation.

### Design

**3a. Add `@MainActor` to all NSView subclasses and coordinators.** Mechanical annotation of every `final class` in `UI/`, `Motion/`, and root-level controllers. Already-annotated types remain unchanged.

**3b. Migrate `PRArtifactResolver` from GCD to async/await.** Replace `DispatchQueue.global().async` + `DispatchQueue.main.async` with an async method that runs subprocess work on the cooperative thread pool and returns naturally to `@MainActor` callers.

**3c. Keep `WorkspaceReviewStateResolver`'s `withCheckedContinuation` bridge.** The bridge wrapping `Process` in async/await is the correct pattern until `Process` natively supports Swift concurrency.

**3d. Replace `DispatchQueue.main.async` in `PaneStripView`** (3 call sites at lines 339, 703, 864) with `Task { @MainActor [weak self] in ... }`.

**3e. Replace `DispatchQueue.main.asyncAfter` in sidebar dismissal** with `Task.sleep`:

```swift
private var sidebarDismissTask: Task<Void, Never>?

private func scheduleSidebarDismissalTimer() {
    cancelSidebarDismissalTimer()
    sidebarDismissTask = Task { @MainActor [weak self] in
        try? await Task.sleep(for: .seconds(SidebarLayout.dismissDelay))
        self?.handleSidebarVisibilityEvent(.dismissTimerElapsed)
    }
}

private func cancelSidebarDismissalTimer() {
    sidebarDismissTask?.cancel()
    sidebarDismissTask = nil
}
```

**3f. Keep `Timer.scheduledTimer` for stale-agent sweep.** A repeating timer with fixed interval is appropriate here.

### Files affected

- All files in `Zentty/UI/` — `@MainActor` annotation
- All files in `Zentty/Motion/` — `@MainActor` annotation
- `Zentty/AppState/PRArtifactResolver.swift` — async migration
- `Zentty/UI/PaneStripView.swift` — GCD replacement
- `Zentty/UI/RootViewController.swift` — sidebar timer migration

### Success criteria

- Every NSView subclass and coordinator has explicit `@MainActor`
- Zero `DispatchQueue.main.async` calls remain in `PaneStripView`
- `PRArtifactResolver` uses async/await
- Sidebar dismissal uses `Task.sleep` with cancellation
- Build succeeds with Swift strict concurrency checking enabled

---

## Section 4: UI Decomposition

### Problem

`RootViewController` (726 LOC) owns sidebar visibility, theme management, layout context, canvas rendering, keyboard monitoring, window observers, and agent sweep timers. `PaneStripView` (902 LOC) handles rendering, layout, gestures, animation, and scroll-switching.

### Design

**4a. Extract `SidebarMotionCoordinator`.**

Extracted from `RootViewController`. Owns dismiss timer, motion state computation, constraint animation, and width persistence. Wraps the existing `SidebarVisibilityController` struct (which remains a separate value-type state machine) — the coordinator subsumes `RootViewController`'s usage of that controller, not the struct itself.

```swift
@MainActor
final class SidebarMotionCoordinator {
    var onMotionStateDidChange: ((SidebarMotionState) -> Void)?
    var effectiveLeadingInset: CGFloat { get }
    var mode: SidebarVisibilityMode { get }
    var showsResizeHandle: Bool { get }
    var isFloating: Bool { get }

    func handle(_ event: SidebarVisibilityEvent)
    func setSidebarWidth(_ width: CGFloat, persist: Bool)
}
```

Source lines from `RootViewController`: sidebar-related properties (~38-42), `handleSidebarVisibilityEvent` (~458-485), `syncSidebarVisibilityControls` (~487-490), `scheduleSidebarDismissalTimer` (~492-504), `applySidebarMotionState` (~506-573), `setSidebarWidth` (~448-456).

**4b. Extract `ThemeCoordinator`.**

Extracted from `RootViewController`. Owns theme resolution, watcher lifecycle, and theme application.

```swift
@MainActor
final class ThemeCoordinator {
    var currentTheme: ZenttyTheme { get }
    var onThemeDidChange: ((ZenttyTheme, Bool) -> Void)?

    func refreshTheme(for appearance: NSAppearance, animated: Bool)
}
```

Source lines: `themeResolver`, `themeWatcher` properties, `refreshTheme` (~405-426), `apply(theme:animated:)` (~428-433).

**4c. Extract `ScrollSwitchGestureHandler` from `PaneStripView`.**

Owns scroll-to-switch state machine: axis detection, delta accumulation, threshold triggering.

```swift
@MainActor
final class ScrollSwitchGestureHandler {
    enum Result { case switchLeft, switchRight, none }
    func handle(scrollEvent: NSEvent) -> Result
    func reset()
}
```

Source state: `activeScrollSwitchAxis`, `accumulatedScrollSwitchDelta`, `hasTriggeredScrollSwitchInGesture`.

**4d. Extract `PaneStripLayoutEngine` from `PaneStripView`.**

Owns frame computation, viewport offset, and transition frame calculation.

```swift
@MainActor
struct PaneStripLayoutEngine {
    func computeFrames(
        for state: PaneStripState,
        in containerSize: CGSize,
        leadingVisibleInset: CGFloat
    ) -> [PaneID: CGRect]

    func computeViewportOffset(
        for state: PaneStripState,
        in containerSize: CGSize,
        leadingVisibleInset: CGFloat
    ) -> CGFloat
}
```

**4e. Target LOC after decomposition:**

| File | Before | After |
|------|--------|-------|
| `RootViewController.swift` | 726 | ~350-400 |
| `PaneStripView.swift` | 902 | ~500-550 |
| `SidebarMotionCoordinator.swift` | (new) | ~200 |
| `ThemeCoordinator.swift` | (new) | ~100 |
| `ScrollSwitchGestureHandler.swift` | (new) | ~80 |
| `PaneStripLayoutEngine.swift` | (new) | ~120 |

### Files affected

- `Zentty/UI/RootViewController.swift` — extract two coordinators
- `Zentty/UI/PaneStripView.swift` — extract gesture handler + layout engine
- New files: `SidebarMotionCoordinator.swift`, `ThemeCoordinator.swift`, `ScrollSwitchGestureHandler.swift`, `PaneStripLayoutEngine.swift`
- Test files for the new types

### Success criteria

- `RootViewController` under 450 LOC
- `PaneStripView` under 600 LOC
- Each extracted type has focused tests
- No behavior regressions (same visual output, same interactions)

---

## Section 5: Error Handling

### Problem

Terminal session startup, IPC payload parsing, and subprocess execution fail silently. Errors are swallowed with `try?` or dropped via optional chaining. Debugging production issues is difficult.

### Design

**5a. Introduce `ZenttyError`:**

```swift
enum ZenttyError: Error, Sendable {
    case terminalSessionFailed(paneID: PaneID, reason: String)
    case agentPayloadMalformed(detail: String)
    case subprocessFailed(command: String, exitCode: Int32, stderr: String)
    case themeResolutionFailed(path: String, reason: String)
}
```

**5b. Surface terminal session failures.** Catch errors from `adapter.startSession()`, log them, and populate the existing `startupFailureMessageValue` with the actual error description instead of a generic message.

**5c. Log malformed agent payloads.** Replace silent `try?` in `AgentStatusCenter` with `do/catch` that logs at `.error` level:

```swift
import os
private let logger = Logger(subsystem: "be.zentty", category: "AgentStatus")

do {
    let payload = try AgentStatusPayload(userInfo: userInfo)
    onPayload?(payload)
} catch {
    logger.error("Malformed agent status payload: \(error.localizedDescription)")
}
```

**5d. Include stderr in subprocess results.** Extend `WorkspaceReviewCommandResult` to carry stderr content from failed `gh` / `git` calls.

**5e. Use `os.Logger` consistently.** Structured logging with subsystem `be.zentty` and per-module categories:

| Category | Used in |
|----------|---------|
| `Terminal` | `LibghosttyAdapter`, `TerminalPaneHostView` |
| `AgentStatus` | `AgentStatusCenter`, `AgentStatusHelper` |
| `ReviewState` | `WorkspaceReviewStateResolver` |
| `Theme` | `GhosttyThemeResolver`, `ThemeCoordinator` |

### Files affected

- New file: `ZenttyError.swift`
- `Zentty/Terminal/TerminalPaneHostView.swift` — session error surfacing
- `Zentty/AppState/AgentStatusCenter.swift` — payload error logging
- `Zentty/AppState/WorkspaceReviewStateResolver.swift` — stderr capture
- `Zentty/UI/GhosttyThemeResolver.swift` — theme error logging

### Success criteria

- No silent `try?` at system boundaries (IPC, subprocess, session start)
- `os.Logger` used in all modules with consistent subsystem
- `ZenttyError` covers all known failure modes
- Existing tests pass; new tests cover error paths

---

## Section 6: Code Hygiene

### Problem

`ForTesting` properties leak into 18 production source files. `AppDelegate` has 15 passthrough `@objc` methods that duplicate what the responder chain does automatically.

### Design

**6a. `ForTesting` cleanup — two tiers:**

- **Accessors that duplicate public state** (e.g., `workspaceTitlesForTesting` on `MainWindowController`): delete. Tests already construct `WorkspaceStore` directly and inspect its state.
- **View-layer test seams** exposing internal NSView properties (frames, colors, alpha): wrap in `#if DEBUG`.

**6b. AppDelegate responder chain cleanup.**

Remove all forwarding `@objc` methods from `AppDelegate`. `MainWindowController` already implements these selectors. AppKit's responder chain dispatches menu actions to the first responder that handles them when the menu item targets `nil`.

Keep only `applicationDidFinishLaunching` and any truly app-level methods.

**6c. Verify `AppMenuBuilder` targets.** Audit all `NSMenuItem` creation to confirm actions use `target: nil` so responder chain routing works. Update any items that explicitly target the app delegate.

### Files affected

- `Zentty/AppDelegate.swift` — remove forwarding methods
- `Zentty/AppMenuBuilder.swift` — verify/update menu targets
- 18 files with `ForTesting` properties — delete or wrap in `#if DEBUG`
- Corresponding test files — update to use direct state inspection where accessors are deleted

### Success criteria

- `AppDelegate` under 25 LOC
- Zero `ForTesting` properties in release builds
- Menu actions route correctly via responder chain
- All tests pass with `#if DEBUG` test seams

---

## Execution Strategy

Single comprehensive refactor. Sections executed in order (1 through 6) because each layer builds on the previous:

1. **State Model** — foundation for everything
2. **Notifications** — requires clean state model
3. **Concurrency** — touches many files but state is stable
4. **UI Decomposition** — requires stable notifications and concurrency
5. **Error Handling** — can be woven in during decomposition
6. **Hygiene** — final cleanup pass

### Risk mitigation

- Tests run after each section completes
- Git commits at section boundaries for rollback capability
- `WorkspaceStore` changes are the riskiest (most downstream consumers) — done first when the rest of the code hasn't changed yet

### Testing strategy

- Existing 28 test files (11,200 LOC) provide regression coverage
- New unit tests for: `PaneAuxiliaryState`, `WorkspaceChange` emission, `SidebarMotionCoordinator`, `ThemeCoordinator`, `ScrollSwitchGestureHandler`, `PaneStripLayoutEngine`, error paths
- No snapshot or UI automation tests required for this refactor
