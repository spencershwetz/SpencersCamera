# Changelog

> **Note:** Push-to-focus (tap to set focus point) is supported. Exposure value (EV) compensation is now fully implemented with a live, continuous wheel picker. Push-to-exposure (tap to set exposure point) is not implemented in this version.

All notable changes to this project will be documented in this file.

## [Unreleased]

*   Enhanced: Added haptic feedback to all adjustment controls:
    *   Added tactile feedback to all lens selection buttons (0.5×, 1×, 2×, 5×)
    *   Added haptic feedback to base menu buttons (Lens, Shutter, ISO, WB)
    *   Added haptic feedback to shutter mode controls (Auto, 180°)
    *   Added consistent feedback to Auto toggles in ISO and WB menus
    *   Standardized UIImpactFeedbackGenerator(style: .light) across all control buttons
    *   Matched the haptic feel of the existing SimpleWheelPicker implementation

*   Performance: Optimized memory management during lens changes and recording:
    *   Fixed memory spikes of 200-300MB when switching lenses
    *   Added explicit texture cache flushing during lens switching
    *   Implemented proper memory cleanup when stopping recording
    *   Added autoreleasepool blocks at critical memory transition points
    *   Improved Metal texture management to prevent resource leaks
    *   Fixed texture resource retention during frame processing
    *   Reduced memory usage by ~300MB during app operation

*   Enhanced: Improved EV compensation wheel performance:
    *   Implemented real-time EV bias updates during wheel scrolling (no wait for scroll end)
    *   Added intelligent throttling (100ms intervals) to prevent GPU overload
    *   Optimized binding updates with threshold-based change detection
    *   Prevented GPU timeout errors during rapid wheel scrolling
    *   Maintained responsive UI feel while ensuring system stability
    *   Added rounded value display to reduce animation thrashing

*   Fixed: Improved session interruption handling when returning from background:
    *   Added proper handling of `.videoDeviceNotAvailableInBackground` interruption reason
    *   Added new `.sessionInterrupted` error type with user-friendly message
    *   Suppressed unnecessary error messages during background/foreground transitions
    *   Properly clears interruption errors when session resumes

*   Enhanced: Improved 180° shutter priority robustness:
    *   Added new `ensureShutterPriorityConsistency()` method to centralize and improve reliability
    *   Enhanced resilience during app backgrounding and session interruptions
    *   Improved recovery after camera access by other apps
    *   Added additional verification and logging for debugging shutter angle issues
    *   Shortened restoration delay timers for more responsive experience

*   UI: Added persistent storage for visibility states:
    *   EV bias wheel visibility state is now preserved between app launches
    *   Debug overlay visibility state is now preserved between app launches
    *   States are managed through SettingsModel using UserDefaults

*   UI: Enhanced EV bias functionality:
    *   EV bias value is now preserved when switching between lenses
    *   Value is automatically restored after a short delay to ensure proper device configuration
    *   Added logging to track EV bias persistence during lens switches

*   Fixed: Shutter Priority exposure lock is now correctly maintained during lens changes when "Lock Exposure During Recording" is enabled:
    *   Added proper exposure lock state preservation in CameraDeviceService.configureSession
    *   Ensures exposure remains locked when switching lenses during recording

*   UI: Migrated to SimpleWheelPicker for precise, live EV bias control:
    *   Horizontal wheel interface with haptic feedback
    *   Smooth scrolling with precise value selection
    *   Visual indicators for zero and current value
    *   Maintains exact position when gesture ends
    *   Always starts centered at 0 EV
    *   **Live updating:** The visual representation updates continuously during drag. The final EV value is committed to the binding after the scroll settles.
    *   **No edge bounce:** The EV wheel now locks exactly on each tick when released, with scroll edge bouncing disabled. There is no overshoot or bounce-back at the ends.
    *   Removed EVWheelPicker and all legacy code related to debounced EV updates.

