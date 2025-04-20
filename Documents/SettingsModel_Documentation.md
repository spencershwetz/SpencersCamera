# SettingsModel Documentation

## Overview

`SettingsModel` is an `ObservableObject` responsible for managing user-configurable settings related to the camera application. It uses `@AppStorage` to persist these settings across app launches.

## Properties

### `selectedFrameRate`: Double

- **Description**: Stores the frame rate selected by the user for video recording.
- **Persistence**: Uses `@AppStorage` with the key `"selectedFrameRate"`.
- **Default Value**: `30.0` (fps)
- **Usage**: This value is read by `CameraViewModel` to configure the `AVCaptureDevice` and `RecordingService` for the desired frame rate during video recording. 