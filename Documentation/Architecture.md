# Project Architecture

> **Note:** Push-to-focus (tap to set focus point) is supported. Exposure value (EV) compensation is now fully implemented with a live, continuous wheel picker. Push-to-exposure (tap to set exposure point) is not implemented in this version.

This document describes the high-level architecture and directory structure of the Spencer's Camera application.

### EV Compensation Control
- The **SimpleWheelPicker** provides precise, live control over exposure value (EV) compensation:
    - Horizontal wheel interface with haptic feedback for value changes
    - Smooth scrolling with precise value selection
    - Visual indicators for zero and current value
    - Maintains exact position when gesture ends
    - Always starts centered at 0 EV
    - **Real-time feedback:** The EV value updates continuously as you drag with optimized throttling (100ms intervals) to prevent GPU overload.
    - **Performance optimized:** Implements intelligent throttling and debouncing to prevent GPU timeouts while maintaining responsive feel.
    - **No edge bounce:** The wheel locks exactly on each tick when released, with scroll edge bouncing disabled. There is no overshoot or bounce-back at the ends.
    - **Tap-to-zero:** If the user taps the Zero button, the wheel visually and logically resets to 0 EV, ensuring the UI and value are always in sync.
- The wheel can be shown/hidden with a vertical swipe gesture on the camera preview:
    - Swipe Up: Shows the EV wheel.
    - Swipe Down: Hides the EV wheel.
- The wheel animates in and out smoothly from the side and does not interfere with other camera gestures.

## Architecture

### Additional Core Components (2025-04-30)

- **RotatingViewController**: Applies rotation transforms to SwiftUI views for orientation-aware UI.
- **OrientationFixViewController**: Enforces fixed interface orientation for child views.
- **DeviceRotationViewModifier**: SwiftUI modifier for rotating UI elements with device orientation.
- **DockAccessoryTrackedPerson**: Represents tracked subjects for DockKit integration.
- **EnabledDockKitFeatures**: Encapsulates feature flags for DockKit accessory capabilities.
- **VideoOutputDelegate**: Handles video sample buffer output for preview/recording.
- **LensSelectionView**: UI for selecting camera lenses.
- **Coordinator Classes**: Bridge UIKit/AppKit delegates to SwiftUI views for event handling.
- **Note:** The debug log for updated rotation angle was removed from `DeviceOrientationViewModel` for cleaner logging.

The application primarily follows the **MVVM (Model-View-ViewModel)** architecture pattern, particularly within the SwiftUI features (`CameraView`, `SettingsView`, `VideoLibraryView`, `Watch App/ContentView`).

*   **Views (SwiftUI)**: Responsible for UI layout, presentation, and user interaction. They observe ViewModels for state changes and forward user actions to the ViewModel.
*   **ViewModels (`ObservableObject`)**: Contain UI state (`@Published` properties) and business logic. They interact with Services to perform tasks (camera control, recording, data fetching) and expose processed data/state to the Views. Communication often involves Combine publishers and subscribers (e.g., `DeviceOrientationViewModel`, `WatchConnectivityService`, `CameraViewModel` reacting to service delegate calls or notifications).
*   **Models (`Struct`, `Enum`)**: Represent data structures (e.g., `CameraLens`, `CameraError`, `VideoAsset`, `SettingsModel`). Value types are preferred.
*   **Services**: Encapsulate specific functionalities, often interacting with system frameworks (AVFoundation, Metal, Photos, WatchConnectivity, DockKit). They communicate back to ViewModels typically via delegate protocols or Combine publishers.
*   **UI Components**: Reusable SwiftUI views like `SimpleWheelPicker` (handles its own state for smooth interaction, updates binding on scroll settle).
*   **Adjustment Controls (2025-05-08)**:
        * Replaces legacy lens button row with `ZoomSliderView` redesign.
        * Base row now has four buttons: **Lens**, **Shutter**, **ISO**, **WB**.
        * Selecting a button reveals a horizontal menu directly above:
            * **Lens**: 0.5× / 1× / 2× / 5× buttons (filtered by `CameraLens.availableLenses()`).
            * **Shutter**: Auto (disables SP) or 180° (enables SP via `toggleShutterPriority()`).
            * **ISO**: "Auto" toggle with manual ISO wheel for precise control.
            * **WB**: "Auto" toggle with Kelvin temperature wheel (2500K-10000K).

