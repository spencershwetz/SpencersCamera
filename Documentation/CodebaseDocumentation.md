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
*   **Utilities (`iPhoneApp/Core/Utilities`)**
    *   **`AppLifecycleObserver` (`AppLifecycleObserver.swift`)**: 
        *   `ObservableObject` designed to be used as a `@StateObject` within a SwiftUI view (like `CameraView`).
        *   Manages the lifecycle of a `UIApplication.didBecomeActiveNotification` observer.
        *   Adds the observer in its `init()` and removes it safely in `deinit()`, preventing retain cycles and ensuring cleanup.
        *   Publishes an event via a Combine `PassthroughSubject` (`didBecomeActivePublisher`) when the notification is received.
        *   This allows views observing it (like `CameraView`) to react to the app becoming active (e.g., restart camera session) without managing the observer manually.

### Features (`iPhoneApp/Features`)

*   **Camera (`iPhoneApp/Features/Camera`)**
    *   **`CameraViewModel` (`CameraViewModel.swift`)**: 
        *   Acts as central coordinator, holding references to all camera-related services and the `LUTManager`.
        *   Manages `AVCaptureSession` state (`session`, `isSessionRunning`, `status`, `error`).
        *   Handles user settings (`selectedResolution`, `selectedCodec`, `selectedFrameRate`, `isAppleLogEnabled`, `currentLens`, `currentZoomFactor`, `whiteBalance`, `iso`, `shutterSpeed`, `currentTint`, `isAutoExposureEnabled`, `isExposureLocked`, `isShutterPriorityEnabled`).
        *   Coordinates service interactions for setup, lens/zoom changes, format changes (resolution, FPS, Apple Log), exposure/WB changes, recording start/stop.
        *   Acts as delegate for all services (`CameraSetupServiceDelegate`, `RecordingServiceDelegate`, etc.) and `WCSessionDelegate`.
        *   Handles state updates from services/delegates and publishes changes via `@Published` properties.
        *   Provides `startRecording`/`stopRecording` async methods, configuring `RecordingService` with current settings (including LUT bake-in state and texture) before starting.
        *   Manages `FlashlightManager` state based on recording and settings.
        *   Handles Watch Connectivity communication (sending state, receiving commands).
        *   (Orientation logic fully delegated: Relies on `DeviceOrientationViewModel` for physical orientation, `AppDelegate`/`OrientationFixView` for interface lock, `RotatingView` for UI element rotation, and `CameraDeviceService`/`RecordingService` for preview/file metadata respectively).
        *   Handles the "Lock Exposure During Recording" setting: If enabled, it stores the previous exposure state before recording. If Shutter Priority is *not* active, it calls `ExposureService.setExposureLock(locked: true)`. If Shutter Priority *is* active, it calls `ExposureService.lockShutterPriorityExposureForRecording()` to initiate the SP-specific lock. On stop, it calls the corresponding unlock/restore methods (`ExposureService.unlockShutterPriorityExposureAfterRecording()` or standard restore logic). Logic is designed to prevent conflicts between the standard AE lock (`isExposureLocked` state) and the internal SP recording lock.
        *   Handles `toggleShutterPriority()`: Calculates the 180° target duration and calls `ExposureService.enable/disableShutterPriority()`. Ensures the standard AE lock UI (`isExposureLocked`) is disabled when SP is enabled.
        *   Handles `toggleExposureLock()`: Toggles the standard AE lock *only* if Shutter Priority is not active.
    *   **`CameraView` (`CameraView.swift`)**: 
        *   Main UI. Observes `CameraViewModel` and `DeviceOrientationViewModel`.
        *   Uses `@StateObject` to manage an instance of `AppLifecycleObserver`, ensuring its lifecycle is tied to the view.
        *   Uses `GeometryReader` for layout.
        *   Displays `CameraPreviewView` (embedding `MetalPreviewView`), applying `.scaleEffect(0.9)` and padding to adjust its size and position below the safe area.
        *   Overlays `FunctionButtonsView` and `ZoomSliderView`.
        *   Passes the `SettingsModel` instance to `FunctionButtonsView`.
        *   Includes Record, Library, and Settings buttons.
        *   Uses `RotatingView` to rotate specific UI elements (e.g., Settings icon) based on physical device orientation.
        *   Manages presentation state for Settings (`.fullScreenCover`), Library (`.fullScreenCover` with `OrientationFixView(allowsLandscapeMode: true)`), and LUT Document Picker (`.sheet`).
        *   Handles `onAppear`/`onDisappear` to start/stop session via ViewModel.
        *   Responds to `UIApplication.willResignActiveNotification` to stop the session.
        *   Uses `.onReceive(appLifecycleObserver.didBecomeActivePublisher)` to call `startSession()` when the app returns to the foreground, ensuring the camera restarts.
        *   (Orientation logic fully delegated: Does not directly handle orientation changes or notifications).
        *   (App lifecycle notification handling is delegated to `AppLifecycleObserver`).
    *   **`CameraPreviewView` (`CameraPreviewView.swift`)**: 
        *   `UIViewRepresentable` for `MTKView`.
        *   `makeUIView`: Creates `MTKView`, sets up `MetalPreviewView` as its delegate (passing `LUTManager`), creates and adds `AVCaptureVideoDataOutput` to the session, sets the delegate to its `Coordinator`.
        *   `Coordinator`: `AVCaptureVideoDataOutputSampleBufferDelegate`. Receives frames and passes them to `metalDelegate.updateTexture(with:)`.
        *   `isAppleLogEnabled`: Controls Apple Log colorspace (requires session reconfiguration).
        *   `isExposureLocked`: Controls whether exposure is locked (`AVCaptureDevice.ExposureMode.locked`).
        *   Coordinates service interactions for setup, lens/zoom changes, format changes (resolution, FPS, Apple Log), exposure/WB changes, recording start/stop, exposure lock.
        *   Acts as delegate for all services (`CameraSetupServiceDelegate`, `RecordingServiceDelegate`, etc.) and `WCSessionDelegate`.
        *   Handles state updates from services/delegates and publishes changes via `@Published` properties.
    *   **Services (`iPhoneApp/Features/Camera/Services`)**: 
        *   `CameraSetupService`: Initializes the `AVCaptureSession`.
        *   Finds the default video device and attempts to configure it early (within `session.begin/commitConfiguration`) including setting focus mode, white balance mode, and crucially, attempting to set the initial exposure mode to `.continuousAutoExposure`.
        *   Adds video and audio inputs to the session.
        *   Sets the session preset (`.hd4K3840x2160` preferred).
        *   Handles camera permission checks and requests.
        *   Starts the `AVCaptureSession` (`startRunning`).
        *   Includes logic after `startRunning` to *verify* and potentially *re-apply* the `.continuousAutoExposure` mode, as the session start can sometimes reset it. Notifies `ExposureService` of the final confirmed mode.
        *   Communicates session status, errors, and the initialized device back to the delegate (`CameraViewModel`).
        *   `CameraDeviceService`: Switches physical lenses by stopping session, removing/adding `AVCaptureDeviceInput`, finding best format (using `VideoFormatService.findBestFormat`), configuring device (format, focus/exposure modes), re-applying color space (via `VideoFormatService.reapplyColorSpaceSettings`), setting the `AVCaptureConnection.videoRotationAngle` for correct *preview* orientation, and restarting session. Handles digital zoom via `setDigitalZoom` (instantaneous) and smooth zoom via `ramp(toVideoZoomFactor:withRate:)` within the same lens.
        *   `VideoFormatService`: Finds and applies `AVCaptureDevice.Format` based on resolution, FPS, and Apple Log requirement (`findBestFormat`). Updates frame rate durations (`updateFrameRate`). Configures device for Apple Log or resets it (`configureAppleLog`, `resetAppleLog`). Reapplies color space based on `isAppleLogEnabled` state (`reapplyColorSpaceSettings`).
        *   `ExposureService`: Holds a reference to the current `AVCaptureDevice`.
        *   Initializes its internal `isAutoExposureEnabled` state based on the device's state when `setDevice` is called, attempting to set `.continuousAutoExposure` if supported.
        *   Provides methods to update white balance (`updateWhiteBalance`), ISO (`updateISO`), shutter speed (`updateShutterSpeed`), shutter angle (`updateShutterAngle`), tint (`updateTint`), and exposure lock (`setExposureLock`).
        *   **Shutter Priority**: 
            *   `enableShutterPriority(duration:)`: Sets mode to `.custom` with fixed `duration` and current ISO. Activates KVO on `exposureTargetOffset`.
            *   `disableShutterPriority()`: Deactivates SP state and reverts exposure mode to `.continuousAutoExposure`.
            *   `handleExposureTargetOffsetUpdate(change:)`: KVO handler. If SP is active and not temporarily locked (`isTemporarilyLockedForRecording`), calculates ideal ISO based on offset, clamps it, checks thresholds/rate limits, and applies the new ISO using `setExposureModeCustom(duration:iso:)`.
            *   `lockShutterPriorityExposureForRecording()`: Sets exposure mode to `.custom` with the current SP duration and ISO, then sets `isTemporarilyLockedForRecording = true` to pause auto-ISO adjustments.
            *   `unlockShutterPriorityExposureAfterRecording()`: Sets `
*   **Settings**: 
    *   `SettingsModel` (`iPhoneApp/Features/Settings/SettingsModel.swift`): 
        *   `ObservableObject` with `@Published` properties for app settings.
        *   Persists settings using `UserDefaults` in property `didSet` observers.
        *   Includes camera format settings (resolution, codec, frame rate, color space/Apple Log), LUT bake-in, flashlight, exposure lock during recording, and debug info display.
        *   Uses `NotificationCenter` to broadcast changes for some settings.
        *   Provides computed properties for enum-based settings to simplify type conversion.
    *   `SettingsView` (`iPhoneApp/Features/Camera/Views/SettingsView.swift`): 
        *   SwiftUI view presenting UI for all settings.
        *   Uses `@ObservedObject` to bind to the shared `SettingsModel`.
        *   Uses `Picker`s and `Toggle`s bound to `SettingsModel` properties.
        *   Includes `.onChange` modifiers to update `CameraViewModel` when settings change.
    *   `FlashlightSettingsView` (`iPhoneApp/Features/Settings/FlashlightSettingsView.swift`): 
        *   Dedicated view for configuring flashlight (intensity, patterns).