//
//  cameraUITests.swift
//  cameraUITests
//
//  Created by spencer on 2025-03-31.
//

import XCTest
import AVFoundation

final class CameraUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it's important to set the initial state - such as interface orientation - required for your tests before they run.
        // The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testCameraLaunchAndOrientation() throws {
        // Launch the app
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launch()
        
        // Wait for the camera to initialize
        let cameraView = app.otherElements["cameraView"]
        XCTAssertTrue(cameraView.waitForExistence(timeout: 5), "Camera view failed to appear")
        
        // Check if the orientation indicator is showing portrait (this would be a custom UI element you'd add)
        // This is a suggestion for a test element to add to your UI for testing
        let orientationIndicator = app.staticTexts["orientationIndicator"]
        if orientationIndicator.exists {
            XCTAssertEqual(orientationIndicator.label, "portrait", "Camera should start in portrait orientation")
        }
        
        // Test initial UI elements appear correctly
        XCTAssertTrue(app.buttons["captureButton"].exists, "Capture button should exist")
        
        // Allow time for UI to settle
        sleep(2)
    }
    
    @MainActor
    func testLensChangeWithLUT() throws {
        // This test requires physical device with multiple camera lenses
        
        // Launch the app with testing flag
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--mockLUT"]  // Add flags for testing with mock LUT
        app.launch()
        
        // Wait for camera interface to load
        let cameraView = app.otherElements["cameraView"]
        XCTAssertTrue(cameraView.waitForExistence(timeout: 5), "Camera view failed to appear")
        
        // Open settings to enable LUT
        app.buttons["settingsButton"].tap()
        
        // Wait for settings sheet
        let lutToggle = app.switches["lutPreviewToggle"]
        XCTAssertTrue(lutToggle.waitForExistence(timeout: 3), "LUT toggle should appear in settings")
        
        // Enable LUT preview
        if lutToggle.value as? String == "0" {
            lutToggle.tap()
        }
        
        // Close settings
        app.buttons["doneButton"].tap()
        
        // Wait for LUT preview to appear
        sleep(2)
        
        // Verify LUT indicator is shown
        let lutIndicator = app.staticTexts["lutIndicator"]
        XCTAssertTrue(lutIndicator.exists, "LUT indicator should be visible when LUT is active")
        
        // Get available lens buttons
        let lensButtons = app.buttons.matching(identifier: "lensButton")
        let lensCount = lensButtons.count
        
        // Skip test if device doesn't have multiple lenses
        guard lensCount > 1 else {
            XCTSkip("This test requires a device with multiple camera lenses")
            return
        }
        
        // Cycle through available lenses
        for i in 0..<lensCount {
            let lensButton = lensButtons.element(boundBy: i)
            lensButton.tap()
            
            // Allow time for lens change to complete
            sleep(1)
            
            // Verify orientation hasn't changed after lens switch
            // You would need a method to check the orientation visually or through accessibility identifiers
            
            // Take a test photo
            app.buttons["captureButton"].tap()
            
            // Wait for photo to be taken
            sleep(2)
            
            // IMPORTANT: In a real implementation, you would add code here to examine orientation 
            // data in the test photos, or check visible UI elements that indicate orientation
        }
    }
    
    @MainActor
    func testOrientationPreservationWithLensChange() throws {
        // Launch the app with testing flags
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--orientationTest"]
        app.launch()
        
        // Wait for the camera UI to appear
        let cameraView = app.otherElements["cameraView"]
        XCTAssertTrue(cameraView.waitForExistence(timeout: 5), "Camera view failed to appear")
        
        // Get the debug overlay to show orientation information
        // (You would need to add this debug overlay element to your app for testing)
        let debugButton = app.buttons["debugButton"]
        if debugButton.exists {
            debugButton.tap()
            
            // Verify initial orientation is portrait
            let orientationLabel = app.staticTexts["currentOrientation"]
            XCTAssertTrue(orientationLabel.waitForExistence(timeout: 2), "Orientation label should appear")
            XCTAssertEqual(orientationLabel.label, "90.0°", "Initial orientation should be portrait (90°)")
            
            // Load a test LUT for the UI test
            app.buttons["testLUTButton"].tap()
            
            // Wait for LUT to load
            sleep(1)
            
            // Change lens
            let lensButtons = app.buttons.matching(identifier: "lensButton")
            if lensButtons.count > 1 {
                lensButtons.element(boundBy: 1).tap() // Tap the second lens option
                
                // Wait for lens change to complete
                sleep(1)
                
                // Check that orientation is preserved
                XCTAssertEqual(orientationLabel.label, "90.0°", "Orientation should remain portrait (90°) after lens change")
            }
        }
    }

    @MainActor
    func testLaunchPerformance() throws {
        if #available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 7.0, *) {
            // This measures how long it takes to launch your application.
            measure(metrics: [XCTApplicationLaunchMetric()]) {
                XCUIApplication().launch()
            }
        }
    }
}
