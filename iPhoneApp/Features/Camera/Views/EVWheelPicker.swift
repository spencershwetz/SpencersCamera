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
    @State private var startLocation: CGFloat = 0
    @State private var hasInitialized: Bool = false
    
    // Threshold for gesture movement before updating value
    private let movementThreshold: CGFloat = 8.0
    private let sensitivity: CGFloat = 1.0
    
    private var evValues: [Float] {
        stride(from: minEV, through: maxEV, by: step).map { round($0 * 100) / 100 }
    }
    
    private var zeroIndex: Int {
        evValues.firstIndex(of: 0) ?? evValues.count / 2
    }
    
    var body: some View {
        GeometryReader { geo in
            let itemWidth: CGFloat = 40 + 16 // width + spacing
            let horizontalPadding = geo.size.width / 2
            
            ZStack {
                // Background gesture area
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: movementThreshold)
                            .onChanged { gesture in
                                if !isDragging {
                                    startLocation = gesture.location.x
                                    isDragging = true
                                }
                                
                                let translation = (gesture.location.x - startLocation) * sensitivity
                                let scrolledValue = -translation / itemWidth
                                let rawIndex = Int(round(scrolledValue)) + lastIndex
                                let clampedIndex = max(0, min(rawIndex, evValues.count - 1))
                                
                                if clampedIndex != lastIndex {
                                    let newValue = evValues[clampedIndex]
                                    if newValue != value {
                                        isSettingValue = true
                                        value = newValue
                                        hapticFeedbackIfNeeded(oldValue: lastFeedbackValue, newValue: newValue)
                                        lastFeedbackValue = newValue
                                        onEditingChanged(true)
                                        isSettingValue = false
                                        lastIndex = clampedIndex
                                    }
                                }
                                
                                // Update visual offset
                                dragOffset = translation
                            }
                            .onEnded { gesture in
                                isDragging = false
                                
                                // Update accumulated offset
                                accumulatedOffset = -CGFloat(lastIndex) * itemWidth
                                
                                // Animate to final position
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8, blendDuration: 0.2)) {
                                    dragOffset = 0
                                }
                                
                                onEditingChanged(false)
                            }
                    )
                
                // EV wheel marks and values
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
                
                // Center indicator
                Rectangle()
                    .frame(width: 2, height: 48)
                    .foregroundColor(.accentColor)
                    .opacity(0.8)
            }
        }
        .frame(height: 72)
        .onAppear {
            guard !hasInitialized else { return }
            hasInitialized = true
            
            // Initialize at zero
            isSettingValue = true
            value = 0
            lastFeedbackValue = 0
            lastIndex = zeroIndex
            
            // Center the wheel at zero
            let itemWidth: CGFloat = 40 + 16
            accumulatedOffset = -CGFloat(zeroIndex) * itemWidth
            initialOffset = accumulatedOffset
            
            isSettingValue = false
        }
        .onChange(of: value) { oldValue, newValue in
            // Only update position if the value was changed externally (not by dragging)
            if !isSettingValue, !isDragging, let index = evValues.firstIndex(of: newValue) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8, blendDuration: 0.2)) {
                    accumulatedOffset = -CGFloat(index) * (40 + 16)
                }
                initialOffset = accumulatedOffset
                lastFeedbackValue = newValue
                lastIndex = index
            }
        }
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
