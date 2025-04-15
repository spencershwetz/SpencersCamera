# Codebase Documentation

This document provides a detailed overview of key classes, components, and their responsibilities in the Spencer's Camera codebase.

## iPhoneApp

### App (`iPhoneApp/App`)

*   **`cameraApp` (`cameraApp.swift`)**: 
    *   SwiftUI `App` entry point.
    *   Initializes and manages `PersistenceController`, `AppDelegate`, and the root `CameraViewModel` (`@StateObject`).
    *   Sets up the main `WindowGroup` containing `CameraView`, passing the `CameraViewModel`.
    *   Injects `managedObjectContext` into the environment.
    *   Applies global modifiers: `ZStack` for black background, `OrientationFixView` (potentially redundant here, might be better solely within `CameraView`), `.ignoresSafeArea(.all)`, `.hideStatusBar()`, `.preferredColorScheme(.dark)`.
    *   Uses `@Environment(\.scenePhase)` and `.onChange` to inform `CameraViewModel` about app active/inactive/background state changes for Watch Connectivity updates.
*   **`AppDelegate` (`AppDelegate.swift`)**: 
    *   UIKit App Delegate (`@UIApplicationDelegateAdaptor`).
    *   Handles app lifecycle (`didFinishLaunching`, `applicationWillTerminate`), mainly for setting up/tearing down `UIDevice.begin/endGeneratingDeviceOrientationNotifications()`.
    *   Implements `application(_:supportedInterfaceOrientationsFor:)` to dynamically control *interface* orientation based on the topmost view controller. Checks `OrientationFixViewController.allowsLandscapeMode`. Defaults to portrait. (Simplified: Removed internal flags).
    *   Provides a helper extension `UIViewController.topMostViewController()`.

### Core (`iPhoneApp/Core`)

*   **Metal (`iPhoneApp/Core/Metal`)**
    *   **`MetalPreviewView` (`MetalPreviewView.swift`)**: 
        *   `NSObject`, `MTKViewDelegate`. Initialized with an `MTKView` and `LUTManager`.
        *   Creates and manages `MTLDevice`, `MTLCommandQueue`, `CVMetalTextureCache`.
        *   Creates Metal render pipelines (`rgbPipelineState`, `yuvPipelineState`) using shaders from `PreviewShaders.metal`.
        *   `updateTexture(with: CMSampleBuffer)`: Creates `MTLTexture`s (`bgraTexture` or `lumaTexture`/`chromaTexture`) from the `CVPixelBuffer` in the `CMSampleBuffer` using the texture cache. Handles `kCVPixelFormatType_32BGRA` and `kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange` ('x422' Apple Log).
        *   `draw(in: MTKView)`: Renders the appropriate texture (`bgraTexture` or `lumaTexture`/`chromaTexture`) to the `MTKView`'s drawable using the corresponding pipeline state (`rgbPipelineState` or `yuvPipelineState`). Fetches the `currentLUTTexture` from `LUTManager` and passes it to the fragment shader. Uses a `DispatchSemaphore` (`inFlightSemaphore`) for triple buffering.
    *   **`MetalFrameProcessor` (`MetalFrameProcessor.swift`)**: 
        *   Handles offline processing of video frames for LUT bake-in.
        *   Initializes Metal device, queue, texture cache, and compute pipelines (`computePipelineStateRGB`, `computePipelineStateYUV`) using kernels from `PreviewShaders.metal` (`applyLUTComputeRGB`, `applyLUTComputeYUV`).
        *   `lutTexture: MTLTexture?`: Public property to set the LUT to be baked in.
        *   `processPixelBuffer(_: CVPixelBuffer)`: Takes an input pixel buffer, creates input Metal textures based on its format (BGRA or YUV 'v210'/'x422'), creates an output BGRA texture/pixel buffer, dispatches the appropriate compute kernel (`applyLUTComputeRGB` or `applyLUTComputeYUV`) with the input textures, output texture, and `lutTexture`, waits for completion, and returns the processed output `CVPixelBuffer` (BGRA).
    *   **`PreviewShaders.metal` (`PreviewShaders.metal`)**: 
        *   `vertexShader`: Simple passthrough vertex shader.
        *   `fragmentShaderRGB`: Samples BGRA input texture, uses its RGB as coordinates to sample the 3D `lutTexture`, returns the LUT color with original alpha.
        *   `fragmentShaderYUV`: Samples Y and CbCr textures ('x422' format assumed), performs YUV(BT.2020) to RGB conversion (producing Log RGB), uses the Log RGB to sample the `lutTexture` (if active), and returns the final color. Includes a uniform `isLUTActive` to bypass LUT sampling.
        *   `applyLUTComputeRGB`: Compute kernel taking BGRA input, BGRA output, and LUT textures. Reads input, samples LUT using input RGB, writes LUT color to output.
        *   `applyLUTComputeYUV`: Compute kernel taking Y input, CbCr input, BGRA output, and LUT textures. Reads Y/CbCr (handles 4:2:2 subsampling), converts to Log RGB, samples LUT using Log RGB, writes LUT color to output BGRA texture.
