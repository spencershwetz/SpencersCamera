# Orientation Handling Strategy

This document outlines how device orientation is managed within the Spencer's Camera application after the simplification refactor (ToDo #2).

The core goals are:
1.  Allow specific views (like the Video Library) to rotate freely to landscape.
2.  Keep the main `CameraView` UI generally locked to portrait for layout stability.
3.  Ensure UI elements that *should* rotate (like icons) follow the physical device orientation.
4.  Embed the correct orientation metadata into recorded video files so they play correctly regardless of how the device was held.

## Key Components & Responsibilities

*   **`AppDelegate.swift`**:
    *   Acts as the **global gatekeeper** for *interface* orientation.
    *   Implements `application(_:supportedInterfaceOrientationsFor:)`.
    *   Determines the top-most view controller.
    *   **Checks several conditions**:
        1.  If the top controller is a `PresentationHostingController` (often used for SwiftUI modals/sheets), it checks if the *child* controller's type name is in a static list (`AppDelegate.landscapeEnabledViewControllers`) to allow landscape.
        2.  If the top controller is an `OrientationFixViewController`, it respects its `allowsLandscapeMode` property.
        3.  If the top controller's type name itself is in the static list (`AppDelegate.landscapeEnabledViewControllers`), it allows landscape.
    *   Defaults to locking the interface to `.portrait` if none of the specific conditions are met or the top controller cannot be determined.

*   **`DeviceOrientationViewModel.swift` (`Core/Orientation`)**:
    *   The **source of truth for physical device orientation**.
    *   Uses `UIDevice.orientationDidChangeNotification` (debounced) to monitor the actual hardware orientation (`UIDeviceOrientation`) and publishes `orientation`.
    *   Uses `CMMotionManager` (device motion updates, specifically gravity) to calculate a rotation angle and publishes `rotationAngleInDegrees`.
    *   Provides a computed `rotationAngle: Angle` derived from the motion-based calculation.

*   **`RotatingView.swift` (`Core/Orientation`)**:
    *   A `UIViewControllerRepresentable` used to **rotate specific SwiftUI content** based on physical orientation.
    *   Observes `DeviceOrientationViewModel.shared.orientation`.
    *   Applies a `CGAffineTransform` rotation to its hosted SwiftUI `Content` view, animating the change.
    *   Used for elements like the Settings button icon in `CameraView`.

*   **`OrientationFixView.swift` (`Core/Orientation`)**:
    *   A `UIViewControllerRepresentable` wrapping `OrientationFixViewController`.
    *   Used to **control the supported *interface* orientations** for a specific SwiftUI view hierarchy it wraps.
    *   Takes an `allowsLandscapeMode: Bool` parameter during initialization.
    *   `OrientationFixViewController` overrides `supportedInterfaceOrientations` based on `allowsLandscapeMode`. If landscape is disallowed, it also attempts to actively enforce portrait mode using `requestGeometryUpdate`. The `AppDelegate` queries the `supportedInterfaceOrientations` override.
    *   This is how `VideoLibraryView` can be allowed to rotate when presented.

*   **`CameraPreviewView.swift` (`Features/Camera/Views`)**: 
    *   Responsible for **rendering the camera preview** using Metal (`MTKView` and `MetalPreviewView` delegate).
    *   While `MetalPreviewView` has rotation capabilities (via `updateRotation`, `rotationBuffer`), `CameraPreviewView` explicitly calls `updateRotation(angle: 90)` during its `makeUIView` setup.
    *   This **fixes the preview rendering rotation to portrait**.
    *   It **does not** observe `DeviceOrientationViewModel` for rotation updates.

*   **`RecordingService.swift` (`Features/Camera/Services`)**:
    *   Responsible for **embedding correct video metadata orientation**.
    *   Before starting recording, it determines the appropriate rotation angle (0, 90, 180, 270 degrees) based on the current device and interface orientation, using the value from `UIDeviceOrientation.videoRotationAngleValue`.
    *   It calculates a `CGAffineTransform` for this rotation.
    *   This transform is applied to the `AVAssetWriterInput` (`transform` property). This ensures the video file itself has the correct orientation flag, regardless of the UI's locked state. (Note: This avoids using the deprecated `videoOrientation` property on `AVCaptureConnection` for file metadata).

*   **`CameraView.swift` / `CameraViewModel.swift`**:
    *   These components are now largely **passive** regarding orientation.
    *   They **do not** directly track device orientation or attempt to manage interface rotation locks themselves.
    *   `CameraView` uses `RotatingView` for specific elements that need to rotate and `OrientationFixView` when presenting modal content (like the library) that requires different orientation rules.

## Summary of Flow

1.  **Physical Orientation**: `DeviceOrientationViewModel` tracks the physical device orientation.
2.  **UI Element Rotation**: `RotatingView` observes the `DeviceOrientationViewModel` and rotates its content accordingly.
3.  **Interface Lock/Allow**: When a view is presented (especially modally), `OrientationFixView` can wrap it. `AppDelegate` queries the topmost controller, checking for `PresentationHostingController` children, `OrientationFixViewController` properties, or matches against a static list (`AppDelegate.landscapeEnabledViewControllers`), to tell the system which interface orientations are permitted *at that moment*.
4.  **Preview Rendering**: `CameraPreviewView` renders the preview frames, fixed in a portrait orientation.
5.  **Video Metadata**: When recording starts, `RecordingService` calculates the necessary transform based on the current physical orientation (using the angle from `videoRotationAngleValue`) and applies it to the video track, ensuring correct playback later.

This approach separates concerns: physical orientation tracking, UI element rotation, interface orientation locking, preview rendering orientation, and video metadata are handled by distinct, specialized components. 