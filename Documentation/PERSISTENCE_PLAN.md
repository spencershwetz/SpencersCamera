# Plan to Persist All User Settings

This document outlines the plan to make *all* user-configurable settings persistent using the existing `SettingsModel` (located in `iPhoneApp/Features/Settings/`) and `@AppStorage`.

**Persisted Settings:**
*   Resolution (`selectedResolutionRaw`)
*   Codec (`selectedCodecRaw`)
*   Frame Rate (`selectedFrameRate`)
*   Color Space / Apple Log (`isAppleLogEnabled`)
*   Selected LUT (`selectedLUTName`)
*   Bake In LUT (`isBakeInLUTEnabled`)
*   Flashlight Intensity (`flashlightIntensity`)
*   Show Grid (`showGrid`)
*   Function Button 1 / Manual Exposure Lock (`isExposureLocked`)
*   Function Button 2 / Shutter Priority (`isShutterPriorityEnabled`)
*   Lock Exposure During Recording (`isLockExposureDuringRecordingEnabled`)
*   Show Debug Info (`isDebugEnabled`)

## 1. Modify `iPhoneApp/Features/Settings/SettingsModel.swift`

*   **Ensure `@AppStorage` Properties for All Settings:**
    *   Verify or add `@AppStorage` wrappers for all settings listed above.
    *   Define unique `UserDefaults` keys and appropriate default values for each.
    *   Example for new ones:
        ```swift
        @AppStorage("selectedResolutionRaw") var selectedResolutionRaw: String = CameraViewModel.Resolution.defaultRes.rawValue
        @AppStorage("selectedCodecRaw") var selectedCodecRaw: String = CameraViewModel.VideoCodec.defaultCodec.rawValue
        @AppStorage("selectedFrameRate") var selectedFrameRate: Double = 30.0
        @AppStorage("isAppleLogEnabled") var isAppleLogEnabled: Bool = false // Example default
        @AppStorage("isDebugEnabled") var isDebugEnabled: Bool = false
        // ... verify existing ones like selectedLUTName, isBakeInLUTEnabled, etc. ...
        ```
*   **Remove Manual `UserDefaults` Logic:** Delete any `didSet` observers or `init()` logic that manually saves/loads these values using `UserDefaults.standard`, as `@AppStorage` handles this automatically.
*   **Add/Verify Computed Properties:**
    *   Provide computed properties for cleaner access to enum types based on the raw string values stored by `@AppStorage`. Ensure they handle potential `nil` results from `rawValue` initializers gracefully.
        ```swift
        var selectedResolution: CameraViewModel.Resolution {
            CameraViewModel.Resolution(rawValue: selectedResolutionRaw) ?? .defaultRes // Use actual default
        }
        var selectedCodec: CameraViewModel.VideoCodec {
            CameraViewModel.VideoCodec(rawValue: selectedCodecRaw) ?? .defaultCodec // Use actual default
        }
        // No computed properties needed for Bool, Double, Float, String types.
        ```

## 2. Modify `iPhoneApp/Features/Camera/CameraViewModel.swift`

*   **Inject `SettingsModel`:** Ensure `CameraViewModel` receives a `SettingsModel` instance (likely already done via `init(settingsModel: SettingsModel)`).
*   **Remove Local State:** Remove any `@Published` properties that duplicate settings now managed by `SettingsModel` (e.g., `selectedResolution`, `selectedCodec`, `selectedFrameRate`, `isAppleLogEnabled`, `isDebugEnabled`).
*   **Initialize from `SettingsModel`:** In `init()`, read the initial values for *all* camera-related settings (resolution, codec, fps, log, LUT, bake-in, flashlight, grid, lock exposure setting, shutter priority) directly from the injected `settingsModel` instance and apply them to the camera session and services using existing configuration methods (e.g., `updateResolution`, `configureSession`, etc.).
*   **Provide Access via Proxy Computed Properties:** Expose settings values from the `settingsModel` via computed properties for views to access, promoting better encapsulation.
    ```swift
    // Read-only examples (views often use update methods)
    var selectedResolution: Resolution { settingsModel.selectedResolution }
    var selectedCodec: VideoCodec { settingsModel.selectedCodec }
    var selectedFrameRate: Double { settingsModel.selectedFrameRate }
    var isAppleLogEnabled: Bool { settingsModel.isAppleLogEnabled }
    var isDebugEnabled: Bool { settingsModel.isDebugEnabled }
    var showGrid: Bool { settingsModel.showGrid }
    var selectedLUTName: String { settingsModel.selectedLUTName }
    var isBakeInLUTEnabled: Bool { settingsModel.isBakeInLUTEnabled }
    var isLockExposureDuringRecordingEnabled: Bool { settingsModel.isLockExposureDuringRecordingEnabled }
    var flashlightIntensity: Float { settingsModel.flashlightIntensity }
    // Function button states might need to remain @Published if their state changes
    // outside of direct user interaction in settings (verify this).
    // Expose the model if direct binding is truly needed:
    // public let settingsModel: SettingsModel
    ```
