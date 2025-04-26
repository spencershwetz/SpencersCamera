# Session Configuration Documentation

## Overview
This document outlines the proper handling of AVCaptureSession configuration changes in the app.

## Configuration Pattern
All session configuration changes MUST follow this strict pattern:

1. Store Current State
```swift
let wasRunning = session.isRunning
```

2. Stop Session (if running)
```swift
if session.isRunning {
    session.stopRunning()
}
```

3. Begin Configuration
```swift
session.beginConfiguration()
```

4. Apply Changes
```swift
do {
    // Make necessary configuration changes here
    // - Update device settings
    // - Modify inputs/outputs
    // - Configure format settings
    
    // IMPORTANT: Do NOT call startRunning here!
    
    // Commit all changes
    try session.commitConfiguration()
    
    // Only restart session after successful commit
    if wasRunning {
        session.startRunning()
    }
} catch {
    // Handle configuration errors
    handleError(error)
    
    // Attempt to restore previous state
    try? session.commitConfiguration()
    
    // Restart session if it was running before
    if wasRunning {
        session.startRunning()
    }
}
```

## Key Considerations

### Critical Rules
- NEVER call `startRunning` between `beginConfiguration` and `commitConfiguration`
- ALWAYS commit configuration before attempting to restart the session
- Handle configuration errors properly and restore previous state

### State Management
- Store session state before making changes
- Only restore running state after successful configuration
- Ensure atomic configuration changes
- Clean up resources on configuration failure

### iOS 17+ Compatibility
- Use `videoRotationAngle` instead of deprecated `videoOrientation`
- Implement proper rotation handling for video output

### Error Handling
- Catch and handle configuration errors appropriately
- Log configuration failures for debugging
- Attempt to restore previous state on failure
- Notify delegate/completion handler of configuration result

### Performance
- Batch related changes together in single configuration block
- Minimize configuration changes frequency
- Avoid unnecessary session stops/starts
- Use appropriate quality of service for configuration changes

## Implementation Example
```swift
func updateSessionConfiguration() {
    let wasRunning = session.isRunning
    
    // Stop running session if needed
    if session.isRunning {
        session.stopRunning()
    }
    
    // Begin configuration block
    session.beginConfiguration()
    
    do {
        // Apply all configuration changes here
        // Example: setting format, inputs, outputs
        
        // Commit changes first
        try session.commitConfiguration()
        
        // Only restart if previously running
        if wasRunning {
            session.startRunning()
        }
        
    } catch {
        logger.error("Failed to update session configuration: \(error.localizedDescription)")
        
        // Try to restore previous state
        try? session.commitConfiguration()
        
        // Restart if needed
        if wasRunning {
            session.startRunning()
        }
    }
} 