## Directory Structure

The project is organized into the following main components:

```
.
├── Documentation/         # Project documentation (this file, ToDo, Specs, etc.)
├── iPhoneApp/             # Main iOS Application Target
│   ├── App/
│   │   └── AppDelegate.swift
│   ├── Assets.xcassets/   # Image assets, colors, etc.
│   ├── Core/
│   │   ├── DockKit/       # DockKit integration
│   │   │   ├── DockControlService.swift  # Main DockKit service actor
│   │   │   ├── DockKitTypes.swift        # DockKit-related types and enums
│   │   │   └── DockAccessoryFeatures.swift # Feature configuration
│   │   ├── Extensions/
│   │   │   ├── CIContext+Shared.swift
│   │   │   └── UIDeviceOrientation+Extensions.swift
│   │   ├── Metal/
│   │   │   ├── MetalFrameProcessor.swift
│   │   │   ├── MetalPreviewView.swift      # Metal-based preview with uniform buffer support
│   │   │   └── PreviewShaders.metal
│   │   ├── Orientation/
│   │   │   ├── DeviceOrientationViewModel.swift
│   │   │   ├── DeviceRotationViewModifier.swift
│   │   │   ├── OrientationFixView.swift
│   │   │   └── RotatingView.swift
│   │   └── Services/      # Core services
│   ├── Features/
│   │   ├── Camera/
│   │   │   ├── DockKitIntegration.swift    # DockKit integration with CameraViewModel
│   │   │   ├── Extensions/
│   │   │   │   └── AVFoundationExtensions.swift
│   │   │   ├── Models/
│   │   │   │   ├── CameraError.swift
│   │   │   │   ├── CameraLens.swift
│   │   │   │   └── ShutterAngle.swift
│   │   │   ├── Services/
│   │   │   │   ├── CameraDeviceService.swift
│   │   │   │   ├── CameraSetupService.swift
│   │   │   │   ├── ExposureService.swift
│   │   │   │   ├── RecordingService.swift
│   │   │   │   ├── VideoFormatService.swift
│   │   │   │   ├── VideoOutputDelegate.swift
│   │   │   │   └── VolumeButtonHandler.swift
│   │   │   ├── Utilities/
│   │   │   │   └── DocumentPicker.swift
│   │   │   └── Core/
│   │   │       └── Utilities/
│   │   │           └── AppLifecycleObserver.swift # Observer for app state
│   │   │   ├── Views/
│   │   │   │   ├── CameraPreviewView.swift
│   │   │   │   ├── CameraView.swift
│   │   │   │   ├── FunctionButtonsView.swift
│   │   │   │   ├── LensSelectionView.swift
│   │   │   │   ├── SettingsView.swift
│   │   │   │   └── ZoomSliderView.swift
│   │   │   ├── CameraViewModel.swift
│   │   │   └── FlashlightManager.swift
│   │   ├── LUT/
│   │   │   ├── Utils/
│   │   │   ├── Views/
│   │   │   ├── CubeLUTLoader.swift
│   │   │   └── LUTManager.swift
│   │   ├── Settings/
│   │   │   ├── FlashlightSettingsView.swift
│   │   │   └── SettingsModel.swift
│   │   └── VideoLibrary/
│   │       ├── VideoLibraryView.swift
│   │       └── VideoLibraryViewModel.swift
│   ├── Preview Content/
│   │   └── Preview Assets.xcassets/
│   ├── camera.xcdatamodeld/
│   │   ├── camera.xcdatamodel/
│   │   │   └── contents
│   │   └── .xccurrentversion
│   ├── cameraApp.swift    # Main application entry point (@main)
│   ├── Info.plist         # Application property list
│   └── Persistence.swift  # Core Data persistence controller
├── SC Watch App/          # WatchOS Application Target
│   ├── Assets.xcassets/   # Watch app assets
│   ├── ContentView.swift  # Main view for the watch app
│   ├── SCApp.swift        # Watch app entry point (@main)
│   └── WatchConnectivityService.swift # Service for iPhone communication
├── Spencer's Camera.xcodeproj/ # Xcode project file
│   └── project.pbxproj
└── README.md              # Project README (Assumed)
```

## Key Component Interactions & Data Flow

