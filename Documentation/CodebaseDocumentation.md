# Codebase Documentation: Spencer's Camera

## 1. Introduction

This document provides an overview of the codebase for the Spencer's Camera iOS application. The app is a custom camera application built using modern iOS technologies, focusing on providing advanced control over camera settings, real-time LUT previews and application via Metal, and Watch Connectivity integration.

The primary architecture follows MVVM (Model-View-ViewModel) using SwiftUI for the user interface. Functionality is modularized into distinct Features and Core services.

## 2. Project Structure

The main application code resides within the `iPhoneApp/` directory. Other top-level directories include `SC Watch App/` (presumably for the WatchOS companion app) and `SpencersCamera/` (currently appears empty).

```
SpencersCamera/
├── Documentation/
│   ├── Apple_Log_Profile_White_Paper.pdf
│   └── CodebaseDocumentation.md  <-- This file
├── iPhoneApp/
│   ├── cameraApp.swift         # App entry point (SwiftUI App protocol)
│   ├── Info.plist              # App configuration
│   ├── Persistence.swift       # Core Data setup (potentially unused)
│   ├── Assets.xcassets/      # Image assets
│   ├── Preview Content/      # Assets for Xcode Previews
│   ├── camera.xcdatamodeld/  # Core Data model (potentially unused)
│   ├── App/
│   │   └── AppDelegate.swift   # Handles orientation locking
│   ├── Core/                   # Core functionalities, services, extensions
│   │   ├── Orientation/        # UI Rotation and Orientation Locking
│   │   ├── Metal/              # Metal rendering pipeline for preview/processing
│   │   ├── Services/           # (Currently empty)
│   │   └── Extensions/         # Swift extensions
│   └── Features/               # Feature modules
│       ├── Camera/             # Main camera functionality
│       ├── Settings/           # Settings management and UI
│       ├── LUT/                # Look-Up Table (LUT) management
│       └── VideoLibrary/       # Video browser for Photo Library
├── SC Watch App/               # WatchOS companion app code (Not analyzed)
└── SpencersCamera.xcodeproj/ # Xcode project file
```

## 3. Core Components (`iPhoneApp/Core/`)

### 3.1. Orientation (`Core/Orientation/`)

Handles UI element rotation and device orientation locking.

-   **`DeviceOrientationViewModel`**: Shared `ObservableObject` tracking `UIDevice.orientationDidChangeNotification` and publishing the current `orientation`. Provides `rotationAngle` for UI rotation.
-   **`DeviceRotationViewModifier`**: SwiftUI `ViewModifier` applying rotation based on `DeviceOrientationViewModel`.
-   **`RotatingView`**: `UIViewControllerRepresentable` wrapping content in a `RotatingViewController` which applies `CGAffineTransform` rotation based on `DeviceOrientationViewModel`. Can invert rotation.
-   **`OrientationFixView`**: `UIViewControllerRepresentable` wrapping content in `OrientationFixViewController`. This controller enforces orientation constraints (portrait-only or all) using `requestGeometryUpdate` and `supportedInterfaceOrientations`. Used for strict control, especially modal presentations like the video library.

### 3.2. Metal (`Core/Metal/`)

Implements the Metal pipeline for camera preview rendering and video frame processing.

-   **`MetalPreviewView`**: `MTKViewDelegate` responsible for rendering camera frames to an `MTKView`.
    -   Manages `MTLDevice`, `MTLCommandQueue`, `CVMetalTextureCache`.
    * Sets up render pipelines (`vertexShader`, `fragmentShaderRGB`, `fragmentShaderYUV`) from `PreviewShaders.metal`.
    -   Handles different pixel formats (`kCVPixelFormatType_32BGRA`, Apple Log 'x422') by creating appropriate `MTLTexture`s from `CVPixelBuffer`s via the texture cache.
    -   Binds input textures (BGRA or Y/CbCr) and the current LUT texture (`MTLTexture` from `LUTManager`) to the fragment shader.
    -   Passes `isLUTActive` uniform to the YUV shader.
-   **`MetalFrameProcessor`**: Applies LUTs to video frames using Metal compute shaders, intended for recording ("bake-in").
    -   Loads compute kernels (`applyLUTComputeRGB`, `applyLUTComputeYUV`) from `PreviewShaders.metal`.
    -   `processPixelBuffer`: Takes an input `CVPixelBuffer`, creates Metal textures, selects the appropriate compute pipeline, binds input/output textures and the LUT texture, dispatches the kernel, waits for completion, and returns the processed BGRA `CVPixelBuffer`. Handles BGRA, 'v210', and 'x422' input formats. Requires `lutTexture` to be set externally.
