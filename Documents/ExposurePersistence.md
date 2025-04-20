# Exposure Mode Persistence

The app now persists the last used manual exposure settings (ISO and shutter speed) when switching between automatic and manual exposure modes during video recording.

**Key Changes:**

1.  **`CameraViewModel.swift`:**
    *   Added `previousISO: Float = 0` and `previousExposureDuration: CMTime = .zero` properties to store the last manual values.
    *   In `setExposureMode(_:)`:
        *   When switching *to* manual mode (`.locked`), if `previousISO` and `previousExposureDuration` are not their default zero values, restore these settings using `setExposure(iso:duration:)`.
        *   When switching *from* manual mode (`.locked`) *to* an automatic mode, store the current `device.iso` and `device.exposureDuration` into `previousISO` and `previousExposureDuration` *before* setting the new mode.
    *   Modified `setExposure(iso:duration:)` to update `previousISO` and `previousExposureDuration` whenever manual adjustments are made, ensuring the *latest* manual setting is saved.

This allows users to seamlessly switch back to their preferred manual settings after temporarily using an automatic mode. 