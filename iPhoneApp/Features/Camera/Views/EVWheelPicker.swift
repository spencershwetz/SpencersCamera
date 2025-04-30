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
    
    // For gesture tracking
    @State private var dragOffset: CGFloat = 0
    @State private var isDragging = false
    @State private var isSettingValue = false
    
    // For smooth scrolling and state management
    @State private var initialOffset: CGFloat = 0
    @State private var accumulatedOffset: CGFloat = 0
    @State private var lastIndex: Int = -1 // Initialize to -1 to ensure first feedback
    @State private var startLocation: CGFloat = 0
    @State private var hasInitialized: Bool = false
    @State private var stableValue: Float = 0.0
    @State private var gestureVelocity: CGFloat = 0
    @State private var lastUpdateTime: Date = Date()
    @State private var lastGestureLocation: CGFloat = 0
    @State private var isAnimating: Bool = false
    @State private var lastExternalValue: Float = 0.0
    @State private var lastSettledValue: Float = 0.0
    @State private var valueSettleTask: Task<Void, Never>?
    @State private var feedbackGenerator = UISelectionFeedbackGenerator()
    
    // Constants for gesture handling - Adjusted for smoother feel
    private let movementThreshold: CGFloat = 5.0   // Lower threshold for responsiveness
    private let sensitivity: CGFloat = 0.5         // Slightly increased sensitivity
    private let velocityThreshold: CGFloat = 50.0  // Increased threshold to require more flick
    private let snapAnimationDuration: TimeInterval = 0.4 // Slightly longer for smoother settle
    private let debounceInterval: TimeInterval = 0.016 // Reduced debounce (~1 frame)
    private let velocityDampingFactor: CGFloat = 0.15 // Increased momentum
    private let valueSettleDelay: TimeInterval = 0.5
    
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
        
        // Cancel any pending settle task
        valueSettleTask?.cancel()
        
        // Round values for comparison
        let roundedNew = round(newValue * 100) / 100
        let roundedCurrent = round(stableValue * 100) / 100
        let roundedLast = round(lastSettledValue * 100) / 100
        
        // Only update if value has changed significantly
        guard abs(roundedNew - roundedCurrent) >= (step / 2) || 
              (!isIntermediate && roundedNew != roundedLast) else { return }
        
        isSettingValue = true
        logger.debug("Updating value from \(stableValue) to \(roundedNew) (intermediate: \(isIntermediate))")
        
        value = roundedNew
        stableValue = roundedNew
        lastExternalValue = roundedNew
        
        if !isIntermediate {
            lastSettledValue = roundedNew
            // Create a new task to settle the value after a delay
            valueSettleTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(valueSettleDelay * 1_000_000_000))
                if !Task.isCancelled {
                    await MainActor.run {
                        lastSettledValue = roundedNew
                    }
                }
            }
        }
        
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
                                    feedbackGenerator.prepare() // Prepare generator on drag start
                                    logger.debug("Started dragging at x: \(startLocation)")
                                }
                                
                                let currentTime = Date()
                                let timeDelta = currentTime.timeIntervalSince(lastUpdateTime)

                                // Guard against near-zero time delta
                                guard timeDelta > 0.001 else {
                                    lastGestureLocation = gesture.location.x // Still update location
                                    return
                                }

                                // Debounce based on time interval
                                guard timeDelta >= debounceInterval else { return }

                                let translation = (gesture.location.x - startLocation) * sensitivity

                                // Calculate and smooth velocity
                                let deltaX = gesture.location.x - lastGestureLocation
                                let instantVelocity = CGFloat(deltaX / CGFloat(timeDelta))
                                // Use a simple low-pass filter for velocity smoothing
                                gestureVelocity = gestureVelocity * 0.8 + instantVelocity * 0.2

                                dragOffset = translation
                                lastUpdateTime = currentTime
                                lastGestureLocation = gesture.location.x

                                let totalOffset = accumulatedOffset + dragOffset
                                let targetIndex = nearestValidIndex(for: totalOffset, itemWidth: itemWidth)
                                
                                if targetIndex != lastIndex {
                                    feedbackGenerator.selectionChanged() // Trigger feedback on index change
                                    logger.debug("Haptic feedback triggered (selectionChanged) for index: \(targetIndex)")
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

                                // Apply momentum only if velocity exceeds threshold
                                if abs(gestureVelocity) > velocityThreshold {
                                    let momentumOffset = gestureVelocity * velocityDampingFactor
                                    let projectedOffset = totalOffset + momentumOffset
                                    targetIndex = nearestValidIndex(for: projectedOffset, itemWidth: itemWidth)
                                    logger.debug("Applying momentum: velocity=\(gestureVelocity), offset=\(momentumOffset), newIndex=\(targetIndex)")
                                } else {
                                    logger.debug("Velocity \(gestureVelocity) below threshold \(velocityThreshold), snapping to nearest.")
                                }

                                // Ensure smooth animation to final position using interactiveSpring
                                isAnimating = true
                                withAnimation(.interactiveSpring(response: snapAnimationDuration, dampingFraction: 0.8, blendDuration: 0.25)) {
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

                // Temporary Test Button - REMOVED
                // VStack {
                //     Spacer()
                //     Button("Test Haptic") {
                //         logger.debug("Test Haptic Button Tapped")
                //         feedbackGenerator.selectionChanged()
                //     }
                //     .buttonStyle(.borderedProminent)
                //     .padding(.bottom, 5)
                // }
                // .frame(maxWidth: .infinity, alignment: .center)
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
            lastExternalValue = 0
            let currentZeroIndex = zeroIndex
            lastIndex = currentZeroIndex // Set initial index
            
            // Center the wheel at zero
            let itemWidth: CGFloat = 40 + 16
            accumulatedOffset = -CGFloat(currentZeroIndex) * itemWidth
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
                    // Use the same interactiveSpring for consistency
                    withAnimation(.interactiveSpring(response: 0.3, dampingFraction: 0.8, blendDuration: 0.25)) {
                        accumulatedOffset = -CGFloat(index) * (40 + 16)
                    }
                    // Reset relevant state variables
                    initialOffset = accumulatedOffset
                    dragOffset = 0 // Ensure drag offset is reset
                    lastExternalValue = newValue
                    gestureVelocity = 0 // Reset velocity on external change
                    stableValue = newValue
                    lastIndex = index // Update index on external change too
                }
            }
        }
    }
}

#Preview {
    EVWheelPicker(value: .constant(0.0), minEV: -3.0, maxEV: 3.0, step: 0.3) { _ in }
        .background(Color.black)
        .frame(width: 350, height: 80)
}