*   **Orientation (`iPhoneApp/Core/Orientation`)**
    *   **`DeviceOrientationViewModel` (`DeviceOrientationViewModel.swift`)**: 
        *   Shared `ObservableObject` (`DeviceOrientationViewModel.shared`).
        *   Uses `NotificationCenter` (`UIDevice.orientationDidChangeNotification`) to observe device orientation changes.
        *   Publishes the current `UIDeviceOrientation` (`orientation`).
        *   Provides computed `rotationAngle: Angle` based on `orientation` for UI rotation.
    *   **`OrientationFixView` (`OrientationFixView.swift`)**: 
        *   `UIViewControllerRepresentable` wrapping `OrientationFixViewController`.
        *   Takes `allowsLandscapeMode: Bool` parameter.
        *   `OrientationFixViewController`: `UIViewController` subclass that hosts the SwiftUI `Content` view. Overrides `supportedInterfaceOrientations` based on `allowsLandscapeMode`. Attempts to enforce portrait orientation using `requestGeometryUpdate` if `allowsLandscapeMode` is false. (Simplified: Removed setting `AppDelegate.isVideoLibraryPresented`).
    *   **`RotatingView` (`RotatingView.swift`)**: 
        *   `UIViewControllerRepresentable` wrapping `RotatingViewController`.
        *   Takes `orientationViewModel` and `invertRotation: Bool`.
        *   `RotatingViewController`: `UIViewController` subclass hosting the SwiftUI `Content`. Observes `orientationViewModel.$orientation` via Combine `sink`. Applies a `CGAffineTransform(rotationAngle:)` to the `hostingController.view.transform` based on the orientation and `invertRotation` flag, animating the change. (Logging reduced).
*   **Extensions (`iPhoneApp/Core/Extensions`)**
    *   **`UIDeviceOrientation+Extensions.swift`**: Adds helpers (`isPortrait`, `isLandscape`, `isValidInterfaceOrientation`), `videoRotationAngleValue: CGFloat` (returns 0, 90, 180, 270 for video metadata), and `videoTransform: CGAffineTransform` (returns rotation transform for video). Also includes `StatusBarHidingModifier`.
    *   **`CIContext+Shared.swift`**: Provides `CIContext.shared` configured for Display P3 and GPU rendering.

### Features (`iPhoneApp/Features`)

