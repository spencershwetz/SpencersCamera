# Technical Specification

> **Note:** Push-to-focus (tap to set focus point) is supported. Exposure value (EV) compensation is now fully implemented with a live, continuous wheel picker. Push-to-exposure (tap to set exposure point) is not implemented in this version.

This document outlines the technical specifications and requirements for the Spencer's Camera application.

## Platform & Target

*   **Target Platform**: iOS & watchOS
*   **Minimum iOS Version**: 18.0
*   **Feature-Specific iOS Requirements**:
    *   iOS 17.2+: Volume button recording control (AVCaptureEventInteraction)
    *   iOS 18.0+: DockKit accessory support
    *   iOS 16.0+: Certain UI features (availability checks in code)
*   **Minimum watchOS Version**: 11.0 (Implied for iOS 18 compatibility)
*   **Target Devices**: 
    *   iOS: iPhone models with Metal support and necessary camera hardware (Wide required, Ultra-Wide/Telephoto optional).
    *   watchOS: Apple Watch models compatible with watchOS 11+.
*   **Architecture**: MVVM (primarily), Service Layer for encapsulating framework interactions.
*   **UI Framework**: SwiftUI (primarily), UIKit (`UIViewControllerRepresentable`, `UIViewRepresentable`, `AppDelegate`) for bridging AVFoundation, MetalKit, and specific view controllers/app lifecycle.
*   **EV Compensation Control**:
    - SimpleWheelPicker component for precise, live EV bias control
    - Horizontal wheel interface with haptic feedback
    - Gesture-based interaction with smooth scrolling
    - Maintains exact position when gesture ends
    - Always initializes centered at 0 EV
    - **Real-time updates with performance optimization:**
        - Updates EV bias in real-time as the user drags (not just on gesture end)
        - Implements intelligent throttling (100ms intervals) to prevent GPU overload
        - Uses threshold-based update detection to reduce unnecessary API calls
        - Manages timers and pending updates to ensure latest value is always applied
        - Balances responsiveness with system stability to prevent GPU timeouts
    - Show/hide with vertical swipe gestures on camera preview
    - **Tap-to-zero:** When the Zero button is tapped, the wheel visually and logically resets to 0 EV, ensuring the UI and value are always in sync.
*   **Lifecycle Management**: App lifecycle events (`didBecomeActive`, `willResignActive`) are handled: 
    *   `willResignActive` triggers `stopSession` via `.onReceive` in `CameraView`.
    *   `didBecomeActive` is managed by `AppLifecycleObserver` (used as `@StateObject` in `CameraView`), which publishes an event triggering `startSession` in `CameraView` to ensure the session restarts correctly after backgrounding.
    *   **Session Interruption Handling**:
        *   Uses `AVCaptureSessionWasInterrupted` and `AVCaptureSessionInterruptionEnded` notifications
        *   Differentiates between background transitions (`.videoDeviceNotAvailableInBackground`) and other interruptions
        *   Manages error state via new `.sessionInterrupted` error type
        *   Coordinates with `AppLifecycleObserver` to avoid duplicate session restarts
        *   Removes `ExposureService` observers immediately on interruption to prevent KVO issues
        *   Restores observers and clears errors when interruption ends
