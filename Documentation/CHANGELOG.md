# Changelog

> **Note:** Push-to-focus (tap to set focus point) is supported. Push-to-exposure (tap to set exposure point) and exposure value (EV) compensation are NOT implemented in this version. Any previous references to these features have been removed or clarified.

All notable changes to this project will be documented in this file.

## [Unreleased]

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