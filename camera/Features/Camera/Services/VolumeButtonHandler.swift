import SwiftUI
import AVKit

@available(iOS 17.2, *)
@MainActor
class VolumeButtonHandler {
    private weak var viewModel: CameraViewModel?
    private var eventInteraction: AVCaptureEventInteraction?
    private var isProcessingEvent = false
    private let debounceInterval: TimeInterval = 1.0
    
    init(viewModel: CameraViewModel) {
        self.viewModel = viewModel
        setupVolumeButtonInteraction()
    }
    
    private func setupVolumeButtonInteraction() {
        // Primary handler (volume down button)
        let primaryHandler = { [weak self] (event: AVCaptureEvent) in
            guard let self = self,
                  let viewModel = self.viewModel,
                  !self.isProcessingEvent else { return }
            
            switch event.phase {
            case .began:
                Task { @MainActor in
                    guard !viewModel.isProcessingRecording else { return }
                    self.isProcessingEvent = true
                    
                    if !viewModel.isRecording {
                        await viewModel.startRecording()
                    } else {
                        await viewModel.stopRecording()
                    }
                    
                    // Add delay before allowing next event
                    try? await Task.sleep(for: .seconds(self.debounceInterval))
                    self.isProcessingEvent = false
                }
            default:
                break
            }
        }
        
        // Secondary handler (volume up button)
        let secondaryHandler = { [weak self] (event: AVCaptureEvent) in
            guard let self = self,
                  let viewModel = self.viewModel,
                  !self.isProcessingEvent else { return }
            
            switch event.phase {
            case .began:
                Task { @MainActor in
                    guard !viewModel.isProcessingRecording else { return }
                    self.isProcessingEvent = true
                    
                    if !viewModel.isRecording {
                        await viewModel.startRecording()
                    } else {
                        await viewModel.stopRecording()
                    }
                    
                    // Add delay before allowing next event
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
    }
    
    func attachToView(_ view: UIView) {
        guard let eventInteraction = eventInteraction else { return }
        view.addInteraction(eventInteraction)
        print("✅ Volume button interaction attached to view")
    }
    
    func detachFromView(_ view: UIView) {
        guard let eventInteraction = eventInteraction else { return }
        view.removeInteraction(eventInteraction)
        print("🔄 Volume button interaction detached from view")
    }
} 