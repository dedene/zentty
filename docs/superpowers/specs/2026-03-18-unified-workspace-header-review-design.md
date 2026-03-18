# Unified Workspace Header Review Design

Date: 2026-03-18
Status: Draft approved in conversation, written for repo review

## Summary

Evolve Zentty's current top chrome from a split attention-plus-context surface into a single unified workspace header row. That row should use horizontal space to show the most relevant ambient state for the active workspace in one glance:

- workspace urgency
- focused tool or pane context
- active branch
- pull request identity
- compact review state such as draft, failing checks, or latest run status

The key product change is not "add a GitHub dashboard." It is "make review state feel native to the same surface that already orients the user inside the workspace."

The approved visual direction is a single-row header on wide displays, with panes starting immediately below it. There is no separate second review band in v1.

## Goals

- Surface Git and GitHub review state without forcing the user out of the terminal workspace.
- Use wide-display horizontal space instead of paying extra vertical cost.
- Keep the panes visually dominant.
- Keep workspace urgency and review state visible at the same time without scattering them across multiple bands.
- Tie Git and PR state to the active pane or worktree.
- Keep the first version mostly passive and command-palette-driven rather than action-heavy.
- Preserve Zentty's calm, opinionated feel rather than introducing a dense control strip.

## Non-Goals

- Building a full GitHub client inside Zentty
- Inline merge, close, ready-for-review, or rerun controls in the header row
- A multi-line or wrapping header row in v1
- A repo-wide dashboard that summarizes all panes or all workspaces at once
- Showing cwd in the unified header in v1
- Adding a separate settings surface just to customize header composition
- Designing the narrow-screen fallback in this spec beyond basic overflow rules

## Current State

Today the workspace header area is split across two separate concepts:

- [`WindowChromeView`](/Users/peter/Development/Personal/worktrees/feature/git/Zentty/UI/WindowChromeView.swift) renders:
  - a workspace attention chip
  - a right-aligned [`ContextStripView`](/Users/peter/Development/Personal/worktrees/feature/git/Zentty/UI/ContextStripView.swift)
- [`ContextStripView`](/Users/peter/Development/Personal/worktrees/feature/git/Zentty/UI/ContextStripView.swift) renders:
  - focused title
  - cwd
  - branch
- [`RootViewController`](/Users/peter/Development/Personal/worktrees/feature/git/Zentty/UI/RootViewController.swift) places that header above the main pane canvas.

That model works for terminal context, but it is not the right surface for review state:

- the current right-side pill is too small and too isolated
- cwd competes with more valuable branch and PR context
- there is no obvious place for PR/check state without adding another band

The approved direction is to replace the current context strip concept with a stronger unified header summary.

## Product Model

### One Header Row

The workspace uses one header row only.

- Height remains aligned with the current `44pt` top chrome rhythm.
- The row stays above the pane canvas.
- The pane canvas begins immediately below the row.
- There is no secondary review band in v1.

### Information Hierarchy

The row combines two different classes of information:

- workspace-level urgency
- active-pane review context

Those should coexist in a single horizontal lane because widescreen layouts have enough width to support both without adding vertical complexity.

### Ownership of Signals

- The workspace attention chip remains workspace-scoped.
  - It reflects the highest-priority urgent agent state in the workspace.
  - It is not tied to the focused pane.
- The rest of the row is active-pane-scoped.
  - It follows the currently focused pane or worktree.
  - It shows branch and review context for what the user is actually looking at.

This gives the user one persistent rule:

- left edge: "is anything in this workspace urgent?"
- rest of row: "what is the review state of what I am focused on?"

## Header Content

### Default Ordering

Recommended left-to-right order:

1. optional workspace attention chip
2. focused tool or pane label
3. branch
4. pull request identity
5. compact review state chips

Example:

`Needs input | Claude Code | feature/review-band | PR #128 | Draft | 2 failing | Latest run failed`

### Element Rules

#### Workspace Attention Chip

- Reuse the existing workspace attention behavior from [`WorkspaceAttentionChipView`](/Users/peter/Development/Personal/worktrees/feature/git/Zentty/UI/WorkspaceAttentionChipView.swift).
- Do not show the phrase "workspace attention" in the UI.
- Show direct state language instead:
  - `Needs input`
  - `Stopped`
- Hide the chip when there is no urgent workspace-level state.

#### Focused Tool or Pane Label

