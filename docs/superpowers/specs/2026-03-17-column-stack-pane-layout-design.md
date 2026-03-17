# Column Stack Pane Layout Design

Date: 2026-03-17
Status: Draft approved in conversation, written for repo review

## Summary

Evolve Zentty from a flat horizontal pane strip into a horizontally scrolling strip of columns. Each column contains one or more vertically stacked panes. Horizontal movement remains the global spatial model. Vertical structure exists only inside a column.

This design keeps the current calm, scrolling-first behavior while using screen height more effectively. It intentionally does not become a recursive split tree or bento grid.

## Goals

- Keep Zentty's core model horizontally scrolling and spatially predictable.
- Match the preferred hybrid behavior:
  - ultrawide screens use a `50/50` first horizontal split
  - laptop and regular large displays preserve the first active pane and scroll to reveal the new column
- Add vertical splits that feel natural from the keyboard without introducing recursive layout complexity.
- Replace confusing density-oriented layout language with explicit screen-behavior presets.
- Preserve a minimal, "zen" flow by preferring opinionated defaults over many knobs.

## Non-Goals

- Recursive pane trees
- Arbitrary horizontal/vertical nesting
- Vertical scrolling between panes
- User-configurable vertical split ratios in v1
- Freeform resize handles in v1
- Full Hyprland/Niri feature parity

## Research Summary

### Hyprland 0.54.0

- Hyprland `0.54.0` added scrolling as a core layout instead of relying on a plugin.
- Its scrolling layout defaults are global rather than screen-class aware. The documented defaults are effectively a `0.5` column width with horizontal scrolling behavior.
- Hyprland core does not provide the exact model desired here: it does not expose a "horizontal scroller with vertical stacks inside columns" concept in the same way Niri does.

Sources:

- <https://wiki.hypr.land/0.54.0/Configuring/Scrolling-Layout/>
- <https://hypr.land/news/update54/>

### Niri

- Niri is the stronger reference for a scrolling-first model with local vertical structure.
- Niri's conceptual model is columns on an infinite horizontal strip, with windows inside a column stacked vertically or presented as tabs.
- That model maps well to Zentty's desired interaction, but Zentty should adopt only the narrow subset that preserves calmness.

Sources:

- <https://niri-wm.github.io/niri/Configuration%3A-Layout.html>
- <https://niri-wm.github.io/niri/Tabs.html>
- <https://github.com/YaLTeR/niri/discussions/1162>

## Product Model

### Core Layout

- A workspace is a horizontal strip of columns.
- Columns are ordered left-to-right on a scrollable track.
- The strip scrolls only horizontally.
- A column contains `1..n` panes stacked vertically.
- There is never a nested horizontal split inside a vertical stack.
- There is never a recursive split tree.

This creates a strict mental model:

- global dimension: horizontal strip of columns
- local dimension: vertical stack inside a column

## Behavior

### Horizontal Split

Horizontal split creates a new sibling column beside the focused pane's current column.

- Shortcut: `Command-D`
- Result:
  - if the focused pane is in a single-pane column, that column stays in place and a new column appears immediately to its right
  - if the focused pane is inside a vertical stack, Zentty still creates a new sibling column immediately to the right of the source column in the main strip
- Width rule:
  - the new column reuses the source column width
  - Zentty does not recompute the whole strip on split
  - the strip scrolls to reveal the new column

### Vertical Split

Vertical split adds a new pane inside the current column.

- Shortcut: `Command-Shift-D`
- Result:
  - the focused pane's column gains one new vertically stacked pane
  - the column rebalances all panes evenly by height
- Ratio rule:
  - vertical splits are always balanced equally in height in v1
  - there is no manual per-split height tuning in v1
- Density rule:
  - Zentty enforces a minimum pane height for vertical stacks in v1
  - if adding one more pane would push the evenly balanced stack below that minimum height, the vertical split is refused
  - planning should treat this as a product rule, not a layout accident; the exact constant can be finalized during implementation

### Close Behavior

- Closing a pane inside a vertical stack removes that pane and rebalances the remaining panes evenly.
- Focus after vertical close moves to the next pane below the removed pane, or to the previous pane above if there is no lower neighbor.
- If a column ends with one remaining pane, it becomes a normal single-pane column again.
- Closing a single-pane column removes that column from the strip and focuses the nearest surviving neighbor by the existing horizontal rules.

## Screen-Class Behavior

Zentty should make screen behavior explicit and opinionated.

### Laptop

- Preserve the active pane on the first horizontal split.
- Create a new sibling column at the configured laptop width.
- Scroll horizontally to reveal the new column.

### Large Display

- Same interaction model as laptop.
- Use a slightly denser default column width so more horizontal structure is visible.

### Ultrawide Hybrid

- The first horizontal split from a single full-width pane becomes `50/50`.
- After that first split, preserve existing column widths and reveal new columns by scrolling.
- Vertical splits only rebalance the current column. They do not affect neighboring columns.

## Navigation

### Horizontal Navigation

- `Command-Option-Left`: move focus to the previous column
- `Command-Option-Right`: move focus to the next column
- `Command-Option-Shift-Left`: jump to the first column
- `Command-Option-Shift-Right`: jump to the last column

Horizontal navigation operates on columns, not raw panes.

### Vertical Navigation

- `Command-Option-Up`: move focus up within the current column
- `Command-Option-Down`: move focus down within the current column

Vertical navigation is local to a column stack. It never scrolls the workspace vertically.

### Column Entry Rule

When focus enters a stacked column from the left or right, Zentty restores focus to the last-focused pane inside that column.

This preserves local context and avoids forcing the user onto the top pane every time they move horizontally.

