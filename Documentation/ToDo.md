# Technical Tasks & Refactoring

This file tracks necessary technical improvements, refactoring tasks, technical debt, and items to review for the Spencer's Camera project.

## Completed Tasks

1.  ~~**Review Orientation Handling Logic [COMPLETED]**~~
    *   **Description**: Analyzed the complex interaction between `AppDelegate`, `OrientationFixView`, `RotatingView`, `DeviceOrientationViewModel`, `CameraViewModel`, and `RecordingService` regarding UI rotation and video metadata orientation. Simplified by centralizing UI orientation in `DeviceOrientationViewModel`, removing direct handling in `CameraViewModel`/`CameraView`, and relying on `RecordingService` for metadata. Simplified `AppDelegate`/`OrientationFixView` logic.
    *   **Original Priority**: High
    *   **Files**: `AppDelegate.swift`, `OrientationFixView.swift`, `RotatingView.swift`, `DeviceOrientationViewModel.swift`, `CameraViewModel.swift`, `RecordingService.swift`, `UIDeviceOrientation+Extensions.swift`, `CameraView.swift`.

2.  ~~**Refine Dynamic Island / Notch Area UI Layout [COMPLETED]**~~
    *   **Description**: Improved the layout and positioning of the function buttons (`FunctionButtonsView`) to better adapt to the Dynamic Island or notch area on different devices, avoiding overlaps or awkward spacing, by removing `ignoresSafeArea()` and adjusting padding. Ensured hit targets are adequate and layout calculations are robust. This is primarily a layout correctness task.
    *   **Original Priority**: Medium
    *   **Files**: `FunctionButtonsView.swift`, `CameraView.swift`.

## Active Tasks

