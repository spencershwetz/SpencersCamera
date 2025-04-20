# Plan to Persist Additional Settings

This document outlines the plan to make the camera format settings (Resolution, Color Space/Apple Log, Codec, Frame Rate) and the "Show Debug Info" setting persistent using the existing `SettingsModel` and `UserDefaults` mechanism.

## 1. Modify `SettingsModel.swift`

*   **Add New `@Published` Properties:**
    *   `@Published var selectedResolutionRaw: String` (Stores enum `rawValue`)
    *   `@Published var selectedCodecRaw: String` (Stores enum `rawValue`)
    *   `@Published var selectedFrameRate: Double`
    *   `@Published var isDebugEnabled: Bool`
    *   *(Keep `@Published var isAppleLogEnabled: Bool` as it already exists for Color Space)*
*   **Add Corresponding Keys:**
    *   Add static string constants to the private `Keys` enum: `selectedResolutionRaw`, `selectedCodecRaw`, `selectedFrameRate`, `isDebugEnabled`.
*   **Update `didSet` Observers:**
    *   For each new property, add a `didSet` observer that saves the value to `UserDefaults` using the corresponding key.
    *   Example:
        ```swift
        @Published var selectedResolutionRaw: String {
            didSet {
                UserDefaults.standard.set(selectedResolutionRaw, forKey: Keys.selectedResolutionRaw)
                // Optional: NotificationCenter.default.post(...)
            }
        }
        // ... similar for others
        ```
*   **Update `init()`:**
    *   Read the new keys from `UserDefaults` (e.g., `UserDefaults.standard.string(forKey: Keys.selectedResolutionRaw)`).
    *   Define default values (e.g., `defaultResolutionRaw = CameraViewModel.Resolution.defaultRes.rawValue`, `defaultCodecRaw = CameraViewModel.VideoCodec.defaultCodec.rawValue`, `defaultFrameRate = 30.0`, `defaultIsDebugEnabled = false`).
    *   Initialize the new `@Published` properties using `UserDefaults` values or defaults (e.g., `self.selectedResolutionRaw = UserDefaults.standard.string(forKey: Keys.selectedResolutionRaw) ?? defaultResolutionRaw`).
    *   If defaults were used, write them back to `UserDefaults`.
*   **Add Computed Properties (Recommended):**
    *   Provide computed properties for cleaner access to enum types.
        ```swift
        var selectedResolution: CameraViewModel.Resolution {
            CameraViewModel.Resolution(rawValue: selectedResolutionRaw) ?? .res1080p // Provide a sensible default
        }
        var selectedCodec: CameraViewModel.VideoCodec {
            CameraViewModel.VideoCodec(rawValue: selectedCodecRaw) ?? .hevc // Provide a sensible default
        }
        ```

## 2. Modify `CameraViewModel.swift`

*   **Inject or Access `SettingsModel`:** Ensure `CameraViewModel` receives or can access a `SettingsModel` instance.
    ```swift
    class CameraViewModel: ObservableObject {
        private let settingsModel: SettingsModel
        // ...
        init(settingsModel: SettingsModel = SettingsModel()) { // Example: Pass in init
            self.settingsModel = settingsModel
            // ... existing init ...
            // Now read initial values from settingsModel
            self.selectedResolution = settingsModel.selectedResolution
            self.selectedCodec = settingsModel.selectedCodec
            self.selectedFrameRate = settingsModel.selectedFrameRate
            self.isAppleLogEnabled = settingsModel.isAppleLogEnabled
            // ... apply these settings to the camera session ...
        }
        // ...
    }
    ```