- Show the best available focused label:
  - terminal title
  - recognized tool name
  - process name
  - pane title fallback
- This label exists to orient the user.
- It should be secondary to branch and PR identity.

#### Branch

- Branch is the stable anchor for Git context.
- If Git metadata is available, branch should always be shown.
- Branch uses monospace styling.

#### Pull Request Identity

- If a PR is known for the active branch, show a compact PR identifier:
  - `PR #128`
- Avoid long PR titles in v1.
- The PR identifier is more stable and more compact than title text.

#### Review State Chips

Show only compact, aggregate review chips in v1. Examples:

- `Draft`
- `Ready`
- `Merged`
- `2 failing`
- `Checks passed`
- `Latest run failed`
- `Running`
- `Blocked`

Avoid per-check names in the header row. The row is a summary surface, not a check inspector.

## Behavior

### Focus-Driven Updates

When pane focus changes:

- the focused tool label updates
- branch updates
- PR identity updates
- review chips update

The workspace attention chip does not depend on focus. It reflects the highest-priority urgent signal across the workspace.

### Passive-First Interaction

The row should remain mostly passive in v1.

Recommended interaction model:

- clicking the PR identifier may open the PR URL if available
- clicking the attention artifact, if present, may open its linked destination
- command-palette actions remain the primary place for mutations and review actions

Do not put merge, close, ready-for-review, or rerun buttons directly into the row in v1.

### Stable Empty States

The row should not visually disappear just because some review data is missing.

#### Non-Git Pane

- show focused tool or pane label only
- omit Git and PR fields

#### Git Branch, No PR

- show focused tool label
- show branch
- show a compact `No PR` state

#### PR Known, Checks Unavailable

- show branch
- show PR identity
- show PR state only

#### GitHub Unavailable

- do not turn the header into a setup warning surface
- continue showing branch-only context if Git metadata exists
- setup and auth diagnostics belong in settings, not in the main workspace header

## Single-Row Constraint

The user explicitly chose a single-row design for now.

That means the product needs an explicit overflow policy instead of wrapping.

### Overflow Policy

When horizontal space gets tight, collapse in this order:

1. remove any non-essential trailing hint text
2. truncate the focused tool label
3. collapse multiple review signals into fewer aggregate chips
4. preserve branch
5. preserve PR identity if present
6. preserve the workspace attention chip when visible

The row must not wrap in v1.

This keeps the most semantically important items stable:

- urgency
- branch
- PR identity

## Visual Direction

### Hierarchy

- The header row should feel like a thin status rail, not a second toolbar.
- Panes remain the dominant visual blocks.
- The row background should stay subtle and integrated with existing chrome.

### Components

- Reuse existing pill geometry and theme language where possible.
- Use chips for discrete states, not large segmented controls.
- Use separators only where they clarify grouping:
  - tool
  - branch
  - PR

### Remove From Current Surface

The current standalone right-aligned context pill should be removed.

Specifically:

- remove the existing `cwd` pill-style presentation from [`ContextStripView`](/Users/peter/Development/Personal/worktrees/feature/git/Zentty/UI/ContextStripView.swift)
- do not duplicate cwd elsewhere in v1

The unified header should prioritize review context over filesystem context.

## Architecture Direction

The implementation should keep rendering and summary-building separate.

### Recommended Units

#### `WorkspaceHeaderSummary`

A single value type describing everything the header needs to render.

Suggested shape:

```swift
struct WorkspaceHeaderSummary: Equatable, Sendable {
    var attention: WorkspaceAttentionSummary?
    var focusedLabel: String?
    var branch: String?
    var pullRequest: WorkspacePullRequestSummary?
    var reviewChips: [WorkspaceReviewChip]
}
```

#### `WorkspacePullRequestSummary`

Compact PR identity and state for the active branch.

Suggested shape:

```swift
struct WorkspacePullRequestSummary: Equatable, Sendable {
    var number: Int
    var url: URL?
    var state: WorkspacePullRequestState
}
```

#### `WorkspaceReviewChip`

A small semantic chip model rather than raw strings.

Suggested shape:

```swift
struct WorkspaceReviewChip: Equatable, Sendable {
    enum Style: Equatable, Sendable {
        case neutral
        case success
        case warning
        case danger
        case info
    }

    var text: String
    var style: Style
}
```

#### `WorkspaceHeaderSummaryBuilder`

Build one summary from:

