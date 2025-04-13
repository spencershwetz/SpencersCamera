import AVFoundation
import CoreVideo
import os.log

// Protocol to abstract the necessary function from MetalPreviewView
// This avoids a direct dependency cycle if MetalPreviewView needed this coordinator
protocol MetalFrameUpdatable: AnyObject {
    func updateTexture(with sampleBuffer: CMSampleBuffer)
}

// Protocol to abstract the necessary function from RecordingService
protocol VideoBufferAppendable: AnyObject {
    func appendVideoBuffer(_ buffer: CMSampleBuffer)
    var isRecording: Bool { get } // Need to know if recording is active
}

/// Coordinates the distribution of video sample buffers from a single AVCaptureVideoDataOutput
/// to potentially multiple consumers (like the live preview and the recording service).
class VideoDataOutputCoordinator: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "VideoDataOutputCoordinator")
    
    // Weak references to avoid retain cycles
    weak var metalPreviewUpdater: MetalFrameUpdatable?
    weak var recordingService: VideoBufferAppendable?
    
    private let videoDataQueue = DispatchQueue(
        label: "com.spencerscamera.VideoDataOutputQueue",
        qos: .userInitiated, // High priority for real-time processing
        attributes: [],
        autoreleaseFrequency: .workItem
    )

    // Public queue for setting the delegate
    var delegateQueue: DispatchQueue {
        return videoDataQueue
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // Distribute the buffer to consumers
        
        // 1. Update the live preview
        if let preview = metalPreviewUpdater {
            preview.updateTexture(with: sampleBuffer)
            // logger.trace("Coordinator: Passed buffer to Metal Preview.") // Optional: Fine-grained logging
        } else {
             // logger.trace("Coordinator: Metal Preview Updater not set.") // Optional
        }
        
        // 2. Append to recording if active
        if let recorder = recordingService, recorder.isRecording {
            recorder.appendVideoBuffer(sampleBuffer)
            // logger.trace("Coordinator: Passed buffer to Recording Service.") // Optional
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        logger.warning("Video frame dropped.")
        // Handle dropped frames if necessary (e.g., log statistics)
    }
} 