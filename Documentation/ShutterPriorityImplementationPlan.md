# Shutter Priority Implementation Plan (Strategy 1)

This document outlines the steps to implement a custom Shutter Priority (SP) mode where the ISO automatically adjusts while the shutter speed remains fixed. This uses Strategy 1: Continuous Custom Exposure Monitoring & Adjustment.

**Core Idea:**

1.  Fix the shutter speed using `.custom` exposure mode.
2.  Monitor the `exposureTargetOffset` using KVO. This tells us how far the current exposure (fixed shutter, current ISO) is from the camera's ideal exposure.
3.  If the offset is significant, calculate a new target ISO to counteract the offset.
4.  Apply the new ISO (keeping the shutter fixed) using `setExposureModeCustom`.
5.  Use thresholds and rate-limiting to prevent unstable oscillations.

---

## Phase 1: Modifying `ExposureService.swift`

~~1.  **Add State Properties:**~~
    Add the following private properties to the `ExposureService` class:

    ```swift
    private var isShutterPriorityActive: Bool = false
    private var targetShutterDuration: CMTime?
    private var exposureTargetOffsetObservation: NSKeyValueObservation?
    private var lastIsoAdjustmentTime: Date = .distantPast // For rate limiting
    // --- Tuning Parameters (Adjust as needed) ---
    private let isoAdjustmentInterval: TimeInterval = 0.1 // Max 10 ISO adjustments/sec
    private let isoPercentageThreshold: Float = 0.05 // 5% change needed to trigger adjustment
    private let evOffsetThreshold: Float = 0.1 // 0.1 EV offset needed to trigger adjustment
    // --- Dispatch Queue ---
    // Add a dedicated serial queue for exposure adjustments to avoid blocking KVO/session queues
    private let exposureAdjustmentQueue = DispatchQueue(label: "com.camera.exposureAdjustmentQueue", qos: .userInitiated)
    ```

~~2.  **Update KVO Setup (`setupDeviceObservers`):**~~
    *   Add a new observer for `exposureTargetOffset`:

    ```swift
    // Inside setupDeviceObservers(for device: AVCaptureDevice)
    exposureTargetOffsetObservation = device.observe(\\.exposureTargetOffset, options: [.new]) { [weak self] device, change in
        self?.handleExposureTargetOffsetUpdate(change: change)
    }
    ```

~~3.  **Update KVO Teardown (`removeDeviceObservers`):**~~
    *   Invalidate and nil out the new observation:

    ```swift
    // Inside removeDeviceObservers()
    exposureTargetOffsetObservation?.invalidate()
    exposureTargetOffsetObservation = nil
    ```

~~4.  **Implement `handleExposureTargetOffsetUpdate(change:)`:**~~
    *   Create this new private method:

    ```swift
    private func handleExposureTargetOffsetUpdate(change: NSKeyValueObservedChange<Float>) {
        // Ensure SP is active and we have the necessary info
        guard isShutterPriorityActive,
              let targetDuration = targetShutterDuration,
              let device = device,
              let newOffset = change.newValue else {
            // logger.debug("SP Adjust: KVO ignored (SP inactive or missing data)")
            return
        }

        // Throttle adjustments
        let now = Date()
        guard now.timeIntervalSince(lastIsoAdjustmentTime) > isoAdjustmentInterval else {
             // logger.debug("SP Adjust: KVO ignored (Rate limited)")
            return
        }

        // Only adjust if EV offset is significant
        guard abs(newOffset) > evOffsetThreshold else {
            // logger.debug("SP Adjust: KVO ignored (EV offset \\(newOffset) within threshold \\(evOffsetThreshold))")
            return
        }

        // Perform calculations and device interaction on the dedicated queue
        exposureAdjustmentQueue.async { [weak self] in
             guard let self = self, self.isShutterPriorityActive, let currentDevice = self.device else { return } // Re-check state inside async block

            let currentISO = currentDevice.iso
            let minISO = currentDevice.activeFormat.minISO
            let maxISO = currentDevice.activeFormat.maxISO

            // Calculate the ideal ISO to compensate for the offset
            // newISO = currentISO / 2^(offset)
            var idealISO = currentISO / pow(2.0, newOffset)

            // Clamp ISO to device limits
            idealISO = min(max(idealISO, minISO), maxISO)

            // Only adjust if the change is significant enough
            let percentageChange = abs(idealISO - currentISO) / currentISO
            guard percentageChange > self.isoPercentageThreshold else {
                // self.logger.debug("SP Adjust: KVO ignored (ISO change \\(percentageChange * 100)% within threshold \\(self.isoPercentageThreshold * 100)%)")
                return
            }

            self.logger.debug("SP Adjust: Offset \\(String(format: "%.2f", newOffset))EV, Current ISO \\(String(format: "%.1f", currentISO)), Ideal ISO \\(String(format: "%.1f", idealISO))")

            do {
                try currentDevice.lockForConfiguration()
                // Re-apply custom exposure with the fixed duration and newly calculated ISO
                currentDevice.setExposureModeCustom(duration: targetDuration, iso: idealISO) { [weak self] _ in
                    // Note: KVO for 'iso' should fire and update the delegate/UI separately
                    self?.logger.debug("SP Adjustment Applied: ISO set attempt to \\(String(format: "%.1f", idealISO))")
                }
                self.lastIsoAdjustmentTime = now // Update timestamp only if adjustment was attempted
                currentDevice.unlockForConfiguration()
            } catch {
                self.logger.error("SP Adjust: Error setting custom exposure: \\(error.localizedDescription)")
                // Attempt to unlock configuration if lock failed during change
                 if currentDevice.isLockedForConfiguration {
                    currentDevice.unlockForConfiguration()
                 }
            }
        }
    }
    ```