*   **Camera Control**: 
    *   Uses `AVCaptureSession` managed primarily within `CameraViewModel` and configured by `CameraSetupService`.
    *   Session start/stop is handled by `startSession`/`stopSession` in `CameraViewModel`, triggered by `CameraView`'s `onAppear`/`onDisappear` and the `AppLifecycleObserver`'s `didBecomeActivePublisher`.
    *   Device discovery and switching handled by `CameraDeviceService` using `AVCaptureDevice.DiscoverySession`.
    *   Lens switching logic in `CameraDeviceService` handles physical switching (reconfiguring session) and digital zoom (setting `videoZoomFactor` on wide lens for 2x).
    *   **Format Selection**: `VideoFormatService` finds the best `AVCaptureDevice.Format` based on resolution, frame rate, and Apple Log requirements using `findBestFormat()`. To enable Apple Log, `configureAppleLog()` finds a suitable format supporting `.appleLog` and sets it as the `device.activeFormat`; it does *not* set `activeColorSpace` directly. `resetAppleLog()` finds a suitable non-Log format and sets it. Frame rate changes are handled by `updateFrameRateForCurrentFormat()`, which locks the device and sets `activeVideoMin/MaxFrameDuration`.
    *   **Manual Exposure/WB/Tint controls**: Managed by `ExposureService` using a state machine pattern (`ExposureStateMachine`). All exposure mode transitions go through the state machine which validates transitions and maintains thread safety. The service uses KVO to observe `iso`, `exposureDuration`, `deviceWhiteBalanceGains`, and `exposureTargetOffset` for real-time delegate updates.
    *   **Shutter Priority**: Implemented in `ExposureService`. When enabled via `CameraViewModel`:
        *   **Shutter Priority Mode:** When enabled, the app sets a fixed shutter duration (typically 180°) and allows ISO to float. The user can toggle this mode, and the app ensures that the correct duration is set based on the selected frame rate. 
        *   **Robust Shutter Priority Logic (2025-04-28):** After every lens switch, the 180° shutter duration is recalculated based on the *current* frame rate and immediately applied. A helper computes the duration as `1.0 / (2 * frameRate)`. This prevents incorrect shutter angles (e.g., 144°, 216°) after lens switches and guarantees consistent 180° exposure regardless of previous state or lens.
        *   During recording, if "Lock Exposure During Recording" is also enabled, the app temporarily locks exposure using the current ISO and duration, then restores shutter priority after lens switches or format changes, using the recalculated duration., subject to rate limits and thresholds (`handleExposureTargetOffsetUpdate`).
        *   **New (2025-05-02):** Shutter Priority re-application after lens switches is now debounced and atomic, with device readiness checks and ISO caching to prevent exposure jumps and race conditions. All KVO and device property changes for exposure are now performed on a serial queue for thread safety.
    *   **Lens Switch Exposure Lock Handling**: When both "Lock Exposure During Recording" and "Shutter Priority" are enabled, `CameraViewModel` restores the exposure lock after a lens change by re-enabling shutter priority and, after a short delay, re-locking ISO. This prevents ISO drift and ensures consistent exposure during recording across lens switches.
    *   **Exposure State Machine (2025-05)**: 
        *   All exposure control flows through `ExposureStateMachine` which manages states: `auto`, `manual(iso, duration)`, `shutterPriority(targetDuration, manualISO)`, `locked(iso, duration)`, `recordingLocked(previousState)`
        *   State transitions triggered by events: `enableAuto`, `enableManual`, `enableShutterPriority`, `overrideISOInShutterPriority`, `clearManualISOOverride`, `lock`, `unlock`, `startRecording`, `stopRecording`
        *   Thread-safe with dedicated queue, validates all transitions
        *   Recording lock preserves any exposure state and restores it after recording
    *   **Exposure Lock**: Standard AE lock (`.locked` mode) is managed by `ExposureService` via `setExposureLock`. Recording lock uses the state machine's `recordingLocked` state. `CameraViewModel` handles the UI state (`isExposureLocked`) and ensures standard AE lock cannot be toggled while Shutter Priority is active.
