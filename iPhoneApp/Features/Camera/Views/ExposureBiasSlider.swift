import SwiftUI

struct ExposureBiasSlider: View {
    @ObservedObject var viewModel: CameraViewModel
    @State private var isDragging = false
    @State private var feedbackGenerator = UIImpactFeedbackGenerator(style: .medium)
    @State private var lastFeedbackValue: Float = 0.0
    
    // Stops for EV values (e.g., -2, -1, 0, 1, 2)
    private let evStops: [Float] = [-2.0, -1.5, -1.0, -0.5, 0.0, 0.5, 1.0, 1.5, 2.0]
    private let feedbackThreshold: Float = 0.1 // How close to a stop before triggering feedback
    
    var body: some View {
        GeometryReader { geo in
            VStack {
                ZStack(alignment: .trailing) {
                    // Slider track background
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.white.opacity(0.15))
                        .frame(width: 3, height: geo.size.height * 0.6)
                    
                    // Tick marks for stops
                    VStack(spacing: 0) {
                        ForEach(evStops.indices, id: \.self) { index in
                            let normalizedPosition = getNormalizedPosition(for: evStops[index])
                            HStack {
                                // Tick mark
                                RoundedRectangle(cornerRadius: 1)
                                    .fill(Color.white.opacity(evStops[index] == 0 ? 0.8 : 0.4))
                                    .frame(width: evStops[index] == 0 ? 12 : 8, height: 2)
                                
                                // Value label only for primary stops (-2, -1, 0, 1, 2)
                                if abs(evStops[index].truncatingRemainder(dividingBy: 1.0)) < 0.01 {
                                    Text("\(evStops[index] > 0 ? "+" : "")\(Int(evStops[index]))")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundColor(.white.opacity(0.8))
                                }
                            }
                            .frame(height: 20)
                            .offset(y: geo.size.height * 0.6 * (0.5 - normalizedPosition) - 10)
                        }
                    }
                    .frame(height: geo.size.height * 0.6)
                    
                    // Slider thumb
                    Circle()
                        .fill(Color.white)
                        .frame(width: 20, height: 20)
                        .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
                        .offset(y: getThumbPosition(size: geo.size))
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    if !isDragging {
                                        feedbackGenerator.prepare()
                                        isDragging = true
                                    }
                                    
                                    let height = geo.size.height * 0.6
                                    let ratio = 1 - ((value.location.y / height) + 0.5)
                                    
                                    let biasDelta = Float(ratio) * (viewModel.maxExposureBias - viewModel.minExposureBias)
                                    let newBias = viewModel.minExposureBias + biasDelta
                                    let clampedBias = min(max(viewModel.minExposureBias, newBias), viewModel.maxExposureBias)
                                    
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
            .padding(.trailing, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        }
    }
    
    // Convert EV value to normalized position [0-1]
    private func getNormalizedPosition(for value: Float) -> CGFloat {
        let range = viewModel.maxExposureBias - viewModel.minExposureBias
        return CGFloat((value - viewModel.minExposureBias) / range)
    }
    
    // Calculate thumb vertical position based on current exposure bias
    private func getThumbPosition(size: CGSize) -> CGFloat {
        let height = size.height * 0.6
        let normalizedBias = getNormalizedPosition(for: viewModel.exposureBias)
        return height * (0.5 - normalizedBias)
    }
    
    // Check if we're near an EV stop for haptic feedback
    private func checkForFeedback(value: Float) {
        // Only provide feedback if we're crossing a stop value
        for stop in evStops {
            if abs(value - stop) < feedbackThreshold && 
               (abs(lastFeedbackValue - stop) >= feedbackThreshold || 
               (value > stop && lastFeedbackValue < stop) || 
               (value < stop && lastFeedbackValue > stop)) {
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
    }
} 