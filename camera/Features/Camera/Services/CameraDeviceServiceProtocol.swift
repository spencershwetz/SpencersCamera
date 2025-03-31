import Foundation
import AVFoundation
import UIKit

/// Protocol defining the camera device service interface
protocol CameraDeviceServiceProtocol {
    /// The current capture device, if any
    var device: AVCaptureDevice? { get }
    
    /// Flag to track orientation locking during recording
    var isRecordingOrientationLocked: Bool { get }
    
    /// Delegate to communicate camera events
    var delegate: CameraDeviceServiceDelegate? { get set }
    
    /// Configures and initializes the capture session
    func configure() async throws
    
    /// Switches to the specified camera lens
    /// - Parameter lens: The lens to switch to
    func switchToLens(_ lens: CameraLens)
    
    /// Sets the zoom factor for the current camera
    /// - Parameters:
    ///   - zoomFactor: The zoom factor to set
    ///   - currentLens: The current lens in use
    ///   - availableLenses: All available lenses on the device
    func setZoomFactor(_ zoomFactor: CGFloat, currentLens: CameraLens, availableLenses: [CameraLens])
    
    /// Updates the video orientation for a capture connection
    /// - Parameters:
    ///   - connection: The AVCaptureConnection to update
    ///   - orientation: The new orientation to set
    func updateVideoOrientation(for connection: AVCaptureConnection, orientation: UIInterfaceOrientation)
    
    /// Locks or unlocks the orientation during recording
    /// - Parameter locked: Whether to lock the orientation
    func lockOrientationForRecording(_ locked: Bool)
    
    /// Sets the capture device
    /// - Parameter device: The capture device to set
    func setDevice(_ device: AVCaptureDevice)
    
    /// Sets the video device input
    /// - Parameter input: The video device input to set
    func setVideoDeviceInput(_ input: AVCaptureDeviceInput)
} 