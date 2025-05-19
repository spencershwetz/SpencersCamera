import CoreHaptics
import os.log
import UIKit
import SwiftUI

class HapticManager {
    static let shared = HapticManager()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "HapticManager")

    private var engine: CHHapticEngine?
    private var supportsHaptics: Bool = false
    private var isEngineRunning: Bool = false
    private var isAppActive: Bool = true
    
    // UIKit haptic generators
    private let lightGenerator = UIImpactFeedbackGenerator(style: .light)
    private let mediumGenerator = UIImpactFeedbackGenerator(style: .medium)
    private let heavyGenerator = UIImpactFeedbackGenerator(style: .heavy)
    private let selectionGenerator = UISelectionFeedbackGenerator()
    private let notificationGenerator = UINotificationFeedbackGenerator()
    
    // Queue for synchronizing haptic operations
    private let hapticQueue = DispatchQueue(label: "com.spencer.camera.haptics", qos: .userInteractive)
    
    // Debounce timing
    private var lastHapticTime: [String: TimeInterval] = [:]
    private let minHapticInterval: TimeInterval = 0.1 // Minimum time between haptics of same type
    
    // For SwiftUI event timing issues
    private var isPrepared = false
    private var prepareTimer: Timer?

    private init() {
        // Observe app state
        NotificationCenter.default.addObserver(self, selector: #selector(appDidBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appWillResignActive), name: UIApplication.willResignActiveNotification, object: nil)
        
        // Initialize UIKit generators on a high priority background thread
        hapticQueue.async { [weak self] in
            guard let self = self else { return }
            self.lightGenerator.prepare()
            self.mediumGenerator.prepare()
            self.heavyGenerator.prepare()
            self.selectionGenerator.prepare()
            self.notificationGenerator.prepare()
            self.isPrepared = true
            self.startPreparationTimer()
        }
        
        // Initialize CoreHaptics
        supportsHaptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics
        guard supportsHaptics else {
            logger.warning("Device does not support Core Haptics.")
            return
        }
        createAndStartEngine()
    }
    
    @objc private func appDidBecomeActive() {
        isAppActive = true
        createAndStartEngine()
    }
    
    @objc private func appWillResignActive() {
        isAppActive = false
        stopEngine()
    }
    
    private func startPreparationTimer() {
        DispatchQueue.main.async { [weak self] in
            self?.prepareTimer?.invalidate()
            self?.prepareTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.prepareAllGenerators()
            }
        }
    }
    
    private func prepareAllGenerators() {
        hapticQueue.async { [weak self] in
            guard let self = self else { return }
            self.lightGenerator.prepare()
            self.mediumGenerator.prepare()
            self.heavyGenerator.prepare()
            self.selectionGenerator.prepare()
            self.notificationGenerator.prepare()
            self.isPrepared = true
        }
    }

    private func createAndStartEngine() {
        guard supportsHaptics else { return }
        do {
            engine = try CHHapticEngine()
            engine?.stoppedHandler = { [weak self] reason in
                self?.logger.warning("Haptic engine stopped: \(reason.rawValue)")
                self?.isEngineRunning = false
                // Attempt to restart the engine if stopped unexpectedly and app is active
                if self?.isAppActive == true {
                    self?.createAndStartEngine()
                }
            }
            engine?.resetHandler = { [weak self] in
                self?.logger.info("Haptic engine reset.")
                // Attempt to restart the engine after reset
                do {
                    try self?.engine?.start()
                    self?.isEngineRunning = true
                } catch {
                    self?.logger.error("Failed to restart haptic engine after reset: \(error.localizedDescription)")
                    self?.isEngineRunning = false
                }
            }
            try engine?.start()
            isEngineRunning = true
            logger.info("Core Haptics engine started successfully.")
        } catch {
            logger.error("Failed to create or start Core Haptics engine: \(error.localizedDescription)")
            engine = nil
            isEngineRunning = false
        }
    }

    func playTick() {
        guard supportsHaptics, let engine = engine else {
            logger.debug("Haptics not supported or engine not running, skipping tick.")
            return
        }

        do {
            // Ensure engine is running before playing
            try engine.start()

            // Create a simple, short tap pattern
            let intensity = CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.7)
            let sharpness = CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5)
            let event = CHHapticEvent(eventType: .hapticTransient, parameters: [intensity, sharpness], relativeTime: 0)

            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
            logger.debug("Played haptic tick via CoreHaptics.")
        } catch let error {
            logger.error("Failed to play haptic tick: \(error.localizedDescription)")
            // If start fails, try recreating engine
            if let chError = error as? CHHapticError {
                // Only check for the engine not running state
                if chError.code == .engineNotRunning {
                    logger.warning("Haptic engine was not running (code: \(chError.code.rawValue)), attempting to restart.")
                    createAndStartEngine()
                }
            }
        }
    }

    func stopEngine() {
        guard supportsHaptics, let engine = engine else { return }
        engine.stop(completionHandler: nil)
        isEngineRunning = false
        logger.info("Core Haptics engine stopped.")
    }
    
    // MARK: - UIKit Haptic Feedback Methods
    
    /// Trigger light impact feedback (best for small controls like buttons)
    func lightImpact() {
        guard isAppActive else {
            logger.debug("App not active, skipping haptic.")
            return
        }
        guard canTriggerHaptic(type: "light") else { return }
        DispatchQueue.main.async {
            self.lightGenerator.impactOccurred()
            self.lastHapticTime["light"] = Date().timeIntervalSince1970
            self.lightGenerator.prepare()
        }
    }
    
    /// Trigger medium impact feedback (best for medium controls)
    func mediumImpact() {
        guard isAppActive else {
            logger.debug("App not active, skipping haptic.")
            return
        }
        guard canTriggerHaptic(type: "medium") else { return }
        DispatchQueue.main.async {
            self.mediumGenerator.impactOccurred()
            self.lastHapticTime["medium"] = Date().timeIntervalSince1970
            self.mediumGenerator.prepare()
        }
    }
    
    /// Trigger heavy impact feedback (best for significant actions)
    func heavyImpact() {
        guard isAppActive else {
            logger.debug("App not active, skipping haptic.")
            return
        }
        guard canTriggerHaptic(type: "heavy") else { return }
        DispatchQueue.main.async {
            self.heavyGenerator.impactOccurred()
            self.lastHapticTime["heavy"] = Date().timeIntervalSince1970
            self.heavyGenerator.prepare()
        }
    }
    
    /// Trigger selection feedback (best for moving through discrete values)
    func selectionChanged() {
        guard isAppActive else {
            logger.debug("App not active, skipping haptic.")
            return
        }
        guard canTriggerHaptic(type: "selection") else { return }
        DispatchQueue.main.async {
            self.selectionGenerator.selectionChanged()
            self.lastHapticTime["selection"] = Date().timeIntervalSince1970
            self.selectionGenerator.prepare()
        }
    }
    
    /// Trigger notification feedback for success/warning/error
    func notification(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        guard isAppActive else {
            logger.debug("App not active, skipping haptic.")
            return
        }
        guard canTriggerHaptic(type: "notification_\(type.rawValue)") else { return }
        DispatchQueue.main.async {
            self.notificationGenerator.notificationOccurred(type)
            self.lastHapticTime["notification_\(type.rawValue)"] = Date().timeIntervalSince1970
            self.notificationGenerator.prepare()
        }
    }
    
    // Helper to prevent haptic overload
    private func canTriggerHaptic(type: String) -> Bool {
        let now = Date().timeIntervalSince1970
        if let lastTime = lastHapticTime[type], 
           now - lastTime < minHapticInterval {
            return false
        }
        return true
    }
} 