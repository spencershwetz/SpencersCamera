# Technical Specification

> **Note:** Push-to-focus (tap to set focus point) is supported. Push-to-exposure (tap to set exposure point) and exposure value (EV) compensation are NOT implemented in this version. Any previous references to these features have been removed or clarified.

This document outlines the technical specifications and requirements for the Spencer's Camera application.

## Platform & Target

*   **Target Platform**: iOS & watchOS
*   **Minimum iOS Version**: 18.0
*   **Minimum watchOS Version**: 11.0 (Implied for iOS 18 compatibility)
*   **Target Devices**: 
    *   iOS: iPhone models with Metal support and necessary camera hardware (Wide required, Ultra-Wide/Telephoto optional).
    *   watchOS: Apple Watch models compatible with watchOS 11+.
*   **Architecture**: MVVM (primarily), Service Layer for encapsulating framework interactions.
*   **UI Framework**: SwiftUI (primarily), UIKit (`UIViewControllerRepresentable`, `UIViewRepresentable`, `AppDelegate`) for bridging AVFoundation, MetalKit, and specific view controllers/app lifecycle.
*   **EV Compensation Control**: 
    - EVWheelPicker component for precise EV bias control
    - Horizontal wheel interface with haptic feedback
    - Gesture-based interaction with smooth scrolling
    - Maintains exact position when gesture ends
    - Always initializes centered at 0 EV
    - Show/hide with edge swipe gestures on camera preview
*   **Lifecycle Management**: App lifecycle events (`didBecomeActive`, `willResignActive`) are handled: 
    *   `willResignActive` triggers `stopSession` via `.onReceive` in `CameraView`.
    *   `didBecomeActive` is managed by `AppLifecycleObserver` (used as `@StateObject` in `CameraView`), which publishes an event triggering `startSession` in `CameraView` to ensure the session restarts correctly after backgrounding.

## Core Features & Implementation Details

*   **Camera Control**: 
    *   Uses `AVCaptureSession` managed primarily within `CameraViewModel` and configured by `CameraSetupService`.
    *   Session start/stop is handled by `startSession`/`stopSession` in `CameraViewModel`, triggered by `CameraView`'s `onAppear`/`onDisappear` and the `AppLifecycleObserver`'s `didBecomeActivePublisher`.
    *   Device discovery and switching handled by `CameraDeviceService` using `AVCaptureDevice.DiscoverySession`.
    *   Lens switching logic in `CameraDeviceService` handles physical switching (reconfiguring session) and digital zoom (setting `videoZoomFactor` on wide lens for 2x).
    *   **Format Selection**: `VideoFormatService` finds the best `AVCaptureDevice.Format` based on resolution, frame rate, and Apple Log requirements using `findBestFormat()`. To enable Apple Log, `configureAppleLog()` finds a suitable format supporting `.appleLog` and sets it as the `device.activeFormat`; it does *not* set `activeColorSpace` directly. `resetAppleLog()` finds a suitable non-Log format and sets it. Frame rate changes are handled by `updateFrameRateForCurrentFormat()`, which locks the device and sets `activeVideoMin/MaxFrameDuration`.
    *   **Manual Exposure/WB/Tint controls**: Managed by `ExposureService`, locking device configuration and setting properties like `exposureMode`, `setExposureModeCustom(duration:iso:)`, `setWhiteBalanceModeLocked(with:)`. It also uses KVO to observe `iso`, `exposureDuration`, `deviceWhiteBalanceGains`, and `exposureTargetOffset` for real-time delegate updates.
    *   **Shutter Priority**: Implemented in `ExposureService`. When enabled via `CameraViewModel`:
        *   **Shutter Priority Mode:** When enabled, the app sets a fixed shutter duration (typically 180°) and allows ISO to float. The user can toggle this mode, and the app ensures that the correct duration is set based on the selected frame rate. 
        *   **Robust Shutter Priority Logic (2025-04-28):** After every lens switch, the 180° shutter duration is recalculated based on the *current* frame rate and immediately applied. A helper computes the duration as `1.0 / (2 * frameRate)`. This prevents incorrect shutter angles (e.g., 144°, 216°) after lens switches and guarantees consistent 180° exposure regardless of previous state or lens.
        *   During recording, if "Lock Exposure During Recording" is also enabled, the app temporarily locks exposure using the current ISO and duration, then restores shutter priority after lens switches or format changes, using the recalculated duration., subject to rate limits and thresholds (`handleExposureTargetOffsetUpdate`).
        *   Includes logic (`isTemporarilyLockedForRecording`, `lock/unlockShutterPriorityExposureForRecording`) to temporarily pause auto-ISO adjustments during recording when the "Lock Exposure During Recording" setting is enabled, preventing conflicts with the intended lock.
    *   **Lens Switch Exposure Lock Handling**: When both "Lock Exposure During Recording" and "Shutter Priority" are enabled, `CameraViewModel` restores the exposure lock after a lens change by re-enabling shutter priority and, after a short delay, re-locking ISO. This prevents ISO drift and ensures consistent exposure during recording across lens switches.
    *   **Exposure Lock**: Standard AE lock (`.locked` mode) is managed by `ExposureService` via `setExposureLock`. `CameraViewModel` handles the UI state (`isExposureLocked`) and ensures standard AE lock cannot be toggled while Shutter Priority is active.
