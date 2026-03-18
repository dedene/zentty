# Sidebar Row Identity Design

Date: 2026-03-18
Status: Draft approved in conversation, written for repo review

## Summary

Redesign the workspace sidebar rows so they identify a workspace by meaningful context instead of leaking raw pane metadata such as `pane 1`, `shell`, or `main`.

The row should usually read like a workspace list, not a pane list:

- home should look like `house icon + ~`
- project rows should be named from cwd
- branch should be visible, but secondary
- agent identity should only take over when agent state is the thing that matters
- multi-pane rows should spend extra vertical space on useful pane-specific cwd/branch lines, not pane counts

This keeps the sidebar calm while making it much easier to scan.

## Goals

- Remove bogus primary labels such as `pane 1` and raw branch names such as `main`.
- Make the primary row identity come from cwd when possible.
- Preserve branch visibility as lightweight context.
- Let multi-pane workspaces communicate real pane context instead of generic counts.
- Keep icon usage sparse and semantic.
- Preserve alignment even when only some rows use icons.
- Stay compatible with the current sidebar architecture: summary building, layout planning, then view rendering.

## Non-Goals

- A fully custom icon system in this pass
- Per-pane interactive controls inside the sidebar row
- Making the sidebar a full dashboard of all pane metadata
- Replacing the context strip’s role as the place for exact cwd detail
- Showing every pane in very large workspaces without overflow handling

## Current Problems

The current model is too close to raw internal state:

- `WorkspaceSidebarSummaryBuilder` can fall back to focused pane titles, which allows `pane 1` into the primary label.
- `WorkspaceContextFormatter.contextText` is useful, but it is currently only one compact string and cannot express multiple pane contexts.
- `SidebarWorkspaceRowLayout` only understands a small fixed set of row types, so it cannot grow naturally when a workspace has several meaningful panes.
- `SidebarView.WorkspaceRowButton` renders one `contextLabel`, which forces multi-pane workspaces into a flattened summary such as `3 panes` instead of showing the panes that actually matter.

## Product Model

### Row Identity Hierarchy

Each row should answer one question first:

> What is this workspace, in human terms?

The row should not mirror the currently focused pane unless that pane is the clearest expression of workspace identity.

Recommended identity order:

1. Promoted attention state identity, if an agent is actively the important thing
2. Cwd-derived workspace identity
3. Explicit user workspace title, as a quiet supporting line
4. Process or tool identity
5. Normalized pane title only as a last resort

### Primary Label Rules

#### Normal project rows

- Use cwd-derived identity as the primary label.
- Prefer a compact, human-readable path over a raw absolute path.
- Prefer the leaf directory when it is distinctive.
- Escalate to a two-segment form when needed for clarity, for example `feature/sidebar`.
- If multiple visible rows would collide, only those rows should expand to a longer label.

#### Home row

- When cwd resolves to the home directory, render the primary label as `~`.
- Pair it with a house icon.
- Do not rename this row to `Home`, `shell`, or an absolute path.

#### Agent-promoted row

- When a workspace’s attention state is the most important thing, promote the agent identity to the primary label.
- Example: `Claude Code` with a supporting status line such as `Needs input`.
- This should happen for states such as:
  - needs input
  - unresolved stop
  - actively running when that workspace is intentionally agent-centric
- Branch and cwd context still appear below the promoted identity.

#### Fallback row

When cwd is unavailable:

- Prefer recognized tool or process identity
- Fall back to a normalized pane label such as `Shell` or `Split`
- Never show generated names like `pane 1` as-is if a better normalization is possible

## Custom Workspace Title

An explicit workspace title still matters, but it should not dominate the row.

- Generated workspace titles such as `MAIN` or `WS 2` remain hidden.
- Meaningful custom titles may appear as a small quiet top line above the primary label.
- The custom title should be omitted if it repeats the same information as the primary label.

Example:

- top line: `Docs`
- primary line: `marketing-site`

## Multi-Pane Row Model

Pane count is weak information. It tells the user that a split exists, but not what is inside it.

For multi-pane workspaces, extra vertical space should be used for pane-context lines instead.

### Pane-Context Lines

Each pane-context line should summarize one pane with the most useful available combination of:

- git branch
- compact cwd
- recognizable tool or pane role if needed to distinguish panes

Examples:

- `fix-pane-border-text-visibility • sidebar`
- `main • git`
- `refresh-homepage-copy • site`
- `notes • copy`

### Ordering

- Focused pane first
- Then other panes with distinct useful context
- Deduplicate redundant lines
- Prefer lines that add new information over lines that restate the same cwd and branch

### Growth Policy

- Rows may grow when the extra pane lines add real signal.
- Use a soft cap of three pane-context lines.
- If more panes still contain useful undisplayed context after that cap, append a muted overflow line such as `+1 more pane` or `+2 more panes`.
- If the additional panes add no distinct information, omit the overflow line entirely.

This keeps the sidebar informative without letting one large workspace consume the entire list.

## Single-Pane Row Model

Single-pane rows should remain compact.

- Home row: primary `~`, one supporting context line if useful
- Normal project row: primary cwd label, one context line for branch and/or secondary cwd detail
- Agent-promoted row: primary agent identity, status line, then one context line

Single-pane rows do not need explicit pane count or pane role unless cwd is missing.

