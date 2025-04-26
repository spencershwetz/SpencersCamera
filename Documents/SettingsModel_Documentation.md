# SettingsModel Documentation

The `SettingsModel` class manages persistent settings for the camera application using `@AppStorage`.

## Properties

### selectedFrameRate
- Description: The currently selected frame rate for video recording
- Persistence: Uses `@AppStorage("selectedFrameRate")`
- Default Value: 30.0 fps
- Usage: Used to configure the `AVCaptureDevice` and `RecordingService` during video recording
- Configuration: 
  - Stops active session before applying changes
  - Commits configuration after changes
  - Restores session state post-commit
  - Includes enhanced error handling for configuration commits

### Session Configuration Handling
- Proper state management before/after configuration changes
- Ensures configuration is committed even on errors
- Maintains session state consistency
- Uses videoRotationAngle for iOS 17+ compatibility

Note: All configuration changes follow a strict pattern:
1. Store current session state
2. Stop session
3. Apply changes
4. Commit configuration
5. Restore session state 