# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Added

*   Feature: Implemented Shutter Priority mode (Function Button 2). Locks shutter speed (180°) and automatically adjusts ISO based on scene brightness changes (`ExposureService`, `CameraViewModel`).
*   Feature: Added temporary exposure lock during recording when Shutter Priority is active and "Lock Exposure During Recording" setting is enabled (`ExposureService`, `CameraViewModel`).
*   Setting: Added "Lock Exposure During Recording" toggle in Settings.
*   Logic: Implemented logic in `CameraViewModel` to automatically lock exposure when recording starts and restore the previous state when recording stops, if the setting is enabled.

### Changed

*   Updated `ExposureService` to use Key-Value Observing (KVO) to monitor `iso`, `exposureDuration`, `deviceWhiteBalanceGains`, and `exposureTargetOffset` on the `AVCaptureDevice`.

### Fixed

*   Resolved issue where ISO would incorrectly continue to adjust during recording when Shutter Priority and "Lock Exposure During Recording" were both enabled. Decoupled UI lock state (`isExposureLocked`) from internal SP recording lock logic in `CameraViewModel`.
*   Prevented manual exposure lock (`toggleExposureLock`) from being activated while Shutter Priority is enabled (`CameraViewModel`).
*   Ensured manual exposure lock UI state (`isExposureLocked`) is correctly turned off when Shutter Priority is enabled (`CameraViewModel`).
*   Corrected KVO KeyPath syntax in `ExposureService`.
*   Added missing explicit `self` references within closures in `ExposureService`.
*   Removed incorrect optional chaining `?.` on non-optional `self` in `ExposureService`.
*   Removed check for non-existent `isLockedForConfiguration` property in `ExposureService` error handling blocks.
*   Fixed logging string interpolation syntax errors in `ExposureService`.
*   Implemented multiple strategies in `CameraSetupService` and `ExposureService` to ensure the camera device consistently initializes with `.continuousAutoExposure` mode, addressing issues where it would default to `.custom` after session start. This involved setting the mode at different lifecycle stages and verifying the final state.
*   Resolved intermittent session start failures (`AVError.Code -11872`) after multiple background/foreground cycles by implementing explicit removal of inputs/outputs in `stopSession` and full reconfiguration (inputs + outputs) via `CameraSetupService` / `RecordingService` in `startSession`.

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
