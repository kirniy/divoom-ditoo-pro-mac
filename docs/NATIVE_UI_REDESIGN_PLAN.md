# Native macOS UI Redesign Plan

## Scope

This plan covers the native AppKit UI only:

- menu bar root menu
- top hero / summary area
- quick actions / tiles
- submenu information architecture
- animation library window

It is based on the current AppKit implementation in `macos/DivoomMenuBar/main.swift` and the current screenshot feedback that the shell still feels like a utility panel instead of a polished Mac product.

## Design thesis

The app should feel like a calm, native desktop companion for a physical desk display.

Right now it feels like:

- multiple frosted cards stacked together
- too many equally-loud actions in a narrow column
- status copy competing with navigation
- a library window that behaves like an internal tool

The redesign should push toward:

- one clear primary state at the top
- one obvious next action
- one coherent navigation model
- restrained glass, not blur everywhere
- motion only for state change, not ambient decoration

## Sharp critique of the current UI

### Root menu

- The root menu tries to be a dashboard, launcher, and settings surface at the same time.
- The summary card and the quick-tile hub are visually equal, so there is no real hierarchy.
- The menu is dense enough that it reads like a control center clone, but without the discipline of Control Center.

### Hero / summary

- The hero is over-packed for a 416pt-wide menu.
- Title, subtitle, headline, rotating copy, and three chips are too many layers for one small card.
- The rotating line makes the card feel unstable and harder to scan.
- Library and cloud inventory are being surfaced in the hero even though they are not hero-level information.
- The screenshot shows the top card feeling foggy and indecisive rather than crisp and intentional.

### Quick tiles

- Six equal tiles flatten importance.
- `Library` is navigation, while `Codex Live` and `Claude Live` are runtime modes. Those should not have the same visual weight.
- `IP Flag` is too niche to sit on the main deck beside core actions.
- The tile surfaces are too pillowy and too similar, which makes the whole cluster feel toy-like.

### Section hierarchy

- The root menu repeats concepts across the custom top area and the submenu rows below.
- `Library` exists as both a top tile and a submenu, but the surrounding shell does not explain why the user should use one vs the other.
- `Studio`, `Library`, `Live Feeds`, and `Ambient & Device` are reasonable buckets, but the route into them is not visually staged.

### Library shell

- The library header is trying to be a hero, toolbar, status area, and analytics strip.
- The current top block in `AnimationLibraryWindowController` is a control panel, not a native browsing shell.
- Search, stats, filters, account actions, and source state are all competing for the same horizontal strip.

### Filter and search layout

- `Search Cloud` as a sibling to normal search is a UX smell.
- Advanced filters expanding as a second horizontal row creates a toolbar-on-toolbar effect.
- Source, scope, category, collection, sort, display mode, favorites-only, refresh, sync, login, and cloud search are too many peers.

### Beam / send affordances

- Beam is exposed in too many places with too many different weights:
  - hover overlay
  - inspector primary button
  - collection item primary hover action
  - result label status text
- The app should pick one primary send interaction and make the others clearly secondary.
- `Beam to Ditoo` is also too verbose for repeated UI. `Beam` is enough once context is clear.

### Login affordance

- The underlying cloud credential state machine is decent.
- The affordance is not.
- `Cloud Login…`, `Import Cloud…`, and `Manage Cloud` are functionally correct but feel like setup plumbing.
- Cloud state should feel like a product capability, not a credential wizard.

## Target experience

### Root menu structure

Use one custom root surface, then one clean navigation list.

1. Hero
2. Primary actions
3. Live modes
4. Standard submenu rows
5. Footer utilities

This is intentionally simpler than the current two-card dashboard.

### Hero redesign

The hero should answer only three questions:

1. Is the Ditoo connected?
2. What is it doing right now?
3. What should I do next?

#### Proposed layout

- top row: app title + device state glyph
- primary line: one stable sentence
- secondary line: one short contextual sentence
- chip row: max two chips

#### Content rules

- Remove rotating copy entirely.
- Do not show favorites count or cloud count in the hero.
- Do not show more than one error or warning sentence at a time.
- If a live mode is active, that becomes the primary line.
- If Bluetooth is blocked, that becomes the primary line.
- Otherwise the primary line should direct the next action, likely `Open Library`, `Open Studio`, or `Beam last favorite`.

#### Native visual rules

- Keep one glass card, not layered fog.
- Use a stronger internal edge highlight and a quieter shadow.
- Let the backdrop shader animate subtly, but keep text layout stable.
- Animate state changes with crossfades, not tickers.

