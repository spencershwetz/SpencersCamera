import AVFoundation

/// Protocol that defines the common interface between AVCaptureSession and MockAVCaptureSession
public protocol CaptureSessionProtocol: AnyObject {
    var outputs: [AVCaptureOutput] { get }
    var inputs: [AVCaptureInput] { get }
    
    func startRunning()
    func stopRunning()
    func beginConfiguration()
    func commitConfiguration()
    
    func addInput(_ input: AVCaptureInput)
    func addOutput(_ output: AVCaptureOutput)
    func removeInput(_ input: AVCaptureInput)
    func removeOutput(_ output: AVCaptureOutput)
    
    var isRunning: Bool { get }
    func canAddInput(_ input: AVCaptureInput) -> Bool
    func canAddOutput(_ output: AVCaptureOutput) -> Bool
}

// Extension to make AVCaptureSession conform to our protocol
extension AVCaptureSession: CaptureSessionProtocol {
} 