*   **Video Recording**: 
    *   Handled by `RecordingService` using `AVAssetWriter`.
    *   Video Input (`AVAssetWriterInput`): Configured with dimensions from active format, codec type (`.hevc` or `.proRes422HQ`), and compression properties (bitrate, keyframe interval, profile level, color primaries based on `isAppleLogEnabled`).
    *   Audio Input (`AVAssetWriterInput`): Configured for Linear PCM (48kHz, 16-bit stereo) when microphone is available. Audio recording is conditional based on microphone permissions:
        *   `CameraSetupService` checks `AVCaptureDevice.authorizationStatus(for: .audio)` on startup
        *   If permission is `.notDetermined`, requests access via `AVCaptureDevice.requestAccess(for: .audio)`
        *   If permission is `.denied` or `.restricted`, or if audio device is unavailable, recording proceeds as video-only
        *   `CameraViewModel` tracks audio availability via `isAudioAvailable` and `audioPermissionStatus` properties
        *   UI displays "NO AUDIO" indicator when recording without audio
    *   Orientation: `CGAffineTransform` is applied to the video input based on device/interface orientation at the start of recording to ensure correct playback rotation.
    *   Pixel Processing: Video frames (`CMSampleBuffer`) are received via delegate (`AVCaptureVideoDataOutputSampleBufferDelegate`). If LUT bake-in is enabled (`SettingsModel.isBakeInLUTEnabled`), the `CVPixelBuffer` is passed to `MetalFrameProcessor.processPixelBuffer` before being appended to the `AVAssetWriterInputPixelBufferAdaptor`. (Note: Default bake-in state is off).
    *   Saving: Finished `.mov` file saved to `PHPhotoLibrary` using `PHPhotoLibrary.shared().performChanges`.
    *   GPS Tagging: `LocationService` provides location data during recording. Location metadata is embedded in the video file when available.
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
    *   Watch (`WatchConnectivityService`): Now injected as an `.environmentObject` at the root of the watch app (`SCApp.swift`). All views access it via `@EnvironmentObject`, ensuring a single instance and robust SwiftUI redraw behavior. The singleton pattern is not used in SwiftUI views, preventing cross-view redraws.
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
*   **Function Buttons**:
    *   Two configurable function buttons in the UI
    *   Abilities defined by `FunctionButtonAbility` enum: None, Lock Exposure, Shutter Priority
    *   Settings persisted in `UserDefaults` via `SettingsModel`
    *   `FunctionButtonsView` handles button display and action dispatch
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
*   **Adjustment Controls (Lens/Shutter/ISO/WB)**:
    *   Base row with four buttons replaces legacy lens buttons.
    *   Each button reveals a horizontal menu:
        *   Lens buttons (0.5×, 1×, 2×, 5×).
        *   Shutter options (Auto, 180°) toggling shutter priority.
        *   ISO wheel (`SimpleWheelPicker`) with auto toggle for exposure control.
        *   Kelvin wheel (`SimpleWheelPicker`) with auto white-balance toggle (2500–10000 K).
    *   All wheels feature identical design with consistent tick spacing and visual styling.
    *   Wheels inherit EV bias picker behavior: view-aligned, haptic feedback, bounce-free scrolling.
    *   Implements throttled camera updates to prevent GPU overload during wheel scrolling.
    *   Newly added `ExposureService.setAutoWhiteBalanceEnabled` supports WB automation.

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

### Enhanced Exposure Handling (2025-05-06)
- **Thread Safety and State Management**:
    - Dedicated `stateQueue` for thread-safe state access
    - `exposureAdjustmentQueue` for serialized exposure operations
    - `ExposureState` struct for atomic state capture and restoration
- **Error Handling**:
    - Typed `ExposureServiceError` with user-friendly messages
    - Automatic recovery mechanisms for failed operations
    - Graceful degradation during device unavailability
- **Exposure Transitions**:
    - Multi-step ISO interpolation for smooth transitions
    - Configurable step count and timing
    - Automatic cleanup of incomplete transitions
- **Stability Monitoring**:
    - Real-time ISO variance monitoring
    - Configurable thresholds for variance detection
    - Automatic logging of stability issues
- **Lens Switch Handling**:
    - Complete state preservation during lens switches
    - Automatic state restoration after switch completion
    - Error recovery for failed state restoration

### Exposure Error Recovery System (2025-05-24)
- **Retry Mechanism**:
    - `ExposureErrorRecovery` actor manages retry logic with exponential backoff
    - Configurable retry count (default: 3) with base delay of 100ms
    - Jittered backoff calculation prevents thundering herd problems
    - Maximum delay capped at 2 seconds