*   UI: Enhanced camera preview interface:
    *   Moved EV compensation wheel to bottom of preview for better visibility
    *   Added debug overlay showing camera parameters (resolution, FPS, ISO, etc.)
    *   Added stabilization status indicator to debug overlay
    *   Both EV wheel and debug overlay now show/hide with vertical swipe gestures:
        *   Swipe Up: Shows both EV wheel and debug overlay
        *   Swipe Down: Hides both EV wheel and debug overlay
    *   Constrained EV wheel width to match camera preview width (90% of screen width)
    *   Improved layout of EV value display above the wheel
    *   Enhanced visual hierarchy with semi-transparent backgrounds and proper spacing

*   Improved: Shutter Priority and lens switching robustness:
    *   Debounced and atomic shutter priority re-application after lens switches to prevent race conditions and state drift.
    *   Added device readiness check before re-applying shutter priority after lens switch.
    *   Cached and restored last ISO value for Shutter Priority mode across lens switches to prevent exposure jumps.
    *   All KVO and device property changes for exposure are now performed on a serial queue for thread safety.
    *   Improved user experience and reliability when rapidly switching lenses or toggling Shutter Priority.

*   Minimized exposure flicker when switching lenses with Shutter Priority enabled by:
    - Applying Shutter Priority as soon as possible after lens switch
    - Pre-calculating ISO/duration for the new lens
    - Freezing exposure UI during transition and unfreezing after SP is re-applied

*   Enhanced: Improved exposure and shutter priority handling:
    *   Added robust error handling with new `ExposureServiceError` type
    *   Implemented thread-safe state management with dedicated queues
    *   Added exposure state persistence during lens switches
    *   Implemented smooth ISO transitions with multi-step interpolation
    *   Added exposure stability monitoring with variance detection
    *   Enhanced error recovery with automatic state restoration
    *   Improved lens switch handling with state preservation

*   Fixed: Stale camera session error alerts (e.g., "failed to start camera session") are now cleared as soon as the session starts successfully. Users will no longer see an error dialog after returning from the lock screen or background if the camera is running fine. This prevents incorrect error UI and improves user experience.

*   Added: Volume button controls for camera capture using AVCaptureEventInteraction (iOS 17.2+):
    *   Both volume up and volume down buttons can start/stop recording
    *   Proper actor isolation for thread safety
    *   Automatic cleanup when view is dismantled
    *   Debounce protection to prevent rapid toggling

*   UI: EV compensation wheel now visually resets to zero when the Zero button is tapped:
    *   The SimpleWheelPicker's position is now synced to the bound value, so tapping Zero instantly and visually resets the wheel to 0 EV.
    *   Ensures the UI and value are always in sync, even when set programmatically.

*   Fixed: EV bias (exposure compensation) now only applies when auto exposure is enabled. The UI disables the EV bias wheel and shows a message when in manual ISO/shutter mode. This prevents user confusion and ensures the device's exposure bias is actually updated.

*   Fixed: Haptic feedback is now robust—HapticManager only plays haptics when the app is active, manages the Core Haptics engine lifecycle, and prevents errors when the app is backgrounded or inactive. Users now reliably get haptic feedback for UI actions.

### Added

*   Feature: Added DockKit integration (iOS 18.0+) for accessory control and tracking:
    *   Added `DockControlService` actor for managing DockKit interactions.
    *   Added support for subject tracking, framing modes, and ROI.
    *   Added manual pan/tilt control via chevrons.
    *   Added battery monitoring and status tracking.
    *   Added support for accessory-initiated camera controls.
