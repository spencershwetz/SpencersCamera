import CoreHaptics
import os.log

class HapticManager {
    static let shared = HapticManager()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "HapticManager")

    private var engine: CHHapticEngine?
    private var supportsHaptics: Bool = false

    private init() {
        supportsHaptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics
        guard supportsHaptics else {
            logger.warning("Device does not support Core Haptics.")
            return
        }
        createAndStartEngine()
    }

    private func createAndStartEngine() {
        guard supportsHaptics else { return }
        do {
            engine = try CHHapticEngine()
            engine?.stoppedHandler = { [weak self] reason in
                self?.logger.warning("Haptic engine stopped: \(reason.rawValue)")
                // Attempt to restart the engine if stopped unexpectedly
                self?.createAndStartEngine()
            }
            engine?.resetHandler = { [weak self] in
                self?.logger.info("Haptic engine reset.")
                // Attempt to restart the engine after reset
                do {
                    try self?.engine?.start()
                } catch {
                    self?.logger.error("Failed to restart haptic engine after reset: \(error.localizedDescription)")
                }
            }
            try engine?.start()
            logger.info("Core Haptics engine started successfully.")
        } catch {
            logger.error("Failed to create or start Core Haptics engine: \(error.localizedDescription)")
            engine = nil
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
        engine.stop()
        logger.info("Core Haptics engine stopped.")
    }
} 