*   **Video Recording**: 
    *   Handled by `RecordingService` using `AVAssetWriter`.
    *   Video Input (`AVAssetWriterInput`): Configured with dimensions from active format, codec type (`.hevc` or `.proRes422HQ`), and compression properties (bitrate, keyframe interval, profile level, color primaries based on `isAppleLogEnabled`).
    *   Audio Input (`AVAssetWriterInput`): Configured for Linear PCM (48kHz, 16-bit stereo).
    *   Orientation: `CGAffineTransform` is applied to the video input based on device/interface orientation at the start of recording to ensure correct playback rotation.
    *   Pixel Processing: Video frames (`CMSampleBuffer`) are received via delegate (`AVCaptureVideoDataOutputSampleBufferDelegate`). If LUT bake-in is enabled (`SettingsModel.isBakeInLUTEnabled`), the `CVPixelBuffer` is passed to `MetalFrameProcessor.processPixelBuffer` before being appended to the `AVAssetWriterInputPixelBufferAdaptor`. (Note: Default bake-in state is off).
    *   Saving: Finished `.mov` file saved to `PHPhotoLibrary` using `PHPhotoLibrary.shared().performChanges`.
    *   Manages transitions between `.continuousAutoExposure` and `.custom` exposure modes via `setAutoExposureEnabled` and `updateExposureMode`. Ensures values (like ISO) are clamped within device limits when setting custom exposure.
    *   Communicates errors and manual value updates (ISO, WB, Shutter) back to the delegate (`CameraViewModel`). The initial auto mode state is primarily managed and verified by `CameraSetupService` after the session starts.
    *   Uses Key-Value Observing (KVO) on `iso`, `exposureDuration`, and `deviceWhiteBalanceGains` properties of the `AVCaptureDevice` to report real-time value changes to the delegate, ensuring the UI reflects the actual camera state even in automatic or locked modes.
    *   `RecordingService`: Manages `AVAssetWriter`, `AVAssetWriterInput` (video/audio), and `AVAssetWriterInputPixelBufferAdaptor`. Configures output settings based on codec/resolution/log state. Before recording starts, calculates the `recordingOrientation` angle based on device/interface orientation and applies the corresponding `CGAffineTransform` to the `AVAssetWriterInput.transform` property to ensure correct *video file* metadata orientation. Implements `AVCaptureVideoDataOutputSampleBufferDelegate` and `AVCaptureAudioDataOutputSampleBufferDelegate` to receive buffers during recording. If LUT bake-in is enabled (`SettingsModel.isBakeInLUTEnabled`), passes video pixel buffers to `MetalFrameProcessor.processPixelBuffer`. Appends video frames using `AVAssetWriterInputPixelBufferAdaptor.append(_:withPresentationTime:)` to handle frame timing correctly, especially for high frame rates. Saves finished video to `PHPhotoLibrary` and generates a thumbnail.
    *   `VolumeButtonHandler`: Uses `AVCaptureEventInteraction` (iOS 17.2+) to trigger `viewModel.start/stopRecording()` on volume button presses (began phase), includes debouncing.
*   **LUT (Look-Up Table) Support**: 
    *   `.cube` file parsing via `CubeLUTLoader` (text-based, handles comments, size, data, clamps values).
    *   `LUTManager` stores loaded LUT data as both:
        *   `currentLUTTexture`: A 3D `MTLTexture` (`rgba32Float`) for Metal pipeline.
        *   `currentLUTFilter`: A `CIColorCube` filter for potential (though likely secondary) Core Image usage.
    *   Preview Application: `MetalPreviewView` reads `currentLUTTexture` and applies it in `fragmentShaderYUV` or `fragmentShaderRGB`.
    *   Bake-in Application: `RecordingService` passes `currentLUTTexture` to `MetalFrameProcessor`, which uses it in `applyLUTComputeRGB`/`applyLUTComputeYUV` kernels.