*   **Update Configuration Methods:** Ensure methods like `updateResolution`, `updateCodec`, `updateFrameRate`, `updateColorSpace`, `updateLUT`, `updateBakeInLUT`, `updateFlashlightIntensity`, `updateIsDebugEnabled` (add if needed), `updateShowGrid`, `updateLockExposureDuringRecording` not only apply the setting change to the camera/services but *also update the corresponding `@AppStorage` property in the injected `settingsModel`*.
    ```swift
    func updateResolution(_ resolution: Resolution) {
        // ... apply change to camera session ...
        settingsModel.selectedResolutionRaw = resolution.rawValue // Update persistent storage
        // objectWillChange.send() // May be needed if views bind directly to computed vars
    }
    // ... similar updates for other methods ...
    ```

## 3. Modify `iPhoneApp/Features/Camera/Views/SettingsView.swift`

*   **Use `viewModel` for Settings:** Remove the local `@StateObject var settingsModel`. Access all required settings values and trigger updates through the injected `@ObservedObject var viewModel`.
*   **Bind Controls to `viewModel`:** Bind Pickers (Resolution, Codec, FPS, Color Space/Log, LUT) and Toggles (Grid, Bake LUT, Lock Exposure, Debug Info) directly to the computed properties exposed by the `viewModel` (which reflect the persistent `settingsModel` values).
    ```swift
    // Example for Resolution Picker
    Picker("Resolution", selection: $viewModel.selectedResolutionRawProxy) { // Requires a writable proxy binding in ViewModel
        ForEach(CameraViewModel.Resolution.allCases, id: \.rawValue) { resolution in
            Text(resolution.displayString).tag(resolution.rawValue) // Use displayString
        }
    }
    // If using update methods via .onChange:
    Picker("Resolution", selection: .constant(viewModel.selectedResolution.rawValue)) { ... }
    .onChange(of: selectedValueState) { _, newRawValue in // Requires a local @State var to drive the picker selection
         if let newResolution = CameraViewModel.Resolution(rawValue: newRawValue) {
             viewModel.updateResolution(newResolution)
         }
    }

    // Example for Debug Toggle
    Toggle("Show Debug Info", isOn: $viewModel.isDebugEnabledProxy) // Requires a writable proxy binding
    // Or if using update methods:
    Toggle("Show Debug Info", isOn: .constant(viewModel.isDebugEnabled))
        .onChange(of: viewModel.isDebugEnabled) { _, newValue in // Doesn't work well for toggles
             // Better to use a binding or update method triggered by tap
        }
    ```
    *Note: Decide on using direct bindings (requires writable proxies in ViewModel) or `.onChange` with update methods.* The `.onChange` approach using `viewModel.update...` methods might be cleaner as it centralizes logic in the ViewModel.
*   **Add Debug Info Toggle:** Add the `Toggle` for "Show Debug Info" if it doesn't exist.
*   **Verify `.onChange` Modifiers:** Ensure all `.onChange` modifiers (if used) correctly call the corresponding `viewModel.update...` methods. These methods will handle applying the change and updating the `settingsModel`.

## 4. Modify `iPhoneApp/Features/Camera/Views/CameraView.swift`

*   **Remove Redundant `SettingsModel`:** Remove the local `@StateObject private var settingsModel`.
*   **Update Debug Overlay Condition:** Change the condition to use `viewModel.isDebugEnabled`.
*   **Update `SettingsView` Presentation:** Remove the explicit `settingsModel` parameter when presenting `SettingsView`. It will access settings via the injected `viewModel`.
    ```swift
    // Change from:
    // SettingsView(..., settingsModel: settingsModel, ...)
    // To:
    SettingsView(viewModel: viewModel, lutManager: lutManager, dismissAction: { ... })
    ```

## 5. Testing

*   **Persistence:** Change every setting, close/kill the app, reopen, verify all settings are retained.
*   **Live Update:** Change settings in the UI, verify the camera preview, controls, or behavior updates immediately as expected.
*   **Defaults:** Clear UserDefaults (e.g., via simulator reset or code `UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier!)`), launch the app, verify all settings default correctly.
*   **ViewModel Init:** Ensure `CameraViewModel` correctly loads and applies all persisted settings on initial launch.
*   **Interactions:** Test interactions between settings (e.g., Shutter Priority disabling manual exposure lock). 