### Quick-action redesign

The current six equal tiles should be split into primary actions and live-mode controls.

#### Primary actions

Use three large actions:

- `Library`
- `Studio`
- `Favorites`

Recommended behavior:

- `Library`: opens the native animation browser
- `Studio`: opens the color/motion surface
- `Favorites`: starts or resumes favorite rotation, with a subtle status sublabel

Optional fourth action if needed:

- `Beam Last`

Do not keep `IP Flag` in the primary deck.

#### Live-mode controls

Replace separate large tiles for `Codex Live`, `Claude Live`, `Split Live`, and `IP Flag` with a compact live shelf:

- a labeled row: `Live`
- 3 compact toggle pills: `Codex`, `Claude`, `Split`
- an overflow submenu entry for `IP Flag`

This keeps live modes present but stops them from dominating the root surface.

#### Visual rules

- Make tiles flatter and more native.
- Reduce radius and shadow depth.
- Use accent only for active state, not as permanent decoration.
- Keep provider marks small and crisp.
- Reintroduce short subtitles only when they add meaning, for example `Connected`, `Running`, or `Last used`.

### Root submenu IA

Below the custom root surface, keep the classic submenu model, but tighten the buckets.

#### Proposed root buckets

- `Studio`
- `Library`
- `Live`
- `Device`
- `Settings`

#### Bucket responsibilities

`Studio`

- colors
- motion
- screen pick
- recent beams

`Library`

- open library window
- library settings
- curated folder
- cloud sync / reveal cloud folder

`Live`

- Codex
- Claude
- Split
- Favorites rotation
- IP flag

`Device`

- Bluetooth access
- diagnostics
- volume / sound
- dashboards
- clocks

`Settings`

- app settings
- about
- logs
- repo / releases
- research notes

#### IA rules

- Rename `Live Feeds` to `Live`.
- Rename `Ambient & Device` to `Device`.
- Keep `Quit` in the footer, separated from the settings submenu.
- Do not add more dashboard-like custom views below the main hero/actions block.

## Library window redesign

### Shell architecture

The current library should stop pretending to be a giant hero panel.

Use a more native Finder-like or Photos-like structure:

- unified titlebar and toolbar
- left sidebar for browsing dimensions
- center content pane for grid/list
- right inspector for preview and actions

This can stay fully AppKit.

#### Recommended native structure

- `NSWindow` / `NSPanel` with unified titlebar styling
- `NSToolbar` for search and primary controls
- `NSSplitViewController` or equivalent split layout
- sidebar item
- browser item
- inspector item

### Library header and toolbar

Move most of the current hero controls into the titlebar toolbar.

#### Toolbar content

- search field
- source selector
- sort menu
- display mode toggle
- cloud state button
- sync button

#### Remove from the giant top content block

- big summary sentence
- four stat chips
- second filter row
- dedicated cloud search button

If you keep any summary text at all, keep it quiet and single-line.

### Sidebar / navigation model

The current popup-based filtering model is too flat.

Move browsing dimensions into a sidebar:

- All
- Favorites
- Recents
- Local
- Cloud
- Playlists
- Search results

Then use grouped sidebar sections or chips beneath:

- Scope
- Category
- Collection

This gives the library actual information architecture instead of layered popup menus.

### Search and filter behavior

Search should be universal.

Rules:

- one search field only
- search operates within the current source / scope context
- if the current source is cloud, the search can invoke cloud-backed results
- no separate `Search Cloud` button in the main chrome

Advanced filters should not open as a second toolbar row.

Better options:

- sidebar filters
- a funnel popover
- an inspector-like filter sheet

### Browser pane

The browser should feel like a media browser, not a debug catalog.

#### Grid

- keep large pixel previews
- reduce metadata density
- title first
- one quiet metadata line
- favorite as a lightweight corner action
- source badge only when it matters

#### List

- optimize for rapid scanning
- show source, category, and collection in a calmer row
- keep path hidden by default

#### Empty state

Use a proper native empty state:

- one sentence saying why nothing is shown
- one suggested recovery action

Do not make the empty state read like a failed query string dump.

### Inspector

The inspector is the correct place for the primary send action.

#### Proposed inspector layout

- large preview
- title
- short metadata line
- tags / chips
- primary CTA: `Beam`
- secondary actions: `Reveal`, `Favorite`, `Like in Cloud`
- optional timing / loop info once parity work lands

#### Beam affordance rules

