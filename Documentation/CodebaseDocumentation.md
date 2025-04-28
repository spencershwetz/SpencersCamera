# Codebase Documentation

> **Note:** Tap-to-focus and exposure value (EV) compensation are NOT implemented in this version. Any previous references to these features have been removed or clarified.

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
    *   Implements `application(_:supportedInterfaceOrientationsFor:)` to dynamically control *interface* orientation based on the topmost view controller. 
        *   Checks if the top controller is a `PresentationHostingController`, examining its child's name against `AppDelegate.landscapeEnabledViewControllers`.
        *   Checks if the top controller is an `OrientationFixViewController`, using its `allowsLandscapeMode` property.
        *   Checks if the top controller's name matches entries in `AppDelegate.landscapeEnabledViewControllers`.
        *   Defaults to portrait if no condition matches.
    *   Provides a helper extension `UIViewController.topMostViewController()`.
    *   Includes a static list `landscapeEnabledViewControllers` used in the orientation logic.

### Core (`iPhoneApp/Core`)

*   **Metal (`iPhoneApp/Core/Metal`)**
    *   **`MetalPreviewView` (`MetalPreviewView.swift`)**: 
        *   `NSObject`, `MTKViewDelegate`. Initialized with an `MTKView` and `LUTManager`.
        *   Creates and manages `MTLDevice`, `MTLCommandQueue`, `CVMetalTextureCache`.
        *   Creates Metal render pipelines (`rgbPipelineState`, `yuvPipelineState`) using shaders from `PreviewShaders.metal` (specifically `vertexShaderWithRotation`, `fragmentShaderRGB`, `fragmentShaderYUV`).
        *   Creates Metal buffers (`isLUTActiveBuffer`, `isBT709Buffer`, `rotationBuffer`) using `device.makeBuffer()` for shader uniforms. Includes `updateRotation(angle:)` method to update `rotationBuffer`.
        *   `updateTexture(with: CMSampleBuffer)`: Creates `MTLTexture`s from the `CVPixelBuffer` using the texture cache. Handles `kCVPixelFormatType_32BGRA`, `'x422'` (Apple Log YCbCr 10-bit 4:2:2), and `'420v'` (BT.709 YCbCr 8-bit 4:2:0). Creates `bgraTexture` or separate `lumaTexture`/`chromaTexture` depending on the format.
        *   `draw(in: MTKView)`: Renders the appropriate texture(s) to the `MTKView`'s drawable using the corresponding pipeline state. Fetches the `currentLUTTexture` from `LUTManager` and passes it, along with uniform buffers (e.g., `isLUTActiveBuffer`, `isBT709Buffer`, `rotationBuffer`), to the shaders. Uses a `DispatchSemaphore` (`inFlightSemaphore`) for triple buffering.
        *   (Note: Although `MetalPreviewView` supports rotation via `updateRotation`, `CameraPreviewView` sets this to a fixed 90 degrees during initialization).
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
        *   Uses `NotificationCenter` (`UIDevice.orientationDidChangeNotification`, debounced) to observe and publish device orientation changes (`orientation: UIDeviceOrientation`).
        *   Uses `CMMotionManager` (device motion updates) to calculate and publish a rotation angle (`rotationAngleInDegrees: Double`).
        *   Provides a computed `rotationAngle: Angle` based on the motion-derived angle for UI rotation.
    *   **`OrientationFixView` (`OrientationFixView.swift`)**: 
        *   `UIViewControllerRepresentable` wrapping `OrientationFixViewController`.
        *   Takes `allowsLandscapeMode: Bool` parameter.
        *   `OrientationFixViewController`: `UIViewController` subclass that hosts the SwiftUI `Content` view (via a `UIHostingController`). Sets its own view background to black. 
            *   Overrides `supportedInterfaceOrientations` based on `allowsLandscapeMode`.
            *   If `allowsLandscapeMode` is false, sets `modalPresentationStyle = .fullScreen` and actively attempts to enforce portrait orientation in `viewWillAppear` by calling `requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))` on the window scene.
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
*   **DockKit (`iPhoneApp/Core/DockKit`)**
    *   **`DockControlService` (`DockControlService.swift`)**: 
        *   Actor that encapsulates all DockKit accessory interactions (iOS 18.0+).
        *   Uses `@Published` properties to expose accessory status, battery state, region of interest, and tracked persons.
        *   Manages accessory state changes via `DockAccessoryManager.shared.accessoryStateChanges`.
        *   Handles tracking control (framing modes, subject selection, ROI).
        *   Manages battery and tracking state subscriptions.
        *   Processes accessory events (buttons, zoom, shutter, camera flip).
        *   Supports manual control via chevrons (pan/tilt) in manual mode.
        *   Uses `CameraCaptureDelegate` to communicate with `CameraViewModel`.
    *   **`DockKitTypes` (`DockKitTypes.swift`)**:
        *   Defines enums and structs for DockKit integration.
        *   `DockAccessoryStatus`: Connection and tracking state.
        *   `DockAccessoryBatteryStatus`: Battery level and charging state.
        *   `DockAccessoryTrackedPerson`: Person tracking data.
        *   `TrackingMode`, `FramingMode`, `Animation`: Control modes.
    *   **`DockAccessoryFeatures` (`DockAccessoryFeatures.swift`)**:
        *   Configuration class for DockKit features.
        *   Manages feature flags and settings.
        *   Controls tracking, ROI, framing, and animation options.