*   Feature: Added Video Stabilization toggle in Settings. The app now sets the `AVCaptureConnection`'s `preferredVideoStabilizationMode` (prioritizing `.standard` over `.auto`, falling back to `.off`) based on this setting during video output configuration.
*   Feature: Implemented Shutter Priority mode (Function Button 2). Locks shutter speed (180°) and automatically adjusts ISO based on scene brightness changes (`ExposureService`, `CameraViewModel`). Uses KVO on `exposureTargetOffset`.
*   Feature: Added temporary exposure lock during recording when Shutter Priority is active and "Lock Exposure During Recording" setting is enabled (`ExposureService`, `CameraViewModel`).
*   Setting: Added "Lock Exposure During Recording" toggle in Settings.
*   Logic: Implemented logic in `CameraViewModel` to automatically lock exposure when recording starts (standard AE lock or temporary SP lock) and restore the previous state when recording stops, if the setting is enabled.
*   Core: Added `AppLifecycleObserver` to manage `didBecomeActiveNotification` observation cleanly within `CameraView`'s lifecycle.
*   Note: Tap-to-focus and exposure value (EV) compensation features are not included in this release. UI does not currently support tap-to-focus or EV compensation.
*   UI: Added vertical `ExposureBiasSlider` on the right side of the preview for exposure compensation (delegates to `ExposureService`).
*   Feature: Enhanced tap-to-focus with lock capability:
    *   Added long-press gesture to lock focus
    *   Implemented two-step focus lock process (auto-focus then lock)
    *   Added visual lock indicator with SF Symbol
    *   Focus square remains visible when locked
*   UI: Added new Adjustment Controls replacing lens buttons:
    *   Four buttons (Lens, Shutter, ISO, WB) now appear where lens buttons were.
    *   Tapping a button reveals a horizontal menu above:
        *   Lens: 0.5×, 1×, 2×, 5× (device-dependent)
        *   Shutter: Auto or 180° (Shutter Priority)
        *   ISO: "Auto" toggle + swipeable ISO wheel (min → max)
        *   WB: "Auto" toggle + swipeable Kelvin wheel (2500–10000 K)
    *   ISO & WB wheels reuse SimpleWheelPicker for haptic, bounce-free scrolling.
    *   Added manual ISO and Kelvin bindings to ExposureService; new auto white-balance support.

### Changed

*   Added DockKit integration to `CameraViewModel` through `CameraCaptureDelegate` protocol.
*   Structured DockKit components in dedicated Core/DockKit directory.
*   Added conditional compilation for DockKit features (iOS 18.0+).
*   Improved DockKit error handling and accessory state management.
*   Updated `ExposureService` to use Key-Value Observing (KVO) to monitor `iso`, `exposureDuration`, `deviceWhiteBalanceGains`, and `exposureTargetOffset` on the `AVCaptureDevice` for real-time updates and Shutter Priority logic.
*   Refined exposure locking logic in `CameraViewModel` to correctly handle interaction between standard AE lock and Shutter Priority's temporary recording lock.
*   Adjusted camera preview position and scale using `.scaleEffect(0.9)` and padding in `CameraView`.
*   Improved initialization sequence in `CameraSetupService` and `ExposureService` to more reliably set `.continuousAutoExposure` mode on startup.
*   Updated `RecordingService` to calculate video orientation transform using `UIDeviceOrientation.videoRotationAngleValue` instead of relying on potentially deprecated properties.
*   Shutter Priority Robustness: After every lens switch, the 180° shutter duration is recalculated based on the current frame rate and immediately applied. This ensures consistent 180° exposure and fixes prior issues with incorrect shutter angles (e.g., 144°, 216°) after lens switches in Shutter Priority mode.

### Fixed

