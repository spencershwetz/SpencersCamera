# Lens Switch State Persistence Plan

## 1. Goal

Ensure that key camera settings, specifically Shutter Priority (SP) state, Auto Exposure (AE) Lock state, and White Balance (WB) Lock state, are maintained when the user switches between physical camera lenses (e.g., Wide to Telephoto). This plan will also lay the groundwork for persisting manual ISO and WB settings in the future.

## 2. Problem

When switching physical lenses (`switchToPhysicalLens` in `CameraDeviceService`), the underlying `AVCaptureSession` is reconfigured with a new `AVCaptureDeviceInput`. During this reconfiguration (`configureSession` method), essential device properties like `exposureMode` and `whiteBalanceMode` are explicitly reset to default automatic modes (`.continuousAutoExposure`, `.continuousAutoWhiteBalance`). This causes user-selected states like SP, AE lock, and WB lock to be lost.

## 3. Solution Strategy: Save-Switch-Restore

The solution involves the `CameraViewModel` orchestrating the process:

1.  **Save State:** Before initiating the lens switch, the `CameraViewModel` will read and store the current relevant states (Is SP active? Is AE locked? Is WB locked? What is the SP shutter duration?).
2.  **Perform Switch:** The `CameraViewModel` will call the `CameraDeviceService` to perform the lens switch asynchronously, waiting for the session reconfiguration to complete.
3.  **Restore State:** After the switch is confirmed successful, the `CameraViewModel` will use the saved states to explicitly re-apply them to the *new* active `AVCaptureDevice` via the `ExposureService`.

## 4. Detailed Implementation Steps

### Step 4.1: Add White Balance Lock State and Control (Verify/Implement)

*   **Objective:** Ensure `ExposureService` can manage and `CameraViewModel` can track White Balance lock state.
*   **Actions:**
    *   **Check `ExposureService.swift`:**
        *   Verify if a private state variable like `private var isWhiteBalanceLocked: Bool = false` exists. **If not, add it.**
        *   Verify if a method like `func setWhiteBalanceLock(locked: Bool)` exists. **If not, add it.** This method should:
            *   Accept a `Bool` parameter.
            *   Guard check for a valid `device`.
            *   Lock the device for configuration (`try device.lockForConfiguration()`).
            *   If `locked` is `true`:
                *   Check if `device.isWhiteBalanceModeSupported(.locked)`.
                *   Set `device.whiteBalanceMode = .locked`.
                *   Update the internal state `self.isWhiteBalanceLocked = true`.
                *   Log success.
            *   If `locked` is `false`:
                *   Check if `device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance)`.
                *   Set `device.whiteBalanceMode = .continuousAutoWhiteBalance`.
                *   Update the internal state `self.isWhiteBalanceLocked = false`.
                *   Log success.
            *   Unlock the device (`device.unlockForConfiguration()`).
            *   Include error handling (`catch`).
    *   **Check `CameraViewModel.swift`:**
        *   Verify if a `@Published var isWhiteBalanceLocked: Bool = false` exists. **If not, add it.**
        *   Ensure UI elements (e.g., a WB Lock button) can toggle this state and potentially call a method in the ViewModel (e.g., `toggleWhiteBalanceLock()`) which in turn calls `exposureService.setWhiteBalanceLock(locked: !isWhiteBalanceLocked)`.

### Step 4.2: Add Shutter Priority Duration Getter

