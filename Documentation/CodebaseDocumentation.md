# Codebase Documentation

This document provides a high-level overview of key classes and components in the Spencer's Camera codebase.

## iPhoneApp

### App (`iPhoneApp/App`)

*   **`cameraApp`**: The main SwiftUI `App` struct. Initializes the `PersistenceController`, `AppDelegate`, and the root `CameraViewModel`. Sets up the main `WindowGroup` containing the `CameraView` and applies global modifiers like background color, status bar hiding, and dark mode.
*   **`AppDelegate`**: Handles app lifecycle events (like `didFinishLaunching`), manages orientation locking logic (`supportedInterfaceOrientationsFor`), and includes helper extensions for view controller hierarchy traversal.

### Core (`iPhoneApp/Core`)

*   **Metal (`iPhoneApp/Core/Metal`)**
    *   **`MetalPreviewView`**: `MTKViewDelegate` implementation. Handles rendering `CMSampleBuffer` frames to an `MTKView` using Metal. Manages texture caches, Metal pipelines (RGB and YUV), and applies LUTs via `PreviewShaders.metal`.
    *   **`MetalFrameProcessor`**: Provides functionality to process `CVPixelBuffer` instances using Metal compute kernels (defined in `PreviewShaders.metal`) to bake in LUTs. Handles different pixel formats (BGRA, YUV) and manages Metal resources.
    *   **`PreviewShaders.metal`**: Contains Metal Shading Language (MSL) code for vertex and fragment shaders used in `MetalPreviewView` for preview rendering (RGB, YUV with LUT application) and compute kernels for `MetalFrameProcessor` to bake LUTs into video frames.
*   **Orientation (`iPhoneApp/Core/Orientation`)**
    *   **`DeviceOrientationViewModel`**: Shared `ObservableObject` that tracks the physical device orientation (`UIDeviceOrientation`) using `NotificationCenter` and provides calculated rotation angles/offsets for UI elements.
    *   **`OrientationFixView`**: `UIViewControllerRepresentable` wrapping a `UIViewController` (`OrientationFixViewController`) that can enforce a specific orientation (typically portrait) or allow all orientations, primarily used to host content like the `CameraView` or `VideoLibraryView`.
    *   **`RotatingView`**: `UIViewControllerRepresentable` that wraps its content in a `RotatingViewController`. Uses `DeviceOrientationViewModel` to apply `CGAffineTransform` rotations to its hosted view, allowing specific UI elements (like buttons) to rotate with the device while the main view remains fixed.
*   **Extensions (`iPhoneApp/Core/Extensions`)**
    *   **`UIDeviceOrientation+Extensions.swift`**: Adds computed properties (`isPortrait`, `isLandscape`, `videoRotationAngleValue`, `videoTransform`) and a `ViewModifier` (`StatusBarHidingModifier`) to `UIDeviceOrientation` and `View`.
    *   **`CIContext+Shared.swift`**: Provides a shared, configured `CIContext` instance for Core Image operations.
    *   **`View+Extensions.swift`**: (Deleted - Contained obsolete code)

### Features (`iPhoneApp/Features`)

*   **Camera (`iPhoneApp/Features/Camera`)**
    *   **`CameraViewModel`**: Central ViewModel for the camera feature. Manages the `AVCaptureSession`, device discovery, format selection, recording state, exposure/focus/white balance settings, zoom, lens switching, LUT application state, and communicates with the Watch App via `WCSessionDelegate`. Coordinates various services.
    *   **`CameraView`**: The main SwiftUI view for the camera interface. Displays the `CameraPreviewView`, overlays function buttons (`FunctionButtonsView`), zoom controls (`ZoomSliderView`), and manages presentation of `SettingsView` and `VideoLibraryView`.
    *   **`CameraPreviewView`**: `UIViewRepresentable` wrapping an `MTKView`. Sets up the `AVCaptureVideoDataOutput`, connects it to the session, and uses `MetalPreviewView` as the `MTKViewDelegate` to render frames.
    *   **Services (`iPhoneApp/Features/Camera/Services`)**: Contains specialized services managed by `CameraViewModel`:
        *   `CameraSetupService`: Handles initial `AVCaptureSession` setup, permissions, and device discovery.
        *   `CameraDeviceService`: Manages switching between physical camera lenses (Wide, Ultrawide, Telephoto) and setting digital zoom.
        *   `VideoFormatService`: Configures the active camera format based on resolution, frame rate, and color space (including Apple Log).
        *   `ExposureService`: Handles manual and automatic exposure, ISO, shutter speed/angle, white balance, and tint adjustments.
        *   `RecordingService`: Manages video recording using `AVAssetWriter`. Handles video/audio input configuration, pixel buffer processing (including Metal LUT bake-in via `MetalFrameProcessor`), orientation transforms, and saving to the photo library.
        *   `VolumeButtonHandler`: Uses `AVCaptureEventInteraction` to trigger start/stop recording via volume buttons (iOS 17.2+).
    *   **`FlashlightManager`**: Controls the device's torch for use as a recording light, including intensity control and a startup flashing sequence.
*   **LUT (`iPhoneApp/Features/LUT`)**
    *   **`LUTManager`**: Manages loading, parsing (using `CubeLUTLoader`), applying, and storing Look-Up Tables (`.cube` files). Provides the `currentLUTTexture` (MTLTexture) for Metal rendering/processing and `currentLUTFilter` (CIFilter) for potential Core Image use. Handles recent LUTs via `UserDefaults`.
    *   **`CubeLUTLoader`**: Static class responsible for parsing the text-based `.cube` file format into dimension and color data (`[Float]`). Includes error handling and fallback mechanisms.
    *   **`LUTProcessor`**: (Potentially less used now with Metal bake-in) Class designed to apply `CIFilter` (like `CIColorCube`) to `CIImage` or `CVPixelBuffer` using Core Image.
*   **Settings (`iPhoneApp/Features/Settings`)**
    *   **`SettingsModel`**: `ObservableObject` holding user-configurable settings like Apple Log enable state, flashlight state/intensity, and LUT bake-in preference. Persists settings to `UserDefaults` and posts notifications on change.
    *   **`SettingsView`**: SwiftUI view presenting the various camera and app settings, allowing users to modify values in `CameraViewModel` and `SettingsModel`.
*   **VideoLibrary (`iPhoneApp/Features/VideoLibrary`)**
    *   **`VideoLibraryViewModel`**: Fetches video assets (`PHAsset`) from the `PHPhotoLibrary`, handles authorization, and manages the display state.
    *   **`VideoLibraryView`**: Displays fetched videos in a grid using `LazyVGrid` and `VideoThumbnailView`. Allows tapping a video to play it in a sheet using `AVPlayerViewController`.

### Other (`iPhoneApp`)

*   **`Persistence.swift`**: Standard Core Data stack setup using `NSPersistentContainer`.
*   **`Info.plist`**: Contains app configuration keys (e.g., `UIFileSharingEnabled`, `ITSAppUsesNonExemptEncryption`).

## SC Watch App

*   **`SCApp`**: Main `App` struct for the WatchOS target.
*   **`ContentView`**: SwiftUI view displaying the recording button and status (Ready/Recording/Time/Prompt). Interacts with `WatchConnectivityService`.
*   **`WatchConnectivityService`**: `ObservableObject` managing the `WCSession` on the watch. Receives context updates from the iPhone (`isRecording`, `isAppActive`, `recordingStartTime`, etc.) and sends commands (`startRecording`, `stopRecording`) back to the iPhone.

*(This documentation is based on initial observation and may require updates as the codebase evolves.)*
