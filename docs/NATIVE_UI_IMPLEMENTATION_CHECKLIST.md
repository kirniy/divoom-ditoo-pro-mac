# Native macOS UI Implementation Checklist

Companion to `docs/NATIVE_UI_REDESIGN_PLAN.md`.

This checklist turns the redesign direction into an implementation sequence against the current AppKit code in `macos/DivoomMenuBar/main.swift`.

The first five items are intentionally chosen for:

- high visible UX payoff
- low to moderate breakage risk
- minimal architectural churn

## Start here: highest leverage, lowest breakage

### 1. Calm the root hero and remove the rotating ticker

- Priority: P0
- Breakage risk: Low
- Why first: The current top card is the most obvious quality problem in the screenshot. Simplifying it will immediately make the app feel more native.
- Current code anchors:
  - `MenuSummaryView`
  - `updateRotatingLines(_:)`
  - `currentSummarySubtitle()`
  - `currentSummaryHeadline()`
  - `currentSummaryRotatingLines(...)`
  - `currentSummaryChips(...)`
- Implementation checklist:
  - [ ] Remove timed rotating summary copy from `MenuSummaryView`.
  - [ ] Keep one primary line and one secondary line only.
  - [ ] Reduce hero chips from 3 to 2 max.
  - [ ] Stop surfacing favorites/cloud counts in the hero.
  - [ ] Tighten hero copy so the default state reads like one stable product sentence.
- Acceptance:
  - [ ] The hero no longer animates text on a timer.
  - [ ] The top card reads cleanly in one glance.
  - [ ] No line wraps feel accidental at the current `rootMenuSurfaceWidth`.

### 2. Rename and tighten the root menu IA without changing the underlying submenu model

- Priority: P0
- Breakage risk: Low
- Why first: It improves clarity immediately and does not require any new AppKit structures.
- Current code anchors:
  - `configureMenu()`
  - submenu titles and `makeSubmenuItem(...)` calls
- Implementation checklist:
  - [ ] Rename `Live Feeds` to `Live`.
  - [ ] Rename `Ambient & Device` to `Device`.
  - [ ] Review submenu section headers so they read like product navigation, not internal categories.
  - [ ] Keep `Quit` as the separated footer action.
  - [ ] Avoid adding any more custom view blocks below the hero/actions area.
- Acceptance:
  - [ ] The menu reads as five clean buckets: `Studio`, `Library`, `Live`, `Device`, `Settings`.
  - [ ] The labels are shorter and more native.

### 3. Rebalance the quick-action area before redesigning it fully

- Priority: P0
- Breakage risk: Low to Medium
- Why first: The equal-weight tile deck is hurting hierarchy now. A lighter rebalance gives most of the benefit before a bigger component rewrite.
- Current code anchors:
  - `QuickActionTileView`
  - `QuickActionHubView`
  - root callbacks wired in `configureMenu()`
- Implementation checklist:
  - [ ] Demote `IP Flag` from the root tile deck.
  - [ ] Keep root quick actions focused on core tasks:
    - `Library`
    - `Codex Live`
    - `Claude Live`
    - `Split`
    - `Favorites`
  - [ ] Use the freed slot for either `Studio` or `Beam Last`, whichever requires less wiring.
  - [ ] Reduce tile visual weight:
    - smaller shadow
    - flatter background
    - less permanent tint
  - [ ] Reintroduce subtitles only for meaningful state, not filler copy.
- Acceptance:
  - [ ] Root actions feel less toy-like.
  - [ ] The top action deck no longer gives niche actions equal status with core flows.

### 4. Simplify the library top block without rebuilding the whole window yet

- Priority: P0
- Breakage risk: Low to Medium
- Why first: The library currently looks like an internal tool because the top block is overloaded. You can get a major improvement by subtracting before re-architecting.
- Current code anchors:
  - `AnimationLibraryWindowController.buildUI(in:)`
  - `summaryLabel`
  - header chips
  - `utilityRow`
  - `advancedFilterRow`
  - `updateLibrarySummary(...)`
- Implementation checklist:
  - [ ] Remove or demote the four large stat chips from the header.
  - [ ] Collapse the summary text to one quiet line.
  - [ ] Remove `Search Cloud` from the top row.
  - [ ] Keep one search field and one compact control row.
  - [ ] Keep advanced filters hidden by default and reduce their visual prominence.
- Acceptance:
  - [ ] The top of the library no longer feels like a dashboard.
  - [ ] Search becomes the primary control, not one of many competing peers.

### 5. Make the inspector the clear primary beam path

- Priority: P0
- Breakage risk: Low
- Why first: The send action is currently duplicated across overlay, grid, and inspector. Clarifying the primary path improves UX with minimal architecture change.
- Current code anchors:
  - `HoverActionPreviewView`
  - `AnimationLibraryCollectionItem`
  - `sendButton`
  - `triggerSend(for:)`
  - `updateDetailPanel()`
- Implementation checklist:
  - [ ] Shorten the primary CTA label from `Beam to Ditoo` to `Beam`.
  - [ ] Keep the inspector button as the main send path.
  - [ ] Reduce the visual dominance of the grid hover overlay.
  - [ ] Move send feedback closer to the inspector action rather than relying on `resultsLabel`.
  - [ ] Keep hover beam as a convenience action, not the dominant interaction model.
