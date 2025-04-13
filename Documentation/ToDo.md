# Project To-Do List

This list tracks potential improvements, refactoring tasks, and items to review in the Spencer's Camera codebase, prioritized by importance.

## Tasks

1.  [ ] **Refactor `LUTVideoPreviewView` and Remove `LUTProcessor`**
    *   Modify `LUTVideoPreviewView.swift` to use `MetalFrameProcessor` for applying LUTs instead of `LUTProcessor`.
    *   Once `LUTProcessor.swift` is confirmed unused, remove the file and related setup code.

2.  ~~[x] **Remove `TestDynamicIslandOverlayView.swift`**~~
    *   ~~File appears unused outside of its own definition and previews.~~
    *   ~~Action: Delete the file `iPhoneApp/Features/Camera/Views/TestDynamicIslandOverlayView.swift`.~~ **DONE**

3.  [ ] **Refactor Camera Preview View Abstraction**
    *   Review the `CameraPreviewView` -> `CameraPreviewImplementation` -> `MetalPreviewView` hierarchy.
    *   Investigate simplifying by merging `CameraPreviewImplementation` or having `CameraPreviewView` represent `MetalPreviewView` directly.

4.  [ ] **Consolidate Orientation Logic**
    *   Review responsibilities of files in `Core/Orientation/` (`OrientationFixView`, `DeviceRotationViewModifier`, `DeviceOrientationViewModel`, `RotatingView`).
    *   Ensure a clear source of truth for orientation state.
    *   Simplify or remove redundant components/observers (check `CameraViewModel` for old observer code).

5.  [ ] **Review Service Dependencies and Protocols**
    *   Ensure service delegate protocols (`CameraSetupServiceDelegate`, `ExposureServiceDelegate`, etc.) are minimal and well-defined.
    *   Evaluate using Combine or async streams for state updates between services and `CameraViewModel` instead of multiple delegate callbacks.
    *   *Potential Dependency:* Changes might impact Error Handling (#8) and Watch Connectivity (#9) if they rely heavily on the current delegate pattern.

6.  [ ] **Review AppDelegate Responsibilities**
    *   Identify logic in `AppDelegate.swift` that could be moved to the SwiftUI `App` struct (`cameraApp.swift`) or `ScenePhase`.
    *   Keep necessary UIKit integration points.
    *   *Potential Dependency:* May affect service initialization timing/location (related to #5).

7.  [ ] **Establish `UI` and `Resources` Directories**
    *   Create `iPhoneApp/UI/` and `iPhoneApp/Resources/` if intended for the structure.
    *   Populate or remove the empty `iPhoneApp/Core/Services/` directory based on plans.

8.  [ ] **Refine Error Handling**
    *   Ensure robust error propagation from background tasks/async operations (Services) to the UI (`CameraViewModel`).
    *   Verify user-facing error messages (`CameraError.swift`) are clear and appropriate.
    *   *Potential Dependency:* Depends on how services propagate errors (related to #5).

9.  [ ] **Review Watch Connectivity Robustness**
    *   Check `WatchConnectivityService.swift` and relevant parts of `CameraViewModel` for edge case handling (reachability, activation state, app active state).
    *   Ensure state synchronization and command handling are resilient.
    *   *Potential Dependency:* Depends on how state updates are received from services (related to #5). 