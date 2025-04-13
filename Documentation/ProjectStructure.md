# Project Structure: Spencer's Camera

This document outlines the structure and component organization of the Spencer's Camera iOS application.

## Architecture

The application follows the **Model-View-ViewModel (MVVM)** architecture pattern with SwiftUI.

## Directory Structure

The codebase is organized into the following main directories:

*   **/iPhoneApp:** The root directory for the iOS application code.
    *   **/Features:** Contains modules for distinct application features (e.g., Camera, Settings, VideoLibrary). Each feature typically includes its own Models, Views, and ViewModels.
    *   **/Core:** Contains shared components, services, utilities, and extensions used across multiple features (e.g., Networking, Persistence, Orientation Handling, Core Extensions).
    *   **/UI:** Contains reusable UI components, themes, styles, and design system elements.
    *   **/Resources:** Contains assets like images (`Assets.xcassets`), localization files, and other resources.
    *   **/App:** Contains the main application entry point (`cameraApp.swift`), AppDelegate, and scene configuration.
*   **/SC Watch App:** Contains the code specific to the watchOS companion app.
*   **/Documentation:** Contains project documentation files like this one.

## Key Component Connections (High-Level)

*(This section will be expanded to show how major components interact, e.g., how `CameraViewModel` uses `RecordingService`, `ExposureService`, etc.)*

## File Descriptions

### iPhoneApp/

*   `cameraApp.swift`: Main SwiftUI App entry point.
*   `Info.plist`: Application configuration and permission settings.
*   `Persistence.swift`: Core Data stack setup.
*   `Assets.xcassets/`: Contains all image assets, icons, and colors.
*   `Preview Content/`: Assets specifically for SwiftUI Previews.
*   `camera.xcdatamodeld/`: Core Data entity definitions.
*   **App/**
    *   `AppDelegate.swift`: Handles application lifecycle events and UIKit integration points.
*   **Features/**
    *   **Camera/**
        *   `CameraViewModel.swift`: Central ViewModel for the camera feature, managing state, services, and user interactions.
        *   `FlashlightManager.swift`: Manages the device torch/flashlight functionality.
        *   **Services/**
            *   `CameraDeviceService.swift`: Handles camera device selection (lenses), zoom control, and related session reconfiguration.
            *   `RecordingService.swift`: Manages video recording logic, including `AVAssetWriter` setup, sample buffer handling, and saving.
            *   `VideoFormatService.swift`: Configures video format settings like resolution, frame rate, codec, and Apple Log.
            *   `VideoOutputDelegate.swift`: Delegate object responsible for receiving video sample buffers from the capture session.
            *   `VolumeButtonHandler.swift`: Detects volume button presses for potential capture triggers.
            *   `CameraSetupService.swift`: Responsible for the initial `AVCaptureSession` setup, device inputs, outputs, and permissions.
            *   `ExposureService.swift`: Manages manual and automatic exposure controls (ISO, Shutter Speed, White Balance, Tint).
        *   **Views/**
            *   `TestDynamicIslandOverlayView.swift`: View likely related to Dynamic Island integration or testing.
            *   `CameraView.swift`: Main SwiftUI container view for the camera UI, composing the preview and controls.
            *   `CameraPreviewView.swift`: `UIViewRepresentable` wrapper for the camera preview (likely Metal-based).
            *   `FunctionButtonsView.swift`: SwiftUI view containing the main action buttons (Record, Mode Switch, etc.).
            *   `SettingsView.swift`: SwiftUI view displaying manual camera controls (ISO, WB, Shutter, etc.).
            *   `LensSelectionView.swift`: SwiftUI view for selecting the active camera lens.
            *   `ZoomSliderView.swift`: SwiftUI view providing a slider for controlling digital zoom.
            *   `CameraPreviewImplementation.swift`: Likely the underlying `UIView` implementation for `CameraPreviewView`, handling the `MetalPreviewView` or `AVCaptureVideoPreviewLayer`.
        *   **Utilities/**
            *   `DocumentPicker.swift`: Utility for presenting a document picker (e.g., for importing LUTs).
        *   **Models/**
            *   `CameraError.swift`: Defines custom error types for camera operations.
            *   `CameraLens.swift`: Enum representing different camera lenses (Wide, Ultra Wide, Telephoto).
            *   `ShutterAngle.swift`: Model/utility related to shutter angle representation and calculation.
        *   **Extensions/**
            *   `AVFoundationExtensions.swift`: Utility extensions for AVFoundation framework classes.
    *   **Settings/**
        *   `SettingsModel.swift`: Model managing persistent application settings.
        *   `FlashlightSettingsView.swift`: SwiftUI view for configuring flashlight behavior and intensity.
    *   **LUT/** (Look-Up Table)
        *   `CubeLUTLoader.swift`: Loads and parses `.cube` LUT files.
        *   `LUTManager.swift`: Manages the available LUTs, selection, and application state.
        *   **Views/**
            *   `LUTVideoPreviewView.swift`: View for previewing video with a selected LUT applied.
        *   **Utils/**
            *   `LUTProcessor.swift`: Older Core Image-based LUT application logic (likely replaced by Metal).
    *   **VideoLibrary/**
        *   `VideoLibraryView.swift`: SwiftUI view displaying the grid of saved video recordings.
        *   `VideoLibraryViewModel.swift`: ViewModel managing data and state for the video library.
*   **Core/**
    *   **Orientation/**
        *   `OrientationFixView.swift`: SwiftUI view potentially used to control or lock view orientation.
        *   `DeviceRotationViewModifier.swift`: ViewModifier reacting to device orientation changes.
        *   `DeviceOrientationViewModel.swift`: ObservableObject tracking and publishing device orientation.
        *   `RotatingView.swift`: SwiftUI view wrapper that rotates its content based on device orientation.
    *   **Metal/**
        *   `MetalPreviewView.swift`: Custom `MTKView` subclass for rendering camera frames via Metal.
        *   `MetalFrameProcessor.swift`: Class handling Metal rendering pipeline and shader application (e.g., applying LUTs).
        *   `PreviewShaders.metal`: Metal Shading Language (MSL) code for shaders used in the preview/processing.
    *   **Extensions/**
        *   `UIDeviceOrientation+Extensions.swift`: Utility extensions for `UIDeviceOrientation`.
        *   `CIContext+Shared.swift`: Extension providing a shared `CIContext` for performance.
        *   `View+Extensions.swift`: General utility extensions for SwiftUI `View`.

### SC Watch App/

*   `WatchConnectivityService.swift`: Manages `WCSession` for communication between the watch and phone apps.
*   `Assets.xcassets/`: Watch app specific image assets.
*   `ContentView.swift`: Main SwiftUI view for the watch app interface.
*   `SCApp.swift`: Main SwiftUI App entry point for the watch app. 