- **Circuit Breaker Pattern**:
    - Prevents cascading failures after 5 consecutive errors
    - 10-second recovery timeout before allowing new operations
    - Half-open state allows testing system recovery
    - Automatic closure on successful operation
- **Operation Queuing**:
    - Queues exposure operations during lens transitions
    - Processes queued operations after transition completes
    - Prevents data loss during state changes
    - Clears queue on device changes to prevent invalid operations
- **Capability Adaptation**:
    - Detects device capability changes during lens switches
    - Automatically clamps ISO/duration values to new device limits
    - Logs capability adaptations for debugging
    - Preserves user intent while respecting hardware constraints
- **Error Classification**:
    - Distinguishes permanent vs transient errors
    - Permanent errors (unauthorized, device unavailable) skip retry
    - Transient errors (configuration failed, lock failed) trigger retry
    - AVFoundation error codes mapped to appropriate actions
- **User Interface Integration**:
    - Enhanced `CameraError` with recovery actions and suggestions
    - Alert dialogs provide actionable recovery options
    - Automatic session restart for recoverable errors
    - Deep links to Settings for permission errors
- **State Machine Integration**:
    - Error events integrated into `ExposureStateMachine`
    - State preserved during error recovery attempts
    - Graceful fallback to auto mode on critical failures
    - Thread-safe error state transitions

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

### Memory Management Optimization (2025-06-01)
- **Metal Resource Management**:
    - Exposed texture cache through controlled interfaces to enable proper flushing
    - Added explicit texture cache cleanup during frame processing
    - Proactively flushes `CVMetalTextureCache` and nils out `MTLTexture`s via `MetalPreviewView.prepareForNewSession()` before session (re)start to prevent GPU timeouts (purple screen issue) when the app returns from background or the session is re-initialized.
    - Implemented reference counting for shared Metal resources
    - Used `autoreleasepool` blocks during high-memory operations
- **Camera Transitions**:
    - Properly release resources during lens changes
    - Temporarily disable LUT processing during lens transitions
    - Implemented staged approach to resource allocation/deallocation
    - Added memory cleanup notification system for cross-component coordination
- **Recording Lifecycle**:
    - Added explicit cleanup after recording stops
    - Properly dispose of temporary buffers and textures
    - Implemented resource caching with lifecycle-aware eviction policies
    - Memory usage reduced by approximately 300MB during normal operations

## Exposure Flicker Minimization During Lens Switch (Shutter Priority)

- Shutter Priority is now applied immediately after a new device is set and the session is running.
- The target ISO and shutter duration for the new lens are pre-calculated and set as soon as possible.
- The exposure UI is frozen during the transition and unfrozen after Shutter Priority is re-applied, minimizing visible flicker.

*(This specification includes deeper implementation details.)*

- CameraViewModel now sets `isAppleLogSupported` in `didInitializeCamera` based on device capabilities, ensuring Apple Log color space is correctly applied at boot if supported and enabled.

## State Management Refactor (2025-05)

- **DeviceOrientationViewModel**: No longer used as a singleton in SwiftUI views. Each view creates its own instance. OrientationCoordinator is used for device orientation updates and is not an observable object.
- **WatchConnectivityService (Watch App)**: Now injected as an .environmentObject at the root of the watch app. All views use @EnvironmentObject, ensuring a single instance and robust SwiftUI redraw behavior.
- **SettingsModel**: Used as a single @StateObject at the app root and injected via .environmentObject (best practice for global settings).
- **CameraViewModel**: Instantiated per screen as a @StateObject and passed down (best practice for screen-specific state).
- **No other ObservableObject singletons are used in SwiftUI views.**
- **Service singletons** (e.g., HapticManager, LocationService) are not observable objects and do not affect SwiftUI redraws.

This approach ensures robust, efficient SwiftUI state management and avoids unnecessary redraws across unrelated views.