*   **Watch App Remote Control**: 
    *   Uses `WatchConnectivity` framework.
    *   iPhone (`CameraViewModel`): Sends state (`isRecording`, `isAppActive`, `selectedFrameRate`, `recordingStartTime`) via `WCSession.updateApplicationContext(_:)`. Receives commands (`startRecording`, `stopRecording`) via `session(_:didReceiveMessage:replyHandler:)`.
    *   Watch (`WatchConnectivityService`): Receives context via `session(_:didReceiveApplicationContext:)` and publishes `latestContext`. Sends commands via `WCSession.sendMessage(_:replyHandler:errorHandler:)`.
    *   Watch `ContentView` observes `latestContext` and uses a `Timer` to calculate/display elapsed time from `recordingStartTime`.
*   **Video Library**: 
    *   Uses `Photos` framework (`PHPhotoLibrary`, `PHAsset`, `PHImageManager`).
    *   `VideoLibraryViewModel` fetches assets matching `mediaType = .video`, sorted by `creationDate`.
    *   Uses `PHPhotoLibrary.requestAuthorization` for permissions.
    *   Uses `PHPhotoLibraryChangeObserver` to refresh on library changes.
    *   Uses `PHImageManager` to request thumbnails (`requestImage`) and `AVAsset`s for playback (`requestAVAsset`).
*   **Orientation Handling**:
    *   UI Rotation: `DeviceOrientationViewModel` detects physical device rotation; `RotatingView` applies rotation transform to specific UI elements (e.g., icons).
    *   View Orientation Lock: `OrientationFixView` (via `AppDelegate`) restricts screen orientation, locking `CameraView` to portrait but allowing landscape for `VideoLibraryView`.
    *   Preview Orientation: `MetalPreviewView` renders frames based on buffer data; visual orientation is fixed portrait.
    *   Recording Orientation: `RecordingService` calculates the correct rotation angle (`videoRotationAngleValue` from `UIDeviceOrientation` or `UIInterfaceOrientation`) and applies it as a `CGAffineTransform` to the `AVAssetWriterInput`'s `transform` property to ensure correct video file metadata.
    *   Centralized Logic: `CameraViewModel` and `CameraView` are passive regarding orientation; `DeviceOrientationViewModel` provides physical orientation, `AppDelegate`/`OrientationFixView` control interface lock, `RotatingView` rotates specific UI, and `RecordingService` handles video metadata.
*   **Real-time Preview**: 
    *   Uses `MetalKit` (`MTKView`) and `MetalPreviewView` delegate.
    *   Rendering Path: `AVCaptureVideoDataOutput` -> `CameraPreviewView.Coordinator` (unused) -> `MetalPreviewView.updateTexture` -> `MetalPreviewView.draw` -> Metal Shaders (`PreviewShaders.metal`, using `vertexShaderWithRotation`) -> `MTKView` Drawable.
    *   Pixel Format Handling: `MetalPreviewView` creates textures for `kCVPixelFormatType_32BGRA`, `'x422'` (Apple Log), and `'420v'` (BT.709 video range).
    *   Metal Buffer Creation: Uses `device.makeBuffer()` to create buffers for shader uniforms (e.g., LUT active flag, BT.709 flag, rotation angle). Buffer content updated via `memcpy`.
    *   Preview Rotation: `MetalPreviewView` includes rotation logic via its `updateRotation` method and `rotationBuffer` uniform. However, `CameraPreviewView` calls `updateRotation(angle: 90)` during initialization, effectively fixing the preview rendering to portrait.
    *   Visual adjustments (`.scaleEffect(0.9)`, padding) are applied to the `CameraPreviewView` within `CameraView.swift` for positioning.
    *   Triple buffering managed via `DispatchSemaphore` in `MetalPreviewView`.
*   **Recording Light**: 
    *   `FlashlightManager` uses `AVCaptureDevice.setTorchModeOn(level:)`.
    *   Intensity controlled via the `level` parameter (clamped 0.001-1.0).
    *   Startup sequence implemented with `Task.sleep` for timing.
