import Foundation
import AVFoundation
import UIKit
@testable import camera

// MARK: - Mock Classes for Testing

// Protocol to abstract connection behavior for testing
protocol CaptureConnectionProtocol {
    var videoRotationAngle: CGFloat { get set }
    var isVideoOrientationSupported: Bool { get }
    func isVideoRotationAngleSupported(_ angle: CGFloat) -> Bool
}

// Mock implementation of connection - no longer inherits from AVCaptureConnection
class MockCaptureConnection: AVCaptureConnection {
    var mockVideoOrientation: AVCaptureVideoOrientation = .portrait
    override var videoOrientation: AVCaptureVideoOrientation {
        get { return mockVideoOrientation }
        set { mockVideoOrientation = newValue }
    }
    
    override var inputPorts: [AVCaptureInput.Port] {
        return []
    }
    
    override var output: AVCaptureOutput? {
        return nil // We'll set this after creation
    }
    
    // Use a proper computed property to override videoRotationAngle
    private var _videoRotationAngle: CGFloat = 0
    override var videoRotationAngle: CGFloat {
        get { return _videoRotationAngle }
        set { _videoRotationAngle = newValue }
    }
    
    override var isVideoOrientationSupported: Bool {
        return true
    }
    
    override func isVideoRotationAngleSupported(_ angle: CGFloat) -> Bool {
        return true
    }
    
    // Factory method that doesn't need AVCaptureOutput
    static func create() -> MockCaptureConnection {
        // Using empty arrays for inputPorts and a dummy output that will be replaced
        let dummyOutput = AVCapturePhotoOutput()
        return MockCaptureConnection(inputPorts: [], output: dummyOutput)
    }
}

// Helper to create a dummy video input
extension AVCaptureDeviceInput {
    static func createDummyVideoInput() -> AVCaptureDeviceInput {
        // Try to get the default video device
        guard let device = AVCaptureDevice.default(for: .video) else {
            fatalError("No camera available for testing")
        }
        
        do {
            return try AVCaptureDeviceInput(device: device)
        } catch {
            fatalError("Failed to create device input: \(error)")
        }
    }
}

// Mock implementation of AVCaptureOutput
class MockCaptureOutput: AVCaptureOutput {
    var mockConnection: MockCaptureConnection?
    var mockConnections: [MockCaptureConnection] = []
    
    override var connections: [AVCaptureConnection] {
        return mockConnections
    }
    
    // NOTE: We can't override or call initializers from AVCaptureOutput
    // as they've been marked unavailable in Swift
    
    // Factory method to create a properly initialized instance
    static func create() -> MockCaptureOutput {
        // Use Objective-C runtime since we can't access the initializers directly in Swift
        let output = MockCaptureOutput.__allocation() as! MockCaptureOutput
        output.__initializeObject()
        return output
    }
    
    // Constructor with specific connection
    static func create(mockConnection: MockCaptureConnection) -> MockCaptureOutput {
        let output = self.create()
        output.mockConnection = mockConnection
        output.mockConnections = [mockConnection]
        return output
    }
    
    override func connection(with mediaType: AVMediaType) -> AVCaptureConnection? {
        return mockConnection
    }
}

/// Mock implementation of AVCaptureSession
class MockAVCaptureSession: CaptureSessionProtocol {
    var outputs: [AVCaptureOutput] = []
    var inputs: [AVCaptureInput] = []
    var isRunning: Bool = false
    
    func startRunning() {
        isRunning = true
    }
    
    func stopRunning() {
        isRunning = false
    }
    
    func beginConfiguration() {
        // No-op for testing
    }
    
    func commitConfiguration() {
        // No-op for testing
    }
    
    func addInput(_ input: AVCaptureInput) {
        inputs.append(input)
    }
    
    func addOutput(_ output: AVCaptureOutput) {
        outputs.append(output)
    }
    
    // Helper method for testing
    func addMockOutput(_ output: MockCaptureOutput) {
        outputs.append(output)
    }
    
    func removeInput(_ input: AVCaptureInput) {
        if let index = inputs.firstIndex(where: { $0 === input }) {
            inputs.remove(at: index)
        }
    }
    
    func removeOutput(_ output: AVCaptureOutput) {
        if let index = outputs.firstIndex(where: { $0 === output }) {
            outputs.remove(at: index)
        }
    }
    
    func canAddInput(_ input: AVCaptureInput) -> Bool {
        return true
    }
    
    func canAddOutput(_ output: AVCaptureOutput) -> Bool {
        return true
    }
}

// Mock CameraDeviceService that implements the protocol
class MockCameraDeviceService: CameraDeviceServiceProtocol {
    public var isRecordingOrientationLocked: Bool = false
    public var device: AVCaptureDevice?
    public var delegate: CameraDeviceServiceDelegate?
    private var videoDeviceInput: AVCaptureDeviceInput?
    weak var cameraViewModelDelegate: CameraDeviceServiceDelegate?
    var currentLens: CameraLens = .wide
    var lastVideoOrientation: UIInterfaceOrientation?
    
    public init() {}
    
    public func configure() async throws {}
    
    public func switchToLens(_ lens: CameraLens) {
        // Just simulate lens switch
        currentLens = lens
    }
    
    public func setZoomFactor(_ zoomFactor: CGFloat, currentLens: CameraLens, availableLenses: [CameraLens]) {
        // Just simulate zoom
    }
    
    public func updateVideoOrientation(for connection: AVCaptureConnection, orientation: UIInterfaceOrientation) {
        // Update the connection orientation based on UI interface orientation
        connection.videoRotationAngle = orientationToAngle(orientation)
        lastVideoOrientation = orientation
    }
    
    private func orientationToAngle(_ orientation: UIInterfaceOrientation) -> CGFloat {
        switch orientation {
        case .portrait:
            return 0
        case .portraitUpsideDown:
            return 180
        case .landscapeLeft:
            return 90
        case .landscapeRight:
            return 270
        default:
            return 0
        }
    }
    
    public func lockOrientationForRecording(_ locked: Bool) {
        isRecordingOrientationLocked = locked
    }
    
    public func setDevice(_ device: AVCaptureDevice) {
        self.device = device
    }
    
    public func setVideoDeviceInput(_ input: AVCaptureDeviceInput) {
        self.videoDeviceInput = input
    }
} 