*   Fixed camera preview rotation by locking it to portrait (90 degrees) in `CameraPreviewView`, removing the dependency on `DeviceOrientationViewModel` for the preview layer.
*   Fixed Metal buffer creation in `MetalPreviewView` by changing `let` constants to `var` for inout parameter compatibility.
*   Resolved issue where camera preview would not restart after the app returned from the background by using `AppLifecycleObserver` to trigger `startSession`.
*   Correctly handled `UIApplication.didBecomeActiveNotification` observer lifecycle using `AppLifecycleObserver` to prevent potential issues and ensure proper removal.
*   Resolved issue where ISO would incorrectly continue to adjust during recording when Shutter Priority and "Lock Exposure During Recording" were both enabled. Decoupled UI lock state (`isExposureLocked`) from internal SP recording lock logic in `CameraViewModel` and `ExposureService`.
*   Fixed: Exposure lock (ISO) is now correctly restored after lens changes when both "Lock Exposure During Recording" and "Shutter Priority" are enabled. CameraViewModel now re-applies the lock with a short delay after lens switch to ensure the camera device is ready, preventing ISO drift.
*   Prevented manual exposure lock (`toggleExposureLock`) from being activated while Shutter Priority is enabled (`CameraViewModel`).
*   Ensured manual exposure lock UI state (`isExposureLocked`) is correctly turned off when Shutter Priority is enabled (`CameraViewModel`).
*   Corrected KVO KeyPath syntax and usage in `ExposureService`.
*   Fixed issue where Apple Log setting was not properly applied at startup or after lens changes, ensuring `VideoFormatService` reapplies the correct color space.
*   Updated debug overlay to show actual camera device color space instead of just the setting value.
*   Refined HDR video configuration logic in `CameraDeviceService.configureSession` to correctly use `automaticallyAdjustsVideoHDREnabled` for non-Log modes, preventing potential crashes.
*   Changed `var targetMode` to `let targetMode` in `CameraDeviceService` during stabilization setup to resolve a compiler warning.
*   Removed duplicate `@main` attribute from AppDelegate to resolve build conflict with SwiftUI app entry point
*   Fixed issue where Shutter Priority exposure lock would not engage during recording even when "Lock Exposure During Recording" was enabled:
    *   Improved lockShutterPriorityExposureForRecording to properly lock exposure values
    *   Enhanced unlockShutterPriorityExposureAfterRecording to restore Shutter Priority state
    *   Added proper state management for recording lock in ExposureService
*   Fixed crash in Apple Log color space configuration by properly checking format support and using correct device properties
*   Improved error handling for unsupported color space configurations
*   Fix: Ensure user-selected color space is respected on initial app boot by explicitly applying the color space after session setup in CameraViewModel. (Color space was not always respected until session restart or setting toggle)
*   Fix: Throttled Metal frame processing to one in-flight command buffer at a time and paused frame processing during session/lens switches to prevent GPU overload and timeouts.
*   Fixed: Apple Log color space is now correctly applied at app launch if supported and enabled. The fix sets `isAppleLogSupported` in `CameraViewModel.didInitializeCamera` based on device capabilities, restoring correct boot behavior after memory management refactor.

### Removed

*   Push-to-exposure (tap to set exposure point) support has been removed. Setting the exposure point via user tap is no longer available; only push-to-focus is supported.
*   Redundant setting of `AVCaptureConnection.videoRotationAngle` in `CameraDeviceService`.

## [2024-08-10]

### Added

*   Initial project structure setup.
*   Core camera functionality (capture session, preview, basic controls).
*   Video recording capability with HEVC and ProRes codecs.
*   Apple Log color space support.
*   Metal-based preview rendering.
*   LUT import (`.cube`) and real-time preview application (via Metal shaders).
*   Optional LUT bake-in during recording (via Metal compute).
*   Watch App for remote recording control.
*   Video Library browser.
*   Flashlight recording indicator with intensity control.
*   Basic settings panel (Resolution, FPS, Codec, Color Space, LUTs, Flashlight).
*   Lens switching (Ultra-Wide, Wide, 2x Digital, Telephoto).
*   Zoom slider and discrete lens buttons.
*   Orientation handling (fixed portrait UI, rotating elements, recording orientation).
*   Volume button recording trigger (iOS 17.2+).
*   Initial documentation files (`Architecture.md`, `CodebaseDocumentation.md`, `TechnicalSpecification.md`, `ToDo.md`, `CHANGELOG.md`).

### Changed

*   (No changes tracked yet for released versions)

### Fixed

*   Reduced excessive logging in `RotatingView` during initialization and orientation changes.
*   Set default LUT bake-in state in `RecordingService` to `false` to prevent unnecessary processing.
*   Removed redundant `didBecomeActiveNotification` observer in `CameraView` to simplify session lifecycle management and potentially resolve preview freezes.
*   Corrected initializer logic in `SettingsModel`

### Refactored

*   WatchConnectivityService is now injected as an `.environmentObject` at the root of the watch app, not used as a singleton in views. This ensures robust SwiftUI redraw behavior and prevents cross-view redraw issues.