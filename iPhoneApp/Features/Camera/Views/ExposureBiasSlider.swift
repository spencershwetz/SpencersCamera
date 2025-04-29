import SwiftUI

struct ExposureBiasSlider: View {
    @ObservedObject var viewModel: CameraViewModel
    @State private var isDragging = false
    @State private var feedbackGenerator = UIImpactFeedbackGenerator(style: .medium)
    @State private var lastFeedbackValue: Float = 0.0
    
    // Expanded stops for EV values from -5 to +5
    private let evStops: [Float] = [-5.0, -4.0, -3.0, -2.0, -1.0, 0.0, 1.0, 2.0, 3.0, 4.0, 5.0]
    private let feedbackThreshold: Float = 0.1 // How close to a stop before triggering feedback
    
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
                                .offset(y: geo.size.height * 0.8 * (0.5 - normalizedPosition) - 12)
                            }
                        }
                    }
                    .frame(height: geo.size.height * 0.8)
                    
                    // Slider thumb
                    Circle()
                        .fill(Color.white)
                        .frame(width: 24, height: 24)
                        .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
                        .offset(y: getThumbPosition(size: geo.size))
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    if !isDragging {
                                        feedbackGenerator.prepare()
                                        isDragging = true
                                    }
                                    
                                    let height = geo.size.height * 0.8
                                    // Calculate position in the visual range space
                                    let inputRatio = (value.location.y / height) + 0.1 // Adjust for the 0.8 height
                                    let visualRatio = 1 - inputRatio
                                    
                                    let visualRange = visualMaxEV - visualMinEV
                                    let visualValue = visualMinEV + (visualRange * Float(visualRatio))
                                    
                                    // Clamp to device's actual supported range
                                    let clampedBias = min(max(viewModel.minExposureBias, visualValue), viewModel.maxExposureBias)
                                    
                                    // Check if we're near a stop value for haptic feedback
                                    checkForFeedback(value: clampedBias)
                                    
                                    let delta = clampedBias - viewModel.exposureBias
                                    viewModel.adjustExposureBias(by: delta)
                                }
                                .onEnded { _ in
                                    isDragging = false
                                    lastFeedbackValue = viewModel.exposureBias
                                }
                        )
                }
            }
            .padding(.trailing, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
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
        
        // Map the current device EV to our visual scale
        let currentEV = viewModel.exposureBias
        let normalizedPosition = getVisualPosition(for: currentEV)
        
        return height * (0.5 - normalizedPosition)
    }
    
    // Check if we're near an EV stop for haptic feedback
    private func checkForFeedback(value: Float) {
        // Only provide feedback if we're crossing a stop value
        for stopValue in stride(from: Float(-5.0), through: Float(5.0), by: Float(1.0)) {
            if abs(value - stopValue) < feedbackThreshold && 
               (abs(lastFeedbackValue - stopValue) >= feedbackThreshold || 
               (value > stopValue && lastFeedbackValue < stopValue) || 
               (value < stopValue && lastFeedbackValue > stopValue)) {
                feedbackGenerator.impactOccurred()
                lastFeedbackValue = value
                break
            }
        }
    }
}

#Preview {
    ZStack {
        Color.black
        ExposureBiasSlider(viewModel: CameraViewModel())
            .frame(height: 600) // Make preview taller to see spacing
    }
} 