-   **`PreviewShaders.metal`**: Contains MSL code:
    -   `vertexShader`: Simple pass-through for a full-screen quad.
    -   `fragmentShaderRGB`: Samples BGRA input texture and uses RGB to sample the 3D LUT texture.
    -   `fragmentShaderYUV`: Samples Y and CbCr textures, converts to Log RGB (BT.2020), and either samples the LUT (if `isLUTActive`) or returns the raw Log RGB. *Note: Apple Log to Linear conversion code is commented out.*
    -   `applyLUTComputeRGB`: Compute kernel for applying LUT to BGRA textures.
    -   `applyLUTComputeYUV`: Compute kernel for applying LUT to YUV ('x422') textures (handles subsampling), converting to Log RGB, sampling the LUT, and writing BGRA output.

### 3.3. Extensions (`Core/Extensions/`)

-   **`UIDeviceOrientation+Extensions.swift`**: Adds computed properties like `isPortrait`, `isLandscape`, `videoRotationAngleValue` (replacement for deprecated API), and `videoTransform`. Also includes `StatusBarHidingModifier`.
-   **`CIContext+Shared.swift`**: Provides a shared, hardware-accelerated `CIContext` instance using Display P3.
-   **`View+Extensions.swift`**: Currently empty (previously held a deprecated safe area modifier).

## 4. Features (`iPhoneApp/Features/`)

### 4.1. Camera (`Features/Camera/`)

The core camera implementation.

#### 4.1.1. `CameraViewModel.swift`

The central `ObservableObject` for the camera feature.

-   **State Management:** Holds numerous `@Published` properties for UI state (e.g., `isSessionRunning`, `isRecording`, `selectedResolution`, `selectedCodec`, `isAppleLogEnabled`, `currentZoomFactor`, `currentLens`, error handling).
-   **Service Delegation:** Initializes and coordinates various services (`CameraSetupService`, `CameraDeviceService`, `VideoFormatService`, `RecordingService`, `ExposureService`). Delegates tasks like lens switching, zoom, format changes, recording start/stop, and exposure adjustments to these services.
-   **AVFoundation:** Manages the core `AVCaptureSession`.
-   **Apple Log:** Handles toggling Apple Log via `isAppleLogEnabled` property, triggering async tasks in `VideoFormatService` and `CameraDeviceService` for reconfiguration.
-   **LUT Management:** Owns `LUTManager` and `MetalFrameProcessor`. Passes the processor to `RecordingService`.
-   **Watch Connectivity:** Implements `WCSessionDelegate`, sends state updates (`isRecording`, `isAppActive`, etc.) to the watch, and handles commands ("startRecording", "stopRecording") received from the watch.
-   **Lifecycle:** Responds to app lifecycle events (via `scenePhase` and notifications) to manage session state.
-   **Delegate Conformance:** Conforms to delegates from all its services to receive updates and handle errors.

#### 4.1.2. Services (`Features/Camera/Services/`)

Encapsulate specific camera functionalities.

-   **`CameraSetupService`**: Handles initial `AVCaptureSession` setup (adding video/audio inputs, setting preset), requests camera permissions, and starts the session. Notifies `CameraViewModel` of status changes and the initial device.
-   **`CameraDeviceService`**: Manages the active `AVCaptureDevice`. Handles switching between physical lenses (`switchToPhysicalLens`) and digital zoom (`setDigitalZoom`). Coordinates session reconfiguration (`configureSession`, `reconfigureSessionForCurrentDevice`) with `VideoFormatService` to apply the correct format and settings for the selected device and configuration (e.g., Apple Log). Sets the video output connection's rotation angle after configuration.
-   **`VideoFormatService`**: Responsible for finding and applying `AVCaptureDevice.Format` based on resolution, frame rate, and Apple Log requirements (`findBestFormat`). Manages `activeColorSpace` and `activeVideoMin/MaxFrameDuration`. Provides `configureAppleLog` and `resetAppleLog` methods for device preparation before session reconfiguration.
-   **`RecordingService`**: Manages video recording using `AVAssetWriter`.
    -   Configures `AVAssetWriterInput` for video (HEVC/ProRes, bitrate, color properties based on Log state, transform based on determined recording orientation) and audio.
    -   Configures `AVAssetWriterInputPixelBufferAdaptor`.
    -   Receives sample buffers via delegate methods.
    -   **LUT Bake-in:** If enabled, calls `metalFrameProcessor.processPixelBuffer` for each video frame before appending to the writer.
    -   Handles starting/stopping the writer, saving the finished file to the Photos library (`saveToPhotoLibrary`), and generating thumbnails (`generateThumbnail`).
