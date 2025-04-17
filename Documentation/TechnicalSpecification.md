# Technical Specification

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

## Core Features & Implementation Details

*   **Camera Control**: 
    *   Uses `AVCaptureSession` managed primarily within `CameraViewModel` and configured by `CameraSetupService`.
    *   Device discovery and switching handled by `CameraDeviceService` using `AVCaptureDevice.DiscoverySession`.
    *   Lens switching logic in `CameraDeviceService` handles physical switching (reconfiguring session) and digital zoom (setting `videoZoomFactor` on wide lens for 2x).
    *   Format selection (Resolution, FPS, Color Space) managed by `VideoFormatService`, finding optimal `AVCaptureDevice.Format` based on requested criteria.
    *   Manual Exposure/WB/Tint controls managed by `ExposureService`, locking device configuration and setting properties like `exposureMode`, `setExposureModeCustom(duration:iso:)`, `setWhiteBalanceModeLocked(with:)`. It uses KVO to observe `iso` and `exposureDuration` for real-time delegate updates. It also provides `getCurrentWhiteBalanceTemperature()` for direct querying. White balance updates for the UI are now handled primarily by a polling mechanism in `CameraViewModel` querying this method, due to potential KVO unreliability.
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
    *   Rendering Path: `AVCaptureVideoDataOutput` -> `CameraPreviewView.Coordinator` -> `MetalPreviewView.updateTexture` -> `MetalPreviewView.draw` -> Metal Shaders (`PreviewShaders.metal`) -> `MTKView` Drawable.
    *   Triple buffering managed via `DispatchSemaphore` in `MetalPreviewView`.
*   **Recording Light**: 
    *   `FlashlightManager` uses `AVCaptureDevice.setTorchModeOn(level:)`.
    *   Intensity controlled via the `level` parameter (clamped 0.001-1.0).
    *   Startup sequence implemented with `Task.sleep` for timing.
*   **Metal vs. Core Image for LUTs**: Chose Metal for primary preview/bake-in path likely for performance benefits and finer control over rendering pipeline compared to `CIFilter`, especially for compute tasks. Core Image (`LUTProcessor`) might be a legacy or fallback path.
*   **White Balance UI Updates**: Implemented a polling mechanism in `CameraViewModel` (using a `Timer` publisher) calling `ExposureService.getCurrentWhiteBalanceTemperature()` to update the UI's white balance display. This was added as a workaround for observed inconsistencies with KVO updates for `deviceWhiteBalanceGains` on newer iOS versions. KVO remains for ISO and Shutter Speed updates.
*   **Fixed Portrait UI**: Simplifies `CameraView` layout. Orientation complexity is managed by dedicated components (`DeviceOrientationViewModel`, `RotatingView`, `OrientationFixView`, `RecordingService`) rather than within `CameraView`/`CameraViewModel`.
    *   Update: Centralized orientation logic significantly reduced complexity compared to previous approaches.
*   **Service Layer**: Encapsulates framework interactions, improving testability and separation of concerns within `CameraViewModel`. Increases number of classes/protocols.
*   **Delegate Protocols vs. Combine**: Primarily uses delegate protocols for service-to-ViewModel communication. Could potentially use Combine publishers for certain events.
*   **Synchronous Metal Bake-in**: `MetalFrameProcessor.processPixelBuffer` waits synchronously (`commandBuffer.waitUntilCompleted()`) for the compute kernel. This simplifies integration into the recording pipeline but could potentially block the processing queue if kernels are slow.
*   **Separate Processing Queue**: `RecordingService` uses a dedicated serial `DispatchQueue` (`com.camera.recording`) for sample buffer delegate methods, potentially preventing UI stalls but requiring careful synchronization if accessing shared state.

*(This specification includes deeper implementation details.)*

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

## Hardware Features Used

*   Back Camera(s) (requires `.builtInWideAngleCamera`, uses `.builtInUltraWideCamera`, `.builtInTelephotoCamera` if available).
*   Microphone(s) (via `AVCaptureDevice.default(for: .audio)`).
*   Torch (Flashlight) (via `AVCaptureDevice.hasTorch`, `.setTorchModeOn`).
*   Metal-capable GPU.
*   Volume Buttons (via `AVCaptureEventInteraction`, iOS 17.2+).

## Key Technical Decisions & Trade-offs

*   **Initial Exposure Mode**: Ensuring the device reliably starts in `.continuousAutoExposure` mode required setting it at multiple points in the initialization lifecycle (before session start, after session start with verification) due to potential AVFoundation state resets during session startup.
*   **Metal vs. Core Image for LUTs**: Chose Metal for primary preview/bake-in path likely for performance benefits and finer control over rendering pipeline compared to `CIFilter`, especially for compute tasks. Core Image (`LUTProcessor`) might be a legacy or fallback path.
*   **White Balance UI Updates**: Implemented a polling mechanism in `CameraViewModel` (using a `Timer` publisher) calling `ExposureService.getCurrentWhiteBalanceTemperature()` to update the UI's white balance display. This was added as a workaround for observed inconsistencies with KVO updates for `deviceWhiteBalanceGains` on newer iOS versions. KVO remains for ISO and Shutter Speed updates.
*   **Fixed Portrait UI**: Simplifies `CameraView` layout. Orientation complexity is managed by dedicated components (`DeviceOrientationViewModel`, `RotatingView`, `OrientationFixView`, `RecordingService`) rather than within `CameraView`/`CameraViewModel`.
    *   Update: Centralized orientation logic significantly reduced complexity compared to previous approaches.
*   **Service Layer**: Encapsulates framework interactions, improving testability and separation of concerns within `CameraViewModel`. Increases number of classes/protocols.
*   **Delegate Protocols vs. Combine**: Primarily uses delegate protocols for service-to-ViewModel communication. Could potentially use Combine publishers for certain events.
*   **Synchronous Metal Bake-in**: `MetalFrameProcessor.processPixelBuffer` waits synchronously (`commandBuffer.waitUntilCompleted()`) for the compute kernel. This simplifies integration into the recording pipeline but could potentially block the processing queue if kernels are slow.
*   **Separate Processing Queue**: `RecordingService` uses a dedicated serial `DispatchQueue` (`com.camera.recording`) for sample buffer delegate methods, potentially preventing UI stalls but requiring careful synchronization if accessing shared state.

*(This specification includes deeper implementation details.)*

### White Balance

*   **Control:** The app allows locking the white balance using `device.setWhiteBalanceModeLocked(with: gains)` and allows continuous auto white balance with `device.whiteBalanceMode = .continuousAutoWhiteBalance`.
*   **Monitoring:** Key-Value Observing (KVO) is used to monitor `device.deviceWhiteBalanceGains` for real-time updates in the UI/debug overlay.
*   **Fallback Mechanism:** If KVO updates for white balance gains are not received consistently (a potential issue observed in some scenarios), a polling mechanism implemented in `ExposureService` periodically fetches the current `deviceWhiteBalanceGains` and updates the `CameraViewModel`. This ensures the UI reflects the current white balance state even if KVO fails. The polling interval is managed within `ExposureService`.
*   **Temperature/Tint Calculation:** The raw RGB gain values are converted to Temperature (Kelvin) and Tint for display using `AVCaptureDevice.WhiteBalanceGains` convenience methods.