~~5.  **Implement `enableShutterPriority(duration: CMTime)`:**
    *   Create this new public method:

    ```swift
    func enableShutterPriority(duration: CMTime) {
        guard let device = device else {
            logger.error("SP Enable: No device available.")
            return
        }
        // Prevent re-enabling if already active
        guard !isShutterPriorityActive else {
            logger.warning("SP Enable: Already active.")
            return
        }

        // Clamp the requested duration just in case
        let minDuration = device.activeFormat.minExposureDuration
        let maxDuration = device.activeFormat.maxExposureDuration
        let clampedDuration = CMTimeClampToRange(duration, range: CMTimeRange(start: minDuration, duration: maxDuration - minDuration))

        self.targetShutterDuration = clampedDuration
        self.isShutterPriorityActive = true
        self.logger.info("Enabling Shutter Priority: Duration \\(String(format: "%.5f", CMTimeGetSeconds(clampedDuration)))s")

        // Perform initial mode set on the adjustment queue
        exposureAdjustmentQueue.async { [weak self] in
             guard let self = self, let currentDevice = self.device, self.isShutterPriorityActive else { return } // Re-check state

            let currentISO = currentDevice.iso
            let minISO = currentDevice.activeFormat.minISO
            let maxISO = currentDevice.activeFormat.maxISO
            let clampedISO = min(max(currentISO, minISO), maxISO)

            do {
                try currentDevice.lockForConfiguration()
                // Set the mode to custom with the fixed duration and current ISO
                currentDevice.setExposureModeCustom(duration: clampedDuration, iso: clampedISO) { [weak self] _ in
                    // Report initial values immediately after setting
                     DispatchQueue.main.async {
                         self?.delegate?.didUpdateShutterSpeed(clampedDuration)
                         self?.delegate?.didUpdateISO(clampedISO)
                         self?.logger.info("SP Enabled: Initial ISO set to \\(String(format: "%.1f", clampedISO))")
                     }
                }
                currentDevice.unlockForConfiguration()
            } catch {
                self.logger.error("SP Enable: Error setting initial custom exposure: \\(error.localizedDescription)")
                 if currentDevice.isLockedForConfiguration {
                     currentDevice.unlockForConfiguration()
                 }
                 // Revert state if failed
                 DispatchQueue.main.async {
                     self.isShutterPriorityActive = false
                     self.targetShutterDuration = nil
                     self.delegate?.didEncounterError(.configurationFailed(message: "Failed to enable SP"))
                 }
            }
        }
    }
    ```

