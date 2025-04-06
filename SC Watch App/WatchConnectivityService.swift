import Foundation
import WatchConnectivity
import Combine
import os.log

class WatchConnectivityService: NSObject, WCSessionDelegate, ObservableObject {
    
    static let shared = WatchConnectivityService()
    
    // Single published property for the latest received context
    @Published var latestContext: [String: Any]
    
    // Removed individual @Published properties:
    // @Published var isRecording: Bool = false
    // @Published var isReachable: Bool = false
    // @Published var isCompanionAppActive: Bool = false
    // @Published var recordingStartTime: Date? = nil
    // @Published var frameRate: Double = 30.0
    
    private var session: WCSession?
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.watchapp", category: "WatchConnectivityService")
    
    private override init() {
        // Initialize latestContext with received context or empty dictionary
        if WCSession.isSupported() {
            self.latestContext = WCSession.default.receivedApplicationContext
        } else {
            self.latestContext = [:]
        }
        
        super.init()
        if WCSession.isSupported() {
            session = WCSession.default
            session?.delegate = self
            session?.activate()
            logger.info("WCSession activated on watch. Initial context: \(self.latestContext)")
        } else {
            logger.warning("WCSession not supported on this watch device.")
        }
    }
    
    // Send start/stop command to iPhone
    func toggleRecording() {
        let isAppActive = latestContext["isAppActive"] as? Bool ?? false
        let isRecordingNow = latestContext["isRecording"] as? Bool ?? false

        guard let session = session, session.isReachable, isAppActive else {
            logger.warning("Cannot send command: iPhone not reachable or companion app not active.")
            return
        }
        
        let command = isRecordingNow ? "stopRecording" : "startRecording"
        let message = ["command": command]
        
        logger.info("Sending message to iPhone: \(message)")
        
        session.sendMessage(message, replyHandler: { reply in
            self.logger.info("Received reply from iPhone: \(reply)")
            // Optional: Handle reply confirmation if needed
        }) { error in
            self.logger.error("Error sending message to iPhone: \(error.localizedDescription)")
        }
    }
    
    // MARK: - WCSessionDelegate Methods
    
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let error = error {
            logger.error("Watch WCSession activation failed: \(error.localizedDescription)")
            // Update context to empty on activation failure
            DispatchQueue.main.async { self.latestContext = [:] }
            return
        }
        logger.info("Watch WCSession activation completed with state: \(activationState.rawValue)")
        DispatchQueue.main.async {
             // Update latestContext with received context on activation
            self.latestContext = session.receivedApplicationContext
            self.logger.info("Updated latestContext on activation: \(self.latestContext)")
            // No need to request context, just rely on received context
        }
    }
    
    func sessionReachabilityDidChange(_ session: WCSession) {
        logger.info("iPhone reachability changed: \(session.isReachable)")
        if !session.isReachable {
             // Clear context if phone becomes unreachable to signify outdated state
             DispatchQueue.main.async { 
                 self.latestContext = [:] 
                 self.logger.info("Cleared latestContext as iPhone became unreachable.")
             }
        } else {
             // When becoming reachable, update with the potentially already received context
             DispatchQueue.main.async { 
                 self.latestContext = session.receivedApplicationContext
                 self.logger.info("Updated latestContext on becoming reachable: \(self.latestContext)")
             }
        }
    }
    
    // Receive application context updates from iPhone
    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String : Any]) {
        logger.info("Received application context update from iPhone: \(applicationContext)")
        DispatchQueue.main.async { [weak self] in
            self?.latestContext = applicationContext
            self?.logger.info("Updated latestContext: \(String(describing: self?.latestContext))")
        }
    }
    
    // Removed private func requestContextUpdateFromPhone()
    
    // Required delegate methods for iOS compatibility (can be empty on watchOS)
    #if os(iOS)
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    #endif

    func session(_ session: WCSession, didReceiveMessage message: [String : Any], replyHandler: @escaping ([String : Any]) -> Void) {
        if let command = message["command"] as? String {
            if command == "launchApp" {
                logger.info("⌚️ Received launchApp command from iPhone. App should activate.")
                // No specific action needed here, receiving the message triggers activation
            }

            // Acknowledge receipt
            replyHandler(["status": "message received"])
        }
    }
} 