*   **Camera Feature**:
    *   `CameraView` observes `CameraViewModel`. It uses `@StateObject` to manage an `AppLifecycleObserver` instance.
    *   `AppLifecycleObserver` manages the `UIApplication.didBecomeActiveNotification` observer lifecycle and publishes an event when the app becomes active.
    *   `CameraView` receives the event from `AppLifecycleObserver` and calls `startSession()` on the `CameraViewModel` to ensure the camera restarts when the app returns from the background.
    *   User tap (push) on the preview sets the focus point only (push-to-focus). Exposure point is not set by user tap.
    *   `CameraViewModel` orchestrates `CameraSetupService`, `CameraDeviceService`, `VideoFormatService`, `ExposureService`, `RecordingService`, and `DockControlService`. It manages Shutter Priority state and coordinates exposure locking logic (standard AE vs. SP temporary lock) with `ExposureService` based on settings.
    *   **Exposure Lock & Shutter Priority Lens Switch Handling:**
        *   Exposure mode is now managed via a single `ExposureMode` enum (`auto`, `manual`, `shutterPriority`, `locked`) in both `CameraViewModel` and `ExposureService`. This enum is the single source of truth for all exposure transitions and UI state.
        *   All transitions (auto/manual/shutterPriority/locked) update the `ExposureMode` property, ensuring consistent state across the app.
        *   The `ExposureState` struct now captures the complete exposure state, including ISO, duration, and mode, and is used for all transitions (not just lens switches). This enables robust restoration after interruptions, errors, or user toggles.
        *   When both "Lock Exposure During Recording" and "Shutter Priority" are enabled, `CameraViewModel` ensures that after a lens change, the correct exposure lock is restored.
        *   **Robust Shutter Priority Logic (2025-05-01):** The app implements a highly consistent 180° shutter angle system with improved reliability through the new `ensureShutterPriorityConsistency()` method.
        *   After every lens switch, app backgrounding, or session interruption, 180° shutter duration is recalculated based on the *current* frame rate and immediately applied via `ExposureService.enableShutterPriority(duration:)`. 
        *   A helper computes the correct 180° duration using `duration = 1.0 / (2 * frameRate)`, ensuring the logic is always up-to-date with the selected frame rate.
        *   After a short delay (to guarantee the camera device is fully ready), `CameraViewModel` re-applies the shutter priority exposure lock if required. This prevents ISO from drifting after lens switches during recording.
        *   Enhanced logging confirms the calculated duration and application of shutter priority after each event that might affect camera state.
        *   Improved session interruption handling ensures shutter priority settings are properly restored after temporary camera access by other apps.
        *   **New (2025-05-02):** Shutter Priority re-application after lens switches is now debounced and atomic, with device readiness checks and ISO caching to prevent exposure jumps and race conditions. All KVO and device property changes for exposure are now performed on a serial queue for thread safety.
    *   `DockControlService` manages DockKit accessory interactions, handling tracking, framing, and camera control events. It communicates with `CameraViewModel` through the `CameraCaptureDelegate` protocol.
    *   `DockKitIntegration` extends `CameraViewModel` to conform to `CameraCaptureDelegate`, enabling DockKit accessory control of camera functions.
    *   **Enhanced Exposure Handling (2025-05-06)**:
        *   New `ExposureState` struct captures complete exposure state including ISO, duration, and mode
        *   Thread-safe state management using dedicated `stateQueue` and `exposureAdjustmentQueue`
        *   Smooth ISO transitions implemented with multi-step interpolation
        *   Exposure stability monitoring with variance detection
        *   Automatic error recovery with state restoration
        *   Improved lens switch handling with state preservation
        *   Robust error handling with typed `ExposureServiceError`

*   **DockKit Integration**:
    *   `DockControlService` (iOS 18.0+) is an actor that manages all DockKit accessory interactions.
    *   Handles accessory state changes, tracking, framing modes, and camera control events.
    *   Uses `@Published` properties to expose accessory status, battery state, and tracking information.
    *   Communicates with `CameraViewModel` through `CameraCaptureDelegate` for camera control.
    *   Supports manual control (chevrons) and system tracking modes.
    *   Manages battery and tracking state subscriptions.
    *   Handles accessory events (buttons, zoom, shutter, camera flip).

*   **LUT Feature**: 
    *   `LUTManager` loads `.cube` files (using `CubeLUTLoader`), creates both a `MTLTexture` (`currentLUTTexture`).
    *   `MetalPreviewView` uses `currentLUTTexture` for rendering.
    *   `RecordingService` uses `MetalFrameProcessor` which uses `currentLUTTexture` for bake-in.
