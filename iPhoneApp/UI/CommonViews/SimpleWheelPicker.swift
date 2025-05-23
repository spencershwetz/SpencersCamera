import SwiftUI
import OSLog // Import OSLog for debugging
import Combine // Import Combine for debounce

/// ViewModifier to disable bounce on underlying UIScrollView (for iOS < 18 compatibility)
struct DisableBounce: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                BounceDisabler()
                    .frame(width: 0, height: 0)
            )
    }
    
    private struct BounceDisabler: UIViewRepresentable {
        func makeUIView(context: Context) -> UIView {
            let view = UIView()
            DispatchQueue.main.async {
                // Traverse superview hierarchy to find UIScrollView
                if let scrollView = view.findSuperview(of: UIScrollView.self) {
                    scrollView.bounces = false
                    scrollView.alwaysBounceHorizontal = false
                }
            }
            return view
        }
        func updateUIView(_ uiView: UIView, context: Context) {}
    }
}

private extension UIView {
    func findSuperview<T: UIView>(of type: T.Type) -> T? {
        var view: UIView? = self.superview
        while let v = view {
            if let match = v as? T { return match }
            view = v.superview
        }
        return nil
    }
}

/// A simple horizontal wheel picker based on ScrollView and .scrollPosition.
struct SimpleWheelPicker: View {
    /// Config
    var config: Config
    @Binding var value: CGFloat
    /// Whether recording is active (disable haptics if true)
    var isRecording: Bool = false
    /// Optional closure called when editing starts/ends (true = start, false = end)
    var onEditingChanged: ((Bool) -> Void)? = nil
    /// View Properties
    @State private var isLoaded: Bool = false
    // Local state to track the value *during* scrolling, avoiding immediate binding updates.
    @State private var intermediateValue: CGFloat = 0.0
    // Logger for debugging
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "SimpleWheelPicker")
    // Debounce drag end
    @State private var dragEndWorkItem: DispatchWorkItem?
    // Timer to debounce scroll end and commit the value
    @State private var scrollEndDebounce: Timer?
    // Track the last scroll position for debounce
    @State private var lastScrollPosition: Int? = nil
    // Track last haptic time to prevent too frequent feedback
    @State private var lastHapticTime: TimeInterval = 0
    // Minimum time between haptic feedback events
    private let minHapticInterval: TimeInterval = 0.07

    // Calculate the total number of finest steps based on range and steps per unit
    private var totalNumberOfSteps: Int {
        Int(round((config.max - config.min) * CGFloat(config.stepsPerUnit)))
    }
    
    // Calculate the step index for a given value
    private func index(for value: CGFloat) -> Int {
        Int(round((value - config.min) * CGFloat(config.stepsPerUnit)))
    }
    
    // Calculate the value for a given step index
    private func value(for index: Int) -> CGFloat {
        config.min + CGFloat(index) / CGFloat(config.stepsPerUnit)
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let horizontalPadding = size.width / 2
            
            ScrollView(.horizontal) {
                LazyHStack(spacing: config.spacing) {
                    ForEach(0...totalNumberOfSteps, id: \.self) { index in
                        // Determine if this is a major tick (representing a whole number or significant fraction)
                        // A major tick occurs every `config.stepsPerUnit` steps.
                        let isMajorTick = index % config.stepsPerUnit == 0
                        let tickValue = value(for: index)
                        
                        // Replace Divider with explicit Rectangle for better rendering
                        Rectangle()
                            .fill(isMajorTick ? Color.white : Color.gray.opacity(0.7))
                            .frame(width: isMajorTick ? 2 : 1, height: isMajorTick ? 18 : 14)
                            .padding(.vertical, 3) // Add some padding to ensure visibility
                            .overlay(alignment: .top) {
                                if isMajorTick && config.showsText {
                                    // Display the value for major ticks
                                    Text(config.labelFormatter(tickValue))
                                        .font(.caption2)
                                        .foregroundColor(.white)
                                        .fixedSize()
                                        .offset(y: -20)
                                        .padding(.top, 0)
                                }
                            }
                            // Removed debug logs that were causing rate limit warnings
                    }
                }
                .frame(height: size.height)
                .padding(.top, 8)
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .modifier(DisableBounce())
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: .init(get: {
                // Read from the intermediate value while scrolling
                let position: Int? = isLoaded ? index(for: intermediateValue) : nil
                return position
            }, set: { newPosition in
                if let newPosition {
                    let newValue = value(for: newPosition).clamped(to: config.min...config.max)
                    // Check if the intermediate value actually changed significantly
                    if abs(newValue - intermediateValue) > 0.01 { // Increased threshold from 0.001 to 0.01
                        // Signal editing started if it hasn't already
                        if dragEndWorkItem == nil { // Check if we are already tracking a drag
                            onEditingChanged?(true)
                        }
                        // Cancel any pending drag end signal
                        dragEndWorkItem?.cancel()
                        dragEndWorkItem = DispatchWorkItem { /* Only used for cancellation */ }
                        
                        // Trigger haptics with rate limiting, only if not recording
                        let now = Date().timeIntervalSince1970
                        if !isRecording && now - lastHapticTime >= minHapticInterval {
                            // Use the enhanced HapticManager instead of local generator
                            HapticManager.shared.selectionChanged()
                            lastHapticTime = now
                        }

                        // --- Update intermediate value first, but only update binding on debounce ---
                        intermediateValue = newValue
                        
                        // Store the last position to prevent feedback loops
                        lastScrollPosition = newPosition
                        
                        // Update binding in real-time during scrolling with throttling
                        if abs(self.value - newValue) > 0.03 { // Slightly higher threshold to reduce updates
                            self.value = newValue  // Update binding immediately without debounce
                        }
                        
                        // Still use debounce for editing ended callback
                        scrollEndDebounce?.invalidate()
                        scrollEndDebounce = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { _ in
                            // Signal editing ended after a slight delay
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                // Only send editing ended if we haven't started a new edit
                                if self.lastScrollPosition == newPosition {
                                    self.onEditingChanged?(false)
                                    self.dragEndWorkItem = nil // Reset drag tracking
                                    self.lastScrollPosition = nil // Reset position tracking
                                    
                                    // One final haptic when scroll settles, only if not recording
                                    if !isRecording {
                                        HapticManager.shared.lightImpact()
                                    }
                                }
                            }
                        }
                    }
                }
            }))
            .overlay(alignment: .center) {
                // Center indicator line with triangle above
                VStack(spacing: 0) {
                    Image(systemName: "arrowtriangle.down.fill")
                        .font(.system(size: 14))  // Increased from 12
                        .foregroundColor(.yellow)
                        .shadow(color: .black.opacity(0.5), radius: 1, x: 0, y: 1)  // Add shadow for contrast
                    
                    Rectangle()
                        .fill(Color.yellow) // Changed to yellow for better visibility
                        .frame(width: 3, height: 44)  // Increased width from 2 to 3 and height from 40 to 44
                        .shadow(color: .black.opacity(0.5), radius: 1, x: 0, y: 0)  // Add shadow for contrast
                        .padding(.bottom, 20) // Adjust vertical position to match lines
                }
            }
            .safeAreaPadding(.horizontal, horizontalPadding)
            .onAppear {
                logger.debug("SimpleWheelPicker appeared. Initial binding value: \(value, format: .fixed(precision: 2))")
                // Initialize intermediateValue from the binding on appear
                let clampedInitialValue = value.clamped(to: config.min...config.max)
                intermediateValue = clampedInitialValue
                if clampedInitialValue != value {
                     value = clampedInitialValue // Ensure binding is also clamped initially
                     logger.warning("Initial binding value \(value, format: .fixed(precision: 2)) was outside range [\(config.min)...\(config.max)], clamped to \(clampedInitialValue).")
                }
                logger.debug("Intermediate value initialized to: \(intermediateValue, format: .fixed(precision: 2))")
                isLoaded = true
            }
            .onChange(of: value) { oldValue, newValue in
                // Only update intermediateValue if not currently dragging (i.e., no dragEndWorkItem)
                if dragEndWorkItem == nil {
                    let clamped = newValue.clamped(to: config.min...config.max)
                    if abs(intermediateValue - clamped) > 0.01 {
                        intermediateValue = clamped
                        logger.debug("[onChange] External value change detected. intermediateValue reset to: \(clamped, format: .fixed(precision: 2))")
                    }
                }
            }
        }
    }
    
    /// Picker Configuration
    struct Config: Equatable {
        var min: CGFloat
        var max: CGFloat
        var stepsPerUnit: Int = 10 // e.g., 10 steps per 1.0 value change means 0.1 increments
        var spacing: CGFloat = 6   // Visual spacing between ticks
        var showsText: Bool = true  // Whether to show text labels on major ticks
        var labelFormatter: (CGFloat) -> String = { String(format: "%g", $0) } // Default formatter
        
        static func == (lhs: Config, rhs: Config) -> Bool {
            lhs.min == rhs.min &&
            lhs.max == rhs.max &&
            lhs.stepsPerUnit == rhs.stepsPerUnit &&
            lhs.spacing == rhs.spacing &&
            lhs.showsText == rhs.showsText
            // Note: We can't compare function properties for equality
        }
    }
}

