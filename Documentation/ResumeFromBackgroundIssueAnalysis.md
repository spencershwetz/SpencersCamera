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

## Current State & Hypothesis

Despite centralizing session control and adding interruption handlers, the black preview issue persists when returning to the app after another app has used the camera. Logs indicate:

1.  `CameraViewModel.startSession()` is called upon becoming active.
2.  The session *appears* to start (`Session started successfully: true`).
3.  **Crucially**, KVO errors related to `ExposureService` (`[TEMP DEBUG] WB KVO: self is nil, exiting callback.`) occur *after* the session supposedly restarts.
4.  `AVCaptureSessionRuntimeErrorNotification` is received shortly after the restart attempt.
5.  The `MTKView` fails to draw (`No valid textures available`).

Hypothesis: The core issue lies in the state management of `AVCaptureSession` and associated components (`ExposureService` KVO observers) during interruptions and restarts. The KVO observers might not be properly removed or re-added, or the session itself enters an unrecoverable state that isn't fixed by a simple `startRunning()` call, leading to immediate runtime errors.

## Implemented Refinements (Session Handling & Cleanup)

To address potential cleanup issues and problematic restarts:

1.  **Added `deinit` to `CameraViewModel`**: Implemented a `deinit` method in `CameraViewModel` to ensure:
    *   All registered `NotificationCenter` observers are removed.
    *   The `AVCaptureSession` is stopped if it's still running.
    *   `exposureService.removeDeviceObservers()` is called as a safeguard (though primary cleanup should be in `ExposureService` itself).
    *   The `WCSession` delegate is cleared.
2.  **Refined `sessionRuntimeError` Handler**: Modified the handler for `AVCaptureSessionRuntimeErrorNotification`:
    *   It now logs the specific `AVError`.
    *   For generic runtime errors (excluding `.mediaServicesWereReset`), it **no longer attempts an immediate `startSession()`**. Instead, it logs the error, sets `isSessionRunning = false`, and updates the `status` to `.failed`. Recovery is now expected to happen via app lifecycle events (e.g., the next `didBecomeActive` trigger) or explicit user action, preventing potential restart loops on a faulty session state.
    *   The specific handling for `.mediaServicesWereReset` remains, as it requires a different recovery path.

## Next Steps & Investigation

While the above refinements improve robustness, the persistent KVO error points towards `ExposureService`:

1.  **Verify `ExposureService` Cleanup**: Ensure `ExposureService` has its own robust `deinit` method that calls `removeDeviceObservers()`.
2.  **Explicit Observer Removal on Stop**: Modify `CameraViewModel.stopSession()` to explicitly call `exposureService.removeDeviceObservers()` *before* `session.stopRunning()` is invoked on the `sessionQueue`. This guarantees observers are removed before the session stops and potentially invalidates device state.
3.  **Analyze KVO Callback**: Add more logging within the `ExposureService` KVO observation callback (`observeValue(forKeyPath:of:change:context:)`) to understand its state (`self` validity, `device` validity) when the callback is invoked, especially after resuming the app.
4.  **Consider Full Session Rebuild**: If runtime errors persist after restarts, explore a more drastic recovery in the runtime error handler or upon `didBecomeActive`: fully tearing down the session (removing inputs/outputs) and rebuilding it using `setupSession()` before starting.

## Next Steps (Revised Plan: Direct Fix)

Based on the analysis, the most probable causes are the lack of explicit interruption handling and the decentralized session start/stop logic. The following steps **have been** taken to address the issue directly:

1.  **Centralize Session Control in `CameraViewModel`:**
    *   Confirmed `startSession()` and `stopSession()` methods within `CameraViewModel.swift`.
    *   Confirmed the logic for calling `session.startRunning()` and `session.stopRunning()` into these ViewModel methods.
    *   Confirmed these methods manage the `isSessionRunning` state and handle potential errors.
2.  **Add Interruption Handling in `CameraViewModel`:**
    *   Confirmed notification observers for `AVCaptureSessionWasInterruptedNotification`, `AVCaptureSessionInterruptionEndedNotification`, and `AVCaptureSessionRuntimeErrorNotification`.
    *   Modified logic to handle these notifications: 
        *   Session is stopped implicitly by the interruption or explicitly in the handler if needed.
        *   **Critically:** The session restart is now explicitly triggered by calling `startSession()` within the `sessionInterruptionEnded` handler, ensuring it happens after the system interruption is fully resolved.
    *   Confirmed observer for `AVCaptureSessionRuntimeErrorNotification` logs critical errors.
3.  **Use Dedicated Serial Queue:**
    *   Confirmed a private serial `DispatchQueue` (`sessionQueue`) in `CameraViewModel` is used for all `AVCaptureSession` operations (`startRunning`, `stopRunning`, configuration changes).
4.  **Update `CameraView`:**
    *   Removed the local `startSession` and `stopSession` methods from `CameraView.swift`.
    *   Updated `onAppear`, `onDisappear`, and the `.onReceive` blocks (for `willResignActive` and `didBecomeActive`) to call `viewModel.startSession()` and `viewModel.stopSession()` as appropriate. (Note: `didBecomeActive` trigger was temporarily removed but reinstated based on further testing).

This centralized approach, combined with triggers on `onAppear`, `sessionInterruptionEnded`, and `didBecomeActive`, aims to ensure the session is correctly started/restarted in various lifecycle scenarios, including resuming after interruptions caused by other apps.

### Current Implementation and Fixes

1.  **Centralized Session Control:** Introduced `CameraViewModel` to manage the `AVCaptureSession` lifecycle.
    *   `startSession()` and `stopSession()` methods control session start/stop on a dedicated serial queue (`sessionQueue`).
    *   `isSessionRunning` (a `@Published` property) tracks the session state.
2.  **Interruption Handling:** Added observers for `AVCaptureSessionWasInterruptedNotification`, `AVCaptureSessionInterruptionEndedNotification`, and `AVCaptureSessionRuntimeErrorNotification`.
    *   **Interruption Started:** Calls `stopSession()` when an interruption begins (e.g., another app uses the camera).
    *   **Interruption Ended:** Calls `startSession()` when the interruption ends.
    *   **Runtime Error:** Logs the specific error (both `AVError` and generic `NSError` types). **Crucially, it no longer attempts an immediate session restart within the error handler.** Instead, it updates the state to `.failed` and relies on app lifecycle events (like returning to the foreground/becoming active) or manual reconfiguration to attempt recovery. This prevents potential restart loops or starting the session in an invalid state.
3.  **Dedicated Session Queue:** All interactions with `AVCaptureSession` methods (`startRunning`, `stopRunning`, configuration changes) are dispatched to `sessionQueue` to prevent deadlocks and ensure thread safety.
4.  **View Lifecycle Integration:** `CameraView.swift`'s `onAppear`, `onDisappear`, and `.onReceive(scenePhase)` modifiers now correctly call `viewModel.startSession()` and `viewModel.stopSession()`, delegating control to the view model.
5.  **Foreground/Background Handling:** Added observation of `UIApplication.didBecomeActiveNotification` and `UIApplication.willResignActiveNotification` to trigger `startSession()` and `stopSession()` respectively, ensuring the session state aligns with the app's active status. 