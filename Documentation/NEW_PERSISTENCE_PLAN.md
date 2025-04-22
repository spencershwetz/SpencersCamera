# Persistence Plan for Remaining Settings

## Goal

Ensure all user-configurable settings persist across application launches. This includes camera format settings, UI state like grid visibility, debug flags, and the currently selected LUT.

## Strategy

Utilize SwiftUI's `@AppStorage` property wrapper within `SettingsModel` for most standard settings (resolution, codec, frame rate, debug, grid). For the currently selected LUT, store its URL string in `UserDefaults` via `LUTManager`. Address the redundancy identified in `isAppleLogEnabled` management.

## Detailed Steps

1.  **Modify `SettingsModel.swift`:**
    *   Add new `@AppStorage` properties for previously non-persistent settings:
        ```swift
        // Define appropriate keys in the Keys enum first
        private enum Keys {
            // ... existing keys ...
            static let selectedResolutionRaw = "selectedResolutionRaw"
            static let selectedCodecRaw = "selectedCodecRaw"
            static let selectedFrameRate = "selectedFrameRate"
            static let isDebugEnabled = "isDebugEnabled"
            static let showGrid = "showGrid"
            static let selectedLUTURLString = "selectedLUTURLString" // Key for LUTManager
        }

        @AppStorage(Keys.selectedResolutionRaw) var selectedResolutionRaw: String = CameraViewModel.Resolution.defaultRes.rawValue // Use appropriate default
        @AppStorage(Keys.selectedCodecRaw) var selectedCodecRaw: String = CameraViewModel.VideoCodec.defaultCodec.rawValue // Use appropriate default
        @AppStorage(Keys.selectedFrameRate) var selectedFrameRate: Double = 30.0 // Use appropriate default
        @AppStorage(Keys.isDebugEnabled) var isDebugEnabled: Bool = false
        @AppStorage(Keys.showGrid) var showGrid: Bool = false // Or true, depending on desired default
        ```
    *   **Resolve `isAppleLogEnabled` Redundancy:**
        *   Keep the `@AppStorage` property for `isAppleLogEnabled` in `SettingsModel` as the single source of truth.
        *   Remove the `@Published var isAppleLogEnabled` property from `CameraViewModel.swift`.
        *   Update all references in `CameraViewModel` and other services (`RecordingService`, `VideoFormatService`) to read the value from the injected `SettingsModel` instance.

2.  **Modify `LUTManager.swift`:**
    *   Modify the `selectedLUTURL` property to save its value to `UserDefaults` when changed:
        ```swift
        @Published var selectedLUTURL: URL? {
            didSet {
                // Save the URL string to UserDefaults
                let urlString = selectedLUTURL?.absoluteString
                UserDefaults.standard.set(urlString, forKey: SettingsModel.Keys.selectedLUTURLString) // Use key from SettingsModel
                logger.info("Saved selectedLUTURL to UserDefaults: \(urlString ?? "nil")")

                // Original logic (if any) in didSet should be preserved if needed
                // e.g., loading the LUT data if not done elsewhere
                if let url = selectedLUTURL {
                     // Potentially reload or re-setup texture/filter if needed here,
                     // or ensure it happens wherever selectedLUTURL is set.
                     // Avoid redundant loading if loadLUT(from:) already handles setup.
                } else {
                    clearLUT() // Reset if URL is set to nil
                }
            }
        }
        ```
    *   Update the `init()` method to load the saved URL and apply the LUT on startup:
        ```swift
        init() {
            guard let metalDevice = MTLCreateSystemDefaultDevice() else {
                fatalError("Metal is not supported on this device")
            }
            self.device = metalDevice
            loadRecentLUTs() // Keep loading recent LUTs

            // Load and apply the last selected LUT
            if let urlString = UserDefaults.standard.string(forKey: SettingsModel.Keys.selectedLUTURLString),
               let url = URL(string: urlString) {
                logger.info("Attempting to load previously selected LUT from UserDefaults: \(url.path)")
                // Use a method that loads AND sets up the filter/texture
                // Assuming loadLUT(from:) handles this and sets selectedLUTURL internally
                 // Use importLUT to ensure file access and copying if needed
                importLUT(from: url) { success in
                    if success {
                        self.logger.info("Successfully reloaded selected LUT from UserDefaults.")
                    } else {
                        self.logger.warning("Failed to reload selected LUT from UserDefaults URL: \(urlString). Clearing.")
                        // Clear the invalid saved URL
                        UserDefaults.standard.removeObject(forKey: SettingsModel.Keys.selectedLUTURLString)
                        self.clearLUT() // Fallback to identity
                    }
                }
            } else {
                 logger.info("No selected LUT found in UserDefaults. Initializing with identity.")
                 setupIdentityLUTTexture() // Ensure identity LUT is set up if none was saved
            }

            // If init() originally called setupIdentityLUTTexture(), ensure it's
            // only called now if no saved LUT was loaded.
        }
        ```
    *   Ensure `loadLUT(from:)` or `importLUT(from:)` correctly sets `selectedLUTURL` *after* successful loading to trigger the `didSet` persistence logic. Avoid setting it *before* trying to load, otherwise, a failed load might persist a non-working URL.

3.  **Modify `CameraViewModel.swift`:**
    *   Ensure `SettingsModel` is injected as an `@StateObject` or `@ObservedObject`.
    *   Remove local `@Published` properties for `selectedResolutionRaw`, `selectedCodecRaw`, `selectedFrameRate`, `isDebugEnabled`, `showGrid`, and `isAppleLogEnabled`.
    *   Update all internal logic, computed properties, and UI bindings (`SettingsView`, `CameraView`) to read these values directly from the `settingsModel` instance (e.g., `settingsModel.selectedFrameRate`).
    *   For UI elements like `Picker`s that need to modify these settings (e.g., Resolution Picker), bind them directly to the `@AppStorage` properties in `settingsModel` (e.g., `$settingsModel.selectedResolutionRaw`). No proxy bindings needed if `SettingsModel` is an `ObservableObject`.

4.  **Refactor Consumers:**
    *   Review `RecordingService`, `VideoFormatService`, `CameraDeviceService`, and any other classes that might have been using the now-removed state from `CameraViewModel`. Update them to read directly from the injected `SettingsModel`.
    *   Ensure default values provided in `@AppStorage` are appropriate for the first launch experience.

5.  **Testing:**
    *   **Clean State:** Delete the app or clear `UserDefaults` (`UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier!)`) before the first launch with the changes.
    *   **Default Verification:** Launch the app and verify that all newly persisted settings (resolution, codec, FPS, debug, grid, LUT) initialize to their defined default values.
    *   **Settings Modification:** Change each setting via the UI.
    *   **Relaunch Verification:** Relaunch the app and confirm that all settings retain their modified values.
    *   **LUT Persistence:** Select a LUT, relaunch, and verify the LUT is still selected and applied. Select "None" or clear the LUT, relaunch, and verify it remains cleared. Import a new LUT, select it, relaunch, verify it's selected.
    *   **Edge Cases:** Test interactions between settings (e.g., does changing resolution affect the persisted frame rate list validity?).
    *   **Test `isAppleLogEnabled`:** Ensure toggling Apple Log works correctly and persists, reading/writing only through `SettingsModel`. 