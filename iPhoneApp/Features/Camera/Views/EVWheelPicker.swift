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
    @State private var stableValue: Float = 0.0
    @State private var gestureVelocity: CGFloat = 0
    @State private var lastUpdateTime: Date = Date()
    @State private var lastGestureLocation: CGFloat = 0
    @State private var isAnimating: Bool = false
    @State private var lastExternalValue: Float = 0.0
    
    // Constants for gesture handling
    private let movementThreshold: CGFloat = 8.0
    private let sensitivity: CGFloat = 0.6  // Reduced sensitivity for more stable control
    private let velocityThreshold: CGFloat = 50.0 // Reduced threshold
    private let snapAnimationDuration: TimeInterval = 0.25
    private let debounceInterval: TimeInterval = 0.1 // Increased debounce
    private let velocityDampingFactor: CGFloat = 0.15 // Reduced momentum effect
    
    private var evValues: [Float] {
        stride(from: minEV, through: maxEV, by: step).map { round($0 * 10) / 10 }
    }
    
    private var zeroIndex: Int {
        evValues.firstIndex(of: 0) ?? evValues.count / 2
    }
    
    private func nearestValidIndex(for offset: CGFloat, itemWidth: CGFloat) -> Int {
        let rawIndex = Int(round(-offset / itemWidth))
        return max(0, min(rawIndex, evValues.count - 1))
    }
    
    private func updateValue(to newValue: Float, isIntermediate: Bool = true) {
        guard !isSettingValue else { return }
        
        // Prevent rapid oscillation by checking if the value has significantly changed
        let roundedNew = round(newValue * 100) / 100
        let roundedCurrent = round(stableValue * 100) / 100
        
        guard abs(roundedNew - roundedCurrent) >= (step / 2) else { return }
        
        isSettingValue = true
        logger.debug("Updating value from \(stableValue) to \(roundedNew) (intermediate: \(isIntermediate))")
        
        value = roundedNew
        stableValue = roundedNew
        lastExternalValue = roundedNew
        
        hapticFeedbackIfNeeded(oldValue: lastFeedbackValue, newValue: roundedNew)
        lastFeedbackValue = roundedNew
        onEditingChanged(isIntermediate)
        
        isSettingValue = false
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
                                    stableValue = value
                                    lastUpdateTime = Date()
                                    lastGestureLocation = gesture.location.x
                                    logger.debug("Started dragging at x: \(startLocation)")
                                }
                                
                                let currentTime = Date()
                                let timeDelta = currentTime.timeIntervalSince(lastUpdateTime)
                                
                                guard timeDelta >= debounceInterval else { return }
                                
                                let translation = (gesture.location.x - startLocation) * sensitivity
                                
                                // Calculate and smooth velocity with more dampening
                                if timeDelta > 0 {
                                    let deltaX = gesture.location.x - lastGestureLocation
                                    let instantVelocity = CGFloat(deltaX / CGFloat(timeDelta))
                                    gestureVelocity = gestureVelocity * 0.5 + instantVelocity * 0.5
                                }
                                
                                dragOffset = translation
                                lastUpdateTime = currentTime
                                lastGestureLocation = gesture.location.x
                                
                                let totalOffset = accumulatedOffset + dragOffset
                                let targetIndex = nearestValidIndex(for: totalOffset, itemWidth: itemWidth)
                                
                                if targetIndex != lastIndex {
                                    let newValue = evValues[targetIndex]
                                    updateValue(to: newValue)
                                    lastIndex = targetIndex
                                }
                            }
                            .onEnded { gesture in
                                logger.debug("Gesture ended with velocity: \(gestureVelocity)")
                                isDragging = false
                                
                                let totalOffset = accumulatedOffset + dragOffset
                                var targetIndex = nearestValidIndex(for: totalOffset, itemWidth: itemWidth)
                                
                                // Apply reduced momentum if significant velocity
                                if abs(gestureVelocity) > velocityThreshold {
                                    let momentumOffset = gestureVelocity * velocityDampingFactor
                                    targetIndex = nearestValidIndex(for: totalOffset + momentumOffset, itemWidth: itemWidth)
                                }
                                
                                // Ensure smooth animation to final position
                                isAnimating = true
                                withAnimation(.spring(response: snapAnimationDuration, dampingFraction: 0.9, blendDuration: 0.1)) {
                                    accumulatedOffset = -CGFloat(targetIndex) * itemWidth
                                    dragOffset = 0
                                }
                                
                                let finalValue = evValues[targetIndex]
                                updateValue(to: finalValue, isIntermediate: false)
                                lastIndex = targetIndex
                                
                                // Reset state
                                gestureVelocity = 0
                                DispatchQueue.main.asyncAfter(deadline: .now() + snapAnimationDuration) {
                                    isAnimating = false
                                }
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
            logger.debug("EVWheelPicker appeared, initializing at zero")
            
            // Initialize at zero
            isSettingValue = true
            value = 0
            stableValue = 0
            lastFeedbackValue = 0
            lastExternalValue = 0
            lastIndex = zeroIndex
            
            // Center the wheel at zero
            let itemWidth: CGFloat = 40 + 16
            accumulatedOffset = -CGFloat(zeroIndex) * itemWidth
            initialOffset = accumulatedOffset
            
            isSettingValue = false
        }
        .onChange(of: value) { oldValue, newValue in
            // Only update position if value changed externally and significantly
            if !isSettingValue, !isDragging, !isAnimating {
                let roundedNew = round(newValue * 100) / 100
                let roundedLast = round(lastExternalValue * 100) / 100
                
                if abs(roundedNew - roundedLast) >= (step / 2),
                   let index = evValues.firstIndex(of: round(newValue * 10) / 10) {
                    logger.debug("External value change: \(oldValue) -> \(newValue)")
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8, blendDuration: 0.2)) {
                        accumulatedOffset = -CGFloat(index) * (40 + 16)
                    }
                    initialOffset = accumulatedOffset
                    lastFeedbackValue = newValue
                    lastIndex = index
                    stableValue = newValue
                    lastExternalValue = newValue
                }
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
