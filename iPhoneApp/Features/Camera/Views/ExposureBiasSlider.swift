import SwiftUI
import CoreHaptics

struct ExposureBiasSlider: View {
    @ObservedObject var viewModel: CameraViewModel
    @State private var isDragging = false
    @State private var dragStartBias: Float = 0.0
    @State private var dragStartPosition: CGFloat = 0.0
    
    // Haptic engine management
    @State private var hapticEngine: CHHapticEngine?
    @State private var lastFeedbackValue: Float = 0.0
    
    // Sensitivity adjustment - lower value means less sensitive
    private let dragSensitivity: CGFloat = 0.5
    
    // Expanded stops for EV values from -5 to +5
    private let evStops: [Float] = [-5.0, -4.0, -3.0, -2.0, -1.0, 0.0, 1.0, 2.0, 3.0, 4.0, 5.0]
    
    // Visual full range (even if device doesn't support full ±5 EV range)
    private let visualMinEV: Float = -5.0
    private let visualMaxEV: Float = 5.0
    
    var body: some View {
        GeometryReader { geo in
            VStack {
                ZStack(alignment: .trailing) {
                    // Slider track background
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.white.opacity(0.15))
                        .frame(width: 3, height: geo.size.height * 0.8)
                        .padding(.vertical, geo.size.height * 0.1) // Center vertically
                    
                    // Tick marks for stops
                    VStack(spacing: 0) {
                        ForEach(evStops.indices, id: \.self) { index in
                            let normalizedPosition = getVisualPosition(for: evStops[index])
                            
                            // Only show ticks that are within the device's actual supported range
                            if evStops[index] >= viewModel.minExposureBias && 
                               evStops[index] <= viewModel.maxExposureBias {
                                HStack(spacing: 6) {
                                    // Tick mark
                                    RoundedRectangle(cornerRadius: 1)
                                        .fill(Color.white.opacity(evStops[index] == 0 ? 0.8 : 0.4))
                                        .frame(width: evStops[index] == 0 ? 16 : 12, height: 2)
                                    
                                    // Value label for all whole stops
                                    Text("\(evStops[index] > 0 ? "+" : "")\(Int(evStops[index]))")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(.white.opacity(0.8))
                                }
                                .frame(height: 24)
                                .offset(y: geo.size.height * 0.8 * (0.5 - normalizedPosition) - 12 + geo.size.height * 0.1)
                            }
                        }
                    }
                    .frame(height: geo.size.height)
                    
                    // Hit area for the slider (wider than the visual track)
                    Color.clear
                        .frame(width: 44, height: geo.size.height * 0.8)
                        .padding(.vertical, geo.size.height * 0.1)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 2)
                                .onChanged { value in
                                    if !isDragging {
                                        // Initialize for drag start
                                        prepareHaptics()
                                        isDragging = true
                                        dragStartBias = viewModel.exposureBias
                                        dragStartPosition = value.location.y
                                    }
                                    
                                    // Calculate slider area
                                    let sliderHeight = geo.size.height * 0.8
                                    
                                    // Calculate delta based on drag movement with reduced sensitivity
                                    let dragDelta = value.location.y - dragStartPosition
                                    
                                    // Convert drag delta to EV bias delta (negative because up = positive EV)
                                    // Apply sensitivity adjustment to make dragging less sensitive
                                    let visualRange = visualMaxEV - visualMinEV
                                    let evDelta = -Float(dragDelta / sliderHeight * dragSensitivity) * visualRange
                                    
                                    // Calculate new bias value based on start value plus delta
                                    let newBias = dragStartBias + evDelta
                                    
                                    // First clamp to visual range
                                    let visuallyClampedBias = min(max(visualMinEV, newBias), visualMaxEV)
                                    
                                    // Then clamp to device's actual supported range
                                    let deviceClampedBias = min(max(viewModel.minExposureBias, visuallyClampedBias), viewModel.maxExposureBias)
                                    
                                    // Only update if value changed
                                    if deviceClampedBias != viewModel.exposureBias {
                                        // Check for feedback at whole EV stops
                                        checkForFeedbackAndTrigger(oldValue: viewModel.exposureBias, newValue: deviceClampedBias)
                                        
                                        // Update the exposure bias
                                        let delta = deviceClampedBias - viewModel.exposureBias
                                        viewModel.adjustExposureBias(by: delta)
                                    }
                                }
                                .onEnded { _ in
                                    isDragging = false
                                }
                        )
                    
                    // Slider thumb
                    Circle()
                        .fill(Color.white)
                        .frame(width: 24, height: 24)
                        .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
                        .offset(y: getThumbPosition(size: geo.size))
                }
            }
            .padding(.trailing, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            .onAppear {
                prepareHaptics()
            }
        }
    }
    
    // Prepare haptic engine
    private func prepareHaptics() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        
        do {
            hapticEngine = try CHHapticEngine()
            try hapticEngine?.start()
            
            // Handle stopping
            hapticEngine?.stoppedHandler = { reason in
                print("Haptic engine stopped: \(reason)")
            }
            
            // Automatically restart if necessary
            hapticEngine?.resetHandler = {
                print("Haptic engine needs reset")
                do {
                    let engine = try CHHapticEngine()
                    try engine.start()
                } catch {
                    print("Failed to restart haptic engine: \(error)")
                }
            }
        } catch {
            print("Haptic engine creation error: \(error)")
        }
    }
    
    // Trigger haptic feedback when crossing integer EV values
    private func checkForFeedbackAndTrigger(oldValue: Float, newValue: Float) {
        for stopValue in evStops {
            // Check if we've crossed this stop value
            if (oldValue < stopValue && newValue >= stopValue) || 
               (oldValue > stopValue && newValue <= stopValue) {
                triggerHapticFeedback(intensity: 0.8)
                break
            }
        }
    }
    
    // Trigger haptic feedback using CoreHaptics for stronger, more reliable feedback
    private func triggerHapticFeedback(intensity: Float) {
        // First try CoreHaptics for stronger feedback
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics,
              let engine = hapticEngine else {
            // Fallback to UIKit haptics if CoreHaptics isn't available
            let impactFeedback = UIImpactFeedbackGenerator(style: .rigid)
            impactFeedback.prepare()
            impactFeedback.impactOccurred(intensity: CGFloat(intensity))
            return
        }
        
        do {
            // Create a pattern
            let intensity = CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity)
            let sharpness = CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.9)
            
            // Create an event
            let event = CHHapticEvent(eventType: .hapticTransient, parameters: [intensity, sharpness], relativeTime: 0)
            
            // Create a pattern from the event
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            
            // Create a player for the pattern
            let player = try engine.makePlayer(with: pattern)
            
            // Start the player
            try player.start(atTime: CHHapticTimeImmediate)
            
        } catch {
            print("Failed to play haptic pattern: \(error)")
            
            // Fallback to UIKit haptics
            let impactFeedback = UIImpactFeedbackGenerator(style: .rigid)
            impactFeedback.prepare()
            impactFeedback.impactOccurred(intensity: CGFloat(intensity))
        }
    }
    
    // Convert EV value to normalized position in visual space [0-1]
    private func getVisualPosition(for value: Float) -> CGFloat {
        let visualRange = visualMaxEV - visualMinEV
        return CGFloat((value - visualMinEV) / visualRange)
    }
    
    // Calculate thumb vertical position based on current exposure bias
    private func getThumbPosition(size: CGSize) -> CGFloat {
        let height = size.height * 0.8
        let verticalOffset = size.height * 0.1 // 10% top margin
        
        // Map the current device EV to our visual scale
        let currentEV = viewModel.exposureBias
        // Clamp the visual representation to our display range
        let clampedEV = min(max(visualMinEV, currentEV), visualMaxEV)
        let normalizedPosition = getVisualPosition(for: clampedEV)
        
        // Position from top of the slider area
        let position = height * (0.5 - normalizedPosition)
        
        // Add the vertical offset to position within the full view
        return position + verticalOffset
    }
}

#Preview {
    ZStack {
        Color.black
        ExposureBiasSlider(viewModel: CameraViewModel())
            .frame(height: 600) // Make preview taller to see spacing
    }
} 