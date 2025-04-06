import SwiftUI
import AVKit

@available(iOS 17.2, *)
@MainActor
class VolumeButtonHandler {
    // Action enum to represent volume button presses
    enum Action {
        case primary // Typically volume down
        case secondary // Typically volume up
    }
    
    private weak var session: AVCaptureSession?
    private var handler: ((Action) -> Void)?
    private var eventInteraction: AVCaptureEventInteraction?
    private var isProcessingEvent = false
    private let debounceInterval: TimeInterval = 0.5
    
    init(session: AVCaptureSession?, handler: @escaping (Action) -> Void) {
        self.session = session
        self.handler = handler
        setupVolumeButtonInteraction() // Setup interaction on init
    }
    
    // Attach interaction to a specific view
    func attach(to view: UIView) {
         guard let interaction = eventInteraction else { 
            print("VolumeButtonHandler Error: Interaction not setup.")
            return
         }
        // Ensure it's not already attached to this view
        if !view.interactions.contains(where: { $0 === interaction }) {
             view.addInteraction(interaction)
             print("✅ Volume button interaction attached to view: \(view)")
        }
    }

    // Detach interaction from a specific view
    func detach(from view: UIView) {
         guard let interaction = eventInteraction else { return }
         if view.interactions.contains(where: { $0 === interaction }) {
            view.removeInteraction(interaction)
            print("🔄 Volume button interaction detached from view: \(view)")
         }
         // Consider setting interaction = nil here if it's truly detached and won't be reattached
         // eventInteraction = nil
    }
    
    private func setupVolumeButtonInteraction() {
        // Ensure interaction isn't already set up
        guard eventInteraction == nil else { return }
        
        // Primary handler (volume down button)
        let primaryHandler = { [weak self] (event: AVCaptureEvent) in
            guard let self = self, !self.isProcessingEvent else { return }
            
            switch event.phase {
            case .began:
                 print("Primary Volume Button Began")
                 Task { @MainActor in
                    self.isProcessingEvent = true
                    self.handler?(.primary) // Call the handler closure
                    // Debounce
                    try? await Task.sleep(for: .seconds(self.debounceInterval))
                    self.isProcessingEvent = false
                }
            default:
                break
            }
        }
        
        // Secondary handler (volume up button)
        let secondaryHandler = { [weak self] (event: AVCaptureEvent) in
            guard let self = self, !self.isProcessingEvent else { return }
            
            switch event.phase {
            case .began:
                 print("Secondary Volume Button Began")
                 Task { @MainActor in
                    self.isProcessingEvent = true
                    self.handler?(.secondary) // Call the handler closure
                    // Debounce
                    try? await Task.sleep(for: .seconds(self.debounceInterval))
                    self.isProcessingEvent = false
                 }
            default:
                break
            }
        }
        
        // Create and configure the interaction
        eventInteraction = AVCaptureEventInteraction(primary: primaryHandler, secondary: secondaryHandler)
        eventInteraction?.isEnabled = true
        print("VolumeButtonHandler: Interaction created.")
    }
    
    // Remove attachToView and detachFromView as we now attach to the scene
    // func attachToView(_ view: UIView) { ... }
    // func detachFromView(_ view: UIView) { ... }
} 