-   **`ExposureService`**: Controls exposure, focus, and white balance settings. Provides methods to set ISO, shutter speed/angle, white balance temperature/tint, and toggle auto exposure. Interacts directly with `AVCaptureDevice` properties after locking for configuration.
-   **`VideoOutputDelegate`**: Older delegate implementation. Currently only passes raw sample buffers to `CameraViewModel.processVideoFrame`. Actual preview/recording processing occurs elsewhere.
-   **`VolumeButtonHandler`**: Uses `AVCaptureEventInteraction` (iOS 17.2+) to toggle recording via volume button presses, including debouncing.

#### 4.1.3. Views (`Features/Camera/Views/`)

SwiftUI views composing the camera interface.

-   **`CameraView`**: The main container view. Arranges subviews (`CameraPreviewView`, `FunctionButtonsView`, `ZoomSliderView`, bottom controls) using `ZStack`. Manages presentation of `SettingsView` and `VideoLibraryView`. Responds to lifecycle events and orientation changes.
-   **`CameraPreviewView`**: `UIViewRepresentable` wrapping an `MTKView`. Sets up the Metal rendering pipeline via `MetalPreviewView` and an `AVCaptureVideoDataOutput` whose delegate (`Coordinator`) passes sample buffers to `MetalPreviewView` for rendering.
-   **`FunctionButtonsView`**: Displays F1-F4 buttons at the top, using `RotatingView` to keep labels upright. Includes `FunctionButtonsContainer` (UIViewRepresentable) to potentially bypass safe areas (usage unclear).
-   **`SettingsView`**: `NavigationView` with a `List` presenting various settings (Resolution, Color Space, Codec, FPS, LUT import/management, Bake-in toggle, Flashlight, Debug toggle). Uses `SettingsModel`.
-   **`LensSelectionView`**: Displays circular buttons for available lenses, highlighting the current one. Used within `ZoomSliderView`.
-   **`ZoomSliderView`**: Provides a horizontal slider for smooth zoom control and integrates `LensSelectionView` buttons below it. Handles drag gestures and triggers lens switches automatically at zoom thresholds.
-   **`CameraPreviewImplementation`**: *Alternative/Unused* `UIViewRepresentable` using `AVCaptureVideoPreviewLayer`, fixed to portrait orientation.
-   **`LUTVideoPreviewView`**: *Alternative/Unused* `UIViewRepresentable` using `AVCaptureVideoPreviewLayer` and an overlaid `CALayer` to display frames processed by `LUTProcessor` (Core Image). Attempts complex manual orientation fixing.

#### 4.1.4. Other (`Features/Camera/...`)

-   **`FlashlightManager`**: (`Utilities/`) Simple class to control the device torch (`setTorchState`), including a startup flash sequence (`performStartupSequence`).
-   **`DocumentPicker`**: (`Utilities/`) `UIViewControllerRepresentable` for `UIDocumentPickerViewController`, used for importing LUTs. Copies selected file to temporary directory.
-   **Models (`Models/`)**:
    -   `CameraError`: Enum for specific camera-related errors.
    -   `CameraLens`: Enum representing camera lenses (Ultra Wide, Wide, 2x, Telephoto) with associated `AVCaptureDevice.DeviceType` and zoom factor. Includes `availableLenses()` check.
    -   `ShutterAngle`: Enum for common shutter angles with string representation of equivalent shutter speed.
-   **Extensions (`Extensions/`)**:
    -   `AVFoundationExtensions`: Extensions for `Double` (clamp), `CMTime` (displayString), `CGSize` (aspectRatio, scaledToFit).

### 4.2. Settings (`Features/Settings/`)

-   **`SettingsModel`**: `ObservableObject` holding settings state (`isAppleLogEnabled`, `isFlashlightEnabled`, `flashlightIntensity`, `isBakeInLUTEnabled`). Persists most settings to `UserDefaults`. Posts notifications on change.
-   **`FlashlightSettingsView`**: SwiftUI `Section` content providing UI (Toggle, Slider) for flashlight settings, interacting with `SettingsModel` and a local `FlashlightManager`.

