# Technical Specification

This document outlines the technical specifications and requirements for the Spencer's Camera application.

## Platform & Target

*   **Target Platform**: iOS
*   **Minimum iOS Version**: 18.0
*   **Target Devices**: iPhone (with back cameras including Wide, potentially Ultra-Wide and Telephoto)
*   **Watch App Target**: watchOS (version corresponding to iOS 18 compatibility, likely watchOS 11+)
*   **Architecture**: MVVM (primarily)
*   **UI Framework**: SwiftUI (primarily), UIKit (`UIViewControllerRepresentable`, `UIViewRepresentable`) used for bridging AVFoundation, MetalKit, and specific view controllers.

## Core Features

*   **Camera Control**: 
    *   Access to back cameras (Wide, Ultra-Wide, Telephoto where available).
    *   Lens switching (0.5x, 1x, 2x Digital, 5x).
    *   Digital zoom control (smooth slider and discrete lens buttons).
    *   Video recording in various formats.
    *   Manual exposure controls (ISO, Shutter Speed/Angle).
    *   Manual White Balance (Temperature, potentially Tint).
    *   Focus (currently Continuous Auto Focus).
*   **Video Recording Formats**: 
    *   Resolutions: 4K UHD (3840x2160), HD (1920x1080), SD (1280x720).
    *   Frame Rates: 23.976, 24, 25, 29.97, 30 fps.
    *   Codecs: HEVC (H.265), Apple ProRes 422 HQ.
    *   Color Spaces: Rec.709 (SDR), Apple Log (HDR).
*   **LUT (Look-Up Table) Support**: 
    *   Import `.cube` files.
    *   Apply LUT for real-time preview using Metal shaders.
    *   Option to bake the LUT into the recorded video file using Metal compute shaders.
    *   Manage recent LUTs.
*   **Watch App Remote Control**: 
    *   Start/Stop recording on iPhone.
    *   Display recording status (Ready, Recording).
    *   Show elapsed recording time (including fractional seconds for frame count).
    *   Prompt user to open iPhone app if not active/reachable.
*   **Video Library**: 
    *   Browse videos recorded by the app (or all videos) in the Photo Library.
    *   View thumbnails and duration.
    *   Play selected videos using `AVPlayer`.
    *   Handle Photo Library authorization.
*   **Orientation Handling**: 
    *   Main camera interface remains fixed in portrait orientation.
    *   Specific UI elements (buttons) rotate with device orientation.
    *   Video recordings are saved with the correct orientation based on device orientation at the start of recording.
    *   Video Library supports landscape orientation.
*   **Real-time Preview**: 
    *   Uses `MetalKit` (`MTKView`) for efficient preview rendering.
    *   Applies selected LUT in real-time via Metal fragment shaders.
*   **Recording Light**: 
    *   Uses device torch (flashlight) as a visual indicator during recording.
    *   Adjustable intensity.
    *   Startup flashing sequence (3-2-1).

## Technical Requirements & Dependencies

*   **AVFoundation**: Core framework for camera capture, session management, device control, recording (`AVAssetWriter`), and playback (`AVPlayer`).
*   **SwiftUI**: Primary UI framework.
*   **Combine**: Used for reactive programming, particularly in ViewModels and services (`@Published`, `ObservableObject`).
*   **MetalKit / Metal**: Used for high-performance camera preview rendering and compute tasks (LUT application/bake-in).
*   **CoreImage**: Used by `LUTManager` for creating `CIFilter` (`CIColorCube`) instances from LUT data (though primary application is Metal).
*   **Photos**: Used by `VideoLibraryViewModel` to access and fetch video assets from the Photo Library (`PHPhotoLibrary`, `PHAsset`).
*   **CoreData**: Used for persistence (though currently only the template `Persistence.swift` and `Item` entity exist).
*   **WatchConnectivity**: Used for communication between the iPhone and Watch App (`WCSession`).
*   **UniformTypeIdentifiers**: Used by `DocumentPicker` and `LUTManager` to define supported file types.

## Hardware Features Used

*   Back Camera(s) (Wide, Ultra-Wide, Telephoto)
*   Microphone(s)
*   Torch (Flashlight)
*   Metal-capable GPU
*   Volume Buttons (via `AVCaptureEventInteraction`)

## Key Technical Decisions (Observed)

*   **Metal for Preview/LUTs**: Using Metal instead of Core Image or `AVCaptureVideoPreviewLayer` directly allows for efficient real-time LUT application via shaders and compute capabilities for bake-in.
*   **Fixed Portrait UI**: The main camera interface is locked to portrait, with specific elements rotating. This simplifies layout but requires careful management of recording orientation.
*   **Service-Oriented Architecture (within CameraViewModel)**: `CameraViewModel` delegates specific tasks (setup, recording, format, device, exposure) to dedicated service classes, promoting separation of concerns.
*   **Watch Connectivity for Remote**: Standard WatchConnectivity framework is used for basic remote control.
*   **Direct Shader LUT Application**: LUTs are applied directly in Metal shaders for preview and compute kernels for bake-in, bypassing intermediate `CIFilter` application for performance.

*(This specification is based on initial observation and may require updates.)*