*   **Camera (`iPhoneApp/Features/Camera`)**
    *   **`CameraViewModel` (`CameraViewModel.swift`)**: 
        *   Acts as central coordinator, holding references to all camera-related services and the `LUTManager`.
        *   Manages `AVCaptureSession` state (`session`, `isSessionRunning`, `status`, `error`).
        *   Handles user settings (`selectedResolution`, `selectedCodec`, `selectedFrameRate`, `isAppleLogEnabled`, `currentLens`, `currentZoomFactor`, `whiteBalance`, `iso`, `shutterSpeed`, `currentTint`, `isAutoExposureEnabled`).
        *   Coordinates service interactions for setup, lens/zoom changes, format changes (resolution, FPS, Apple Log), exposure/WB changes, recording start/stop.
        *   Acts as delegate for all services (`CameraSetupServiceDelegate`, `RecordingServiceDelegate`, etc.) and `WCSessionDelegate`.
        *   Handles state updates from services/delegates and publishes changes via `@Published` properties.
        *   Provides `startRecording`/`stopRecording` async methods, configuring `RecordingService` with current settings (including LUT bake-in state and texture) before starting.
        *   Manages `FlashlightManager` state based on recording and settings.
        *   Handles Watch Connectivity communication (sending state, receiving commands).
        *   (Orientation logic fully delegated: Relies on `DeviceOrientationViewModel` for physical orientation, `AppDelegate`/`OrientationFixView` for interface lock, `RotatingView` for UI element rotation, and `CameraDeviceService`/`RecordingService` for preview/file metadata respectively).
    *   **`CameraView` (`CameraView.swift`)**: 
        *   Main UI. Observes `CameraViewModel` and `DeviceOrientationViewModel`.
        *   Uses `GeometryReader` for layout.
        *   Displays `CameraPreviewView` (embedding `MetalPreviewView`).
        *   Overlays `FunctionButtonsView` and `ZoomSliderView`.
        *   Includes Record, Library, and Settings buttons.
        *   Uses `RotatingView` to rotate specific UI elements (e.g., Settings icon) based on physical device orientation.
        *   Manages presentation state for Settings (`.fullScreenCover`), Library (`.fullScreenCover` with `OrientationFixView(allowsLandscapeMode: true)`), and LUT Document Picker (`.sheet`).
        *   Handles `onAppear`/`onDisappear` to start/stop session via ViewModel.
        *   Responds to `UIApplication.willResignActiveNotification`.
        *   (Orientation logic fully delegated: Does not directly handle orientation changes or notifications).
    *   **`CameraPreviewView` (`CameraPreviewView.swift`)**: 
        *   `UIViewRepresentable` for `MTKView`.
        *   `makeUIView`: Creates `MTKView`, sets up `MetalPreviewView` as its delegate (passing `LUTManager`), creates and adds `AVCaptureVideoDataOutput` to the session, sets the delegate to its `Coordinator`.
        *   `Coordinator`: `AVCaptureVideoDataOutputSampleBufferDelegate`. Receives frames and passes them to `metalDelegate.updateTexture(with:)`.
    *   **Services (`iPhoneApp/Features/Camera/Services`)**: 
        *   `CameraSetupService`: Initializes session, requests permissions, adds initial video/audio inputs, sets initial preset, starts session.
        *   `CameraDeviceService`: Switches physical lenses by stopping session, removing/adding `AVCaptureDeviceInput`, finding best format (using `VideoFormatService.findBestFormat`), configuring device (format, focus/exposure modes), re-applying color space (via `VideoFormatService.reapplyColorSpaceSettings`), setting the `AVCaptureConnection.videoRotationAngle` for correct *preview* orientation, and restarting session. Handles digital zoom via `setDigitalZoom` (instantaneous) and smooth zoom via `ramp(toVideoZoomFactor:withRate:)` within the same lens.
        *   `VideoFormatService`: Finds and applies `AVCaptureDevice.Format` based on resolution, FPS, and Apple Log requirement (`findBestFormat`). Updates frame rate durations (`updateFrameRate`). Configures device for Apple Log or resets it (`configureAppleLog`, `resetAppleLog`). Reapplies color space based on `isAppleLogEnabled` state (`reapplyColorSpaceSettings`).
        *   `ExposureService`: Sets white balance gains, ISO, exposure duration (`setExposureModeCustom`), and exposure mode (`.continuousAutoExposure` vs `.custom`). Calculates shutter duration from angle/FPS.
        *   `RecordingService`: Manages `AVAssetWriter`, `AVAssetWriterInput` (video/audio), and `AVAssetWriterInputPixelBufferAdaptor`. Configures output settings based on codec/resolution/log state. Before recording starts, calculates the `recordingOrientation` angle based on device/interface orientation and applies the corresponding `CGAffineTransform` to the `AVAssetWriterInput.transform` property to ensure correct *video file* metadata orientation. Implements `AVCaptureVideoDataOutputSampleBufferDelegate` and `AVCaptureAudioDataOutputSampleBufferDelegate` to receive buffers during recording. If LUT bake-in is enabled (`SettingsModel.isBakeInLUTEnabled`), passes video pixel buffers to `MetalFrameProcessor.processPixelBuffer` before appending to the writer. (Default bake-in is now false). Saves finished video to `PHPhotoLibrary` and generates a thumbnail.
        *   `VolumeButtonHandler`: Uses `AVCaptureEventInteraction` (iOS 17.2+) to trigger `viewModel.start/stopRecording()` on volume button presses (began phase), includes debouncing.
    *   **`FlashlightManager` (`FlashlightManager.swift`)**: Uses `AVCaptureDevice` torch controls (`setTorchModeOn(level:)`) to manage the flashlight state and intensity. Includes an async startup sequence (`performStartupSequence`) with timed flashes.
