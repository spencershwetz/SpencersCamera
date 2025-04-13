# Project To-Do List

This list tracks potential improvements, refactoring tasks, and items to review in the Spencer's Camera codebase, prioritized by importance.

## High Priority

- [ ] **Remove Unused LUT Processor (`LUTProcessor.swift`)**
    - Verify no code paths reference `LUTProcessor.swift`.
    - If unused, remove the file and related setup code.
- [ ] **Evaluate/Remove `TestDynamicIslandOverlayView.swift`**
    - Determine if the view is still needed for testing or active development.
    - If not needed, remove the file.

## Medium Priority

- [ ] **Refactor Camera Preview View Abstraction**
    - Review the `CameraPreviewView` -> `CameraPreviewImplementation` -> `MetalPreviewView` hierarchy.
    - Investigate simplifying by merging `CameraPreviewImplementation` or having `CameraPreviewView` represent `MetalPreviewView` directly.
- [ ] **Consolidate Orientation Logic**
    - Review responsibilities of files in `Core/Orientation/`.
    - Ensure a clear source of truth for orientation state.
    - Simplify or remove redundant components/observers (check `CameraViewModel` for old observer code).
- [ ] **Review Service Dependencies and Protocols**
    - Ensure service delegate protocols are minimal and well-defined.
    - Evaluate using Combine or async streams for state updates between services and `CameraViewModel` instead of multiple delegate callbacks.

## Low Priority

- [ ] **Review AppDelegate Responsibilities**
    - Identify logic in `AppDelegate.swift` that could be moved to the SwiftUI `App` struct or `ScenePhase`.
    - Keep necessary UIKit integration points.
- [ ] **Establish `UI` and `Resources` Directories**
    - Create `iPhoneApp/UI/` and `iPhoneApp/Resources/` if intended for the structure.
    - Populate or remove the empty `iPhoneApp/Core/Services/` directory based on plans.
- [ ] **Refine Error Handling**
    - Ensure robust error propagation from background tasks/async operations to the UI.
    - Verify user-facing error messages are clear and appropriate.
- [ ] **Review Watch Connectivity Robustness**
    - Check `WatchConnectivityService.swift` and `CameraViewModel` for edge case handling (reachability, activation state).
    - Ensure state synchronization and command handling are resilient. 