3.  **Implement Testing Strategy** (Was #1)
    *   **Description**: Create XCTest/XCUITest targets. Implement unit tests for ViewModels (mocking services), services (especially camera logic, format finding, LUT loading/parsing), and utilities. Implement UI tests for critical user flows (recording start/stop, changing settings, importing LUTs, navigating library).
    *   **Priority**: High
    *   **Files**: Requires new test targets and test files (`*Tests.swift`). Tests would target most existing Swift files.
    *   **Dependencies**: Improved error handling (Task #4) and service decoupling (Task #6) would facilitate testing.

4.  **Implement Robust Permission Handling** (Was #12)
    *   **Description**: Ensure the application gracefully handles all states of essential permissions (Camera, Microphone, Photo Library, Location [if added]). This includes checking authorization status on launch/relevant feature access, disabling UI/features appropriately if denied, guiding the user to Settings if needed, and handling changes in permission status while the app is running or between launches. Avoid crashes or undefined behavior due to missing permissions.
    *   **Priority**: High (Core Functionality / Stability)
    *   **Files**: App-wide, especially `CameraViewModel.swift`, `AppDelegate.swift` (or startup sequence), `PhotoLibraryService.swift` (if exists), potentially a new `PermissionManager.swift`.
    *   **Dependencies**: Related to Task #5 (Error Handling).

5.  **Improve Error Handling & Presentation** (Was #3)
    *   **Description**: Systematically review error handling paths. Ensure all potential errors (AVFoundation session/device config, Metal shader compilation/runtime, `AVAssetWriter` errors, File I/O, `PHPhotoLibrary` saving, WatchConnectivity) are caught, logged appropriately, and presented to the user in a non-disruptive way (e.g., subtle alerts, status indicators in UI). Consider specific error codes/messages for `CameraError`.
    *   **Priority**: Medium
    *   **Files**: App-wide, especially `CameraViewModel.swift` and all Service classes.
    *   **Dependencies**: None.

6.  **Review Camera Service Dependencies & Responsibilities** (Was #5)
    *   **Description**: Examine the interactions between camera services. For example, `CameraDeviceService` calls `VideoFormatService.findBestFormat` and `reapplyColorSpaceSettings`. Ensure responsibilities are clear (e.g., who is ultimately responsible for setting the `activeFormat` vs. `activeColorSpace` vs. frame durations during a lens switch or format change?). Minimize coupling where possible for better maintainability and testability.
    *   **Priority**: Medium
    *   **Files**: All files within `iPhoneApp/Features/Camera/Services/`, `CameraViewModel.swift`.
    *   **Dependencies**: None.

7.  **Profile Metal Performance** (Was #6)
    *   **Description**: Use Instruments (Metal System Trace, GPU Counters) to profile the Metal preview rendering (`MetalPreviewView`, fragment shaders) and the compute kernels (`MetalFrameProcessor`, compute shaders) used for LUT bake-in. Check for high GPU/CPU usage, memory bandwidth issues, or pipeline stalls, especially with 4K/ProRes/Log workflows. Optimize shaders and resource usage as needed.
    *   **Priority**: Medium
    *   **Files**: `MetalPreviewView.swift`, `MetalFrameProcessor.swift`, `PreviewShaders.metal`.
    *   **Dependencies**: Requires running on a physical device.

8.  **Implement Structured Logging** (Was #7)
    *   **Description**: Replace basic `print`/`os.log` statements with a more structured logging framework (e.g., using unified `OSLog` more effectively, `Pulse`, `OSLogStore` for on-device inspection) for better debugging, performance monitoring, and production issue tracking. This enhances maintainability.
    *   **Priority**: Medium
    *   **Files**: App-wide integration, potentially a dedicated logging service/wrapper.
    *   **Dependencies**: None.

9.  **Improve Accessibility Implementation** (Was #8)
    *   **Description**: Ensure proper implementation of accessibility modifiers (`.accessibilityLabel`, `.accessibilityHint`, `.accessibilityValue`, etc.) for all interactive UI elements. Verify VoiceOver navigation and usability. Test Dynamic Type support thoroughly. This is essential for app quality and usability.
    *   **Priority**: Medium
    *   **Files**: All UI files (`*View.swift`).
    *   **Dependencies**: None.

10. **Address Empty `Core/Services/` Directory** (Was #9)
    *   **Description**: The `iPhoneApp/Core/Services/` directory is currently empty. Decide if this is reserved for future truly *core* services (unrelated to specific features like Camera or LUT) or if it should be removed for structural clarity.
    *   **Priority**: Low
    *   **Files**: `iPhoneApp/Core/Services/` directory.
    *   **Dependencies**: None.

11. **Review Hardcoded Values** (Was #10)
    *   **Description**: Search for hardcoded numbers/strings (e.g., UI padding/sizes, default settings, queue labels, notification names). Replace with named constants (`Constants.swift`?), enums, or configuration values where appropriate for better maintainability and clarity.
    *   **Priority**: Low
    *   **Files**: App-wide search needed.
    *   **Dependencies**: None.

12. **REMOVE: Review/Remove `LUTVideoPreviewView`** (Was #11)
    *   **Description**: The `LUTVideoPreviewView` (and `LUTProcessor`) seems outdated and potentially conflicts with the primary `MetalPreviewView` and `MetalFrameProcessor` used for preview and bake-in. It uses Core Image for processing and a separate `AVCaptureVideoPreviewLayer`, which differs from the main Metal pipeline. Review its necessity and remove if redundant to simplify the codebase and focus on the Metal path.
    *   **Priority**: Low
    *   **Files**: `LUTVideoPreviewView.swift`, `LUTProcessor.swift`.
    *   **Dependencies**: Depends on confirming `MetalFrameProcessor` fully handles bake-in needs.

*(Priorities and dependencies are estimates and may change.)*

---

# Future Features / Enhancements

This section lists potential features and improvements for future consideration.

1.  **Manual/Auto Exposure Controls & 180-Degree Shutter Mode** (Was #4)
    *   **Description**: Implement controls for switching between Auto Exposure (AE), Manual Exposure (setting ISO and Shutter Speed), and potentially a "180-Degree Shutter Priority" mode. This mode would attempt to keep the shutter speed at `1 / (2 * FrameRate)` while adjusting ISO automatically for correct exposure. Requires UI elements for selection and manual adjustment (sliders/steppers).
    *   **Priority**: Medium/High (Core Camera Functionality)
    *   **Files**: `CameraViewModel.swift`, `CameraDeviceService.swift` (for `AVCaptureDevice` exposure controls), new UI components in `CameraView.swift` or subviews.
    *   **Dependencies**: `AVFoundation` exposure APIs (`setExposureModeCustom`, `setExposureTargetBias`, `exposureDuration`, `iso`).

2.  **Exposure Analysis Tools (Histogram, False Color, Zebras)** (Was #7)
    *   **Description**: Implement real-time video analysis tools displayed as overlays. 
        *   **Histogram**: Display luminance and/or RGB channel distribution.
        *   **False Color**: Map luminance ranges to specific colors to visualize exposure levels across the image.
        *   **Zebras**: Overlay stripes on areas exceeding a configurable IRE/luminance threshold to indicate overexposure.
    *   **Priority**: Medium/High (Pro Feature)
    *   **Files**: Likely requires updates to `MetalFrameProcessor.swift` (or a new analysis processor), new Metal shaders (`AnalysisShaders.metal`?), new UI overlay views integrated into `CameraView.swift`, settings for configuration.
    *   **Dependencies**: Metal Performance Shaders (`MPSImageHistogram`?) or custom Metal compute kernels for analysis. Requires efficient data transfer from GPU to CPU/UI or GPU-based overlay rendering.

3.  **Camera Data Heads-Up Display (HUD)** (Was #5)
    *   **Description**: Create an overlay view (HUD) on the `CameraView` to display critical real-time camera settings and status information. This includes Timecode, ISO, Shutter Speed, Aperture (if available/variable), White Balance (Kelvin/Tint), Resolution, Frame Rate (FPS), Recording Codec, Color Space (e.g., Rec.709, Apple Log), active LUT name, Recording Status (Rec/Standby), remaining storage time estimate, audio levels meter.
    *   **Priority**: Medium (Usability/Information)
    *   **Files**: New `CameraHUDView.swift`, integrated into `CameraView.swift`, data sourced from `CameraViewModel.swift`.
    *   **Dependencies**: Relies on accurate state being published by `CameraViewModel`. Timecode generation/display might need a dedicated utility or rely on `AVAssetWriter`.

4.  **Focus Peaking** (Was #8)
    *   **Description**: Highlight edges that are in sharp focus with a configurable color overlay. Helps confirm focus, especially during manual focusing.
    *   **Priority**: Medium (Focus Assist Feature)
    *   **Files**: `MetalFrameProcessor.swift` (or similar), new Metal shader for edge detection/highlighting, integrated into `CameraPreviewView`/`CameraView.swift`, settings for color/threshold.
    *   **Dependencies**: Metal compute kernel for edge detection (e.g., Sobel operator) and overlay rendering.

5.  **Composition Overlays (Horizon Level, Rule of Thirds)** (Was #9)
    *   **Description**: Provide optional visual guides for composition.
        *   **Horizon/Level Indicator**: Display a line or graphic indicating camera tilt based on motion data (`CoreMotion`).
        *   **Rule of Thirds Grid**: Overlay simple lines dividing the frame into thirds horizontally and vertically.
    *   **Priority**: Medium (Usability Feature)
    *   **Files**: New SwiftUI overlay views (`LevelIndicatorView.swift`, `GridOverlayView.swift`) integrated into `CameraView.swift`, potentially a service using `CoreMotion` (`MotionService.swift`).
    *   **Dependencies**: `CoreMotion` for level indicator. Simple drawing for grid overlay.

6.  **External USB-C Recording & Destination Indicator** (Was #10)
    *   **Description**: Enable recording directly to an external storage device connected via USB-C (relevant for iPhone 15 Pro and later). Includes adding a UI indicator (e.g., in the HUD) to clearly show whether recording is targeted to internal storage or the external device.
    *   **Priority**: Medium (Pro Feature / Hardware Dependent)
    *   **Files**: `RecordingService.swift` (to handle different output URLs), `CameraViewModel.swift` (to manage state and destination selection), `CameraView.swift`/`CameraHUDView.swift` (for the indicator), potentially new UI for destination selection.
    *   **Dependencies**: Requires handling external volume access permissions and monitoring connection status. `AVAssetWriter` needs to be configured with the correct file URL.

7.  **Expanded Codec Selection (ProRes/HEVC Variants)** (Was #11)
    *   **Description**: Provide granular control over the recording codec beyond the basic type. Allow users to select specific variants like ProRes 422 HQ, ProRes 422, ProRes 422 LT, ProRes 4444, ProRes 4444 XQ (if supported by hardware), and potentially different HEVC profiles (e.g., 10-bit HEVC).
    *   **Priority**: Medium (Pro Feature)
    *   **Files**: `SettingsView.swift` (for UI selection), `CameraViewModel.swift` (to store selection), `VideoFormatService.swift`/`RecordingService.swift` (to configure `AVCaptureSession` and `AVAssetWriter` outputs based on selected format identifier).
    *   **Dependencies**: Relies on querying device capabilities (`AVCaptureDevice.Format.supportedProResCodecTypes`, etc.) and configuring `AVOutputSettingsAssistant` or `AVAssetWriterInput` settings correctly.

8.  **Onboarding / Permissions Primer Screen** (Was #13)
    *   **Description**: Implement an initial onboarding flow or context-specific primer screens presented *before* the system permission prompts (Camera, Microphone, Photo Library, Location). These screens should clearly explain *why* each permission is needed for the app's functionality, increasing the likelihood of user acceptance.
    *   **Priority**: Medium (User Experience / Onboarding)
    *   **Files**: New SwiftUI Views (`OnboardingView.swift`, `PermissionPrimerView.swift`), integrated early in the app lifecycle or before permission-requiring features are accessed.
    *   **Dependencies**: Relies on the robust permission handling logic (Technical Task #4).

9.  **GPS Data Tagging for Videos** (Was #1)
    *   **Description**: Capture the user's location (with permission) while recording and embed GPS coordinates (latitude, longitude, altitude, timestamp) into the video file's metadata (e.g., using `AVMetadataItem`).
    *   **Priority**: Low/Medium (Feature)
    *   **Files**: `RecordingService.swift`, potentially a new `LocationService.swift` (using `CoreLocation`).
    *   **Dependencies**: Requires adding `CoreLocation` framework and handling location permissions (`Info.plist` keys).

10. **Apple Watch Companion Display Enhancements** (Was #6)
    *   **Description**: Update the SC Watch App interface to display the current Resolution, Color Space, and Recording Codec/File Type being used by the connected iPhone app. This provides quick glanceable information during recording setup or monitoring.
    *   **Priority**: Low/Medium (Companion App Feature)
    *   **Files**: `SC Watch App/ContentView.swift` (or relevant Watch App views), `WatchConnectivityService.swift` (for data transfer), `CameraViewModel.swift` (to send updated settings).
    *   **Dependencies**: Relies on `WatchConnectivity` framework for communication between iPhone and Watch.

11. **Custom Recording Save Location (incl. iCloud Drive)** (Was #12)
    *   **Description**: Allow the user to select a specific folder as the destination for saved recordings, including locations within iCloud Drive or potentially other cloud storage providers via the document picker/file system APIs.
    *   **Priority**: Low/Medium (Usability/Flexibility)
    *   **Files**: `RecordingService.swift` (to use the selected URL), `SettingsView.swift` or a dedicated file picker UI, potentially a `StorageManager` service to handle bookmarking/accessing selected locations.
    *   **Dependencies**: Requires using `UIDocumentPickerViewController` or file system APIs to select folders, handling security-scoped bookmarks for persistent access, managing potential network/iCloud delays or errors.

12. **DockKit Integration** (Was #2)
    *   **Description**: Implement support for DockKit-compatible motorized stands. Allow the app to detect connection, potentially control pan/tilt for subject tracking, and query dock status.
    *   **Priority**: Low (Feature / Accessory Support)
    *   **Files**: New services/managers related to DockKit framework (`DockKit`), potentially impacting `CameraViewModel.swift` or a dedicated `DockManager.swift`.
    *   **Dependencies**: Requires adding `DockKit` framework, handling relevant entitlements and permissions.

13. **External Camera Control Button Support** (Was #3)
    *   **Description**: Allow external hardware buttons (e.g., volume buttons, dedicated Bluetooth shutter remotes, potentially MFi accessory buttons) to trigger actions like starting/stopping recording or taking a photo (if photo mode is added).
    *   **Priority**: Low (Feature / Usability)
    *   **Files**: Potentially `CameraViewModel.swift`, `AppDelegate.swift` (for handling certain system events), or a dedicated input handling service.
    *   **Dependencies**: May require different approaches depending on the type of control (Volume buttons vs. Bluetooth HID vs. MFi).
