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
    *   Checks the `topMostViewController()`. If it's an `OrientationFixViewController`, it respects its `allowsLandscapeMode` property.
    *   Otherwise, it defaults to locking the interface to `.portrait`.

*   **`DeviceOrientationViewModel.swift` (`Core/Orientation`)**:
    *   The **source of truth for physical device orientation**.
    *   Uses `UIDevice.orientationDidChangeNotification` to monitor the actual hardware orientation (`UIDeviceOrientation`).
    *   Publishes the current `orientation: UIDeviceOrientation`.
    *   Provides a computed `rotationAngle: Angle` derived from the physical orientation.

*   **`RotatingView.swift` (`Core/Orientation`)**:
    *   A `UIViewControllerRepresentable` used to **rotate specific SwiftUI content** based on physical orientation.
    *   Observes `DeviceOrientationViewModel.shared.orientation`.
    *   Applies a `CGAffineTransform` rotation to its hosted SwiftUI `Content` view, animating the change.
    *   Used for elements like the Settings button icon in `CameraView`.

*   **`OrientationFixView.swift` (`Core/Orientation`)**:
    *   A `UIViewControllerRepresentable` wrapping `OrientationFixViewController`.
    *   Used to **control the supported *interface* orientations** for a specific SwiftUI view hierarchy it wraps.
    *   Takes an `allowsLandscapeMode: Bool` parameter during initialization.
    *   `OrientationFixViewController` overrides `supportedInterfaceOrientations` to return `.all` if `allowsLandscapeMode` is `true`, otherwise `.portrait`.
    *   This is how `VideoLibraryView` is allowed to rotate when presented via `.fullScreenCover(content: { OrientationFixView(allowsLandscapeMode: true) { VideoLibraryView(...) } })`, while `CameraView` remains primarily portrait.

*   **`RecordingService.swift` (`Features/Camera/Services`)**:
    *   Responsible for **embedding correct video metadata orientation**.
    *   Before starting recording, it determines the appropriate rotation angle (0, 90, 180, 270 degrees) based on the current device and interface orientation.
    *   It calculates a `CGAffineTransform` for this rotation.
    *   This transform is applied to the `AVAssetWriterInput` (`transform` property). This ensures the video file itself has the correct orientation flag, regardless of the UI's locked state.

*   **`CameraView.swift` / `CameraViewModel.swift`**:
    *   These components are now largely **passive** regarding orientation.
    *   They **do not** directly track device orientation or attempt to manage interface rotation locks themselves.
    *   `CameraView` uses `RotatingView` for specific elements that need to rotate and `OrientationFixView` when presenting modal content (like the library) that requires different orientation rules.

## Summary of Flow

1.  **Physical Orientation**: `DeviceOrientationViewModel` tracks the physical device orientation.
2.  **UI Element Rotation**: `RotatingView` observes the `DeviceOrientationViewModel` and rotates its content accordingly.
3.  **Interface Lock/Allow**: When a view is presented (especially modally), `OrientationFixView` wraps it if specific orientation rules are needed. `AppDelegate` queries the `OrientationFixViewController`'s `allowsLandscapeMode` property (or defaults to portrait) to tell the system which interface orientations are permitted *at that moment*.
4.  **Video Metadata**: When recording starts, `RecordingService` calculates the necessary transform based on the current orientation and applies it to the video track, ensuring correct playback later.

This approach separates concerns: physical orientation tracking, UI element rotation, interface orientation locking, and video metadata are handled by distinct, specialized components. 