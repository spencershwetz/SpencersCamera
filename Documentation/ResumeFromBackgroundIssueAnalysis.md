# Analysis of Camera Preview Resume Issue

This document summarizes the findings from investigating the issue where the camera preview remains black after the app is resumed, specifically when returning after another application has been opened (as opposed to a simple background/foreground cycle).

## Observed Behavior & Log Analysis

1.  **Scenario:** The issue manifests reliably when switching to another app and then back to Spencer's Camera, resulting in a black preview area. Resuming after only backgrounding the app seems to work correctly.
2.  **`AppLifecycleObserver` Works:** Logs confirm that the `AppLifecycleObserver` correctly detects the app becoming active (`UIApplication.didBecomeActiveNotification`) and triggers the `startSession()` method in `CameraView` via its `didBecomeActivePublisher`.
    ```
    DEBUG: App became active - notification received by AppLifecycleObserver
    DEBUG: Received didBecomeActivePublisher event, calling startSession()
    ```
3.  **Session Fails to Start:** Despite `startSession()` being called, logs show that immediately afterward, the `AVCaptureSession` is not running in the failure case:
    ```
    DEBUG: Camera session running: false 
    ```
    This indicates the call to `session.startRunning()` within `CameraView.startSession()` failed silently or was prevented.
4.  **Critical KVO Error (`ExposureService`):** Repeated log messages indicate a serious issue within the Key-Value Observing (KVO) callback for white balance gains in `ExposureService`:
    ```
    [TEMP DEBUG] WB KVO Callback Entered!
    [TEMP DEBUG] WB KVO: self is nil, exiting callback. 
    ```
    This means the `ExposureService` instance (`self`) has been deallocated *before* the KVO notification handler finishes executing.

## Code Review Findings

1.  **`startSession`/`stopSession` Location:** These methods are implemented directly within `CameraView.swift`, not `CameraViewModel.swift`. They directly call `viewModel.session.startRunning()` and `stopRunning()` on a background queue.
2.  **Missing Interruption Handling:** There are no observers or specific handling logic for critical `AVCaptureSession` notifications like `AVCaptureSessionWasInterruptedNotification`, `AVCaptureSessionInterruptionEndedNotification`, or `AVCaptureSessionRuntimeErrorNotification` in `CameraViewModel` or `CameraView`. Relying only on `didBecomeActive` is likely insufficient, especially when another app takes camera control.
3.  **`ExposureService` KVO Lifecycle:** `ExposureService` uses `[weak self]` correctly in its KVO observation closures and has a `deinit` method that calls `removeDeviceObservers()`. This *should* prevent the `self is nil` issue under normal circumstances.
4.  **Potential Deallocation:** The `self is nil` KVO error strongly suggests that the `ExposureService` instance is being deallocated prematurely. Since `CameraViewModel` holds the primary reference to `ExposureService`, this implies that the `CameraViewModel` itself might also be getting deallocated unexpectedly during the app switching process.

## Hypothesis

When another app takes control of the camera hardware, the `AVCaptureSession` in Spencer's Camera is interrupted more forcefully than a simple backgrounding event. Upon returning:

1.  The `CameraViewModel` and/or its associated `ExposureService` might be prematurely deallocated due to complex interactions within the SwiftUI/UIKit lifecycle during this forceful interruption and resumption.
2.  This premature deallocation causes pending KVO callbacks in `ExposureService` to fail (`self is nil`).
3.  When `CameraView.startSession()` is triggered by `didBecomeActive`, it attempts to call `session.startRunning()`. However, this fails because either:
    *   The session requires explicit handling of the `AVCaptureSessionInterruptionEndedNotification` before it can restart.
    *   The session configuration or associated services (like the potentially deallocated `ExposureService`) are in an invalid state.

The lack of explicit interruption handling combined with the likely premature deallocation of key service objects prevents the session from restarting correctly, resulting in the black preview.

## Next Steps (Revised Plan: Direct Fix)

Based on the analysis, the most probable causes are the lack of explicit interruption handling and the decentralized session start/stop logic. The following steps will be taken to address the issue directly:

1.  **Centralize Session Control in `CameraViewModel`:**
    *   Create `startSession()` and `stopSession()` methods within `CameraViewModel.swift`.
    *   Move the logic for calling `session.startRunning()` and `session.stopRunning()` into these ViewModel methods.
    *   These methods will manage the `isSessionRunning` state and handle potential errors.
2.  **Add Interruption Handling in `CameraViewModel`:**
    *   Add notification observers for `AVCaptureSessionWasInterruptedNotification` and `AVCaptureSessionInterruptionEndedNotification`.
    *   Implement logic to handle these notifications: stop session on interruption (if needed), and attempt to restart the session *only* after receiving the `interruptionEnded` notification (especially for interruptions caused by other apps).
    *   Add an observer for `AVCaptureSessionRuntimeErrorNotification` to log critical errors.
3.  **Use Dedicated Serial Queue:**
    *   Create a private serial `DispatchQueue` in `CameraViewModel` for all `AVCaptureSession` operations (`startRunning`, `stopRunning`, configuration changes).
4.  **Update `CameraView`:**
    *   Modify `CameraView.swift` to remove its local `startSession` and `stopSession` methods.
    *   Update `onAppear`, `onDisappear`, and the `.onReceive` blocks to call `viewModel.startSession()` and `viewModel.stopSession()` as appropriate. 