*   **LUT (`iPhoneApp/Features/LUT`)**
    *   **`LUTManager` (`LUTManager.swift`)**: 
        *   `ObservableObject`. Holds `currentLUTFilter` (CIFilter) and `currentLUTTexture` (MTLTexture).
        *   Loads LUTs from Bundle or URL using `CubeLUTLoader`.
        *   `setupLUTTexture`: Creates a 3D `MTLTexture` (`.rgba32Float`) from loaded LUT data (converts RGB to RGBA) and publishes it to `currentLUTTexture`.
        *   `setupLUTFilter`: Creates a `CIColorCube` filter using loaded LUT data and stores it in `currentLUTFilter`.
        *   Manages recent LUT URLs in `UserDefaults`.
        *   `importLUT`: Copies selected LUT to app's Documents directory before loading.
        *   `clearLUT`: Resets `currentLUTTexture` to an identity LUT texture and clears `currentLUTFilter`.
    *   **`CubeLUTLoader` (`CubeLUTLoader.swift`)**: 
        *   Static methods `loadCubeFile(name:)` and `loadCubeFile(from:)`.
        *   Parses `.cube` file format (handles comments, `LUT_3D_SIZE`, data lines).
        *   Includes error handling for file reading, parsing, incomplete data, and out-of-range values (clamps 0-1).
        *   Provides fallback to identity LUT if parsing fails significantly.
    *   **`LUTProcessor` (`LUTProcessor.swift`)**: 
        *   Simple class holding a `CIFilter`. 
        *   `processImage`: Applies the held `lutFilter` to a `CIImage`.
        *   `processPixelBuffer`: Converts `CVPixelBuffer` to `CIImage`, calls `processImage`, renders result back to a *new* `CVPixelBuffer` using `CIContext.shared.render`.
        *   (Seems potentially redundant given `MetalFrameProcessor` handles bake-in).
    *   **`LUTVideoPreviewView` (`LUTVideoPreviewView.swift`)**: 
        *   `UIViewRepresentable` wrapping `LUTPreviewView`. 
        *   Sets up a *separate* `AVCaptureVideoDataOutput` and acts as its delegate (`Coordinator`).
        *   `Coordinator.captureOutput`: Receives frames, processes them using the *`LUTProcessor`* (Core Image), and displays the result in `LUTPreviewView`'s `processedLayer`.
        *   `LUTPreviewView`: `UIView` subclass whose backing layer is `AVCaptureVideoPreviewLayer`. Also contains a `processedLayer` (CALayer). Shows/hides layers based on whether `LUTProcessor` has a filter set. Tries to maintain a fixed portrait orientation.
        *   (This entire view seems outdated/conflicting with the `MetalPreviewView` approach used in `CameraView` and should likely be reviewed/removed - see Task #13 in ToDo.md).
*   **Settings (`iPhoneApp/Features/Settings`)**
    *   **`SettingsModel` (`SettingsModel.swift`)**: `ObservableObject` holding `@Published` properties for `isAppleLogEnabled`, `isFlashlightEnabled`, `flashlightIntensity`, `isBakeInLUTEnabled`. Uses `UserDefaults` for persistence (correctly defaults `isBakeInLUTEnabled` to false on first launch). Posts notifications (`.appleLogSettingChanged`, etc.) on `didSet`.
    *   **`FlashlightSettingsView` (`FlashlightSettingsView.swift`)**: Section within `SettingsView` for flashlight toggle and intensity slider. Interacts with `SettingsModel` and a local `FlashlightManager` instance.
    *   **`SettingsView` (`SettingsView.swift`)**: SwiftUI `List` view presented modally. Contains pickers for `CameraViewModel` settings (Resolution, Color Space, Codec, FPS) and controls for `LUTManager` (Import, Remove, Recent) and `SettingsModel` (Bake-in LUT, Flashlight via `FlashlightSettingsView`, Debug Info). Uses `NavigationView` and `.sheet` for `DocumentPicker`.
*   **VideoLibrary (`iPhoneApp/Features/VideoLibrary`)**
    *   **`VideoLibraryViewModel` (`VideoLibraryViewModel.swift`)**: `ObservableObject`, `PHPhotoLibraryChangeObserver`. Requests Photo Library access (`requestAccess`), fetches video `PHAsset`s (`fetchVideos`), publishes them as `[VideoAsset]`, manages loading/error/empty states, and handles authorization status. Publishes `selectedVideo` for presenting the player.
    *   **`VideoLibraryView` (`VideoLibraryView.swift`)**: SwiftUI view using `NavigationStack`. Displays loading indicator, empty state (`EmptyVideoStateView`), or a `ScrollView` with `LazyVGrid` of `VideoThumbnailView`s based on `VideoLibraryViewModel` state. Presents `VideoPlayerView` as a sheet when `selectedVideo` is set. Includes Close and Refresh buttons.
    *   **`VideoThumbnailView`**: Displays a thumbnail image (loaded via `PHImageManager`) and duration for a `VideoAsset`.
    *   **`VideoPlayerView`**: Simple view wrapping `AVPlayerViewController` (`VideoPlayer`) to play the selected `PHAsset` (loaded via `PHImageManager.requestAVAsset`).

### Other (`iPhoneApp`)

*   **`Persistence.swift`**: Standard Core Data boilerplate setup.
*   **`Info.plist`**: App configuration. Key values: `UIFileSharingEnabled` (true), `UIViewControllerBasedStatusBarAppearance` (false), `ITSAppUsesNonExemptEncryption` (false).

## SC Watch App

*   **`SCApp` (`SCApp.swift`)**: WatchOS `App` entry point. Sets up `WindowGroup` with `ContentView`.
*   **`ContentView` (`ContentView.swift`)**: SwiftUI view. Observes `WatchConnectivityService.shared`. Displays a large record button (circle/square) and status text (Prompt/Ready/Elapsed Time). Sends `toggleRecording` message via `connectivityService` on button tap. Uses a `Timer` (`.publish(every: 0.05)`) and `onReceive` to update the `elapsedTimeString` state frequently when recording.
*   **`WatchConnectivityService` (`WatchConnectivityService.swift`)**: `ObservableObject`, `WCSessionDelegate`. Manages `WCSession`. Publishes `latestContext: [String: Any]` received from iPhone via `session(_:didReceiveApplicationContext:)`. Sends `toggleRecording` message (`startRecording`/`stopRecording`) to iPhone via `sendMessage(_:replyHandler:errorHandler:)`. Updates UI state based on `latestContext` (e.g., `isRecording`, `isAppActive`, `recordingStartTime`). Handles reachability changes.

*(This documentation provides a more detailed component breakdown.)*
