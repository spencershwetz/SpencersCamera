import Foundation
import AVFoundation
import os.log

/// Manages error recovery and retry logic for exposure operations
actor ExposureErrorRecovery {
    private let logger = Logger(subsystem: "com.camera", category: "ExposureErrorRecovery")
    
    // Retry configuration
    private let maxRetries = 3
    private let baseDelay: TimeInterval = 0.1 // 100ms
    private let maxDelay: TimeInterval = 2.0
    
    // Circuit breaker configuration
    private let failureThreshold = 5
    private let recoveryTimeout: TimeInterval = 10.0
    
    // State tracking
    private var failureCount = 0
    private var lastFailureTime: Date?
    private var isCircuitOpen = false
    private var circuitOpenedAt: Date?
    
    // Pending operations queue during transitions
    private var pendingOperations: [ExposureOperation] = []
    private var isTransitioning = false
    
    /// Represents an exposure operation that can be retried
    struct ExposureOperation {
        let id = UUID()
        let type: OperationType
        let execute: () async throws -> Void
        let validate: () -> Bool
        
        enum OperationType: String {
            case setISO
            case setShutterSpeed
            case setWhiteBalance
            case setExposureMode
            case lockExposure
            case applyShutterPriority
        }
    }
    
    /// Executes an exposure operation with retry logic
    func executeWithRetry(_ operation: ExposureOperation) async throws {
        // Check circuit breaker
        if isCircuitOpen {
            try await checkCircuitBreakerRecovery()
            if isCircuitOpen {
                logger.error("Circuit breaker is open, rejecting operation: \(operation.type.rawValue)")
                throw ExposureServiceError.circuitBreakerOpen
            }
        }
        
        // Queue operation if transitioning
        if isTransitioning {
            logger.info("Queuing operation during transition: \(operation.type.rawValue)")
            pendingOperations.append(operation)
            return
        }
        
        var lastError: Error?
        
        for attempt in 0..<maxRetries {
            do {
                // Validate preconditions
                guard operation.validate() else {
                    logger.warning("Operation validation failed: \(operation.type.rawValue)")
                    throw ExposureServiceError.invalidState
                }
                
                // Execute the operation
                try await operation.execute()
                
                // Reset failure tracking on success
                recordSuccess()
                
                logger.info("Operation succeeded: \(operation.type.rawValue) (attempt \(attempt + 1))")
                return
                
            } catch {
                lastError = error
                logger.error("Operation failed: \(operation.type.rawValue), attempt \(attempt + 1)/\(self.maxRetries), error: \(error)")
                
                recordFailure()
                
                // Don't retry if it's a permanent error
                if isPermanentError(error) {
                    logger.error("Permanent error detected, not retrying: \(error)")
                    throw error
                }
                
                // Don't retry if we've exhausted attempts
                if attempt >= maxRetries - 1 {
                    break
                }
                
                // Calculate exponential backoff delay
                let delay = calculateBackoffDelay(attempt: attempt)
                logger.debug("Waiting \(delay)s before retry...")
                
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        
        // All retries exhausted
        logger.error("All retries exhausted for operation: \(operation.type.rawValue)")
        throw lastError ?? ExposureServiceError.retryExhausted
    }
    
    /// Marks the start of a lens transition
    func beginTransition() {
        logger.info("Beginning lens transition, queuing operations")
        isTransitioning = true
    }
    
    /// Marks the end of a lens transition and processes queued operations
    func endTransition() async {
        logger.info("Ending lens transition, processing \(self.pendingOperations.count) queued operations")
        isTransitioning = false
        
        let operations = pendingOperations
        pendingOperations.removeAll()
        
        for operation in operations {
            do {
                try await executeWithRetry(operation)
            } catch {
                logger.error("Failed to execute queued operation: \(operation.type.rawValue), error: \(error)")
            }
        }
    }
    
    /// Clears all pending operations (e.g., when device changes)
    func clearPendingOperations() {
        logger.info("Clearing \(self.pendingOperations.count) pending operations")
        pendingOperations.removeAll()
    }
    
    // MARK: - Private Methods
    
    private func recordSuccess() {
        failureCount = max(0, failureCount - 1)
        
        // Close circuit if it was open and we've had a success
        if isCircuitOpen {
            logger.info("Circuit breaker closing after successful operation")
            isCircuitOpen = false
            circuitOpenedAt = nil
        }
    }
    
    private func recordFailure() {
        failureCount += 1
        lastFailureTime = Date()
        
        // Open circuit if we've hit the threshold
        if failureCount >= failureThreshold && !isCircuitOpen {
            logger.warning("Circuit breaker opening after \(self.failureCount) failures")
            isCircuitOpen = true
            circuitOpenedAt = Date()
        }
    }
    
    private func checkCircuitBreakerRecovery() async throws {
        guard isCircuitOpen,
              let openedAt = circuitOpenedAt else { return }
        
        let timeOpen = Date().timeIntervalSince(openedAt)
        if timeOpen >= recoveryTimeout {
            logger.info("Circuit breaker recovery timeout reached, attempting half-open state")
            // Circuit moves to half-open state - next operation will test if system has recovered
            // Don't close it yet, let the next successful operation do that
        }
    }
    
    private func calculateBackoffDelay(attempt: Int) -> TimeInterval {
        let exponentialDelay = baseDelay * pow(2.0, Double(attempt))
        let jitteredDelay = exponentialDelay * (0.5 + Double.random(in: 0...0.5))
        return min(jitteredDelay, maxDelay)
    }
    
    private func isPermanentError(_ error: Error) -> Bool {
        // Determine if an error is permanent and shouldn't be retried
        if let exposureError = error as? ExposureServiceError {
            switch exposureError {
            case .deviceUnavailable, .invalidState:
                return true
            case .transitionFailed, .lockFailed, .circuitBreakerOpen, .retryExhausted:
                return false
            case .custom:
                return false
            }
        }
        
        if let cameraError = error as? CameraError {
            switch cameraError {
            case .unauthorized, .mediaServicesWereReset:
                return true
            default:
                return false
            }
        }
        
        // AVFoundation errors
        if let avError = error as? AVError {
            switch avError.code {
            case .applicationIsNotAuthorizedToUseDevice,
                 .deviceNotConnected,
                 .unsupportedDeviceActiveFormat:
                return true
            default:
                return false
            }
        }
        
        return false
    }
}