- current workspace
- focused pane metadata
- existing workspace attention summary
- inferred or explicit PR artifact info
- review state provider output

This builder should own prioritization and fallback rules. The view should not.

#### `WorkspaceReviewStateProvider`

Define one explicit owner for PR and check enrichment.

Suggested boundary:

```swift
protocol WorkspaceReviewStateProvider: Sendable {
    func reviewState(
        for workspace: WorkspaceState,
        focusedPaneID: PaneID?
    ) -> WorkspaceReviewState?
}
```

Suggested review-state model:

```swift
struct WorkspaceReviewState: Equatable, Sendable {
    var branch: String?
    var pullRequest: WorkspacePullRequestSummary?
    var reviewChips: [WorkspaceReviewChip]
}
```

Rules:

- This provider is the only component allowed to decide PR/check enrichment for the header.
- `WorkspaceHeaderSummaryBuilder` consumes provider output and merges it with workspace urgency and focused-pane metadata.
- The first implementation may be thin and partial.
  - branch-only context can come from terminal metadata
  - PR URL or PR number can come from inferred artifact state when available
  - richer check data can arrive later through the same provider boundary
- The interface must stay stable even if the backing source changes.

#### `WindowChromeView`

[`WindowChromeView`](/Users/peter/Development/Personal/worktrees/feature/git/Zentty/UI/WindowChromeView.swift) should become the single rendering surface for the unified row.

Responsibilities:

- render a `WorkspaceHeaderSummary`
- lay out attention chip, context items, and review chips
- own truncation and spacing behavior

It should not derive business rules from raw workspace state.

`WindowChromeView` must consume a fully materialized `WorkspaceHeaderSummary`. It should not query review-state submodels or workspace state directly.

## Integration Points

### Existing Reusable Pieces

- [`WorkspaceAttentionSummaryBuilder`](/Users/peter/Development/Personal/worktrees/feature/git/Zentty/AppState/AgentStatus.swift) already provides workspace urgency.
- [`PRArtifactResolver`](/Users/peter/Development/Personal/worktrees/feature/git/Zentty/AppState/PRArtifactResolver.swift) already suggests a path for inferred PR artifacts.
- focused pane metadata already includes branch information through terminal metadata flows.

### New Review Data

The header needs a compact source of PR and check state for the active branch.

That source should be modeled as one explicit provider:

- `WorkspaceReviewStateProvider` is the single boundary for review enrichment
- branch-only context works without full provider coverage
- PR/check chips appear when provider output exists

This keeps the UI useful before full GitHub integration is present while preventing multiple competing review-state pipelines from appearing during implementation.

### Data Flow

Recommended flow:

1. `RootViewController` gathers the active workspace and focused pane context
2. `WorkspaceAttentionSummaryBuilder` produces workspace urgency
3. `WorkspaceReviewStateProvider` produces branch/PR/check enrichment
4. `WorkspaceHeaderSummaryBuilder` merges those into one `WorkspaceHeaderSummary`
5. `WindowChromeView` renders that summary only

This preserves a clean boundary:

- builders and providers decide meaning
- the view decides layout only

## Settings Direction

Learn from Supacode here:

- settings should stay operational, not expansive
- GitHub setup belongs in a minimal integration/settings surface
- the workspace header should not become a configuration or error console

For this feature specifically:

- no user setting for single-row vs multi-row in v1
- no user setting for chip composition in v1

## Testing

### Unit Tests

Add builder tests for:

- urgent attention plus focused review context
- focused pane with branch but no PR
- focused pane with PR and failing checks
- focused pane with successful checks
- non-Git pane
- overflow prioritization and collapse ordering where modeled

### View Tests

Add targeted layout/render tests for:

- attention chip hidden vs visible
- branch visible without PR
- PR identifier visible without title
- no wrapping behavior
- truncation of focused tool label before branch or PR identity is lost

### Regression Focus

Protect against these regressions:

- attention chip disappearing when focus moves away from the urgent pane
- branch disappearing when review chips are present
- long tool names pushing out PR identity
- reintroducing cwd as a competing top-level element

## Recommendation

Implement the unified single-row workspace header first.

That is the strongest synthesis of the Supacode learnings and the approved Zentty direction:

- ambient Git review state
- gh/GitHub style integration without a second dashboard
- pane-first layout preserved
- horizontal space used deliberately

Future work can decide how the row should collapse on narrower displays, but v1 should optimize the widescreen case cleanly and decisively.
