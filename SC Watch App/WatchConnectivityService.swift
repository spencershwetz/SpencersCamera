import Foundation
import WatchConnectivity
import Combine
import os.log

class WatchConnectivityService: NSObject, WCSessionDelegate, ObservableObject {
    
    static let shared = WatchConnectivityService()
    
    // Published properties for the UI to observe
    @Published var isRecording: Bool = false
    @Published var isReachable: Bool = false
    @Published var isCompanionAppActive: Bool = false
    @Published var recordingStartTime: Date? = nil
    @Published var frameRate: Double = 30.0 // Store frame rate, default to 30
    
    private var session: WCSession?
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.watchapp", category: "WatchConnectivityService")
    
    private override init() {
        super.init()
        if WCSession.isSupported() {
            session = WCSession.default
            session?.delegate = self
            session?.activate()
            logger.info("WCSession activated on watch.")
        } else {
            logger.warning("WCSession not supported on this watch device.")
        }
    }
    
    // Send start/stop command to iPhone
    func toggleRecording() {
        guard let session = session, session.isReachable, isCompanionAppActive else {
            logger.warning("Cannot send command: iPhone not reachable or companion app not active.")
            return
        }
        
        let command = isRecording ? "stopRecording" : "startRecording"
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
            return
        }
        logger.info("Watch WCSession activation completed with state: \(activationState.rawValue)")
        DispatchQueue.main.async {
            self.isReachable = session.isReachable
            // Request initial context update upon activation
            self.requestContextUpdateFromPhone()
        }
    }
    
    func sessionReachabilityDidChange(_ session: WCSession) {
        logger.info("iPhone reachability changed: \(session.isReachable)")
        DispatchQueue.main.async {
             self.isReachable = session.isReachable
             if !session.isReachable {
                 // Reset states if phone becomes unreachable
                 self.isCompanionAppActive = false
                 self.isRecording = false
                 self.recordingStartTime = nil
             } else {
                 // Request context when becoming reachable again
                 self.requestContextUpdateFromPhone()
             }
        }
    }
    
    // Receive application context updates from iPhone
    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String : Any]) {
        logger.info("Received application context from iPhone: \(applicationContext)")
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            let newRecordingStatus = applicationContext["isRecording"] as? Bool ?? false
            let newAppActiveStatus = applicationContext["isAppActive"] as? Bool ?? false
            var newStartTime: Date? = nil
            // Default frame rate if not provided
            var newFrameRate = self.frameRate // Keep current if key is missing

            if let startTimeInterval = applicationContext["recordingStartTime"] as? TimeInterval {
                newStartTime = Date(timeIntervalSince1970: startTimeInterval)
            }
            
            // Update frame rate
            if let receivedFrameRate = applicationContext["selectedFrameRate"] as? Double {
                 newFrameRate = receivedFrameRate
            }
            
            // Update properties only if they changed to avoid redundant UI updates
            if self.isRecording != newRecordingStatus {
                self.isRecording = newRecordingStatus
                self.logger.info("Updated isRecording state to: \(newRecordingStatus)")
            }
            if self.isCompanionAppActive != newAppActiveStatus {
                self.isCompanionAppActive = newAppActiveStatus
                self.logger.info("Updated isCompanionAppActive state to: \(newAppActiveStatus)")
            }
            if self.recordingStartTime != newStartTime {
                self.recordingStartTime = newStartTime
                self.logger.info("Updated recordingStartTime to: \(String(describing: newStartTime))")
            }
            if self.frameRate != newFrameRate {
                self.frameRate = newFrameRate
                self.logger.info("Updated frameRate to: \(newFrameRate)")
            }
            
             // If app becomes inactive, ensure recording state is also false
            if !newAppActiveStatus {
                if self.isRecording {
                    self.isRecording = false
                    self.logger.info("Companion app inactive, setting recording state to false.")
                }
                if self.recordingStartTime != nil {
                    self.recordingStartTime = nil
                    self.logger.info("Companion app inactive, clearing start time.")
                }
            }
        }
    }
    
    // Helper to request context (e.g., when watch app launches or becomes reachable)
    private func requestContextUpdateFromPhone() {
         guard let session = session, session.isReachable else {
             logger.debug("Request context update skipped: iPhone not reachable.")
             return
         }
         // Send an empty message; the iOS side can reply with current context or trigger a context update
         // For now, we rely on the iOS app sending context when it becomes active or changes state.
         // Alternatively, the iOS app could handle a specific "requestContext" message.
         logger.info("Relying on iOS app to send context update.")
    }
    
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