### 4.3. LUT (`Features/LUT/`)

Handles Look-Up Table loading, management, and processing.

-   **`CubeLUTLoader`**: (`Utils/`) Parses text-based `.cube` files, extracts dimension and float data. Handles comments, different encodings, validation, padding/clamping, and fallback identity LUT generation. Includes `validateLUTFile` helper.
-   **`LUTManager`**: `ObservableObject` managing the currently active LUT.
    -   Loads LUTs from bundle (`loadLUT(named:)`) or file URL (`loadLUT(from:)`, used by importer).
    -   Uses `CubeLUTLoader` for parsing.
    -   Creates and holds the active LUT as both a `MTLTexture` (`currentLUTTexture`) via `setupLUTTexture` and a `CIFilter` (`currentLUTFilter`) via `setupLUTFilter`. The `MTLTexture` is primary for Metal pipeline.
    -   Manages recent LUTs (`recentLUTs`) using `UserDefaults`.
    -   Provides `importLUT` which copies the selected file to a sandboxed "Documents/LUTs" directory before loading.
    -   Provides `clearLUT` to reset to an identity texture/filter.
-   **`LUTProcessor`**: (`Utils/`) Class encapsulating Core Image LUT application using `CIColorCube`. Likely only used by the unused `LUTVideoPreviewView`. Provides `processImage` (CIImage -> CIImage) and `processPixelBuffer` (CVPixelBuffer -> CVPixelBuffer).

### 4.4. Video Library (`Features/VideoLibrary/`)

-   **`VideoLibraryView`**: SwiftUI view displaying videos from the user's `PHPhotoLibrary`. Uses a grid (`VideosGridView`) of thumbnails (`VideoThumbnailView`). Presents a player (`VideoPlayerView` using `AVPlayer`) in a sheet. Handles empty/unauthorized states (`EmptyVideoStateView`). Wrapped in `OrientationFixView(allowsLandscapeMode: true)` to allow landscape browsing.
-   **`VideoLibraryViewModel`**: `ObservableObject` handling `PHPhotoLibrary` authorization (`requestAccess`), fetching video `PHAsset`s (`fetchVideos`), managing loading/selection state, and observing library changes (`PHPhotoLibraryChangeObserver`).

## 5. Key Technologies

-   **UI:** SwiftUI, UIKit (`UIViewControllerRepresentable`, `UIViewRepresentable`)
-   **Camera:** AVFoundation (`AVCaptureSession`, `AVCaptureDevice`, `AVAssetWriter`, etc.)
-   **Graphics/Processing:** Metal (Shaders, `MTKView`, Compute), Core Image (`CIColorCube`, `CIContext`), VideoToolbox (Hardware HEVC Encoding)
-   **Persistence:** UserDefaults (`SettingsModel`, `LUTManager`), Core Data (Setup present, usage unclear)
-   **Concurrency:** `async`/`await`, Combine (`ObservableObject`, `@Published`), Grand Central Dispatch (GCD)
-   **Other:** Watch Connectivity (`WCSession`), Photos (`PHPhotoLibrary`, `PHAsset`)

## 6. Observations / Potential Issues

-   **Multiple Preview Implementations:** `CameraPreviewView` (Metal, currently used), `CameraPreviewImplementation` (fixed PreviewLayer), and `LUTVideoPreviewView` (PreviewLayer + CI processing) exist. The latter two appear unused and could potentially be removed.
-   **Core Data Usage:** `Persistence.swift` and `camera.xcdatamodeld` exist, but no direct usage was observed in the analyzed code. May be legacy or for future features.
-   **`VideoOutputDelegate` Role:** Seems to have been refactored, now only passes buffers. Processing logic moved to `MetalPreviewView` / `RecordingService`.
-   **Orientation Handling Complexity:** Orientation is managed in multiple places (`AppDelegate`, `OrientationFixView`, `DeviceOrientationViewModel`, `RotatingView`, `CameraView` onReceive, `RecordingService` transform). While it seems functional, simplification might be possible. Explicit 90-degree rotation is set on connections in several places (`CameraDeviceService`, `CameraPreviewView`, `RecordingService`), ensuring portrait data streams.
-   `xcpretty` dependency in build script caused initial failure.
-   Warning about unused result of `viewModel.processVideoFrame` call in `VideoOutputDelegate`. 