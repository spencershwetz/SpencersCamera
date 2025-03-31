//
//  cameraUNITTests.swift
//  cameraUNITTests
//
//  Created by spencer on 2025-03-31.
//

import Testing
import XCTest
@testable import camera
import AVFoundation
import UIKit
import SwiftUI
import CoreImage

struct CameraOrientationTests {
    
    // MARK: - Video Orientation Tests
    
    @Test func testDeviceOrientationExtensions() async throws {
        // Test portrait mode
        let portrait = UIDeviceOrientation.portrait
        let portraitUpsideDown = UIDeviceOrientation.portraitUpsideDown
        
        #expect(portrait.isPortrait == true)
        #expect(portraitUpsideDown.isPortrait == true)
        #expect(portrait.isLandscape == false)
        #expect(portrait.isValidInterfaceOrientation == true)
        #expect(portrait.videoRotationAngleValue == 90.0)
        #expect(portraitUpsideDown.videoRotationAngleValue == 270.0)
        
        // Test landscape mode
        let landscapeLeft = UIDeviceOrientation.landscapeLeft
        let landscapeRight = UIDeviceOrientation.landscapeRight
        
        #expect(landscapeLeft.isLandscape == true)
        #expect(landscapeRight.isLandscape == true)
        #expect(landscapeLeft.isPortrait == false)
        #expect(landscapeLeft.isValidInterfaceOrientation == true)
        #expect(landscapeLeft.videoRotationAngleValue == 0.0)
        #expect(landscapeRight.videoRotationAngleValue == 180.0)
        
        // Test invalid orientations
        let faceUp = UIDeviceOrientation.faceUp
        let faceDown = UIDeviceOrientation.faceDown
        
        #expect(faceUp.isValidInterfaceOrientation == false)
        #expect(faceDown.isValidInterfaceOrientation == false)
        #expect(faceUp.videoRotationAngleValue == 90.0) // Default to portrait
    }
    
    // MARK: - LUT Tests
    
    @Test func testLUTOrientationWithLensChange() async throws {
        // Create mock services
        let mockCameraService = MockCameraDeviceService()
        let mockSession = AVCaptureSession()
        let mockSessionOutput = MockCaptureOutput()
        let mockConnection = MockCaptureConnection()
        
        // Add mock connection to output
        mockSessionOutput.mockConnection = mockConnection
        mockSession.addOutput(mockSessionOutput)
        
        // Setup view model with mocks
        let viewModel = CameraViewModel(
            cameraDeviceService: mockCameraService,
            lutManager: LUTManager(),
            session: mockSession
        )
        
        // First test case: Ensure orientation is correct when changing lenses with LUT active
        
        // 1. Set up scenario: Apply LUT but don't bake it
        let lutManager = viewModel.lutManager
        
        // Create a simple identity LUT filter for testing
        let testFilter = CIFilter(name: "CIColorCube")
        lutManager.currentLUTFilter = testFilter
        
        // 2. Set portrait orientation
        let portraitOrientation = UIInterfaceOrientation.portrait
        mockConnection.mockVideoRotationAngle = 90.0
        viewModel.updateOrientation(portraitOrientation)
        
        // 3. Simulate lens change
        viewModel.switchToLens(.wide)
        
        // 4. Verify orientation is still correct after lens change
        // The orientation value should be preserved as portrait (90°)
        #expect(mockConnection.mockVideoRotationAngle == 90.0)
        
        // 5. Simulate another lens change to ultrawide
        viewModel.switchToLens(.ultraWide)
        
        // 6. After the lens change, the orientation should still be correct
        #expect(mockConnection.mockVideoRotationAngle == 90.0)
        
        // 7. Test landscape orientation cases
        mockConnection.mockVideoRotationAngle = 0.0
        viewModel.updateOrientation(.landscapeLeft)
        
        // 8. Simulate lens change while in landscape
        viewModel.switchToLens(.telephoto)
        
        // 9. Verify orientation is maintained
        #expect(mockConnection.mockVideoRotationAngle == 0.0)
    }
    
    @Test func testOrientationAfterLUTToggle() async throws {
        // Create mock services
        let mockCameraService = MockCameraDeviceService()
        let mockSession = AVCaptureSession()
        let mockSessionOutput = MockCaptureOutput()
        let mockConnection = MockCaptureConnection()
        
        // Add mock connection to output
        mockSessionOutput.mockConnection = mockConnection
        mockSession.addOutput(mockSessionOutput)
        
        // Setup view model with mocks
        let viewModel = CameraViewModel(
            cameraDeviceService: mockCameraService,
            lutManager: LUTManager(),
            session: mockSession
        )
        
        // Start with portrait orientation
        mockConnection.mockVideoRotationAngle = 90.0
        viewModel.updateOrientation(.portrait)
        
        // 1. Test enabling LUT
        let testFilter = CIFilter(name: "CIColorCube")
        viewModel.lutManager.currentLUTFilter = testFilter
        
        // Force an orientation update - should maintain portrait
        viewModel.updateOrientation(.portrait)
        #expect(mockConnection.mockVideoRotationAngle == 90.0)
        
        // 2. Test disabling LUT
        viewModel.lutManager.currentLUTFilter = nil
        
        // Force an orientation update - should maintain portrait
        viewModel.updateOrientation(.portrait)
        #expect(mockConnection.mockVideoRotationAngle == 90.0)
        
        // 3. Test with landscape
        mockConnection.mockVideoRotationAngle = 0.0
        viewModel.updateOrientation(.landscapeLeft)
        
        // Enable LUT again
        viewModel.lutManager.currentLUTFilter = testFilter
        
        // Verify orientation is preserved in landscape
        #expect(mockConnection.mockVideoRotationAngle == 0.0)
    }
}