*   **Settings**: 
    *   `SettingsView` interacts with `SettingsModel` and `CameraViewModel`.
    *   `SettingsModel` uses `UserDefaults` for persistence and `NotificationCenter` to signal changes (e.g., flashlight, bake-in LUT).
    *   Camera format settings (resolution, codec, frame rate, Apple Log color space) and debug info are persisted through `SettingsModel` using `UserDefaults`.
    *   `CameraViewModel` observes notifications or directly uses `SettingsModel` state to configure services (e.g., `RecordingService` for bake-in LUT state).
*   **Watch Connectivity**: 
    *   `CameraViewModel` acts as `WCSessionDelegate`

- ExposureService and CameraViewModel now coordinate to minimize exposure flicker when switching lenses with Shutter Priority enabled by:
  - Applying SP immediately after device switch
  - Pre-calculating ISO/duration
  - Freezing/unfreezing exposure UI during transition

- **CameraViewModel**: Central coordinator for camera state, settings, and service orchestration. Now ensures Apple Log color space is correctly applied at boot by setting `isAppleLogSupported` in `didInitializeCamera` based on device capabilities.

- **Note:** The app now automatically restores the last loaded LUT after lens switches, fixing a previous issue where the LUT would be lost.
- **Note:** LUT loading is always decoupled from color space configuration. Only the user's Apple Log toggle controls the color space; loading a LUT never changes the camera's color space, even if the LUT is named for a specific color space.

- **WatchConnectivityService**: Now injected as an `.environmentObject` at the root of the Watch app (`SCApp.swift`). All views access it via `@EnvironmentObject`, ensuring a single instance and robust SwiftUI redraw behavior. The singleton pattern is not used in SwiftUI views.

## State Management & ViewModel Refactoring (2025-05)

- **DeviceOrientationViewModel**: Previously used as a singleton (`.shared`) in multiple views, which caused unnecessary SwiftUI redraws. Now, each view creates its own instance (`@StateObject` or `@ObservedObject`). A new `OrientationCoordinator` handles device orientation updates and is not an observable object, so only the views that need to update do so.
- **WatchConnectivityService (Watch App)**: Now created as a `@StateObject` at the root (`SCApp.swift`) and injected via `.environmentObject`. All views use `@EnvironmentObject`, ensuring a single instance and robust SwiftUI redraw behavior. The singleton pattern is not used in SwiftUI views.
- **SettingsModel**: Remains a single `@StateObject` at the app root, injected via `.environmentObject` (best practice for global settings).
- **CameraViewModel**: Instantiated per screen as a `@StateObject` and passed down (best practice for screen-specific state).
- **No other ObservableObject singletons are used in SwiftUI views.**
- **Service singletons** (e.g., `HapticManager`, `LocationService`) are not observable objects and do not affect SwiftUI redraws.

This approach ensures robust, efficient SwiftUI state management and avoids unnecessary redraws across unrelated views.

*   **Manual ISO Override in Shutter Priority (2025-05-08):**
    *   When Shutter Priority (SP) is enabled, users can now manually override ISO.
    *   The app tracks this with `isManualISOInSP` in both `CameraViewModel` and `ExposureService`.
    *   When the user adjusts ISO in SP mode, the app stops all SP auto-ISO adjustments and respects the user's value until the user explicitly resets ("Reset to SP ISO").
    *   All SP ISO logic is blocked while manual ISO is active, ensuring no feedback loop or fighting the user.
    *   Debug logs are present for every transition and override, aiding troubleshooting.
    *   A "Reset to SP ISO" action is available in the UI when manual ISO is active in SP mode, restoring auto ISO calculation.
    *   This prevents feedback loops and ensures a smooth, predictable user experience for advanced shooters.
*   **ISO Wheel (2025-05-08):**
    *   The ISO wheel now uses 100 ISO increments per major tick mark for faster, more precise adjustments.
    *   This makes it easier to select common ISO values and improves usability for advanced users.
    *   **(2025-05-09):** The ISO wheel and Auto button now match the EV bias scale and Zero button exactly in appearance and behavior. Both use stepsPerUnit: 10, spacing: 6, and show an overlay/disable the wheel when auto is enabled. The only difference is the label (Auto for ISO, Zero for EV bias).