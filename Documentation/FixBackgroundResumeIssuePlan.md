# Plan to Fix Background Resume Issue

This plan addresses the issue where the camera session sometimes fails to restart correctly after the app resumes from the background, likely due to unnecessary KVO observer churn in `ExposureService`.

## Steps

1.  **Modify `ExposureService.setDevice()`:**
    *   **Goal:** Prevent the removal and re-adding of Key-Value Observers (KVO) if the `AVCaptureDevice` instance being passed in is the *same* as the one already configured in the service.
    *   **Action:** In `iPhoneApp/Features/Camera/Services/ExposureService.swift`, within the `setDevice(_:)` function, add a check at the beginning. If the incoming `device` parameter is identical (`===`) to the existing `self.device` and `self.device` is not `nil`, log a message indicating that the observers are being kept and return early from the function. Otherwise, proceed with the current logic (remove old observers, store the new device, add new observers).

2.  **Review `CameraViewModel.startSession()`:**
    *   **Goal:** Ensure `exposureService.setDevice()` is still called appropriately after the session starts successfully, allowing the (now smarter) `setDevice` method to decide whether to update observers.
    *   **Action:** Briefly review the logic in `iPhoneApp/Features/Camera/CameraViewModel.swift` within the `startSession()` method (around lines 1190-1220). Confirm that `self.exposureService.setDevice(currentDevice)` is called *after* the session is confirmed to be running (`sessionSuccessfullyStarted` is true) and also in the `else` block where the session was already running. No code changes are expected here, just verification.

3.  **Build and Test:**
    *   **Action:**
        *   Perform a clean build of the project.
        *   Run the application.
        *   Repeatedly background and foreground the app.
        *   Monitor the console logs to verify that the "Removing KVO observers" and "Setting up KVO observers" messages *do not* appear every time the app resumes, but *do* appear on initial launch or if the camera device genuinely changes (e.g., lens switch).
        *   Confirm the `-11872` error no longer occurs frequently upon resuming.
        *   Run tests using `xcodebuild test ... | xcpretty`.

4.  **Update Documentation:**
    *   **Goal:** Reflect the optimized observer handling.
    *   **Action:** Briefly update `Documentation/TechnicalSpecification.md` and potentially `Documentation/Architecture.md` to mention that `ExposureService.setDevice` now intelligently avoids unnecessary KVO observer reconfiguration if the device instance hasn't changed. 