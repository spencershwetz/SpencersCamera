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