6.  **Implement `disableShutterPriority()`:**
    *   Create this new public method:

    ```swift
    func disableShutterPriority() {
        guard isShutterPriorityActive else {
            // logger.debug("SP Disable: Already inactive.")
            return
        }
        guard let device = device else {
            logger.error("SP Disable: No device available.")
            return
        }

        isShutterPriorityActive = false // Set flag immediately to stop adjustments
        targetShutterDuration = nil
        logger.info("Disabling Shutter Priority.")

        // Revert to auto-exposure on the adjustment queue
        exposureAdjustmentQueue.async { [weak self] in
             guard let self = self, let currentDevice = self.device else { return }

            do {
                try currentDevice.lockForConfiguration()
                // Always revert to continuousAutoExposure when SP is turned off
                if currentDevice.isExposureModeSupported(.continuousAutoExposure) {
                    currentDevice.exposureMode = .continuousAutoExposure
                     self.logger.info("SP Disabled: Reverted to Continuous Auto Exposure.")
                    // KVO should automatically report the new auto values
                } else {
                    self.logger.warning("SP Disable: Continuous Auto Exposure not supported, leaving mode as is.")
                }
                currentDevice.unlockForConfiguration()
            } catch {
                self.logger.error("SP Disable: Error reverting to auto exposure: \\(error.localizedDescription)")
                 if currentDevice.isLockedForConfiguration {
                     currentDevice.unlockForConfiguration()
                 }
                 // Should we notify delegate of error?
            }
        }
    }
    ```

7.  **Refine `updateShutterSpeed`/`updateShutterAngle`:**
    *   Modify these methods to *only* set manual exposure if Shutter Priority is *not* currently active. This prevents them from interfering with the SP logic.

    ```swift
    // Inside updateShutterSpeed(_ speed: CMTime)
    // ... (setup, clamping) ...
    do {
        try device.lockForConfiguration()
        // --- Modification Start ---
        if !isShutterPriorityActive {
            // Only set full manual if SP is OFF
            if device.isExposureModeSupported(.custom) {
                device.setExposureModeCustom(duration: clampedSpeed, iso: AVCaptureDevice.currentISO) { [weak self] timestamp in
                    // Report immediately
                    DispatchQueue.main.async {
                        self?.delegate?.didUpdateShutterSpeed(clampedSpeed)
                        // Also report the locked ISO value
                        if let currentISO = self?.device?.iso {
                             self?.delegate?.didUpdateISO(currentISO)
                        }
                        self?.logger.debug("Manual Shutter Set (SP OFF): Speed \\(CMTimeGetSeconds(clampedSpeed))s, ISO locked to current.")
                    }
                }
            } else {
                 logger.warning("Manual Shutter Set (SP OFF): Custom mode not supported.")
            }
        } else {
             // If SP is ON, this method should probably do nothing,
             // or perhaps just update the targetDuration for the SP logic?
             // For now, let's do nothing to avoid conflicts.
             logger.info("updateShutterSpeed called while SP is active. Ignoring.")
        }
        // --- Modification End ---
        device.unlockForConfiguration()
    } catch {
       // ... existing error handling ...
    }

    // Inside updateShutterAngle(_ angle: Double, frameRate: Double)
    // ... (calculations) ...
    // let time = CMTimeMakeWithSeconds(...)
    // logger.debug(...)
    // Update: Only call updateShutterSpeed if SP is NOT active?
    // Or should changing the angle while SP is active *update* the SP target duration?
    // Let's assume changing angle should update the SP target duration.
    if isShutterPriorityActive {
         logger.info("Updating SP target duration due to angle change.")
         // Re-enable SP with the new duration. This will handle the mode setting.
         enableShutterPriority(duration: time)
    } else {
         // If SP is off, proceed with the normal manual shutter speed update.
         updateShutterSpeed(time)
    }
    ```

    *   **Note:** There's a design decision here: should changing the shutter angle/speed slider *while SP is active* update the SP target duration, or should it do nothing? The code above assumes it *should* update the SP target.

## Phase 2: Modifying `CameraViewModel.swift`

1.  **Add State:**
    *   Ensure you have the `@Published var isShutterPriorityEnabled: Bool = false` property.

