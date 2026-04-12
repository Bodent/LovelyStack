## Summary
- 

## Validation
- [ ] `xcodebuild -project LovelyStack.xcodeproj -scheme ShelfDrop -configuration Debug build`
- [ ] `xcodebuild -project LovelyStack.xcodeproj -scheme ShelfDrop -configuration Debug test -only-testing:ShelfDropAppTests -only-testing:ShelfDropCoreTests`

## UI Architecture Checklist
- [ ] This change does not add new shared global UI state that should be scene-local.
- [ ] This change does not introduce a second background or material owner for the same pane.
- [ ] This change does not use `@AppStorage` for state that should be window- or scene-local.
- [ ] This change does not add AppKit mutation for styling that should stay declarative in SwiftUI.

If any item above is not true, explain the architectural exception here:

-
