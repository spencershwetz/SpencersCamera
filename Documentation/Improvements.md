# Potential Codebase Improvements

This document outlines potential areas for improvement in the Spencer's Camera codebase, ordered by perceived importance based on robustness, correctness, performance, and maintainability.

1.  **Preview Orientation Setting Verification**
    *   **Goal**: Ensure the hardcoded `videoRotationAngle = 0` for the preview connection is always correct, or implement dynamic setting based on buffer/device properties.
    *   **Why**: Ensures the live preview orientation is consistently correct regardless of underlying buffer orientation changes.
    *   **Connection Points**:
        *   `CameraViewModel.swift`: Primarily within the `setupUnifiedVideoOutput()` method where the `AVCaptureConnection.videoRotationAngle` is currently set.
        *   Might require querying device/format properties or buffer attachments within `setupUnifiedVideoOutput()` or the `captureOutput` delegate method.

2.  **Recording Orientation Robustness (Fallback)**
    *   **Goal**: Improve the fallback logic for determining recording orientation when the device is face-up or face-down.
    *   **Why**: Relying solely on interface orientation as a fallback might not accurately reflect user intent, potentially leading to incorrectly rotated recordings in ambiguous situations.
    *   **Connection Points**:
        *   `RecordingService.swift`: Modify the orientation calculation logic within `startRecording()`.
        *   **(New)** Potentially introduce a `CoreMotionService` to get gravity data as a fallback.
        *   Project Settings: Add `CoreMotion.framework`.
        *   `CameraViewModel.swift`: May need to manage/provide the `CoreMotionService` if implemented.

3.  **Metal Shader Precision (`applyLUTComputeYUV`)**
    *   **Goal**: Refine the YUV compute kernel to explicitly handle chroma subsampling differences between 4:2:2 and 4:2:0 formats.
    *   **Why**: Improves the correctness of LUT application during bake-in for different YUV pixel formats.
    *   **Connection Points**:
        *   `PreviewShaders.metal`: Update the `applyLUTComputeYUV` kernel logic for chroma coordinate calculation (`cbcr_gid`).
        *   `MetalFrameProcessor.swift`: May need modification in `processFrame()` to pass a flag or enum indicating the specific YUV format to the shader via a buffer.

4.  **Asynchronous Metal Processing**
    *   **Goal**: Change `MetalFrameProcessor` to process frames asynchronously instead of using `commandBuffer.waitUntilCompleted()`.
    *   **Why**: Could improve performance and reduce potential blocking on the `RecordingService`'s processing queue, especially with complex LUTs or high frame rates/resolutions.
    *   **Connection Points**:
        *   `MetalFrameProcessor.swift`: Refactor `processFrame()` to use completion handlers, Combine publishers, or async/await with Metal's event/listener mechanisms.
        *   `RecordingService.swift`: Update the `captureOutput` delegate method (video handling) to manage the asynchronous processing results and buffer lifecycle correctly.

5.  **Error Handling Details**
    *   **Goal**: Map more specific framework errors (e.g., `AVError`, `MTLError`, `POSIXError`) to the custom `CameraError` enum.
    *   **Why**: Provides more informative error messages for debugging and potentially allows for more specific error recovery logic.
    *   **Connection Points**:
        *   Various Services (`catch` blocks): Update error catching to identify specific framework error types/codes.
        *   `CameraError.swift`: Add new cases or associated values to the enum.
        *   `CameraViewModel.swift`: Update `didEncounterError` if necessary, and potentially UI-facing alert presentation.

6.  **Dependency Management (DI)**
    *   **Goal**: Implement a more formal dependency injection pattern for creating and providing services to `CameraViewModel`.
    *   **Why**: Improves testability (allowing mock services) and modularity.
    *   **Connection Points**:
        *   `CameraViewModel.swift`: Modify `init` to receive service instances as parameters instead of creating them internally. Remove internal `setupServices()`.
        *   `cameraApp.swift`: Update the creation point of `CameraViewModel` to instantiate and inject the required services.
        *   **(Optional)** Introduce a simple DI container class.

7.  **Configuration/Tuning Parameters**
    *   **Goal**: Move hardcoded tuning parameters (e.g., Shutter Priority thresholds/interval in `ExposureService`, zoom ramp rate in `CameraDeviceService`) to a more configurable location.
    *   **Why**: Allows easier adjustment and experimentation without modifying service code directly.
    *   **Connection Points**:
        *   `ExposureService.swift`: Replace hardcoded values with properties or constants.
        *   `CameraDeviceService.swift`: Replace hardcoded zoom ramp rate.
        *   **(Optional)** `SettingsModel.swift` / `SettingsView.swift`: Add new settings if user-configurability is desired.
        *   **(Alternative)** A dedicated `Configuration.swift` or similar constants file.

8.  **Code Clarity/Cleanup**
    *   **Goal**: Review and remove commented-out code, ensure consistent logging practices, fix minor warnings.
    *   **Why**: Improves general code readability and maintainability.
    *   **Connection Points**: Potentially affects many files codebase-wide. Requires careful review of comments and logging statements.
    *   **Completed Examples**: Fixed `targetMode` variable warning in `CameraDeviceService`. 