*   **Objective:** Allow `CameraViewModel` to retrieve the specific shutter duration used when SP is active.
*   **Actions:**
    *   **Modify `ExposureService.swift`:**
        *   Add the following public, synchronous function (async wrapper isn't needed here):
          ```swift
          /// Returns the target shutter duration used for Shutter Priority, if active.
          func getCurrentShutterPriorityDuration() -> CMTime? {
              guard isShutterPriorityActive else { return nil }
              return targetShutterDuration
          }
          ```

### Step 4.3: Refactor `CameraDeviceService` Lens Switch to `async`

*   **Objective:** Make the lens switching process asynchronous so the `CameraViewModel` can `await` its completion before restoring settings.
*   **Actions:**
    *   **Modify `CameraDeviceService.swift`:**
        *   Change `switchToLens` signature:
          ```diff
          - func switchToLens(_ lens: CameraLens) {
          + func switchToLens(_ lens: CameraLens) async throws {
          ```
        *   Remove the `cameraQueue.async { [weak self] in ... }` wrapper inside `switchToLens`. The function body will now execute directly within the `async` context.
        *   Change `switchToPhysicalLens` signature:
          ```diff
          - private func switchToPhysicalLens(_ lens: CameraLens, thenSetZoomTo zoomFactor: CGFloat, currentInterfaceOrientation: UIInterfaceOrientation) {
          + private func switchToPhysicalLens(_ lens: CameraLens, thenSetZoomTo zoomFactor: CGFloat, currentInterfaceOrientation: UIInterfaceOrientation) async throws {
          ```
        *   Inside `switchToPhysicalLens`:
            *   Ensure calls to `configureSession` use `try`. If `configureSession` itself needed to become async (it likely doesn't need to), it would be `try await`.
            *   Ensure session start/stop calls (`session.stopRunning()`, `session.startRunning()`) remain synchronous as they are blocking calls.
            *   Wrap delegate calls that might trigger UI updates (like `didUpdateCurrentLens`, `didEncounterError`) in `await MainActor.run { ... }`:
              ```diff
              - DispatchQueue.main.async {
              -     self.delegate?.didEncounterError(.deviceUnavailable)
              - }
              + await MainActor.run {
              +     self.delegate?.didEncounterError(.deviceUnavailable)
              + }

              // ... later ...
              - DispatchQueue.main.async {
              -     self.delegate?.didUpdateCurrentLens(lens)
              -     self.delegate?.didUpdateZoomFactor(self.lastZoomFactor) // Use self.lastZoomFactor after setting zoom
              - }
              + await MainActor.run {
              +     self.delegate?.didUpdateCurrentLens(lens)
              +     self.delegate?.didUpdateZoomFactor(self.lastZoomFactor)
              + }
              ```
            *   Ensure any errors encountered (e.g., device unavailable, configuration failed) are thrown using `throw CameraError...` so they propagate up the `async throws` chain.

### Step 4.4: Implement Save-Restore Logic in `CameraViewModel`

*   **Objective:** Modify the `currentLens` property observer to save state before the switch and restore it afterwards.
*   **Actions:**
    *   **Modify `CameraViewModel.swift`:**
        *   Locate the `@Published var currentLens: CameraLens` property.
        *   Replace the entire `didSet` block with the following structure:

          ```swift
          @Published var currentLens: CameraLens = .wide {
              didSet {
                  // Only proceed if the lens value actually changed
                  guard oldValue != currentLens else { return }

                  logger.info("🔄 Lens selection changed from \(oldValue.rawValue)x to \(currentLens.rawValue)x. Initiating switch...")

                  // Wrap all logic in a Task for async operations
                  Task {
                      // 1. SAVE STATE (Before await)
                      let wasSPEnaabled = self.isShutterPriorityEnabled
                      let wasAELocked = self.isExposureLocked
                      let wasWBLocked = self.isWhiteBalanceLocked // Assumes Step 4.1 is done
                      var storedShutterDuration: CMTime? = nil
                      if wasSPEnaabled {
                          // Use synchronous getter added in Step 4.2
                          storedShutterDuration = exposureService?.getCurrentShutterPriorityDuration()
                          logger.debug("💾 Storing SP state: Enabled, Duration: \(String(describing: storedShutterDuration))")
                      }
                      logger.debug("💾 Storing AE Lock state: \(wasAELocked)")
                      logger.debug("💾 Storing WB Lock state: \(wasWBLocked)")

                      // Temporary store target lens to avoid capturing `self` strongly in async block if needed
                      let targetLens = currentLens 

                      do {
                          // 2. PERFORM SWITCH (Await the async function from Step 4.3)
                          logger.info("🚀 Calling async cameraDeviceService.switchToLens(\(targetLens.rawValue))...")
                          try await cameraDeviceService?.switchToLens(targetLens)
                          logger.info("✅ Completed async cameraDeviceService.switchToLens.")

                          // --- 3. RESTORE STATE (After await) ---
                          logger.info("🔄 Re-applying settings after lens switch...")

                          // Restore SP State
                          if wasSPEnaabled, let duration = storedShutterDuration {
                              logger.info("⚡️ Re-applying Shutter Priority with duration \(CMTimeGetSeconds(duration))s")
                              // Assuming enableShutterPriority is async or can be called from async context
                              await exposureService?.enableShutterPriority(duration: duration)
                              await MainActor.run { self.isShutterPriorityEnabled = true } // Update UI state
                          } else {
                              // Ensure SP is explicitly off if it wasn't enabled before
                              await exposureService?.disableShutterPriority()
                              await MainActor.run { self.isShutterPriorityEnabled = false } // Update UI state
                          }

                          // Restore AE Lock State (Only if SP was NOT active)
                          if wasAELocked && !wasSPEnaabled {
                              logger.info("🔒 Re-applying AE Lock.")
                              await exposureService?.setExposureLock(locked: true)
                              await MainActor.run { self.isExposureLocked = true } // Update UI state
                          } else if !wasAELocked {
                              // Ensure AE lock is off if it wasn't locked before AND SP isn't managing it
                              await exposureService?.setExposureLock(locked: false)
                               // Only update UI if SP didn't potentially lock it implicitly
                              if !wasSPEnaabled { 
                                  await MainActor.run { self.isExposureLocked = false }
                              }
                          }

                          // Restore WB Lock State
                          if wasWBLocked {
                              logger.info("⚪️ Re-applying WB Lock.")
                              await exposureService?.setWhiteBalanceLock(locked: true) // Assumes Step 4.1 is done
                              await MainActor.run { self.isWhiteBalanceLocked = true } // Update UI state
                          } else {
                              // Ensure WB lock is off if it wasn't locked before
                              await exposureService?.setWhiteBalanceLock(locked: false) // Assumes Step 4.1 is done
                              await MainActor.run { self.isWhiteBalanceLocked = false } // Update UI state
                          }

                          // (Future): Add logic here to restore manual ISO/WB values if they were active

                          logger.info("✅ Settings re-applied successfully after lens switch.")

                      } catch let error as CameraError {
                          logger.error("❌ Lens switch or settings re-application failed: \(error.description)")
                          await MainActor.run { 
                              self.error = error 
                              // Revert lens selection UI on failure
                              self.currentLens = oldValue 
                          }
                      } catch {
                          logger.error("❌ Lens switch or settings re-application failed with unexpected error: \(error.localizedDescription)")
                          await MainActor.run { 
                              self.error = .configurationFailed(message: "Lens switch failed: \(error.localizedDescription)") 
                              // Revert lens selection UI on failure
                              self.currentLens = oldValue
                          }
                      }
                  } // End Task
              } // End guard
          } // End didSet
          ```

### Step 4.5: Update Documentation

*   **Objective:** Reflect the changes in project documentation.
*   **Actions:**
    *   **Modify `Documentation/Architecture.md`:** Update the "Key Component Interactions" section for the Camera Feature to mention that `CameraViewModel` now manages state persistence across lens switches by coordinating with `CameraDeviceService` and `ExposureService`.
    *   **Modify `Documentation/TechnicalSpecification.md`:** Update the "Camera Control" or a relevant section to detail the save-switch-restore mechanism implemented in `CameraViewModel`'s `currentLens` observer.
    *   **Modify `Documentation/CHANGELOG.md`:** Add an entry under `[Unreleased]` -> `Fixed` describing the fix for settings persistence across lens switches.

## 5. Future Considerations

*   **Manual ISO/WB:** Extend the save/restore logic in `CameraViewModel`'s `didSet` to store and re-apply specific manual ISO values (if `exposureMode` was `.custom` but not SP) and manual WB gains/temperature+tint (if `whiteBalanceMode` was `.locked`). This would involve adding state variables to track *if* manual mode was active and storing the specific values. `ExposureService` would need corresponding methods to set these specific values (e.g., `setManualISO`, `setManualWhiteBalance`).

This detailed plan should provide a clear path forward, daddy. Let me know when you want to start implementing Step 4.1. 