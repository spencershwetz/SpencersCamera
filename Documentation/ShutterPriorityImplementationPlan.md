# Shutter Priority Implementation Plan (Strategy 1)

This document outlines the steps to implement a custom Shutter Priority (SP) mode where the ISO automatically adjusts while the shutter speed remains fixed. This uses Strategy 1: Continuous Custom Exposure Monitoring & Adjustment.

**Core Idea:**

1.  Fix the shutter speed using `.custom` exposure mode.
2.  Monitor the `exposureTargetOffset` using KVO. This tells us how far the current exposure (fixed shutter, current ISO) is from the camera's ideal exposure.
3.  If the offset is significant, calculate a new target ISO to counteract the offset.
4.  Apply the new ISO (keeping the shutter fixed) using `setExposureModeCustom`.
5.  Use thresholds and rate-limiting to prevent unstable oscillations.
6.  Implement logic to temporarily pause auto-ISO adjustments during recording if the "Lock Exposure During Recording" setting is enabled.

---

## Phase 1: Modifying `ExposureService.swift` (KVO & Base Logic)

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

~~6.  **Implement `disableShutterPriority()`:~~
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

~~7.  **Refine `updateShutterSpeed`/`updateShutterAngle`:**~~
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
                 logger.warning("Custom exposure mode not supported.")
            }
        } else {
             logger.info("Manual shutter update ignored because Shutter Priority is active.")
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

## Phase 2: Modifying `CameraViewModel.swift` (Basic Toggle)

~~1.  **Add State:**~~
    *   Ensure you have the `@Published var isShutterPriorityEnabled: Bool = false` property.

~~2.  **Modify `toggleShutterPriority()`:**~~
    *   Implement the logic to calculate the 180° duration and call `ExposureService.enable/disableShutterPriority()`.

## Phase 3: Implementing Recording Lock for SP

~~1.  **Add Recording Lock State to `ExposureService`:**~~
    *   Add `private var isTemporarilyLockedForRecording: Bool = false`.

~~2.  **Implement Lock/Unlock Methods in `ExposureService`:**~~
    *   `lockShutterPriorityExposureForRecording()`: Sets mode to `.custom` with current SP duration/ISO and sets `isTemporarilyLockedForRecording = true`.
    *   `unlockShutterPriorityExposureAfterRecording()`: Sets `isTemporarilyLockedForRecording = false`.

~~3.  **Update `handleExposureTargetOffsetUpdate`:**~~
    *   Add a guard at the beginning to return if `isTemporarilyLockedForRecording` is `true`.

~~4.  **Update `enableShutterPriority`/`disableShutterPriority`:**~~
    *   Ensure `isTemporarilyLockedForRecording` is reset to `false` when SP is enabled or disabled.

~~5.  **Update `CameraViewModel.startRecording`:**~~
    *   Inside the `if settingsModel.isExposureLockEnabledDuringRecording` block, add a check for `isShutterPriorityEnabled`.
    *   If SP is enabled, call `exposureService.lockShutterPriorityExposureForRecording()` instead of the standard AE lock logic.

~~6.  **Update `CameraViewModel.stopRecording`:**~~
    *   Inside the restore logic (if `settingsModel.isExposureLockEnabledDuringRecording` was true), add a check for `isShutterPriorityEnabled`.
    *   If SP was enabled, call `exposureService.unlockShutterPriorityExposureAfterRecording()` instead of the standard AE restore logic.

## Phase 4: Decoupling UI Lock State from SP Lock

~~1.  **Modify `CameraViewModel.startRecording`:**~~
    *   When SP is active and lock-during-recording is enabled, **remove** the line `self.isExposureLocked = false` after calling `exposureService.lockShutterPriorityExposureForRecording()`.

~~2.  **Modify `CameraViewModel.stopRecording`:**~~
    *   When restoring state after recording with SP active and lock-during-recording enabled, **remove** the line `self.isExposureLocked = false` after calling `exposureService.unlockShutterPriorityExposureAfterRecording()`.

~~3.  **Modify `CameraViewModel.toggleExposureLock`:**~~
    *   Add a guard at the beginning to prevent toggling the standard AE lock if `isShutterPriorityEnabled` is true.

~~4.  **Modify `CameraViewModel.toggleShutterPriority`:**~~
    *   When enabling SP (`if !isShutterPriorityEnabled`), add logic to explicitly set `self.isExposureLocked = false` to ensure the standard AE lock UI turns off.

## Phase 5: Build & Test

1.  **Build:** Run `xcodebuild` after applying the code changes. Fix any compilation errors. (Successfully built after Phase 4). 
2.  **Test:**
    *   **Basic SP:** (Passed) Enable SP. Point camera at different light levels. Shutter Speed remains fixed, ISO adjusts automatically.
    *   **SP Toggle:** (Passed) Disable SP. Exposure returns to auto.
    *   **SP + Recording (Lock On):** (Passed) Enable SP, turn ON "Lock Exposure During Recording". Start recording. Verify shutter remains fixed and ISO **remains locked** during recording. Stop recording. Verify SP remains active and ISO resumes adjusting automatically.
    *   **SP + Recording (Lock Off):** (Passed) Enable SP, turn OFF "Lock Exposure During Recording". Start recording. Verify shutter remains fixed and ISO *continues to adjust* during recording. Stop recording. Verify SP remains active.
    *   **Standard Lock + Recording (Lock On):** (Passed - Existing) Disable SP, turn ON "Lock Exposure During Recording". Tap AE Lock button. Start recording. Verify exposure remains locked. Stop recording. Verify AE lock remains active.
    *   **Angle Change during SP:** (Passed) Enable SP. Adjust shutter angle slider. Verify target shutter speed updates and ISO continues to adjust.
    *   **Edge Cases:** (Passed) Test with very bright/dark scenes. ISO clamps correctly.
    *   **Interaction with Standard AE Lock:** (Passed) Ensure enabling SP disables the standard AE Lock button/state, and toggling standard AE Lock is prevented while SP is active. 