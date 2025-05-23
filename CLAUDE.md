# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build and Development Commands

### Building
```bash
# Build the main iOS app
xcodebuild -scheme "Spencer's Camera" build

# Build the watch app
xcodebuild -scheme "SC Watch App" build

# Build all targets
xcodebuild -scheme "Spencer's Camera" build
xcodebuild -scheme "SC Watch App" build
xcodebuild -scheme "CaptureExtension" build
xcodebuild -scheme "WidgetExtension" build

# Clean build
xcodebuild -scheme "Spencer's Camera" clean

# Archive for distribution
xcodebuild -scheme "Spencer's Camera" archive
```

### Running Tests
Currently, no test files are implemented. The Tests directory exists but is empty. When adding tests:
- Create XCTest files in `iPhoneApp/Tests/`
- Use the existing test scheme with `shouldAutocreateTestPlan = "YES"`

### Development Notes
- No linting tools are currently configured
- No CI/CD pipeline is set up
- Use Xcode for primary development

## Architecture Overview

This is a multi-platform camera app with iOS, watchOS, widget, and capture extension targets. The app follows MVVM architecture with a service layer pattern.

### Key Architectural Patterns

1. **MVVM with Service Layer**
   - ViewModels contain UI state (`@Published` properties) and orchestrate services
   - Services encapsulate framework interactions (AVFoundation, Metal, Photos, DockKit)
   - Communication uses delegate protocols and Combine publishers
   - Views observe ViewModels for reactive updates

2. **Camera Pipeline**
   - `CameraViewModel` orchestrates all camera services
   - Services handle specific responsibilities:
     - `CameraDeviceService`: Lens switching and device management
     - `VideoFormatService`: Format selection and frame rate control
     - `ExposureService`: Exposure, white balance, and shutter priority
     - `RecordingService`: Video recording with AVAssetWriter
     - `DockControlService`: DockKit accessory integration (iOS 18.0+)

3. **Metal Rendering Pipeline**
   - `MetalPreviewView`: Real-time preview with LUT support
   - `MetalFrameProcessor`: LUT bake-in during recording
   - Triple buffering with semaphore synchronization
   - Handles multiple pixel formats (BGRA, 420v, x422 for Apple Log)

4. **State Management**
   - `SettingsModel`: Global settings persisted to UserDefaults
   - Each view creates its own `DeviceOrientationViewModel` instance (no singleton)
   - `WatchConnectivityService`: Injected as environment object in watch app
   - No ObservableObject singletons in SwiftUI views

### Critical Implementation Details

1. **Exposure System**
   - Single `ExposureMode` enum manages all exposure states (auto, manual, shutterPriority, locked)
   - `ExposureState` struct captures complete exposure state for transitions
   - Thread-safe with dedicated queues (`stateQueue`, `exposureAdjustmentQueue`)
   - Smooth ISO transitions with multi-step interpolation
   - Automatic error recovery and state restoration

2. **Shutter Priority Mode**
   - Fixed 180° shutter angle with floating ISO
   - Recalculates duration after every lens switch: `duration = 1.0 / (2 * frameRate)`
   - Debounced re-application with device readiness checks
   - Manual ISO override supported with `isManualISOInSP` tracking

3. **Orientation Handling**
   - UI locked to portrait via `OrientationFixView`
   - `RotatingView` rotates individual UI elements
   - `RecordingService` applies rotation transform to video metadata
   - Preview always rendered in portrait (90° rotation)

4. **Memory Management**
   - Proactive Metal texture cache flushing before session starts
   - Resource cleanup during lens transitions
   - Staged allocation/deallocation approach
   - Approximately 300MB memory reduction achieved

5. **Focus System**
   - Push-to-focus with tap gesture
   - Long press for focus lock
   - Two-phase locking: autoFocus → 300ms wait → locked
   - Lock state maintained across lens switches

## Common Development Tasks

### Adding Camera Features
1. Create service in `iPhoneApp/Features/Camera/Services/`
2. Add delegate protocol for ViewModel communication
3. Integrate with `CameraViewModel` orchestration
4. Update UI in `CameraView` or related views

### Working with LUTs
- LUT files parsed by `CubeLUTLoader`
- `LUTManager` creates both MTLTexture and CIFilter
- Preview uses Metal shaders in `PreviewShaders.metal`
- Recording bake-in via `MetalFrameProcessor`

### Debugging Camera Issues
- Check `CameraViewModel` state properties
- Monitor service delegate callbacks
- Use debug overlay (toggled in settings)
- Watch for GPU timeouts (purple screen)

### Platform-Specific Development
- iOS 18.0+ required for DockKit features
- Use conditional compilation: `#if canImport(DockKit)`
- Watch app uses WatchConnectivity for remote control
- Widgets and capture extension have limited camera access

## Important Considerations

1. **Thread Safety**: All camera operations must respect the serial queues in ExposureService
2. **Memory Pressure**: Always clean up Metal resources during transitions
3. **Orientation Complexity**: Preview is fixed portrait; only UI elements rotate
4. **Apple Log Support**: Requires specific formats and device capabilities
5. **Performance**: LUT processing and Metal operations can cause GPU timeouts if not throttled