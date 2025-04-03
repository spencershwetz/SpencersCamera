# Camera App Orientation Handling

This document explains how orientation is managed throughout the camera application to ensure a consistent user experience for both the live preview and recorded videos.

## Key Concepts

*   **Interface Orientation (`UIInterfaceOrientation`):** The orientation of the application's user interface (portrait, landscapeLeft, landscapeRight, portraitUpsideDown). This is typically derived from the `UIWindowScene`.
*   **Device Orientation (`UIDeviceOrientation`):** The physical orientation of the device. Can include states like faceUp/faceDown which are not valid interface orientations.
*   **`videoRotationAngle`:** A property of `AVCaptureConnection` (used for preview, video data output, and recording). It specifies the clockwise rotation angle (0, 90, 180, 270 degrees) that should be applied to the video frames *relative to the sensor's native orientation* to make them appear upright according to the desired interface orientation.

## Initial Setup

1.  When the `CameraViewModel` initializes, it sets up the `CameraSetupService`.
2.  The `CameraSetupService` configures the initial `AVCaptureSession`, including adding video input and outputs.
3.  During setup, or shortly after the session starts running (`didStartRunning` delegate call), the initial `videoRotationAngle` is determined based on the current interface orientation and applied to the relevant connections (like the `AVCaptureVideoPreviewLayer`'s connection).

## Live Preview (`CameraPreviewView.swift`)

1.  The `CustomPreviewView` (UIViewRepresentable's UIView) contains the `AVCaptureVideoPreviewLayer`.
2.  It observes `UIDevice.orientationDidChangeNotification`.
3.  When an orientation change occurs (`handleOrientationChange`), it gets the current *interface* orientation from the `windowScene`.
4.  It calculates the required `videoRotationAngle` (0, 90, 180, 270) based on the *interface* orientation.
5.  This calculated angle is applied to the `previewLayer.connection?.videoRotationAngle`.
6.  If the `AVCaptureVideoDataOutput` is active (e.g., for applying LUTs), its connection's `videoRotationAngle` is also updated similarly.
7.  **LUT Overlay:** The `captureOutput` delegate method processes frames using the `LUTProcessor` and creates a `CGImage`. This image is displayed in a `CALayer` (`LUTOverlayLayer`) added as a sublayer to the `previewLayer`. This overlay layer's frame is automatically updated to match the `previewLayer`'s bounds in `layoutSubviews`, ensuring it rotates and resizes correctly with the preview.

## Lens Switching (`CameraDeviceService.swift`)

1.  When a lens switch is initiated (e.g., `CameraViewModel.switchToLens`), the *current interface orientation* is captured immediately on the main thread.
2.  The actual switching logic runs on a background queue (`cameraQueue`).
3.  Inside `switchToPhysicalLens`, the previously captured interface orientation is used to calculate the `targetVideoAngle` (0, 90, 180, 270) needed for the *new* camera device/lens.
4.  The `AVCaptureSession` is reconfigured (beginConfiguration/commitConfiguration):
    *   Old inputs are removed.
    *   The new `AVCaptureDeviceInput` is added.
    *   **Crucially:** *Before* committing the configuration, the calculated `targetVideoAngle` is applied to all relevant *new* video connections associated with the session's outputs.
5.  This ensures that when the session restarts with the new lens, the connections are already set to the correct rotation angle, preventing an upside-down preview.

## Recording

1.  **Starting Recording (`CameraViewModel.startRecording`):**
    *   Before starting the `RecordingService`, the `CameraViewModel.getCurrentVideoTransform` method is called.
    *   This method determines the correct `CGAffineTransform` for the recording.
    *   It *prioritizes* the current `UIDevice.orientation` if it's a valid interface orientation (portrait/landscape). If the device orientation is invalid (e.g., faceUp), it falls back to using the current `UIInterfaceOrientation`.
    *   The angle (0, 90, 180, 270) derived from the chosen orientation is converted into a rotation transform.
    *   This transform is passed to the `RecordingService.startRecording` method.
2.  **During Recording:**
    *   The `RecordingService` uses the transform passed during `startRecording` to configure the `AVAssetWriterInput`.
    *   Orientation updates *can* be optionally locked during recording. The `CameraDeviceService` has a `lockOrientationForRecording` method which sets a flag (`isRecordingOrientationLocked`). If this flag is true, the `updateVideoOrientation` method (which would normally update connection angles) is skipped.
    *   The `CameraPreviewView`'s `handleOrientationChange` method *continues* to update the preview layer's connection angle even if recording orientation is locked, ensuring the live preview always matches the UI orientation.

## Key Components

*   **`CameraViewModel`:** Holds overall state, initiates lens switching, starts/stops recording, determines recording transform.
*   **`CameraPreviewView` / `CustomPreviewView`:** Manages the `AVCaptureVideoPreviewLayer`, observes orientation changes, updates preview connection angle, displays LUT overlay.
*   **`CameraDeviceService`:** Handles device discovery, lens switching logic (`switchToPhysicalLens`), applies the correct orientation angle to connections during reconfiguration, provides the orientation lock mechanism.
*   **`RecordingService`:** Receives the video transform at the start of recording and applies it to the asset writer.