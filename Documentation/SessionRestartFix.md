# Fixing the Session Start Failure After Multiple Background/Foreground Cycles

## Problem Description

The application experienced an issue where the `AVCaptureSession` would fail to start correctly after being stopped and started multiple times, typically triggered by putting the app into the background and bringing it back to the foreground repeatedly.

1.  **Initial State:** App launches, camera starts fine.
2.  **Cycle 1 (BG -> FG):** App goes to background, session stops. App returns to foreground, session restarts successfully.
3.  **Cycle 2 (BG -> FG):** App goes to background, session stops. App returns to foreground, session restarts successfully (sometimes showing a brief black preview first).
4.  **Cycle 3 (BG -> FG):** App goes to background, session stops. App returns to foreground, attempts to restart session.
    *   **Failure:** The `session.startRunning()` call would complete without throwing an immediate error.
    *   **Symptom:** Checking `session.isRunning` *immediately* after the `startRunning()` call returned `false`.
    *   **Error:** Eventually, an asynchronous `AVCaptureSessionRuntimeError` notification was observed with `AVError.Code -11872` (Cannot Record / OutOfMemory), indicating "Too many camera hardware resources were requested."

This indicated that resources were not being properly released during the stop/background cycle, leading to cumulative pressure and eventual failure when trying to reacquire them.

## Solution: Explicit Teardown and Reconfiguration

The fix involved ensuring a more robust teardown and setup cycle for the `AVCaptureSession` components, specifically the inputs and outputs:

1.  **Explicit Teardown (`CameraViewModel.stopSession`):
    *   Before calling `session.stopRunning()`, all existing inputs (`session.inputs`) and outputs (`session.outputs`) are explicitly removed from the session using `session.removeInput(_:)` and `session.removeOutput(_:)`.
    *   This forces AVFoundation to release the hardware resources associated with those inputs/outputs more reliably than relying solely on `stopRunning()`.

2.  **Full Reconfiguration (`CameraViewModel.startSession`):
    *   Since inputs/outputs are now removed on stop, they must be re-added on start.
    *   Before calling `session.startRunning()`, the `startSession` method now performs a full reconfiguration within a `session.beginConfiguration() / session.commitConfiguration()` block.
    *   It calls `CameraSetupService.reconfigureSession()`. This internal helper method:
        *   Re-adds the necessary `AVCaptureDeviceInput` (video, audio).
        *   Calls `RecordingService.ensureOutputsAreAdded()`.
    *   `RecordingService.ensureOutputsAreAdded()`:
        *   This new method checks if the `AVCaptureVideoDataOutput` and `AVCaptureAudioDataOutput` (managed by `RecordingService`) are currently attached to the session.
        *   If an output is missing, it re-adds it to the session.
    *   Only after this full reconfiguration succeeds does `startSession` proceed to the pre-start device checks and the final `session.startRunning()` call.

## Summary

By explicitly removing inputs *and* outputs when stopping the session and explicitly re-adding inputs *and ensuring* outputs are re-added before starting, we guarantee a cleaner state transition. This prevents the accumulation of resource demands that previously led to the `-11872` runtime error and session start failure after multiple background/foreground cycles. 

## Additional Recovery Mechanism: Manual Reboot

While the explicit teardown/reconfiguration significantly reduces the occurrence of session start failures, unrecoverable errors like `-11872` or media service resets (`.mediaServicesWereReset`) can potentially still occur under high system pressure or other edge cases.

To provide a user-initiated recovery path for these situations:

1.  **Error Detection (`CameraViewModel.sessionRuntimeError`):
    *   The runtime error handler now specifically detects `AVError.Code -11872` and `.mediaServicesWereReset`.
    *   When detected, these errors (along with other critical session start failures) are mapped to a new specific error case: `CameraError.cameraSystemError`.
    *   This error is published via the `viewModel.error` property.

2.  **UI Feedback (`CameraView`):
    *   `CameraView` observes `viewModel.error`.
    *   When `viewModel.error == .cameraSystemError`, a modal overlay is presented to the user.
    *   This overlay explains that a system error occurred and provides a \"Restart Camera\" button, while disabling other camera controls.

3.  **Reboot Action (`CameraViewModel.rebootCamera`):
    *   Tapping the \"Restart Camera\" button calls the `viewModel.rebootCamera()` function.
    *   This function performs a controlled restart sequence:
        *   Calls `stopSession()` to ensure the session is fully stopped (if it wasn't already).
        *   Clears the `.cameraSystemError` from the `viewModel.error` state.
        *   Waits for a short duration (e.g., 0.75 seconds) to allow system resources to settle.
        *   Calls `startSession()` to attempt a fresh start of the camera system.

This manual reboot mechanism acts as a final fallback, allowing the user to attempt recovery from severe system-level camera errors without needing to force-quit the application. 