### Features (`iPhoneApp/Features`)

*   **Camera (`iPhoneApp/Features/Camera`)**
    *   **`CameraViewModel` (`CameraViewModel.swift`)**:
    *   Handles restoration of exposure lock after lens changes when both "Lock Exposure During Recording" and "Shutter Priority" are enabled. After a lens switch, it re-enables shutter priority and, after a short delay, re-applies the shutter priority exposure lock to ensure ISO remains fixed. 
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
        *   `makeUIView`: Creates `MTKView`, sets its background to black. Creates `MetalPreviewView` as its delegate (passing `LUTManager`). Calls `metalDelegate.updateRotation(angle: 90)` to fix the preview rendering rotation to portrait. Assigns the delegate to `CameraViewModel.metalPreviewDelegate`.
        *   The coordinator is currently unused.
    *   **Services (`iPhoneApp/Features/Camera/Services`)**:
        *   `CameraSetupService`: Configures the `AVCaptureSession`, sets initial device settings (including attempting to set `.continuousAutoExposure` mode early and verifying after start), requests permissions, adds inputs, sets preset, calls `ViewModel` to setup video output, and reports status/device via delegate. Includes logic after `startRunning` to *verify* and potentially *re-apply* the `.continuousAutoExposure` mode, as the session start can sometimes reset it. Notifies `ExposureService` of the final confirmed mode. Communicates session status, errors, and the initialized device back to the delegate (`CameraViewModel`).
        *   `CameraDeviceService`: Switches physical lenses by stopping session, removing/adding `AVCaptureDeviceInput`, finding best format (using `VideoFormatService.findBestFormat`), configuring device (format, focus/exposure modes, color space, HDR), re-applying stabilization and exposure lock state, and restarting session. Handles digital zoom via `setDigitalZoom` (instantaneous) and smooth zoom via `ramp(toVideoZoomFactor:withRate:)` within the same lens. 
            *   **HDR Logic**: Correctly configures HDR based on whether Apple Log is requested *and* supported by the selected format. For Apple Log, it disables `automaticallyAdjustsVideoHDREnabled` and manually sets `isVideoHDREnabled = true`. For non-Log modes, it ensures `automaticallyAdjustsVideoHDREnabled = true` and *avoids* manually setting `isVideoHDREnabled` to prevent crashes.
        *   `VideoFormatService`: Finds and applies `AVCaptureDevice.Format` based on resolution, FPS, and Apple Log requirement (`findBestFormat`). Updates frame rate durations (`updateFrameRate`). Configures device for Apple Log or resets it (`configureAppleLog`, `resetAppleLog`). Reapplies color space based on `isAppleLogEnabled` state (`reapplyColorSpaceSettings`).
        *   `ExposureService`: Holds a reference to the current `AVCaptureDevice`. Initializes its internal `isAutoExposureEnabled` state based on the device's state when `setDevice` is called, attempting to set `.continuousAutoExposure` if supported. Uses KVO to monitor `iso`, `exposureDuration`, `deviceWhiteBalanceGains`, and `exposureTargetOffset` properties on the `AVCaptureDevice` to report real-time value changes to the delegate, ensuring UI reflects actual camera state. Provides methods to update white balance (`updateWhiteBalance`), ISO (`updateISO`), shutter speed (`updateShutterSpeed`), shutter angle (`updateShutterAngle`), tint (`updateTint`), and exposure lock (`setExposureLock`).
            *   **Shutter Priority**:
                *   `enableShutterPriority(duration:)`: Sets mode to `.custom` with fixed `duration` and current ISO. Activates KVO on `exposureTargetOffset`.
                *   `disableShutterPriority()`: Deactivates SP state and reverts exposure mode to `.continuousAutoExposure`.
                *   `handleExposureTargetOffsetUpdate(change:)`: KVO handler. If SP is active and not temporarily locked (`isTemporarilyLockedForRecording`), calculates ideal ISO based on offset, clamps it, checks thresholds/rate limits, and applies the new ISO using `setExposureModeCustom(duration:iso:)`.
                *   `lockShutterPriorityExposureForRecording()`: Sets exposure mode to `.custom` with the current SP duration and ISO, then sets `isTemporarilyLockedForRecording = true`
    *   **`DockKitIntegration` (`DockKitIntegration.swift`)**:
        *   Extension to `CameraViewModel` implementing `CameraCaptureDelegate`.
        *   Handles DockKit-initiated camera actions:
            *   `startOrStopCapture`: Toggles recording.
            *   `switchCamera`: Cycles through available lenses.
            *   `zoom`: Handles zoom requests with factor and direction.
            *   `convertToViewSpace`: Transforms tracking coordinates.
        *   Bootstraps DockKit integration in `CameraViewModel`.
        *   Conditionally compiled for iOS 18.0+ using `canImport(DockKit)`.
*   **Settings (`iPhoneApp/Features/Settings`)**
    *   **`SettingsModel` (`iPhoneApp/Features/Settings/SettingsModel.swift`)**: 
        *   `ObservableObject` with `@Published` properties for app settings.
        *   Persists settings using `UserDefaults` in property `didSet` observers.
        *   Includes camera format settings (resolution, codec, frame rate, color space/Apple Log), LUT bake-in, flashlight, exposure lock during recording, video stabilization, and debug info display.
        *   Uses `NotificationCenter` to broadcast changes for some settings.
        *   Provides computed properties for enum-based settings to simplify type conversion.