## Iconography

Icon usage should stay intentionally sparse.

### Use icons for

- home rows
- agent-promoted rows

### Do not use icons for

- every project row by default
- every pane role by default
- decorative repetition that does not help identification

### Icon quality rule

The current icon treatment needs polish. The design intent is:

- home icon should read instantly and quietly
- agent icon should feel specific enough to the tool or at least clearly “agent-like”
- plain project rows should be allowed to stay typographic

### Icon source for v1

Use SF Symbols for this pass.

Reasons:

- the app already uses `NSImage(systemSymbolName:)`
- SF Symbols fit the current AppKit rendering path and native macOS chrome
- this keeps the icon discussion focused on meaning and selection, not asset pipeline work

The question for implementation is not “which icon library should we adopt,” but “which small SF Symbols set best communicates home and agent-promoted rows without feeling noisy.”

Lucide or another custom icon system can be revisited later if the app needs a broader non-native icon language.

## Alignment Rule

Use a conditional leading icon gutter:

- if at least one visible sidebar row uses a leading icon, reserve the same leading gutter for all visible rows
- if no visible rows use a leading icon, remove the gutter and let text align flush-left

This preserves visual alignment without baking permanent dead space into all-text lists.

## Context Formatting Rules

The current `WorkspaceContextFormatter` should stay the home for compact cwd and branch formatting, but it needs to support pane-line composition instead of only returning one flat row string.

Recommended formatting behavior:

- compact cwd names should prefer meaningful, short labels
- worktree paths should be able to collapse to forms like `feature/sidebar`
- home should resolve to `~`
- branch and cwd should be joined with ` • ` when both exist
- exact absolute cwd still belongs in the context strip, not the sidebar row

## Data Model Direction

The current summary model is too flat for this design.

Today:

```swift
struct WorkspaceSidebarSummary {
    let title: String
    let primaryText: String
    let statusText: String?
    let contextText: String
    ...
}
```

Recommended direction:

```swift
struct WorkspaceSidebarSummary {
    let workspaceID: WorkspaceID
    let topLabel: String?
    let primaryText: String
    let statusText: String?
    let detailLines: [WorkspaceSidebarDetailLine]
    let leadingAccessory: WorkspaceSidebarAccessory?
    let artifactLink: WorkspaceArtifactLink?
    let isActive: Bool
}

struct WorkspaceSidebarDetailLine {
    let text: String
    let emphasis: WorkspaceSidebarLineEmphasis
}
```

Key consequences:

- the row can render zero, one, or several detail lines
- status can stay distinct from generic detail lines
- icon decisions become summary data instead of view-only guesses
- layout can compute height from the actual number of visible lines

## Unit Boundaries

Keep the implementation split into clear units.

### `WorkspaceSidebarSummaryBuilder`

Responsible for:

- choosing primary identity
- deciding whether attention state promotes agent identity
- building pane-context lines
- deciding whether a leading accessory is present

Not responsible for:

- pixel layout
- text measurement
- color or animation

### `WorkspaceContextFormatter`

Responsible for:

- path compaction
- home normalization
- branch/cwd string composition
- pane-line text formatting helpers

Not responsible for:

- row ordering across panes
- attention prioritization

### `SidebarWorkspaceRowLayout`

Responsible for:

- computing which lines are visible
- computing row height from line count
- supporting variable-height rows

Not responsible for:

- picking the row’s semantic content

### `SidebarView.WorkspaceRowButton`

Responsible for:

- rendering the richer summary model
- honoring the conditional gutter
- displaying artifact pills and status styling

Not responsible for:

- inventing fallback labels

## Rendering Direction

The row should remain a single sidebar button, but its internal stack needs to be more flexible.

Recommended structure:

- optional quiet top label
- primary label
- optional status line
- zero to three detail lines
- optional overflow line
- optional artifact pill

Rows should center vertically only when compact. Expanded rows should align content to a stable top inset so variable-height rows still feel orderly.

## Edge Cases

### Duplicate compact labels

If two workspaces would both render to the same compact cwd label:

- expand only the colliding rows to a longer path form
- do not globally make every row more verbose

### Missing metadata

If cwd and branch are both missing:

- use process or recognized tool identity
- use normalized pane-role fallback if needed
- avoid raw generated pane names if a cleaner label is available

### Too many panes

If a workspace contains many panes:

- show the most informative pane-context lines first
- use a muted overflow line only if hidden panes add distinct information

### Attention plus many panes

If attention state is promoted:

- primary becomes the agent identity
- status remains visible
- only one context/detail line is needed beneath it unless more detail materially helps

The attention row should not become the tallest row by default.

## Testing Strategy

Add or update tests around:

- primary label selection for cwd, home, agent, and fallback cases
- suppression of generated labels such as `pane 1`
- smart path compaction including worktree-style paths
- collision expansion for duplicate compact labels
- pane-context line ordering and deduplication
- overflow handling for large multi-pane workspaces
- conditional gutter behavior in `SidebarView`
- variable-height row layout stability across width changes

## Recommendation

Implement this as an evolution of the existing sidebar summary pipeline, not a rewrite.

The current structure is already good:

- summary building
- row layout planning
- row rendering

The change should be to enrich the summary model and let layout/rendering consume that richer structure. That keeps the behavior easier to reason about and test.
