# Unified Video Output Refactor Plan

## Background

Currently the app uses two separate `AVCaptureVideoDataOutput` instances: one for the live Metal preview (in `CameraPreviewView`) and one for recording (in `RecordingService`). When the app goes to background and returns to foreground, the session ends up with duplicate outputs and leads to an AVError `-11872 (Cannot Record)` at runtime.

## Motivation

- Eliminate the `Cannot Record (-11872)` error caused by conflicting multiple video outputs.
- Simplify the capture pipeline by centralizing buffer dispatch in one place.
- Improve maintainability by having a single entry point for video frames.

## Proposed Solution

1. **Remove** all existing setup and removal of the `AVCaptureVideoDataOutput` in both `CameraPreviewView` and `RecordingService`.
2. **Add** exactly one `AVCaptureVideoDataOutput` to the shared `AVCaptureSession`, configured in `CameraViewModel` (on `sessionQueue`).
3. **Set** `CameraViewModel` as the `sampleBufferDelegate` for this output.
4. **In** `CameraViewModel.captureOutput(_:didOutput:from:)`:
   - Forward each `CMSampleBuffer` to the Metal preview—via the existing `MetalPreviewView` delegate.
   - Forward the same `CMSampleBuffer` to `RecordingService` (e.g., through a new method `process(sampleBuffer:)`).
5. **Remove** the `dismantleUIView` cleanup in `CameraPreviewView` since no separate preview output exists.
6. **Update** the recording code path to assume frames come from `CameraViewModel`, not its own output.
7. **Ensure** session configuration (adding/removing outputs) always happens on `sessionQueue` to avoid threading races.

## Implementation Steps

1. In `RecordingService`:
   - Delete `setupVideoDataOutput()` and `setupAudioDataOutput()` calls in `init`.
   - Remove the `videoDataOutput` property and any `captureOutput` implementation there.
2. In `CameraPreviewView`:
   - Delete the `AVCaptureVideoDataOutput` configuration in `makeUIView` and the corresponding cleanup in `dismantleUIView`.
3. In `CameraViewModel`:
   - Add a new method `setupVideoOutput()` on `sessionQueue` that:
     ```swift
     let videoOutput = AVCaptureVideoDataOutput()
     videoOutput.setSampleBufferDelegate(self, queue: processingQueue)
     session.beginConfiguration()
     session.addOutput(videoOutput)
     session.commitConfiguration()
     ```
   - Conform to `AVCaptureVideoDataOutputSampleBufferDelegate` and implement:
     ```swift
     func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
       metalPreviewDelegate?.updateTexture(with: sampleBuffer)
       recordingService.process(sampleBuffer)
     }
     ```
4. Wire up `metalPreviewDelegate` in `CameraViewModel` to the existing `MetalPreviewView` instance created in SwiftUI.
5. Add `process(_:)` entry in `RecordingService` to accept buffers directly, replacing its previous delegate method.

## Testing & Validation

- Build and run on iOS 18+ simulator.
- Verify live preview remains smooth and recording starts/stops without `-11872`.
- Background/foreground cycle should no longer trigger a session runtime error.
- Record short video clips, confirm they save correctly.

## Next Steps

- Clean up any leftover legacy code in Services and Views.
- Add unit tests for `CameraViewModel.captureOutput` multiplexer logic.
- Update documentation and README with the new architecture. 