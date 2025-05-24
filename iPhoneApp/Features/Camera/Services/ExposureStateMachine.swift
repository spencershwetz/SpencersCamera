import Foundation
import AVFoundation
import os.log
import CoreMedia

/// Represents all possible exposure states in the camera system
indirect enum ExposureState: Equatable {
    case auto
    case manual(iso: Float, duration: CMTime)
    case shutterPriority(targetDuration: CMTime, manualISO: Float?)
    case locked(iso: Float, duration: CMTime)
    case recordingLocked(previousState: ExposureState)
    
    var isLocked: Bool {
        switch self {
        case .locked, .recordingLocked:
            return true
        default:
            return false
        }
    }
    
    var isShutterPriority: Bool {
        switch self {
        case .shutterPriority:
            return true
        case .recordingLocked(let previous):
            return previous.isShutterPriority
        default:
            return false
        }
    }
    
    var isManualMode: Bool {
        switch self {
        case .manual, .shutterPriority:
            return true
        case .recordingLocked(let previous):
            return previous.isManualMode
        default:
            return false
        }
    }
}

/// Events that can trigger state transitions
enum ExposureEvent: Equatable {
    case enableAuto
    case enableManual(iso: Float?, duration: CMTime?)
    case enableShutterPriority(duration: CMTime)
    case overrideISOInShutterPriority(iso: Float)
    case clearManualISOOverride
    case lock
    case unlock
    case startRecording
    case stopRecording
    case deviceChanged
    case errorOccurred(Error)
    
    static func == (lhs: ExposureEvent, rhs: ExposureEvent) -> Bool {
        switch (lhs, rhs) {
        case (.enableAuto, .enableAuto),
             (.clearManualISOOverride, .clearManualISOOverride),
             (.lock, .lock),
             (.unlock, .unlock),
             (.startRecording, .startRecording),
             (.stopRecording, .stopRecording),
             (.deviceChanged, .deviceChanged):
            return true
        case (.enableManual(let lhsISO, let lhsDuration), .enableManual(let rhsISO, let rhsDuration)):
            return lhsISO == rhsISO && lhsDuration == rhsDuration
        case (.enableShutterPriority(let lhsDuration), .enableShutterPriority(let rhsDuration)):
            return lhsDuration == rhsDuration
        case (.overrideISOInShutterPriority(let lhsISO), .overrideISOInShutterPriority(let rhsISO)):
            return lhsISO == rhsISO
        case (.errorOccurred, .errorOccurred):
            // Errors are considered equal for simplicity
            return true
        default:
            return false
        }
    }
}

/// Manages exposure state transitions with a proper state machine
class ExposureStateMachine {
    private let logger = Logger(subsystem: "com.camera", category: "ExposureStateMachine")
    private let queue = DispatchQueue(label: "com.camera.exposureStateMachine", qos: .userInitiated)
    
    private(set) var currentState: ExposureState = .auto
    private var device: AVCaptureDevice?
    
    /// Callback for state changes
    var onStateChange: ((ExposureState, ExposureState) -> Void)?
    