*   **Settings**: 
    *   `SettingsModel` uses `UserDefaults` for persistence and `NotificationCenter` for change broadcasting.
    *   Persists all critical camera settings including:
        *   Resolution, Codec, and Frame Rate formats
        *   Color Space (Apple Log toggle)
        *   LUT bake-in state 
        *   Video Stabilization state
        *   Debug overlay visibility
        *   Flashlight settings
        *   Exposure lock during recording setting
    *   Uses `@Published` properties with `didSet` observers to write to `UserDefaults` when values change.
    *   Provides computed properties for enum-based settings to simplify type conversion between raw strings and enum values.
    *   Initializes from `UserDefaults` with appropriate defaults if no stored values exist.
    *   `CameraViewModel` reads initial values from `SettingsModel` during initialization and applies them to the camera configuration.
    *   UI in `SettingsView` binds directly to `SettingsModel` properties, with `.onChange` handlers to update the active camera configuration.
*   **Camera Configuration**: `CameraViewModel` orchestrates service interactions. `CameraSetupService` configures the initial session. `CameraDeviceService` handles lens changes. `VideoFormatService` handles format/frame rate/color space. `ExposureService` handles exposure/WB/tint. `CameraViewModel`'s `setupUnifiedVideoOutput` configures the `AVCaptureVideoDataOutput` connection, including setting `preferredVideoStabilizationMode` (prioritizing `.standard` over `.auto`) based on `SettingsModel`.
*   **DockKit Integration** (iOS 18.0+):
    *   Uses Apple's DockKit framework for accessory control and tracking.
    *   `DockControlService` (actor) manages all DockKit interactions:
        *   Handles accessory state changes and tracking.
        *   Manages battery and tracking state subscriptions.
        *   Processes accessory events (buttons, zoom, shutter, camera flip).
        *   Supports manual control (pan/tilt) and system tracking modes.
    *   Feature Support:
        *   Subject Tracking: System and manual tracking modes.
        *   Framing Modes: Auto, center, left, right positioning.
        *   Region of Interest: Custom tracking regions.
        *   Motion Control: Manual pan/tilt via chevrons.
        *   Animations: Yes, no, wakeup, kapow gestures.
    *   Camera Integration:
        *   `CameraCaptureDelegate` protocol bridges DockKit and camera controls.
        *   Supports zoom, lens switching, recording control.
        *   Coordinate space conversion for tracking overlay.
    *   State Management:
        *   Published properties for accessory status and battery state.
        *   Tracked person detection and position updates.
        *   Battery level monitoring and charging state.
    *   Error Handling:
        *   Graceful degradation when accessory disconnects.
        *   Proper cleanup of subscriptions and tasks.
        *   Logging via unified logging system.
*   **Focus Control Implementation**:
    *   Focus Point Management:
        *   Uses `AVCaptureDevice.focusPointOfInterest` for point targeting
        *   Coordinates normalized to device space (0,1 x 0,1)
        *   Handles 90-degree rotation transform for portrait orientation
    *   Focus Lock Implementation:
        *   Long press gesture recognition via `UILongPressGestureRecognizer`
        *   Two-phase locking process:
            1. Sets `.autoFocus` mode to acquire focus at point
            2. Waits 300ms for focus acquisition
            3. Transitions to `.locked` mode to maintain focus
        *   Maintains lock state across lens switches
    *   UI Components:
        *   `FocusSquare` SwiftUI view with lock state
        *   Uses SF Symbols "lock.fill" for lock indicator
        *   Persistent display when locked
        *   Auto-hiding behavior when unlocked
    *   Coordinate Space Handling:
        *   Transforms between UI and device coordinate spaces
        *   Accounts for device orientation and preview scaling
        *   Maintains accuracy across all device orientations

## Technical Requirements & Dependencies

*   **AVFoundation**: Capture, Session, Device Control, Recording, Playback.
*   **SwiftUI**: UI, State Management (@State, @StateObject, @ObservedObject, @EnvironmentObject), View Lifecycle.
*   **Combine**: Reactive state updates (@Published, ObservableObject, .sink).
*   **MetalKit / Metal**: Preview Rendering (`MTKView`, `MTLRenderCommandEncoder`), Compute Shaders (`MTLComputeCommandEncoder`) for LUT bake-in, Texture Management (`MTLTexture`, `CVMetalTextureCache`).
*   **CoreImage**: Potentially used by `LUTProcessor` (`CIFilter`, `CIColorCube`, `CIContext`). Shared `CIContext` provided.
*   **Photos**: Video Library access (`PHPhotoLibrary`, `PHAsset`, `PHImageManager`, `PHPhotoLibraryChangeObserver`).
*   **CoreData**: Persistence framework (currently unused beyond template).
*   **WatchConnectivity**: iPhone-Watch communication (`WCSession`, `WCSessionDelegate`).
*   **UniformTypeIdentifiers**: Defining supported document types (`.cube`).
*   **os.log**: Basic logging framework used throughout.
*   **DockKit**: Accessory control, tracking, and camera integration (iOS 18.0+).

