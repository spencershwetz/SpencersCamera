# Technical Tasks & Refactoring

This file tracks necessary technical improvements, refactoring tasks, technical debt, and items to review for the Spencer's Camera project.

1.  **Implement Testing Strategy**
    *   **Description**: Create XCTest/XCUITest targets. Implement unit tests for ViewModels (mocking services), services (especially camera logic, format finding, LUT loading/parsing), and utilities. Implement UI tests for critical user flows (recording start/stop, changing settings, importing LUTs, navigating library).
    *   **Priority**: High
    *   **Files**: Requires new test targets and test files (`*Tests.swift`). Tests would target most existing Swift files.
    *   **Dependencies**: Improved error handling (Task #3) and service decoupling (Task #6) would facilitate testing.

2.  **Review Orientation Handling Logic [COMPLETED]**
    *   **Description**: Analyzed the complex interaction between `AppDelegate`, `OrientationFixView`, `RotatingView`, `DeviceOrientationViewModel`, `CameraViewModel`, and `RecordingService` regarding UI rotation and video metadata orientation. Simplified by centralizing UI orientation in `DeviceOrientationViewModel`, removing direct handling in `CameraViewModel`/`CameraView`, and relying on `RecordingService` for metadata. Simplified `AppDelegate`/`OrientationFixView` logic.
    *   **Priority**: High
    *   **Files**: `AppDelegate.swift`, `OrientationFixView.swift`, `RotatingView.swift`, `DeviceOrientationViewModel.swift`, `CameraViewModel.swift`, `RecordingService.swift`, `UIDeviceOrientation+Extensions.swift`, `CameraView.swift`.
    *   **Dependencies**: May impact Task #4 (UI Refinements).

3.  **Improve Error Handling & Presentation**
    *   **Description**: Systematically review error handling paths. Ensure all potential errors (AVFoundation session/device config, Metal shader compilation/runtime, `AVAssetWriter` errors, File I/O, `PHPhotoLibrary` saving, WatchConnectivity) are caught, logged appropriately, and presented to the user in a non-disruptive way (e.g., subtle alerts, status indicators in UI). Consider specific error codes/messages for `CameraError`.
    *   **Priority**: Medium
    *   **Files**: App-wide, especially `CameraViewModel.swift` and all Service classes.
    *   **Dependencies**: None.

4.  **Refine Dynamic Island / Notch Area UI Layout [COMPLETED]**
    *   **Description**: Improved the layout and positioning of the function buttons (`FunctionButtonsView`) to better adapt to the Dynamic Island or notch area on different devices, avoiding overlaps or awkward spacing, by removing `ignoresSafeArea()` and adjusting padding. Ensured hit targets are adequate and layout calculations are robust. This is primarily a layout correctness task.
    *   **Priority**: Medium
    *   **Files**: `FunctionButtonsView.swift`, `CameraView.swift`.
    *   **Dependencies**: Potentially Task #2 (Orientation Logic Review).

5.  **Review Camera Service Dependencies & Responsibilities**
    *   **Description**: Examine the interactions between camera services. For example, `CameraDeviceService` calls `VideoFormatService.findBestFormat` and `reapplyColorSpaceSettings`. Ensure responsibilities are clear (e.g., who is ultimately responsible for setting the `activeFormat` vs. `activeColorSpace` vs. frame durations during a lens switch or format change?). Minimize coupling where possible for better maintainability and testability.
    *   **Priority**: Medium
    *   **Files**: All files within `iPhoneApp/Features/Camera/Services/`, `CameraViewModel.swift`.
    *   **Dependencies**: None.

6.  **Profile Metal Performance**
    *   **Description**: Use Instruments (Metal System Trace, GPU Counters) to profile the Metal preview rendering (`MetalPreviewView`, fragment shaders) and the compute kernels (`MetalFrameProcessor`, compute shaders) used for LUT bake-in. Check for high GPU/CPU usage, memory bandwidth issues, or pipeline stalls, especially with 4K/ProRes/Log workflows. Optimize shaders and resource usage as needed.
    *   **Priority**: Medium
    *   **Files**: `MetalPreviewView.swift`, `MetalFrameProcessor.swift`, `PreviewShaders.metal`.
    *   **Dependencies**: Requires running on a physical device.

7.  **Implement Structured Logging**
    *   **Description**: Replace basic `print`/`os.log` statements with a more structured logging framework (e.g., using unified `OSLog` more effectively, `Pulse`, `OSLogStore` for on-device inspection) for better debugging, performance monitoring, and production issue tracking. This enhances maintainability.
    *   **Priority**: Medium
    *   **Files**: App-wide integration, potentially a dedicated logging service/wrapper.
    *   **Dependencies**: None.

8.  **Improve Accessibility Implementation**
    *   **Description**: Ensure proper implementation of accessibility modifiers (`.accessibilityLabel`, `.accessibilityHint`, `.accessibilityValue`, etc.) for all interactive UI elements. Verify VoiceOver navigation and usability. Test Dynamic Type support thoroughly. This is essential for app quality and usability.
    *   **Priority**: Medium
    *   **Files**: All UI files (`*View.swift`).
    *   **Dependencies**: None.

9.  **Address Empty `Core/Services/` Directory**
    *   **Description**: The `iPhoneApp/Core/Services/` directory is currently empty. Decide if this is reserved for future truly *core* services (unrelated to specific features like Camera or LUT) or if it should be removed for structural clarity.
    *   **Priority**: Low
    *   **Files**: `iPhoneApp/Core/Services/` directory.
    *   **Dependencies**: None.

10. **Review Hardcoded Values**
    *   **Description**: Search for hardcoded numbers/strings (e.g., UI padding/sizes, default settings, queue labels, notification names). Replace with named constants (`Constants.swift`?), enums, or configuration values where appropriate for better maintainability and clarity.
    *   **Priority**: Low
    *   **Files**: App-wide search needed.
    *   **Dependencies**: None.

11. **REMOVE: Review/Remove `LUTVideoPreviewView`** (Related to original Task #13)
    *   **Description**: The `LUTVideoPreviewView` (and `LUTProcessor`) seems outdated and potentially conflicts with the primary `MetalPreviewView` and `MetalFrameProcessor` used for preview and bake-in. It uses Core Image for processing and a separate `AVCaptureVideoPreviewLayer`, which differs from the main Metal pipeline. Review its necessity and remove if redundant to simplify the codebase and focus on the Metal path.
    *   **Priority**: Low
    *   **Files**: `LUTVideoPreviewView.swift`, `LUTProcessor.swift`.
    *   **Dependencies**: Depends on confirming `MetalFrameProcessor` fully handles bake-in needs.

*(Priorities and dependencies are estimates and may change.)*

---

# Future Features / Enhancements

This section lists potential features and improvements for future consideration.

1.  **GPS Data Tagging for Videos**
    *   **Description**: Capture the user's location (with permission) while recording and embed GPS coordinates (latitude, longitude, altitude, timestamp) into the video file's metadata (e.g., using `AVMetadataItem`).
    *   **Priority**: Low/Medium (Feature)
    *   **Files**: `RecordingService.swift`, potentially a new `LocationService.swift` (using `CoreLocation`).
    *   **Dependencies**: Requires adding `CoreLocation` framework and handling location permissions (`Info.plist` keys).

2.  **DockKit Integration**
    *   **Description**: Implement support for DockKit-compatible motorized stands. Allow the app to detect connection, potentially control pan/tilt for subject tracking, and query dock status.
    *   **Priority**: Low (Feature / Accessory Support)
    *   **Files**: New services/managers related to DockKit framework (`DockKit`), potentially impacting `CameraViewModel.swift` or a dedicated `DockManager.swift`.
    *   **Dependencies**: Requires adding `DockKit` framework, handling relevant entitlements and permissions.

3.  **External Camera Control Button Support**
    *   **Description**: Allow external hardware buttons (e.g., volume buttons, dedicated Bluetooth shutter remotes, potentially MFi accessory buttons) to trigger actions like starting/stopping recording or taking a photo (if photo mode is added).
    *   **Priority**: Low (Feature / Usability)
    *   **Files**: Potentially `CameraViewModel.swift`, `AppDelegate.swift` (for handling certain system events), or a dedicated input handling service.
    *   **Dependencies**: May require different approaches depending on the type of control (Volume buttons vs. Bluetooth HID vs. MFi).
