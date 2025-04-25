# Project Architecture

This document describes the high-level architecture and directory structure of the Spencer's Camera application.

## Architecture

The application primarily follows the **MVVM (Model-View-ViewModel)** architecture pattern, particularly within the SwiftUI features (`CameraView`, `SettingsView`, `VideoLibraryView`, `Watch App/ContentView`).

*   **Views (SwiftUI)**: Responsible for UI layout, presentation, and user interaction. They observe ViewModels for state changes and forward user actions to the ViewModel.
*   **ViewModels (`ObservableObject`)**: Contain UI state (`@Published` properties) and business logic. They interact with Services to perform tasks (camera control, recording, data fetching) and expose processed data/state to the Views. Communication often involves Combine publishers and subscribers (e.g., `DeviceOrientationViewModel`, `WatchConnectivityService`, `CameraViewModel` reacting to service delegate calls or notifications).
*   **Models (`Struct`, `Enum`)**: Represent data structures (e.g., `CameraLens`, `CameraError`, `VideoAsset`, `SettingsModel`). Value types are preferred.
*   **Services**: Encapsulate specific functionalities, often interacting with system frameworks (AVFoundation, Metal, Photos, WatchConnectivity). They communicate back to ViewModels typically via delegate protocols or Combine publishers.

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
│   │   ├── Extensions/
│   │   │   ├── CIContext+Shared.swift
│   │   │   └── UIDeviceOrientation+Extensions.swift
│   │   ├── Metal/
│   │   │   ├── MetalFrameProcessor.swift
│   │   │   ├── MetalPreviewView.swift
│   │   │   └── PreviewShaders.metal
│   │   ├── Orientation/
│   │   │   ├── DeviceOrientationViewModel.swift
│   │   │   ├── DeviceRotationViewModifier.swift
│   │   │   ├── OrientationFixView.swift
│   │   │   └── RotatingView.swift
│   │   └── Services/      # (Currently Empty)
│   ├── Features/
│   │   ├── Camera/
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
    *   `CameraViewModel` orchestrates `CameraSetupService`, `CameraDeviceService`, `VideoFormatService`, `ExposureService`, `RecordingService`. It manages Shutter Priority state and coordinates exposure locking logic (standard AE vs. SP temporary lock) with `ExposureService` based on settings.
    *   `CameraSetupService` configures the `AVCaptureSession`, sets initial device settings (including attempting to set `.continuousAutoExposure` mode early and verifying after start), requests permissions, adds inputs, sets preset, and reports status/device via delegate.
    *   `CameraDeviceService` handles lens switching and zoom, interacting directly with `AVCaptureDevice` and notifying `CameraViewModel` via delegate.
    *   `VideoFormatService` sets resolution, frame rate, and color space (`isAppleLogEnabled` state) on `AVCaptureDevice`, coordinated by `CameraViewModel`.
    *   `ExposureService` sets exposure mode, ISO, shutter, WB, tint based on `CameraViewModel` requests. It also attempts to set `.continuousAutoExposure` upon device initialization (`setDevice`), with the final state synchronized via `CameraSetupService`. It uses Key-Value Observing (KVO) to monitor `iso`, `exposureDuration`, `deviceWhiteBalanceGains` and `exposureTargetOffset` on the `AVCaptureDevice`. 
        *   In **Shutter Priority** mode (`enableShutterPriority`), it sets the mode to `.custom` with a fixed shutter duration, then uses KVO on `exposureTargetOffset` to monitor deviations and automatically adjust the ISO (`setExposureModeCustom`), managed by `handleExposureTargetOffsetUpdate`.
        *   It provides methods (`lock/unlockShutterPriorityExposureForRecording`) to temporarily pause auto-ISO adjustments during recording, coordinated by `CameraViewModel` based on settings.
        *   It reports real-time values via delegate.
    *   `RecordingService` uses the configured session/device to write video/audio using `AVAssetWriter`. It receives pixel buffers, potentially processes them using `MetalFrameProcessor` (for LUT bake-in) based on `SettingsModel` state provided via `CameraViewModel`, applies the correct orientation transform, and saves the final file.
    *   `CameraView` displays preview via `CameraPreviewView` (which uses `MetalPreviewView` internally).
    *   `MetalPreviewView` receives raw `CMSampleBuffer`s, creates Metal textures, and renders them using shaders from `PreviewShaders.metal`, applying the `currentLUTTexture` from `LUTManager` in the fragment shader.
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