## Hardware Features Used

*   Back Camera(s) (requires `.builtInWideAngleCamera`, uses `.builtInUltraWideCamera`, `.builtInTelephotoCamera` if available).
*   Microphone(s) (via `AVCaptureDevice.default(for: .audio)`).
*   Torch (Flashlight) (via `AVCaptureDevice.hasTorch`, `.setTorchModeOn`).
*   Metal-capable GPU.
*   Volume Buttons (via `AVCaptureEventInteraction`, iOS 17.2+).
*   DockKit-compatible accessories (iOS 18.0+).

## Key Technical Decisions & Trade-offs

### Additional Components (2025-04-30)
- **RotatingViewController**: UIViewController subclass for applying rotation transforms to SwiftUI content.
- **OrientationFixViewController**: Locks interface orientation for embedded SwiftUI views.
- **DeviceRotationViewModifier**: SwiftUI modifier for device-based UI rotation.
- **DockAccessoryTrackedPerson**: Data model for tracked subjects in DockKit.
- **EnabledDockKitFeatures**: Struct for feature flags/configuration in DockKit.
- **VideoOutputDelegate**: Handles video sample buffer output for camera preview/recording.
- **LensSelectionView**: SwiftUI view for camera lens selection.
- **Coordinator Classes**: Used for bridging UIKit/AppKit delegates to SwiftUI.

*   **Initial Exposure Mode**: Ensuring the device reliably starts in `.continuousAutoExposure` mode required setting it at multiple points in the initialization lifecycle (before session start, after session start with verification) due to potential AVFoundation state resets during session startup. `CameraSetupService` handles the initial attempts, and `ExposureService` confirms after the device is set.
*   **Shutter Priority Implementation**: Using KVO on `exposureTargetOffset` allows for reactive ISO adjustments based on the camera's own metering, rather than manual calculations. Requires careful tuning of thresholds and rate limits. The temporary lock during recording (`isTemporarilyLockedForRecording`) ensures predictable behavior when combined with the lock-on-record feature.
*   **Exposure Lock Decoupling**: Separating the UI state (`CameraViewModel.isExposureLocked`) from the internal Shutter Priority recording lock logic (`ExposureService.isTemporarilyLockedForRecording`) was crucial to prevent conflicts and ensure the correct lock (standard AE or SP custom) is applied and maintained during recording, coordinated by `CameraViewModel`.
*   **Metal vs. Core Image for LUTs**: Chose Metal for primary preview/bake-in path likely for performance benefits and finer control over rendering pipeline compared to `CIFilter`, especially for compute tasks. Core Image (`LUTProcessor`) might be a legacy or fallback path.
*   **Fixed Portrait UI**: Simplifies `CameraView` layout. Orientation complexity is managed by dedicated components (`DeviceOrientationViewModel`, `RotatingView`, `OrientationFixView`, `RecordingService`) rather than within `CameraView`/`CameraViewModel`.
    *   Update: Centralized orientation logic significantly reduced complexity compared to previous approaches.
*   **Service Layer**: Encapsulates framework interactions, improving testability and separation of concerns within `CameraViewModel`. Increases number of classes/protocols.
*   **Delegate Protocols vs. Combine**: Primarily uses delegate protocols for service-to-ViewModel communication. Could potentially use Combine publishers for certain events.
*   **Synchronous Metal Bake-in**: `MetalFrameProcessor.processPixelBuffer` waits synchronously (`commandBuffer.waitUntilCompleted()`) for the compute kernel. This simplifies integration into the recording pipeline but could potentially block the processing queue if kernels are slow.
*   **Separate Processing Queue**: `RecordingService` uses a dedicated serial `DispatchQueue` (`com.camera.recording`) for sample buffer delegate methods, potentially preventing UI stalls but requiring careful synchronization if accessing shared state.
*   **DockKit Integration**: Implemented as a separate actor service with conditional compilation (`canImport(DockKit)`) to maintain compatibility with simulators and older iOS versions. Uses delegate pattern for camera control to keep core camera logic independent of DockKit availability.

*(This specification includes deeper implementation details.)*