    /// Process an event and transition to the appropriate state
    func processEvent(_ event: ExposureEvent, device: AVCaptureDevice?) -> ExposureState {
        self.device = device
        
        return queue.sync {
            let oldState = currentState
            let newState: ExposureState
            
            switch (currentState, event) {
            // Auto mode transitions
            case (.auto, .enableManual(let iso, let duration)):
                if let device = device {
                    #if !os(macOS)
                    let actualISO = iso ?? device.iso
                    let actualDuration = duration ?? device.exposureDuration
                    newState = .manual(iso: actualISO, duration: actualDuration)
                    #else
                    newState = currentState
                    #endif
                } else {
                    newState = currentState
                }
                
            case (.auto, .enableShutterPriority(let duration)):
                newState = .shutterPriority(targetDuration: duration, manualISO: nil)
                
            case (.auto, .lock):
                if let device = device {
                    #if !os(macOS)
                    newState = .locked(iso: device.iso, duration: device.exposureDuration)
                    #else
                    newState = currentState
                    #endif
                } else {
                    newState = currentState
                }
                
            // Manual mode transitions
            case (.manual, .enableAuto):
                newState = .auto
                
            case (.manual, .enableShutterPriority(let duration)):
                newState = .shutterPriority(targetDuration: duration, manualISO: nil)
                
            case (.manual(let iso, let duration), .lock):
                newState = .locked(iso: iso, duration: duration)
                
            case (.manual, .enableManual(let iso, let duration)):
                if let device = device {
                    #if !os(macOS)
                    let actualISO = iso ?? device.iso
                    let actualDuration = duration ?? device.exposureDuration
                    newState = .manual(iso: actualISO, duration: actualDuration)
                    #else
                    newState = currentState
                    #endif
                } else {
                    newState = currentState
                }
                
            // Shutter Priority mode transitions
            case (.shutterPriority(_, _), .enableAuto):
                newState = .auto
                
            case (.shutterPriority(let targetDuration, _), .enableManual(_, _)):
                if let device = device {
                    #if !os(macOS)
                    newState = .manual(iso: device.iso, duration: targetDuration)
                    #else
                    newState = currentState
                    #endif
                } else {
                    newState = currentState
                }
                
            case (.shutterPriority(let targetDuration, _), .overrideISOInShutterPriority(let iso)):
                newState = .shutterPriority(targetDuration: targetDuration, manualISO: iso)
                
            case (.shutterPriority(let targetDuration, _), .clearManualISOOverride):
                newState = .shutterPriority(targetDuration: targetDuration, manualISO: nil)
                
            case (.shutterPriority(let targetDuration, let manualISO), .lock):
                if let device = device {
                    #if !os(macOS)
                    let lockISO = manualISO ?? device.iso
                    newState = .locked(iso: lockISO, duration: targetDuration)
                    #else
                    newState = currentState
                    #endif
                } else {
                    newState = currentState
                }
                
            // Locked mode transitions
            case (.locked(let iso, let duration), .unlock):
                // Intelligently restore to the appropriate mode based on device state
                if let device = device {
                    // If we were in a mode that uses custom exposure settings, restore to manual
                    // Otherwise, restore to auto
                    if device.exposureMode == .custom {
                        newState = .manual(iso: iso, duration: duration)
                    } else {
                        newState = .auto
                    }
                } else {
                    // Default to auto if no device info
                    newState = .auto
                }
                
            case (.locked, .enableAuto):
                newState = .auto
                
            case (.locked, .enableManual(let iso, let duration)):
                if let device = device {
                    #if !os(macOS)
                    let actualISO = iso ?? device.iso
                    let actualDuration = duration ?? device.exposureDuration
                    newState = .manual(iso: actualISO, duration: actualDuration)
                    #else
                    newState = currentState
                    #endif
                } else {
                    newState = currentState
                }
                
            case (.locked, .enableShutterPriority(let duration)):
                newState = .shutterPriority(targetDuration: duration, manualISO: nil)
                
            // Recording lock transitions
            case (_, .startRecording) where !currentState.isLocked:
                newState = .recordingLocked(previousState: currentState)
                
            case (.recordingLocked(let previousState), .stopRecording):
                newState = previousState
                
            // Device change handling
            case (_, .deviceChanged):
                // Reset to auto on device change for safety
                newState = .auto
                logger.info("Device changed, resetting to auto exposure")
                
            // Error handling
            case (_, .errorOccurred(let error)):
                logger.error("Exposure error occurred: \(error.localizedDescription), maintaining current state")
                newState = currentState
                
            // Handle clearManualISOOverride in any state - it's a no-op if not in SP mode
            case (_, .clearManualISOOverride):
                // Only relevant in shutter priority mode
                if case .shutterPriority(let duration, let manualISO) = currentState, manualISO != nil {
                    newState = .shutterPriority(targetDuration: duration, manualISO: nil)
                } else {
                    // No-op in other states
                    newState = currentState
                }
                
            // Default: maintain current state for invalid transitions
            default:
                logger.debug("No valid transition from \(String(describing: self.currentState)) with event \(String(describing: event))")
                newState = currentState
            }
            
            if newState != oldState {
                currentState = newState
                logger.info("Exposure state transition: \(String(describing: oldState)) -> \(String(describing: newState))")
                onStateChange?(oldState, newState)
            }
            
            return newState
        }
    }
    
    /// Get the AVCaptureDevice.ExposureMode that corresponds to the current state
    func deviceExposureMode(for state: ExposureState) -> AVCaptureDevice.ExposureMode {
        switch state {
        case .auto:
            return .continuousAutoExposure
        case .manual, .shutterPriority:
            return .custom
        case .locked, .recordingLocked:
            return .locked
        }
    }
    
    /// Check if a transition is valid from the current state
    func canTransition(to event: ExposureEvent) -> Bool {
        switch (currentState, event) {
        case (.recordingLocked, _):
            // Only allow stopping recording when in recording locked state
            return event == .stopRecording
        case (_, .stopRecording):
            // Can only stop recording if we're in recording locked state
            if case .recordingLocked = self.currentState {
                return true
            }
            return false
        default:
            return true
        }
    }
}
