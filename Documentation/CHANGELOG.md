# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Added

*   Feature: Implemented Shutter Priority mode (Function Button 2). Locks shutter speed (180°) and automatically adjusts ISO based on scene brightness changes (`ExposureService`, `CameraViewModel`). Uses KVO on `exposureTargetOffset`.
*   Feature: Added temporary exposure lock during recording when Shutter Priority is active and "Lock Exposure During Recording" setting is enabled (`ExposureService`, `CameraViewModel`).
*   Setting: Added "Lock Exposure During Recording" toggle in Settings.
*   Logic: Implemented logic in `CameraViewModel` to automatically lock exposure when recording starts (standard AE lock or temporary SP lock) and restore the previous state when recording stops, if the setting is enabled.
*   Core: Added `AppLifecycleObserver` to manage `didBecomeActiveNotification` observation cleanly within `CameraView`'s lifecycle.

### Changed

*   Updated `ExposureService` to use Key-Value Observing (KVO) to monitor `iso`, `exposureDuration`, `deviceWhiteBalanceGains`, and `exposureTargetOffset` on the `AVCaptureDevice` for real-time updates and Shutter Priority logic.
*   Refined exposure locking logic in `CameraViewModel` to correctly handle interaction between standard AE lock and Shutter Priority's temporary recording lock.
*   Adjusted camera preview position and scale using `.scaleEffect(0.9)` and padding in `CameraView`.
*   Improved initialization sequence in `CameraSetupService` and `ExposureService` to more reliably set `.continuousAutoExposure` mode on startup.
*   Updated `RecordingService` to calculate video orientation transform using `UIDeviceOrientation.videoRotationAngleValue` instead of relying on potentially deprecated properties.

### Fixed

*   Resolved issue where camera preview would not restart after the app returned from the background by using `AppLifecycleObserver` to trigger `startSession`.
*   Correctly handled `UIApplication.didBecomeActiveNotification` observer lifecycle using `AppLifecycleObserver` to prevent potential issues and ensure proper removal.
*   Resolved issue where ISO would incorrectly continue to adjust during recording when Shutter Priority and "Lock Exposure During Recording" were both enabled. Decoupled UI lock state (`isExposureLocked`) from internal SP recording lock logic in `CameraViewModel` and `ExposureService`.
*   Prevented manual exposure lock (`toggleExposureLock`) from being activated while Shutter Priority is enabled (`CameraViewModel`).
*   Ensured manual exposure lock UI state (`isExposureLocked`) is correctly turned off when Shutter Priority is enabled (`CameraViewModel`).
*   Corrected KVO KeyPath syntax and usage in `ExposureService`.
*   Fixed issue where Apple Log setting was not properly applied at startup or after lens changes, ensuring `VideoFormatService` reapplies the correct color space.
*   Updated debug overlay to show actual camera device color space instead of just the setting value.

### Removed

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
*   Corrected initializer logic in `SettingsModel` to properly default `isBakeInLUTEnabled` to false on first launch, fixing a build error.
*   Simplified `OrientationFixViewController` by removing aggressive parent background setting logic to potentially resolve black screen issues when presenting the Video Library.

### Removed

*   Obsolete `View+Extensions.swift` file.