## Settings

The current layout settings language is too abstract for the product behavior the user actually experiences.

### Remove From Main Product Surface

- `Compact`
- `Balanced`
- `Roomy`

These labels describe density indirectly and make the settings harder to reason about.

### Replace With Explicit Behavior Presets

- `Laptop`
- `Large Display`
- `Ultrawide Hybrid`

The settings UI should describe behavior, not just ratio.

Example summaries:

- `Laptop`: preserve the active pane, then scroll horizontally
- `Large Display`: preserve the active pane with denser default columns
- `Ultrawide Hybrid`: first split is `50/50`, then continue as a horizontal scroller

## Data Model Direction

The current layout state is a flat array of panes with widths. That is no longer the right abstraction.

### Current Limitation

Today `PaneStripState` models:

- `panes: [PaneState]`
- one focused pane ID
- per-pane width

That fits a flat strip only.

### New Shape

Introduce an explicit column model:

```swift
struct PaneColumnState: Equatable, Sendable {
    let id: PaneColumnID
    var panes: [PaneState]
    var width: CGFloat
    var focusedPaneID: PaneID?
}

struct PaneStripState: Equatable, Sendable {
    private(set) var columns: [PaneColumnState]
    private(set) var focusedColumnID: PaneColumnID?
    let layoutSizing: PaneLayoutSizing
}
```

Key consequences:

- widths belong to columns, not individual panes
- focus becomes two-level:
  - focused column
  - focused pane inside that column
- navigation and split logic can stay simple because the model is still non-recursive

## Command Model Direction

The current command set assumes a flat strip:

- split after focused pane
- split before focused pane

That should evolve to match the new product semantics.

Recommended commands:

```swift
enum PaneCommand: Equatable, Sendable {
    case splitHorizontally
    case splitVertically
    case closeFocusedPane
    case focusLeft
    case focusRight
    case focusUp
    case focusDown
    case focusFirstColumn
    case focusLastColumn
}
```

`split before focused pane` should be removed as a first-class user-facing concept. It is low-value in a scrolling layout compared with a true vertical split.

## Rendering Direction

### Main Strip

- The outer strip remains a horizontal `NSScrollView` or equivalent track-driven presentation.
- Each visible item in the strip is a column container.

### Column View

- A column view contains one or more vertically stacked pane containers.
- The column owns horizontal width.
- Each child pane fills the column width and receives an equal share of available height in v1.

### Motion

- Horizontal motion should continue to feel like the current scrolling pane strip.
- Vertical split/close motion should stay local to the affected column.
- Avoid global reshuffles when local structure changes.

## Interaction Constraints

These boundaries are important to keep Zentty calm:

- no recursive grid
- no vertical scrolling
- no nested horizontal split inside a stack
- no arbitrary resize controls in v1
- no screen-class-specific branching beyond the first horizontal split policy and base widths

If future versions expand the model, they should do so only after validating that the simple column/stack layout still feels predictable.

## Testing Strategy

### Layout State Tests

Add or update tests for:

- horizontal split from a single-pane column
- horizontal split from a pane inside a vertical stack
- horizontal split inserts the new column immediately to the right of the source column
- first horizontal split behavior on laptop
- first horizontal split behavior on large display
- first horizontal split behavior on ultrawide
- vertical split creating balanced heights
- vertical split refusal when the minimum pane height would be violated
- close behavior inside a vertical stack
- focus after vertical close chooses lower neighbor, then upper neighbor
- collapse from stacked column to single-pane column
- focus restore when re-entering a stacked column

### Keyboard Tests

Add or update tests for:

- `Command-D` maps to horizontal split
- `Command-Shift-D` maps to vertical split
- `Command-Option-Up/Down` navigate within a stack
- left/right navigation remains column-based

### View Tests

Add or update tests for:

- column containers render stacked panes vertically
- horizontal strip still scrolls to reveal new columns
- vertical split animations affect only the source column
- closing a stacked pane reflows only that column

## Files Likely Impacted

| File | Change |
|---|---|
| `Zentty/Layout/PaneStripState.swift` | Replace flat pane model with column model |
| `Zentty/AppState/PaneStripStore.swift` | Update split, close, and focus behaviors to operate on columns plus local stacks |
| `Zentty/Input/PaneCommand.swift` | Replace insertion-direction split commands with horizontal/vertical split semantics |
| `Zentty/Input/KeyboardShortcutResolver.swift` | Map `Command-D` to horizontal split and `Command-Shift-D` to vertical split; add vertical focus shortcuts |
| `Zentty/AppMenuBuilder.swift` | Rename menu items to match the new split semantics |
| `Zentty/UI/PaneStripView.swift` | Render columns that contain vertical pane stacks |
| `Zentty/Motion/PaneStripMotionController.swift` | Preserve horizontal strip motion while allowing local vertical reflow |
| `Zentty/Layout/PaneLayoutPreferences.swift` | Shift from density vocabulary toward explicit screen-behavior presets |
| `Zentty/UI/PaneLayoutSettingsWindowController.swift` | Rework copy and presentation for `Laptop`, `Large Display`, and `Ultrawide Hybrid` |
| `ZenttyTests/*` | Update state, input, motion, and settings tests for the new model |

## Recommended Rollout

Implement in this order:

1. Introduce column state and keep behavior equivalent for single-pane columns.
2. Rename split commands and shortcuts to the new semantics.
3. Add vertical stack support in state and rendering.
4. Add vertical navigation and focus restoration.
5. Rework settings UI and copy to match the new opinionated behavior.

This sequence keeps the migration testable and avoids changing layout state, input semantics, and UI copy all at once.
