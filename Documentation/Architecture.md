# Project Architecture

This document describes the high-level architecture and directory structure of the Spencer's Camera application.

## Architecture

The application primarily follows the **MVVM (Model-View-ViewModel)** architecture pattern, particularly within the SwiftUI features.

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

## Key Components & Connections

*   **iPhoneApp:** The main iOS application.
    *   `cameraApp.swift`: Entry point, sets up the main view and environment.
    *   `CameraView` / `CameraViewModel`: Core of the camera functionality, handling capture session, settings, recording, and UI updates. Uses multiple services (`CameraSetupService`, `RecordingService`, etc.).
    *   `MetalPreviewView`: Renders the camera preview using Metal, applying LUTs via shaders.
    *   `LUTManager`: Handles loading, parsing, and applying `.cube` LUT files.
    *   `WatchConnectivityService` (in Watch App): Manages communication between the watch and iPhone for remote control.
    *   `VideoLibraryView` / `VideoLibraryViewModel`: Displays videos from the Photo Library.
*   **SC Watch App:** Provides remote control functionality for the iPhone app.
    *   Communicates with the iPhone app via `WatchConnectivityService`.
    *   Allows starting/stopping recording.
    *   Displays recording status and elapsed time.

*(This structure is based on initial observation and may evolve.)*
