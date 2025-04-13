# Technical Specification: Spencer's Camera

## 1. Introduction

This document outlines the technical specifications and implementation details of the Spencer's Camera iOS application. The application aims to provide a high-degree of manual control over camera settings, real-time Look-Up Table (LUT) application using Metal, and integration with a companion WatchOS app.

## 2. Target Platform

-   **Operating System:** iOS 18.0 and later.
-   **Architecture:** arm64
-   **Companion:** WatchOS (Specific version assumed compatible based on Watch Connectivity usage, details in `SC Watch App/` target not analyzed).

## 3. Architecture

-   **Pattern:** Model-View-ViewModel (MVVM)
-   **UI Framework:** SwiftUI (Primary), UIKit for specific components (`UIViewControllerRepresentable`, `UIViewRepresentable` wrappers like `MTKView`, `AVCaptureVideoPreviewLayer`, `UIDocumentPickerViewController`).
-   **Modularity:** Code is organized into `Core` and `Features` directories.
    -   `Core`: Contains foundational services (Metal, Orientation) and extensions.
    -   `Features`: Contains distinct functional modules (Camera, Settings, LUT, VideoLibrary).
    -   **Service Layer:** Functionality within features (especially Camera) is further broken down into dedicated service classes (e.g., `CameraSetupService`, `RecordingService`, `VideoFormatService`, `ExposureService`, `CameraDeviceService`) managed by the primary `CameraViewModel`.

## 4. Core Technologies

-   **Camera:** AVFoundation (AVCaptureSession, AVCaptureDevice, AVCaptureInput, AVCaptureOutput, AVAssetWriter).
-   **Graphics & Processing:**
    -   Metal: For real-time camera preview rendering (`MTKView`, `MetalPreviewView`, custom vertex/fragment shaders) and compute-based frame processing (`MetalFrameProcessor`, compute shaders for LUT bake-in).
    -   CoreVideo: `CVPixelBuffer`, `CVMetalTextureCache`.
    -   CoreImage: `CIImage`, `CIContext`, `CIColorCube` (Used for LUT filter creation, potentially legacy processing path).
    -   VideoToolbox: Hardware-accelerated HEVC encoding (`VTCompressionSession` hinted at, specific properties set in `AVAssetWriter` settings).
-   **UI:** SwiftUI, UIKit (interop).
-   **Concurrency:** `async`/`await`, Combine (`ObservableObject`, `@Published`), Grand Central Dispatch (GCD) for background tasks (session start/stop, video fetching, sample buffer queues).
-   **Persistence:** `UserDefaults` (for `SettingsModel`, `LUTManager` recents), Core Data (setup exists, usage unclear).
-   **Connectivity:** Watch Connectivity (`WCSession`, `WCSessionDelegate`).
-   **Media Library:** Photos framework (`PHPhotoLibrary`, `PHAsset`, `PHImageManager`).
-   **File Management:** `FileManager`, `UIDocumentPickerViewController`, `UTType`.

## 5. Key Feature Implementation Details

### 5.1. Camera Control

-   **Exposure:** Manual control via ISO and Shutter Speed/Angle. Auto exposure mode (`continuousAutoExposure`) toggle.
    -   Implementation: `ExposureService` interacts with `AVCaptureDevice.setExposureModeCustom`.
-   **White Balance:** Manual control via Temperature and Tint sliders.
    -   Implementation: `ExposureService` calculates `AVCaptureDevice.WhiteBalanceGains` and uses `AVCaptureDevice.setWhiteBalanceModeLocked`.
-   **Focus:** Appears to use `continuousAutoFocus` by default (set in `CameraDeviceService`). No explicit manual focus UI observed.
-   **Lens Switching:** Supports Ultra Wide, Wide, Telephoto, and 2x (digital zoom on Wide). Uses `AVCaptureDevice.DiscoverySession`.
    -   Implementation: `CameraDeviceService` handles finding devices and session reconfiguration. `ZoomSliderView` triggers automatic switching based on zoom factor.
-   **Zoom:** Smooth digital zoom via slider (`ramp(toVideoZoomFactor:withRate:)`) within a lens's range, instant digital zoom (`videoZoomFactor`) for lens simulation (2x), and physical lens switching.
    -   Implementation: `CameraDeviceService`, `ZoomSliderView`.

### 5.2. Video Recording

-   **Engine:** `AVAssetWriter` with separate video and audio `AVAssetWriterInput`s.
-   **Formats:** Configurable Resolution (e.g., 4K, 1080p) and Frame Rate (e.g., 24, 25, 30, 23.976, 29.97).
    -   Implementation: `VideoFormatService` finds appropriate `AVCaptureDevice.Format` and sets `activeFormat`, `activeVideoMin/MaxFrameDuration`.
-   **Codecs:** HEVC (H.265) and Apple ProRes 422 HQ.
    -   Implementation: `RecordingService` configures `AVAssetWriterInput` settings (`AVVideoCodecKey`, `AVVideoCompressionPropertiesKey`) based on selection.
    -   HEVC uses hardware encoding (`com.apple.videotoolbox.videoencoder.hevc.422v2`, `HEVC_Main42210_AutoLevel` profile). Configurable bitrate.
-   **Apple Log:** Supports enabling/disabling Apple Log recording.
    -   Implementation: `CameraViewModel` toggles state, triggering `VideoFormatService` (`configureAppleLog`/`resetAppleLog`) to find appropriate format and set `activeColorSpace = .appleLog`/`.sRGB`, `isVideoHDREnabled`. Session is reconfigured by `CameraDeviceService`.
