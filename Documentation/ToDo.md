# ToDo & Technical Debt

This file tracks potential improvements, refactoring tasks, technical debt, and items to review.

## Potential Tasks / Improvements

*   **Core Data Usage**: The project includes Core Data setup (`Persistence.swift`, `camera.xcdatamodeld`), but it doesn't seem to be actively used for storing application data yet. Define entities and integrate Core Data for storing settings, LUT metadata, or other relevant information if needed.
*   **Error Handling**: Enhance error handling throughout the app. While `CameraError` exists, ensure all potential errors from AVFoundation, Metal, File I/O, etc., are caught and presented gracefully to the user.
*   **Audio Metering**: Implement audio level metering during recording.
*   **Focus Control**: Add manual focus controls (e.g., tap-to-focus, focus peaking).
*   **Exposure Control**: Add manual exposure bias control.
*   **UI Refinements**: 
    *   Improve layout constraints and responsiveness, especially around the Dynamic Island/notch area (`FunctionButtonsView`).
    *   Refine animations for smoother transitions (e.g., zoom, settings presentation).
*   **Watch App Features**: 
    *   Display preview on watch (might be resource-intensive).
    *   Allow changing basic settings (resolution, FPS) from the watch.
*   **Testing**: Implement Unit Tests (XCTest) for ViewModels, services, and utilities. Implement UI Tests (XCUITest) for key user flows.
*   **Accessibility**: Review and improve accessibility features (VoiceOver labels, dynamic type support).
*   **Localization**: Add support for multiple languages.
*   **Analytics/Logging**: Integrate a more robust logging/analytics framework for tracking usage and errors in production.
*   **CI/CD**: Set up a Continuous Integration/Continuous Deployment pipeline.

## Technical Debt / Areas for Review

*   **`LUTProcessor.swift`**: This class uses Core Image (`CIFilter`) to process LUTs. Since the primary preview and bake-in logic now uses Metal shaders (`MetalPreviewView`, `MetalFrameProcessor`), review if `LUTProcessor` and its usage in `LUTVideoPreviewView` are still necessary or can be refactored/removed to rely solely on the Metal pipeline.
*   **Orientation Logic**: The orientation handling involves multiple components (`AppDelegate`, `OrientationFixView`, `RotatingView`, `DeviceOrientationViewModel`, service logic). Review for potential simplification and ensure consistency, especially around the fixed portrait preview vs. rotating UI elements and recording orientation.
*   **Empty `iPhoneApp/Core/Services/`**: This directory exists but is empty. Determine if it's needed or if core services should reside elsewhere.
*   **`TestDynamicIslandOverlayView.swift`**: This file seems experimental. Determine if it's still needed or can be removed.
*   **Dependencies between Services**: Analyze dependencies between the various camera services (`RecordingService`, `VideoFormatService`, `CameraDeviceService`, etc.) to ensure clear responsibilities and minimal coupling.
*   **Hardcoded Values**: Look for and replace hardcoded values (e.g., UI dimensions, default settings) with constants or configurable properties where appropriate.
*   **Metal Performance**: Profile Metal usage (preview rendering, compute shaders) using Instruments to identify potential bottlenecks.

*(This list is based on initial observation.)*