- Acceptance:
  - [ ] There is one obvious primary send action.
  - [ ] The browser grid feels less noisy.

## Next wave: moderate change, still worthwhile

### 6. Convert the quick-action deck into primary actions plus a compact live shelf

- Priority: P1
- Breakage risk: Medium
- Current code anchors:
  - `QuickActionHubView`
  - likely a new lightweight live toggle view
- Checklist:
  - [ ] Replace the 2x3 equal tile matrix with:
    - primary action row
    - compact live controls row
  - [ ] Keep `Codex`, `Claude`, and `Split` as compact live toggles.
  - [ ] Move `IP Flag` to submenu or overflow behavior only.

### 7. Replace the library popup-heavy browsing model with sidebar-driven browsing

- Priority: P1
- Breakage risk: Medium to High
- Current code anchors:
  - `AnimationLibraryWindowController`
  - source/scope/category/collection popup rebuild methods
- Checklist:
  - [ ] Introduce a sidebar with source and saved views.
  - [ ] Move scope/category/collection browsing into the sidebar or a secondary filter surface.
  - [ ] Reduce popup controls to sort and display mode only.

### 8. Replace the in-content library hero with a real native toolbar

- Priority: P1
- Breakage risk: Medium to High
- Current code anchors:
  - `AnimationLibraryWindowController`
  - current `heroCard` build path
- Checklist:
  - [ ] Move search and source controls into `NSToolbar`.
  - [ ] Keep cloud state and sync in the toolbar.
  - [ ] Shrink or remove the current giant top header block.

### 9. Turn cloud login into a stateful source control

- Priority: P1
- Breakage risk: Medium
- Current code anchors:
  - `updateCloudLoginButton()`
  - `openCloudSettings()`
  - cloud empty-state handling
- Checklist:
  - [ ] Replace setup-style language with source-state language:
    - `Connect Cloud`
    - `Import from Passwords`
    - `Cloud Connected`
  - [ ] Add a proper cloud empty state when cloud browsing is unavailable.
  - [ ] Remove login guidance from the main library summary sentence.

### 10. Add native transition polish for state changes only

- Priority: P1
- Breakage risk: Low to Medium
- Current code anchors:
  - `HoverActionPreviewView.updateOverlay(animated:)`
  - root hero update path
  - tile appearance update path
- Checklist:
  - [ ] Add `NSAnimationContext` transitions for hero state changes.
  - [ ] Animate tile active-state changes subtly.
  - [ ] Animate inspector content swaps cleanly.
  - [ ] Do not add decorative motion to informational copy.

## Structural work after the shell is calmer

### 11. Rebuild the library using a true sidebar + browser + inspector split structure

- Priority: P2
- Breakage risk: High
- Current code anchors:
  - `AnimationLibraryWindowController`
  - split-view layout creation
- Checklist:
  - [ ] Migrate toward a true three-pane layout.
  - [ ] Keep the inspector persistent.
  - [ ] Make the browser feel closer to Finder or Photos than a debug asset list.

### 12. Revisit collection item density and metadata hierarchy

- Priority: P2
- Breakage risk: Medium
- Current code anchors:
  - `AnimationLibraryCollectionItem`
- Checklist:
  - [ ] Reduce metadata noise in grid mode.
  - [ ] Hide file-path style strings by default in grid mode.
  - [ ] Keep source badges only where they clarify mixed-source browsing.

### 13. Introduce proper empty states and recovery actions across the shell

- Priority: P2
- Breakage risk: Low
- Current code anchors:
  - root hero copy helpers
  - library `emptyLabel`
  - cloud state handling
- Checklist:
  - [ ] Add explicit empty states for no results, no cloud login, and no selection.
  - [ ] Pair each empty state with one direct recovery action.

### 14. Unify material, radius, border, and shadow rules across all custom AppKit surfaces

- Priority: P2
- Breakage risk: Low to Medium
- Current code anchors:
  - `MenuSummaryView`
  - `QuickActionTileView`
  - `QuickActionHubView`
  - `AnimationLibraryCollectionItem`
  - `AnimationLibraryWindowController.configureCard(...)`
- Checklist:
  - [ ] Define one quiet base surface recipe.
  - [ ] Define one elevated surface recipe.
  - [ ] Remove the current “everything is a frosted card” effect.

## Suggested execution order

1. Hero cleanup
2. Root menu label / IA cleanup
3. Quick-action rebalance
4. Library header simplification
5. Beam-path clarification
6. Quick-action live shelf redesign
7. Cloud state redesign
8. Sidebar-based library browsing
9. Toolbar migration
10. Material and motion polish

## Definition of success for the first pass

The first pass is successful if all of the following are true:

- [ ] The root menu no longer looks crowded in a screenshot.
- [ ] The hero reads as status plus next action, not status plus marketing plus inventory.
- [ ] The quick-action deck emphasizes core flows over novelty actions.
- [ ] The library top block no longer feels like a utility dashboard.
- [ ] `Beam` has one primary home in the inspector.

## Code review guardrails while implementing

- [ ] Do not rewrite the whole library shell before subtracting obvious clutter.
- [ ] Do not add more custom views to the root menu.
- [ ] Do not solve hierarchy problems with width alone.
- [ ] Do not keep timed rotating text anywhere in the shell.
- [ ] Do not let cloud/login copy leak into primary hero messaging unless it is the blocking state.