// Example Preview
struct SimpleWheelPicker_Previews: PreviewProvider {
    struct PreviewWrapper: View {
        // Example: -3.0 to +3.0 with 0.1 steps (stepsPerUnit = 10)
        @State private var config: SimpleWheelPicker.Config = .init(min: -3.0, max: 3.0, stepsPerUnit: 10, spacing: 8, showsText: true)
        @State private var currentValue: CGFloat = 0.0 // Start at 0.0
        
        var body: some View {
            VStack {
                Text("Value: \(currentValue, specifier: "%.1f")")
                    .font(.headline)
                SimpleWheelPicker(config: config, value: $currentValue)
                    .frame(height: 60)
                    .background(Color.gray.opacity(0.2))
                
                // Controls to test config changes (optional)
                Text("Config:")
                HStack {
                    Text("Min: \(config.min, specifier: "%.1f")")
                    Slider(value: $config.min, in: -10...0)
                }
                HStack {
                    Text("Max: \(config.max, specifier: "%.1f")")
                    Slider(value: $config.max, in: 0...10)
                }
                Stepper("Steps/Unit: \(config.stepsPerUnit)", value: $config.stepsPerUnit, in: 1...20)
                Slider(value: $config.spacing, in: 2...20) { Text("Spacing: \(config.spacing, specifier: "%.0f")") }
            }
            .padding()
        }
    }
    
    static var previews: some View {
        PreviewWrapper()
    }
} 