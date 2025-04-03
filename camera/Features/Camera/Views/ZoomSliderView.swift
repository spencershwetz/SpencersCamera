import SwiftUI
import Foundation

struct ZoomSliderView: View {
    @ObservedObject var viewModel: CameraViewModel
    let availableLenses: [CameraLens]
    @State private var isDragging = false
    @State private var dragVelocity: CGFloat = 0
    @State private var lastDragLocation: CGPoint?
    @State private var lastDragTime: Date?
    
    private let minZoom: CGFloat = 1.0
    private let maxZoom: CGFloat = 10.0
    private let sliderWidth: CGFloat = 200
    
    var body: some View {
        VStack(spacing: 12) {
            // Zoom slider
            GeometryReader { geometry in
                HStack {
                    Spacer()
                    ZStack(alignment: .leading) {
                        // Background track
                        Rectangle()
                            .fill(Color.white.opacity(0.3))
                            .frame(height: 2)
                        
                        // Zoom indicator
                        Rectangle()
                            .fill(Color.yellow)
                            .frame(width: 2, height: 12)
                            .offset(x: normalizedPosition * sliderWidth)
                        
                        // Lens position indicators
                        ForEach(availableLenses, id: \.self) { lens in
                            Rectangle()
                                .fill(Color.white.opacity(0.5))
                                .frame(width: 1, height: 8)
                                .offset(x: normalizedZoomPosition(for: lens) * sliderWidth)
                        }
                    }
                    .frame(width: sliderWidth)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                isDragging = true
                                
                                // Calculate velocity
                                if let lastLocation = lastDragLocation,
                                   let lastTime = lastDragTime {
                                    let deltaX = value.location.x - lastLocation.x
                                    let deltaTime = Date().timeIntervalSince(lastTime)
                                    dragVelocity = CGFloat(deltaX / CGFloat(deltaTime))
                                }
                                
                                lastDragLocation = value.location
                                lastDragTime = Date()
                                
                                // Apply zoom with velocity sensitivity
                                let normalizedX = value.location.x / sliderWidth
                                let velocityFactor = min(abs(dragVelocity) / 1000, 2.0)
                                let zoomDelta = (normalizedX - normalizedPosition) * velocityFactor
                                let newZoom = calculateZoomFactor(for: normalizedPosition + zoomDelta)
                                
                                // Handle lens transitions
                                switch viewModel.currentLens {
                                case .wide:
                                    if newZoom >= 2.0 {
                                        viewModel.switchToLens(.x2)
                                    } else {
                                        viewModel.setZoomFactor(newZoom)
                                    }
                                case .x2:
                                    if newZoom <= 1.0 {
                                        viewModel.switchToLens(.wide)
                                    } else if newZoom >= 5.0 && availableLenses.contains(.telephoto) {
                                        viewModel.switchToLens(.telephoto)
                                    } else {
                                        viewModel.setZoomFactor(newZoom)
                                    }
                                case .telephoto:
                                    if newZoom <= 2.0 {
                                        viewModel.switchToLens(.x2)
                                    } else {
                                        viewModel.setZoomFactor(min(newZoom, 10.0))
                                    }
                                default:
                                    viewModel.setZoomFactor(newZoom)
                                }
                            }
                            .onEnded { _ in
                                isDragging = false
                                lastDragLocation = nil
                                lastDragTime = nil
                                dragVelocity = 0
                            }
                    )
                    Spacer()
                }
            }
            .frame(height: 20)
            
            // Current zoom display
            Text(String(format: "%.1f×", viewModel.currentZoomFactor))
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.yellow)
                .opacity(isDragging ? 1 : 0)
            
            // Lens buttons
            HStack(spacing: 14) {
                ForEach(availableLenses, id: \.self) { lens in
                    // Use the helper function to determine highlighting
                    let highlight = self.shouldHighlight(lens: lens)
                    
                    Button(action: {
                        viewModel.switchToLens(lens)
                    }) {
                        Text(lens.rawValue + "×")
                            .font(.system(size: highlight ? 17 : 15, weight: .medium))
                            .foregroundColor(highlight ? .yellow : .white)
                            .frame(width: highlight ? 42 : 36, height: highlight ? 42 : 36)
                            .background(
                                Circle()
                                    .fill(Color.black.opacity(0.65))
                            )
                    }
                    .transition(.scale)
                }
            }
        }
    }
    
    // Helper function to determine if a lens button should be highlighted
    private func shouldHighlight(lens: CameraLens) -> Bool {
        if lens == .x2 {
            // Highlight 2x only if zoom factor is near 2.0
            return abs(viewModel.currentZoomFactor - 2.0) < 0.01
        } else if lens == .wide {
            // Highlight 1x only if it's the current lens AND zoom is NOT near 2.0
            return viewModel.currentLens == .wide && abs(viewModel.currentZoomFactor - 2.0) >= 0.01
        } else {
            // Highlight other physical lenses only if they are the current lens
            return viewModel.currentLens == lens
        }
    }
    
    private var normalizedPosition: CGFloat {
        (viewModel.currentZoomFactor - minZoom) / (maxZoom - minZoom)
    }
    
    private func normalizedZoomPosition(for lens: CameraLens) -> CGFloat {
        (lens.zoomFactor - minZoom) / (maxZoom - minZoom)
    }
    
    private func calculateZoomFactor(for normalized: CGFloat) -> CGFloat {
        let clamped = normalized.clamped(to: 0...1)
        return minZoom + (clamped * (maxZoom - minZoom))
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        return min(max(self, range.lowerBound), range.upperBound)
    }
} 