- Primary beam action lives in the inspector.
- Grid hover beam is allowed, but it should be explicitly secondary.
- Double-click on a grid item can also beam.
- Status feedback should appear beside the button or as inline inspector feedback, not be dumped into `resultsLabel`.

### Cloud login and account state

Cloud should become a native source state, not a setup task.

#### Toolbar account control

Use one button in the toolbar that changes state:

- `Connect Cloud`
- `Import from Passwords`
- `Cloud Connected`

Clicking it can open the current settings flow, but the surface itself should feel like account state.

#### Empty-state handling

If the user enters the cloud source without credentials:

- show a polished empty state
- explain what cloud unlocks
- give one primary action

Do not bury the login path in a stats sentence.

## Motion and material system

### Materials

Use fewer material recipes.

- window background: one quiet base material
- hero or elevated card: one higher-emphasis material
- tiles and inspector elements: rely more on spacing and border than repeated blur

Too many identical blur cards make the UI feel cheap.

### Animation plan

Use native AppKit animation only for meaningful transitions:

- hero state change
- tile active-state transition
- live-mode handoff
- inspector selection change
- hover overlay fade
- sidebar or filter reveal

Do not animate:

- informational text on timers
- decorative gradients beyond subtle shader drift

## Prioritized implementation plan

### Phase 1: Root menu architecture

Goal: make the root menu feel intentional and scannable.

#### Changes

- collapse the summary card into a calmer hero
- remove rotating summary lines
- split quick tiles into:
  - primary actions
  - live shelf
- rename root buckets:
  - `Live`
  - `Device`
- demote `IP Flag` out of the primary tile deck

#### Likely code areas

- `MenuSummaryView`
- `QuickActionTileView`
- `QuickActionHubView`
- `configureMenu()`
- summary copy methods:
  - `currentSummarySubtitle()`
  - `currentSummaryHeadline()`
  - `currentSummaryRotatingLines()`
  - `currentSummaryChips()`

#### Acceptance bar

- the hero fits without visual crowding
- the user can identify one primary next action in under a second
- live modes no longer crowd out core product actions

### Phase 2: Library shell

Goal: turn the library into a native media browser.

#### Changes

- remove the large in-content hero block
- move controls into a real toolbar
- add a sidebar-based browsing model
- simplify search into one universal field
- replace expanded filter row with sidebar or popover filtering

#### Likely code areas

- `AnimationLibraryWindowController`
- `updateLibrarySummary()`
- `updateCloudLoginButton()`
- filter rebuild methods
- layout code in `buildUI(in:)`

#### Acceptance bar

- search, browse, and source-switching feel like one system
- the top chrome does not wrap or feel overloaded
- cloud state is understandable without reading tooltips

### Phase 3: Inspector and beam flow

Goal: make send behavior deliberate and native.

#### Changes

- make inspector beam CTA primary
- reduce hover overlay dominance in grid
- move progress and result feedback into inspector-local state
- shorten button copy from `Beam to Ditoo` to `Beam`

#### Likely code areas

- `HoverActionPreviewView`
- `AnimationLibraryCollectionItem`
- inspector button setup in `AnimationLibraryWindowController`
- `triggerSend(for:)`
- `updateDetailPanel()`

#### Acceptance bar

- there is one obvious primary beam path
- secondary actions stay secondary
- send feedback appears where the action happened

### Phase 4: Material and motion polish

Goal: push the whole app from utility UI to native premium UI.

#### Changes

- reduce repeated blur-card styling
- unify corner radii and border treatment
- tune shadow depth
- add small `NSAnimationContext` transitions for state change
- keep all motion brief and purposeful

#### Likely code areas

- `MenuSummaryView`
- `QuickActionTileView`
- `HoverActionPreviewView`
- library card configuration in `AnimationLibraryWindowController`

#### Acceptance bar

- the UI feels lighter and less foggy
- active state changes feel crisp
- no part of the shell depends on gimmicky animation to explain itself

## Code area map

Current AppKit types most directly affected by this redesign:

- `MenuSummaryView`
- `QuickActionTileView`
- `QuickActionHubView`
- `HoverActionPreviewView`
- `AnimationLibraryCollectionItem`
- `AnimationLibraryWindowController`
- `configureMenu()`
- summary copy helpers near the bottom of `AppDelegate`

## Bottom line

The redesign should not add more chrome.

It should remove competition.

The fastest path to a more native result is:

1. calm the hero
2. split primary actions from live modes
3. simplify root IA
4. turn the library into a toolbar + sidebar + browser + inspector window
5. make cloud and beam feel like product features instead of utility controls