2.  **Modify `toggleShutterPriority()`:**
    *   Implement the logic to calculate the duration and call the new `ExposureService` methods:

    ```swift
    func toggleShutterPriority() {
        // Ensure frame rate is valid
        guard selectedFrameRate > 0 else {
            logger.error("Cannot toggle Shutter Priority: Invalid frame rate (0).")
            // Optionally show an error to the user
            return
        }

        // Calculate target duration for 180 degrees
        let targetDurationSeconds = 1.0 / (selectedFrameRate * 2.0)
        let targetDuration = CMTimeMakeWithSeconds(targetDurationSeconds, preferredTimescale: 1_000_000) // High precision

        if !isShutterPriorityEnabled {
            logger.info("ViewModel: Enabling Shutter Priority.")
            exposureService.enableShutterPriority(duration: targetDuration)
            isShutterPriorityEnabled = true // Update state AFTER calling service
        } else {
            logger.info("ViewModel: Disabling Shutter Priority.")
            exposureService.disableShutterPriority()
            isShutterPriorityEnabled = false // Update state AFTER calling service
        }
    }
    ```

3.  **Handle Interaction with Recording Lock (Option C Implementation):**
    *   Modify `startRecording` and `stopRecording` to check `isShutterPriorityEnabled`.

    ```swift
    // --- Inside startRecording ---
    if settingsModel.isExposureLockEnabledDuringRecording {
        // Only apply standard lock if Shutter Priority is NOT active
        if !isShutterPriorityEnabled {
            logger.info("Auto-locking exposure for recording start.")
            // Store previous state only if not already custom (or handle custom state)
            // ... (Store previous lock state, likely needs isAutoExposureEnabled check) ...
            storeAndLockExposureForRecording() // Refactor lock logic if needed
        } else {
            logger.info("Shutter Priority active, skipping standard exposure lock during recording.")
        }
        // ... White balance lock logic ...
    }
    // --- Inside stopRecording ---
     // Restore exposure state if it was locked
     if settingsModel.isExposureLockEnabledDuringRecording {
         // Only restore standard lock if Shutter Priority is NOT active
         if !isShutterPriorityEnabled {
             logger.info("Recording stopped: Restoring previous exposure state.")
             restoreExposureAfterRecording() // Refactor unlock logic if needed
         } else {
             logger.info("Shutter Priority active, skipping standard exposure restore after recording.")
         }
         // ... White balance unlock logic ...
     }
    ```
    *   **Note:** You might need to refactor the existing `storeAndLockExposureForRecording()` and `restoreExposureAfterRecording()` logic slightly to handle the `isShutterPriorityEnabled` check cleanly. The key is to *not* call `exposureService.setCustomExposure` or `exposureService.setExposureLock(locked:)` if SP is active during the start/stop recording phase when the "Lock Exposure During Recording" setting is enabled.

## Phase 3: Build & Test

1.  **Build:** Run `xcodebuild` after applying the code changes. Fix any compilation errors.
2.  **Test:**
    *   **Basic SP:** Enable SP. Point the camera at different light levels. Verify the Shutter Speed display remains fixed (e.g., 1/60s for 30fps/180°) while the ISO display changes automatically. Check logs for `SP Adjust` messages and ensure they aren't firing too rapidly or oscillating wildly.
    *   **SP Toggle:** Disable SP. Verify ISO and Shutter return to auto behavior.
    *   **SP + Recording (Lock On):** Enable SP, turn ON "Lock Exposure During Recording". Start recording. Verify shutter remains fixed and ISO *continues to adjust* during recording (per Option C). Stop recording. Verify SP remains active and ISO continues adjusting.
    *   **SP + Recording (Lock Off):** Enable SP, turn OFF "Lock Exposure During Recording". Start recording. Verify shutter remains fixed and ISO continues to adjust during recording. Stop recording. Verify SP remains active.
    *   **Angle Change during SP:** Enable SP. Adjust the shutter angle slider (if implemented). Verify the target shutter speed updates and the ISO continues to adjust around the new fixed shutter speed.
    *   **SP Toggle During Recording:** (Optional) Decide if this should be allowed. If so, test toggling SP on/off during an active recording. Ensure smooth transitions.
    *   **Edge Cases:** Test with very bright and very dark scenes to ensure ISO clamping (`minISO`, `maxISO`) works correctly and doesn't cause crashes. Check behavior when switching cameras while SP is active (it should probably be disabled automatically). 