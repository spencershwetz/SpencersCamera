import SwiftUI
import os.log

/// A horizontally scrolling wheel picker for Exposure Value (EV) compensation, based on the reference WheelPicker.
struct EVWheelPicker: View {
    // Logger instance
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "EVWheelPicker")
    
    // Bind to the camera's exposure bias value
    @Binding var value: Float
    let minEV: Float
    let maxEV: Float
    let step: Float
    let onEditingChanged: (Bool) -> Void
    
    // For haptic feedback and gesture tracking
    @State private var lastFeedbackValue: Float = 0.0
    @State private var dragOffset: CGFloat = 0
    @State private var isDragging = false
    @State private var isSettingValue = false
    
    // For smooth scrolling and state management
    @State private var initialOffset: CGFloat = 0
    @State private var accumulatedOffset: CGFloat = 0
    @State private var lastIndex: Int = 0
    
    // Threshold for gesture movement before updating value
    private let movementThreshold: CGFloat = 8.0
    
    private var evValues: [Float] {
        stride(from: minEV, through: maxEV, by: step).map { round($0 * 100) / 100 }
    }
    
    var body: some View {
        GeometryReader { geo in
            let itemWidth: CGFloat = 40 + 16 // width + spacing
            let horizontalPadding = geo.size.width / 2
            
            HStack(spacing: 16) {
                ForEach(evValues, id: \.self) { ev in
                    VStack(spacing: 4) {
                        Rectangle()
                            .fill(ev == 0 ? Color.accentColor : Color.gray.opacity(0.6))
                            .frame(width: 2, height: ev == 0 ? 32 : 20)
                        Text(ev == 0 ? "0" : String(format: "%+.1f", ev))
                            .font(.caption2)
                            .foregroundColor(ev == value ? .accentColor : .secondary)
                    }
                    .frame(width: 40)
                    .id(ev)
                }
            }
            .offset(x: horizontalPadding + accumulatedOffset + dragOffset)
            .gesture(
                DragGesture(minimumDistance: movementThreshold)
                    .onChanged { gesture in
                        isDragging = true
                        let translation = gesture.translation.width
                        
                        // Apply movement threshold and smoothing
                        let scrolledValue = -translation / itemWidth
                        let rawIndex = Int(round(scrolledValue))
                        
                        // Only update if we've moved enough to warrant a change
                        if abs(rawIndex - lastIndex) >= 1 {
                            let index = max(0, min(rawIndex, evValues.count - 1))
                            lastIndex = index
                            
                            let newValue = evValues[index]
                            if newValue != value {
                                logger.debug("📱 Setting new value: \(value) -> \(newValue)")
                                isSettingValue = true
                                value = newValue
                                hapticFeedbackIfNeeded(oldValue: lastFeedbackValue, newValue: newValue)
                                lastFeedbackValue = newValue
                                onEditingChanged(true)
                                isSettingValue = false
                            }
                        }
                        
                        // Update visual offset with smoothing
                        dragOffset = translation
                    }
                    .onEnded { gesture in
                        isDragging = false
                        
                        // Find the nearest value with improved rounding
                        let finalOffset = gesture.translation.width
                        let nearestIndex = Int(round(-finalOffset / itemWidth))
                        let clampedIndex = max(0, min(nearestIndex, evValues.count - 1))
                        
                        // Animate to the nearest value
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8, blendDuration: 0.2)) {
                            accumulatedOffset = -CGFloat(clampedIndex) * itemWidth
                            dragOffset = 0
                        }
                        
                        // Update the value one final time
                        let finalValue = evValues[clampedIndex]
                        if finalValue != value {
                            isSettingValue = true
                            value = finalValue
                            lastFeedbackValue = finalValue
                            isSettingValue = false
                        }
                        
                        lastIndex = clampedIndex
                        onEditingChanged(false)
                    }
            )
        }
        .frame(height: 72)
        .onAppear {
            // Set initial position
            if let index = evValues.firstIndex(of: value) {
                accumulatedOffset = -CGFloat(index) * (40 + 16)
                initialOffset = accumulatedOffset
                lastFeedbackValue = value
                lastIndex = index
            }
        }
        .onChange(of: value) { oldValue, newValue in
            // Only update position if the value was changed externally (not by dragging)
            if !isSettingValue, !isDragging, let index = evValues.firstIndex(of: newValue) {
                logger.debug("📍 External value change: \(oldValue) -> \(newValue)")
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8, blendDuration: 0.2)) {
                    accumulatedOffset = -CGFloat(index) * (40 + 16)
                }
                initialOffset = accumulatedOffset
                lastFeedbackValue = newValue
                lastIndex = index
            }
        }
        .overlay(
            Rectangle()
                .frame(width: 2, height: 48)
                .foregroundColor(.accentColor)
                .opacity(0.8),
            alignment: .center
        )
    }
    
    private func hapticFeedbackIfNeeded(oldValue: Float, newValue: Float) {
        if Int(oldValue * 10) != Int(newValue * 10) {
            let generator = UIImpactFeedbackGenerator(style: .rigid)
            generator.prepare()
            generator.impactOccurred()
        }
    }
}

#Preview {
    EVWheelPicker(value: .constant(0.0), minEV: -3.0, maxEV: 3.0, step: 0.3) { _ in }
        .background(Color.black)
        .frame(width: 350, height: 80)
}
