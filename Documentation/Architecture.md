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
│   ├── App/               # App Delegate, main App struct
│   │   └── AppDelegate.swift
│   ├── Assets.xcassets/   # Image assets, colors, etc.
│   ├── Core/              # Core functionalities shared across features
│   │   ├── Extensions/    # Swift extensions (UIDeviceOrientation, CIContext)
│   │   ├── Metal/         # Metal rendering code (Preview, Shaders, Processor)
│   │   │   ├── MetalPreviewView.swift  # MTKViewDelegate for live preview
│   │   │   ├── MetalFrameProcessor.swift # Processes frames for LUT bake-in
│   │   │   └── PreviewShaders.metal    # Shaders for preview & compute
│   │   ├── Orientation/   # Device orientation handling (ViewModel, Views, Modifiers)
│   │   └── Services/      # Shared services (Currently Empty)
│   ├── Features/          # Feature-specific modules
│   │   ├── Camera/        # Camera capture and control feature
│   │   │   ├── Extensions/
│   │   │   ├── Models/    # Data models (CameraError, CameraLens, ShutterAngle)
│   │   │   ├── Services/  # Camera-specific services (Setup, Recording, Device, Format, Exposure)
│   │   │   ├── Utilities/ # Utility components (DocumentPicker)
│   │   │   ├── Views/     # SwiftUI Views (CameraView, Settings, Preview, Buttons, Zoom)
│   │   │   ├── CameraViewModel.swift
│   │   │   └── FlashlightManager.swift
│   │   ├── LUT/           # Look-Up Table (LUT) feature
│   │   │   ├── Utils/     # LUT processing utilities
│   │   │   ├── Views/     # LUT-related views
│   │   │   ├── CubeLUTLoader.swift
│   │   │   └── LUTManager.swift
│   │   ├── Settings/      # Application settings feature
│   │   │   ├── FlashlightSettingsView.swift
│   │   │   └── SettingsModel.swift
│   │   └── VideoLibrary/  # Video library browser feature
│   │       ├── VideoLibraryView.swift
│   │       └── VideoLibraryViewModel.swift
│   ├── Preview Content/   # Assets for SwiftUI Previews
│   ├── camera.xcdatamodeld/ # Core Data model definition
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
    *   `CameraView` observes `CameraViewModel`.
    *   `CameraViewModel` orchestrates `CameraSetupService`, `CameraDeviceService`, `VideoFormatService`, `ExposureService`, `RecordingService`.
    *   `CameraSetupService` configures the `AVCaptureSession` and reports status/device via delegate.
    *   `CameraDeviceService` handles lens switching and zoom, interacting directly with `AVCaptureDevice` and notifying `CameraViewModel` via delegate.
    *   `VideoFormatService` sets resolution, frame rate, and color space (`isAppleLogEnabled` state) on `AVCaptureDevice`, coordinated by `CameraViewModel`.
    *   `ExposureService` sets exposure mode, ISO, shutter, WB, tint based on `CameraViewModel` requests.
    *   `RecordingService` uses the configured session/device to write video/audio using `AVAssetWriter`. It receives pixel buffers, potentially processes them using `MetalFrameProcessor` (for LUT bake-in) based on `SettingsModel` state provided via `CameraViewModel`, and saves the final file.
    *   `CameraView` displays preview via `CameraPreviewView` (which uses `MetalPreviewView` internally).
    *   `MetalPreviewView` receives raw `CMSampleBuffer`s, creates Metal textures, and renders them using shaders from `PreviewShaders.metal`, applying the `currentLUTTexture` from `LUTManager` in the fragment shader.
*   **LUT Feature**: 
    *   `LUTManager` loads `.cube` files (using `CubeLUTLoader`), creates both a `MTLTexture` (`currentLUTTexture`) and a `CIFilter` (`currentLUTFilter`).
    *   `MetalPreviewView` uses `currentLUTTexture` for rendering.
    *   `RecordingService` uses `MetalFrameProcessor` which uses `currentLUTTexture` for bake-in.
*   **Settings**: 
    *   `SettingsView` interacts with `SettingsModel` and `CameraViewModel`.
    *   `SettingsModel` uses `UserDefaults` for persistence and `NotificationCenter` to signal changes (e.g., flashlight, bake-in LUT).
    *   `CameraViewModel` observes notifications or directly uses `SettingsModel` state to configure services (e.g., `RecordingService` for bake-in LUT state).
*   **Watch Connectivity**: 
    *   `CameraViewModel` acts as `WCSessionDelegate` on iOS, sending state (`isRecording`, `isAppActive`, etc.) via `updateApplicationContext`. It receives messages (start/stop) and triggers corresponding actions.
    *   `WatchConnectivityService` is `WCSessionDelegate` on watchOS, receiving context updates (`latestContext`) published to `ContentView`, and sending messages to iOS.
*   **Orientation**: 
    *   `DeviceOrientationViewModel` publishes device orientation.
    *   `RotatingView` subscribes and applies transforms to specific UI elements.
    *   `OrientationFixView` enforces specific screen orientations for views like `CameraView` and `VideoLibraryView`.
    *   `RecordingService` determines video orientation metadata based on device/interface orientation at the start of recording.

*(This architecture description provides a more detailed overview but may still evolve.)*
