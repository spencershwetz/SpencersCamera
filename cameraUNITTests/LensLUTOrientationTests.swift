import Testing
import XCTest
@testable import camera
import AVFoundation
import UIKit
import CoreImage

struct LensLUTOrientationTests {
    
    // Test for the specific issue: Changing lenses with LUT applied but not baked
    func testLensChangeWithUnbakedLUT() {
        // Create our mock camera testing environment
        let mockSession = MockAVCaptureSession()
        let mockConnection = MockCaptureConnection.create()
        let mockOutput = MockCaptureOutput.create(mockConnection: mockConnection)
        mockSession.addOutput(mockOutput)
        
        let cameraDeviceService = MockCameraDeviceService()
        let lutManager = LUTManager()
        
        // Create view model with mock session
        let viewModel = CameraViewModel(
            cameraDeviceService: cameraDeviceService,
            lutManager: lutManager,
            session: mockSession
        )
        
        // Set initial orientation to portrait
        viewModel.updateOrientation(.portrait)
        
        // Verify orientation matches expectation for portrait
        XCTAssertEqual(mockOutput.mockConnection?.videoRotationAngle, 0, "Rotation angle should be 0 for portrait orientation")
        
        // Change lens with LUT active
        lutManager.loadIdentityLUT()
        viewModel.switchToLens(.telephoto)
        
        // Verify orientation is maintained after lens change
        XCTAssertEqual(mockOutput.mockConnection?.videoRotationAngle, 0, "Rotation angle should remain 0 after lens change")
        
        // Change to landscape orientation
        viewModel.updateOrientation(.landscapeLeft)
        
        // Verify orientation matches expectation for landscape
        XCTAssertEqual(mockOutput.mockConnection?.videoRotationAngle, 90, "Rotation angle should be 90 for landscape left orientation")
        
        // Change lens again with LUT active
        viewModel.switchToLens(.wide)
        
        // Verify orientation is maintained after lens change
        XCTAssertEqual(mockOutput.mockConnection?.videoRotationAngle, 90, "Rotation angle should remain 90 after lens change")
    }
    
    func testLUTAppliedAfterLensChange() async throws {
        // This test verifies that applying a LUT after a lens change maintains proper orientation
        
        // Create a mock camera testing environment
        let mockSession = MockAVCaptureSession()
        let mockDeviceService = MockCameraDeviceService()
        let mockLUTManager = LUTManager()
        
        // Configure the mock session with outputs
        let videoConnection = MockCaptureConnection.create()
        let videoOutput = MockCaptureOutput.create(mockConnection: videoConnection)
        mockSession.addMockOutput(videoOutput)
        
        // Create the view model with our mocks
        let viewModel = CameraViewModel(
            cameraDeviceService: mockDeviceService,
            lutManager: mockLUTManager,
            session: mockSession
        )
        
        // Set initial orientation to portrait
        videoConnection.videoRotationAngle = 90.0
        viewModel.updateOrientation(.portrait)
        
        // Change lens first (no LUT active)
        viewModel.switchToLens(CameraLens.ultraWide)
        
        // Allow time for the async operations to complete
        try await Task.sleep(nanoseconds: 200_000_000) // 0.2 seconds
        
        // Verify orientation is maintained
        XCTAssertEqual(videoConnection.videoRotationAngle, 90.0)
        
        // Now apply a LUT after the lens change
        let testFilter = OrientationTestHelper.createTestLUTFilter()
        mockLUTManager.currentLUTFilter = testFilter
        
        // Allow time for the async operations to complete
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        
        // Verify orientation is still correct
        XCTAssertEqual(videoConnection.videoRotationAngle, 90.0)
        
        // Change lens again with LUT active
        viewModel.switchToLens(CameraLens.wide)
        
        // Allow time for the async operations to complete
        try await Task.sleep(nanoseconds: 200_000_000) // 0.2 seconds
        
        // Verify orientation is maintained
        XCTAssertEqual(videoConnection.videoRotationAngle, 90.0)
    }
}

// The class below is now defined in MockCameraClasses.swift
// class MockAVCaptureSession: AVCaptureSession {
//     var mockOutputs: [AVCaptureOutput] = []
//     var isRunning = false
// 
//     override func addOutput(_ output: AVCaptureOutput) {
//         mockOutputs.append(output)
//     }
// 
//     override func startRunning() {
//         isRunning = true
//     }
// 
//     override func stopRunning() {
//         isRunning = false
//     }
// 
//     override var outputs: [AVCaptureOutput] {
//         return mockOutputs
//     }
// } 