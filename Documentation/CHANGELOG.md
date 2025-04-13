# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Added

### Changed

### Fixed

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
