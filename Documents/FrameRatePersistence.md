# Frame Rate Persistence

The selected frame rate is now persisted using `@AppStorage` within the `SettingsModel`. The `CameraViewModel` reads this value directly from `SettingsModel` instead of storing it locally.

**Key Changes:**

1.  **`SettingsModel.swift`:**
    *   Added `@AppStorage("selectedFrameRate") public var selectedFrameRate: Double = 30.0`.
2.  **`CameraViewModel.swift`:**
    *   Removed the local `selectedFrameRate` property.
    *   Updated references to `selectedFrameRate` to read from `SettingsModel().selectedFrameRate`.
    *   Ensured `updateVideoConfiguration` uses the persisted value.
3.  **`SettingsView.swift`:**
    *   Modified the `Picker` to bind directly to `settingsModel.selectedFrameRate`.

This ensures that the user's selected frame rate setting is saved across app launches. 