*   **Update Configuration Methods:** Ensure methods like `updateResolution`, `updateCodec`, `updateFrameRate`, `updateColorSpace` correctly apply the changes passed to them (these will be called from `SettingsView`'s `.onChange`).

## 3. Modify `SettingsView.swift`

*   **Bind Controls to `SettingsModel`:**
    *   Change `Picker` selections and `Toggle` `isOn` parameters to bind to the properties in `@StateObject settingsModel`. Use the `Raw` properties for `UserDefaults` persistence and potentially the computed properties for display/tagging if helpful.
        ```swift
        // Example for Resolution Picker
        Picker("Resolution", selection: $settingsModel.selectedResolutionRaw) {
            ForEach(CameraViewModel.Resolution.allCases, id: \.rawValue) { resolution in
                Text(resolution.rawValue).tag(resolution.rawValue)
            }
        }
        // Example for Debug Toggle
        Toggle("Show Debug Info", isOn: $settingsModel.isDebugEnabled)
        // ... similar for Codec, Frame Rate, Color Space/Apple Log ...
        ```
    *   Remove the `@Binding var isDebugEnabled` property.
*   **Add `.onChange` Modifiers:**
    *   Add `.onChange` modifiers to the Pickers to trigger live updates in `CameraViewModel`.
        ```swift
        // Example for Resolution Picker
        .onChange(of: settingsModel.selectedResolutionRaw) { _, newRawValue in
            if let newResolution = CameraViewModel.Resolution(rawValue: newRawValue) {
                viewModel.updateResolution(newResolution) // Ensure this method exists
            }
        }
        // Example for Color Space Picker (using isAppleLogEnabled)
        .onChange(of: settingsModel.isAppleLogEnabled) { _, newValue in
             viewModel.updateColorSpace(isAppleLogEnabled: newValue) // Ensure this method exists
        }
        // ... similar .onChange for Codec and Frame Rate ...
        ```

## 4. Modify `CameraView.swift`

*   **Remove `@State var isDebugEnabled`:** Delete the local state variable.
*   **Access `SettingsModel`:** Add access, likely via `@StateObject`.
    ```swift
    @StateObject private var settingsModel = SettingsModel() // Add this
    ```
*   **Update Debug Overlay Condition:** Change the `if isDebugEnabled` condition to `if settingsModel.isDebugEnabled`.
*   **Update `SettingsView` Presentation:** Remove the `isDebugEnabled` binding when creating `SettingsView`.
    ```swift
    // Change from:
    // SettingsView(..., isDebugEnabled: $isDebugEnabled, ...)
    // To:
    SettingsView(lutManager: lutManager, viewModel: viewModel, dismissAction: { ... }) // isDebugEnabled is now handled internally by SettingsView's own settingsModel
    ```

## 5. Testing

*   Verify persistence: Change settings, close/reopen app, check if settings are retained.
*   Verify live update: Change settings in UI, check if camera preview/configuration updates immediately.
*   Verify defaults: Clear UserDefaults (e.g., via simulator reset or code), launch app, check if default settings are applied correctly.
*   Verify `CameraViewModel` init: Ensure the view model correctly loads persisted settings on launch. 

## 6. Implementation Status

The persistence plan has been successfully implemented with the following key components:

1. `SettingsModel.swift` has been updated to include all the necessary `@Published` properties with `UserDefaults` persistence:
   * `selectedResolutionRaw`
   * `selectedCodecRaw`
   * `selectedFrameRate`
   * `isAppleLogEnabled` (was already implemented)
   * `isDebugEnabled`

2. `CameraViewModel.swift` has been modified to:
   * Use the persisted settings from `SettingsModel` during initialization
   * Ensure that the Apple Log setting is correctly applied at startup
   * Fix an issue where the Apple Log setting was being overridden by the device's active color space

3. `SettingsView.swift` has been updated to:
   * Use `@ObservedObject` to bind to the shared `SettingsModel`
   * Bind all UI controls to the `SettingsModel` properties
   * Add appropriate `.onChange` modifiers to trigger live updates in `CameraViewModel`

4. `CameraView.swift` has been updated to:
   * Use the shared `SettingsModel` for the debug overlay toggle
   * Pass the `SettingsModel` to `SettingsView` 

## 7. Known Issues & Fixes

* An issue was identified and fixed where the Apple Log setting was not being correctly applied at startup, causing the color space to remain as Rec.709 despite being enabled in settings.

* The debug overlay was updated to show the actual camera device color space instead of just the setting value, improving the accuracy of the information displayed.

## 8. Conclusion

The implementation of camera settings persistence has been completed successfully. Users can now configure their preferred resolution, codec, frame rate, and color space settings, and these settings will be preserved across app launches. Additionally, the "Show Debug Info" setting is now also persistent.

This implementation enhances the user experience by eliminating the need to reconfigure settings each time the app is opened, providing a more professional and streamlined workflow for video capture. 