-   **Orientation:** Recording orientation is determined based on `UIDevice.orientation` (if valid) or fallback to `UIInterfaceOrientation`. Angle is applied via `CGAffineTransform` to the `AVAssetWriterInput`.
    -   Implementation: `RecordingService` determines angle and sets `assetWriterInput.transform`.
-   **LUT Bake-in:** Option to apply the selected LUT permanently during recording.
    -   Implementation: `RecordingService` delegate method checks flag, calls `metalFrameProcessor.processPixelBuffer` on each frame, and appends the *processed* buffer to the `AVAssetWriterInputPixelBufferAdaptor`.
-   **File Saving:** Recorded `.mov` files are saved to the `PHPhotoLibrary`.
    -   Implementation: `RecordingService.saveToPhotoLibrary` using `PHPhotoLibrary.shared().performChanges`.

### 5.3. LUT Processing

-   **Preview:** Real-time LUT preview applied via Metal fragment shader.
    -   Implementation: `MetalPreviewView` binds the `MTLTexture` from `LUTManager` to `fragmentShaderRGB` or `fragmentShaderYUV`. Shader samples the LUT.
-   **Bake-in (Recording):** LUT applied via Metal compute shader.
    -   Implementation: `RecordingService` uses `MetalFrameProcessor` which dispatches `applyLUTComputeRGB` or `applyLUTComputeYUV` kernel.
-   **Loading:** Supports `.cube` files (text-based). Includes robust parsing with encoding fallbacks, validation, padding/clamping.
    -   Implementation: `CubeLUTLoader`.
-   **Management:** `LUTManager` handles importing (via `DocumentPicker`), loading from bundle/URL, managing recent LUTs (via `UserDefaults`), creating `MTLTexture` and `CIFilter` representations, and clearing the current LUT.
    -   Imported LUTs are copied to the app's Documents directory.

### 5.4. Orientation Handling

-   **UI Elements:** Uses `DeviceOrientationViewModel` and `RotatingView` to rotate specific UI elements (e.g., settings button label) to remain upright relative to the user.
-   **Preview Layer/Stream:** The preview layer (`MTKView` via `MetalPreviewView`) and the video data streams (`AVCaptureVideoDataOutput` connections in `CameraPreviewView`, `RecordingService`, `CameraDeviceService`) appear to be consistently configured to a fixed 90-degree rotation (Portrait), regardless of device orientation. This simplifies downstream processing.
-   **Orientation Locking:** `AppDelegate` implements `application(_:supportedInterfaceOrientationsFor:)` to dynamically restrict orientations based on `AppDelegate.isVideoLibraryPresented` flag and view controller checks. `OrientationFixView` provides explicit control for specific views (e.g., Video Library).

### 5.5. Watch Connectivity

-   **Framework:** `WatchConnectivity.framework` (`WCSession`).
-   **Functionality:**
    -   Syncs state (`isRecording`, `isAppActive`, `recordingStartTime`, `selectedFrameRate`) from iPhone to Watch via `updateApplicationContext`.
    -   Receives commands ("startRecording", "stopRecording") from Watch via `session(_:didReceiveMessage:replyHandler:)` and triggers corresponding `CameraViewModel` actions.
    -   Sends a "launchApp" message to the Watch.
-   **Implementation:** `CameraViewModel` acts as `WCSessionDelegate`.

### 5.6. Video Library Access

-   **Framework:** `Photos.framework`.
-   **Functionality:** Browses videos, displays thumbnails, plays selected videos.
    -   Implementation: `VideoLibraryViewModel` fetches `PHAsset`s, `VideoLibraryView` displays them in a grid using `VideoThumbnailView`, `VideoPlayerView` uses `AVPlayer` to play the selected asset.

### 5.7. Persistence

-   **Mechanism:** Primarily `UserDefaults`.
-   **Data:** App settings (`SettingsModel`), Recent LUTs (`LUTManager`).
-   **Core Data:** Setup exists (`Persistence.swift`, `.xcdatamodeld`), but no active usage observed in the analyzed code.

## 6. UI/UX

-   **Framework:** SwiftUI.
-   **Layout:** Uses `ZStack` for layering camera controls over the preview. `GeometryReader` used for positioning. Custom controls for zoom slider, lens selection, record button.
-   **Navigation:** SwiftUI `NavigationStack`, `.sheet`, `.fullScreenCover` used for Settings and Video Library.
-   **Dark Mode:** Appears to force dark mode (`preferredColorScheme(.dark)`).
-   **Status Bar:** Hidden (`.hideStatusBar()`, `UIViewControllerBasedStatusBarAppearance=false`).

## 7. Concurrency

-   **Main Actor:** UI updates and `ViewModel` interactions primarily occur on `@MainActor`.
-   **Background Threads:** GCD queues used for sample buffer handling (`RecordingService`, `CameraPreviewView`), session start/stop (`CameraSetupService`), video fetching (`VideoLibraryViewModel`).
-   **Async/Await:** Used extensively for asynchronous operations like starting/stopping recording, configuring Apple Log, requesting photo library access, saving videos, handling volume button presses.
-   **Combine:** Used for `ObservableObject` and `@Published` properties for reactive UI updates.

## 8. External Dependencies

-   No third-party libraries identified beyond standard Apple frameworks.

## 9. Build & Configuration

-   Requires Xcode project `Spencer's Camera.xcodeproj`.
-   Targets `Spencer's Camera` (iOS) and `SC Watch App` (WatchOS).
-   Requires code signing identity.
-   Info.plist enables File Sharing, disables VC-based status bar appearance. 