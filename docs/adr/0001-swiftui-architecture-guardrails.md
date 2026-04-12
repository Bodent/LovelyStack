# ADR 0001: SwiftUI Architecture Guardrails

## Status
Accepted

## Context
ShelfDrop is a macOS SwiftUI app with a multi-pane window, scene-local UI state, and an app-wide ingest pipeline. Recent regressions came from treating visible window state, persisted app state, pane background ownership, and AppKit interop as interchangeable. Small UI edits then cascaded across multiple layers and were "fixed" by stacking more workarounds.

We need one source of truth for each kind of state and one intentional owner for each pane surface.

## Decision
- `ShelfSceneState` owns per-window transient UI state.
  - This includes visible shelf selection, selected items, search text, rename drafts, preview state, busy/error presentation, and inspector section restoration.
- `ShelfViewModel` and the store own app-wide persisted data.
  - This includes shelves, items, recent destinations, and `rememberedIngestTargetSessionID`.
  - Visible per-window selection must not be stored as shared global UI state.
- `selectedSessionID` is compatibility glue, not an architectural extension point.
  - New feature work must not use it to reintroduce shared window selection behavior.
- UI persistence defaults are:
  - `@SceneStorage` for per-window restoration.
  - model/store persistence for true app data.
  - `@AppStorage` only for real cross-window preferences.
- Background and material ownership is single-source.
  - The root window surface, the center content pane, and the inspector pane each get one intentional owner.
  - Do not add host-view "clear/fix" helpers to fight SwiftUI backgrounds.
- AppKit interop is a narrow escape hatch.
  - It is allowed for window chrome, responder-chain behaviors, system panels, Finder integration, or other macOS behaviors SwiftUI does not model cleanly.
  - It must not be used to patch styling or pane backgrounds that should remain declarative in SwiftUI.
- Oversized root views are architectural risk.
  - If a root scene begins mixing layout, pane styling, inspector sections, drag/drop, and AppKit bridges again, split it before merging.

## Edit Protocol
Before changing pane backgrounds, selection behavior, inspector persistence, or split-view structure:

1. Identify the current owner in code.
2. Change only that owner.
3. If the change appears to require touching multiple state owners or both SwiftUI and AppKit, stop and do a short architecture check before adding another workaround.

## Review Contract
Every UI-affecting pull request must answer:

- Does this add new global UI state that should be scene-local?
- Does this introduce a second background or material owner for the same pane?
- Does this use `@AppStorage` for state that is really window or scene state?
- Does this add AppKit mutation for something that should remain declarative in SwiftUI?

If any answer is yes, the PR must include an explicit justification.

## Consequences
- UI behavior becomes more predictable across multiple windows.
- Future changes have a written contract and regression tests.
- Some UI changes will require a small amount of up-front architecture discipline, but that is cheaper than reintroducing styling and state loops.
