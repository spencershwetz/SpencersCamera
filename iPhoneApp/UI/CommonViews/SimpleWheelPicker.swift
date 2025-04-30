import SwiftUI
import OSLog // Import OSLog for debugging

/// A simple horizontal wheel picker based on ScrollView and .scrollPosition.
struct SimpleWheelPicker: View {
    /// Config
    var config: Config
    @Binding var value: CGFloat
    /// View Properties
    @State private var isLoaded: Bool = false
    // Logger for debugging
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "SimpleWheelPicker")

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
                HStack(spacing: config.spacing) {
                    ForEach(0...totalNumberOfSteps, id: \.self) { index in
                        // Determine if this is a major tick (representing a whole number or significant fraction)
                        // A major tick occurs every `config.stepsPerUnit` steps.
                        let isMajorTick = index % config.stepsPerUnit == 0
                        let tickValue = value(for: index)
                        
                        Divider()
                            .background(isMajorTick ? Color.primary : .gray)
                            .frame(width: 0, height: isMajorTick ? 20 : 10, alignment: .center)
                            .frame(maxHeight: 20, alignment: .bottom)
                            .overlay(alignment: .bottom) {
                                if isMajorTick && config.showsText {
                                    // Display the value for major ticks
                                    Text(String(format: "%g", tickValue)) // Use %g for cleaner number format
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                        .textScale(.secondary)
                                        .fixedSize()
                                        .offset(y: 20)
                                }
                            }
                    }
                }
                .frame(height: size.height)
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: .init(get: {
                // Calculate the scroll position (index) based on the current value
                let position: Int? = isLoaded ? index(for: value) : nil
                logger.trace("ScrollPosition GET: value = \(value, format: .fixed(precision: 2)), position = \(position ?? -1)")
                return position
            }, set: { newPosition in
                if let newPosition {
                    let newValue = value(for: newPosition).clamped(to: config.min...config.max)
                    logger.trace("ScrollPosition SET: newPosition = \(newPosition), calculated newValue = \(newValue, format: .fixed(precision: 2))")
                    // Check if the value actually changed to avoid redundant updates and haptics
                    if abs(newValue - value) > 0.001 { // Use a small tolerance
                        // Create and trigger haptic feedback *locally* when position changes
                        let impact = UIImpactFeedbackGenerator(style: .light)
                        impact.impactOccurred()
                        logger.debug("Haptic triggered for position \(newPosition), value \(newValue, format: .fixed(precision: 2))")
                        // Update the binding value based on the new scroll position
                        value = newValue
                    }
                }
            }))
            .overlay(alignment: .center) {
                // Center indicator line
                Rectangle()
                    .fill(Color.accentColor) // Use accent color for visibility
                    .frame(width: 1, height: 40)
                    .padding(.bottom, 20) // Adjust vertical position to match lines
            }
            .safeAreaPadding(.horizontal, horizontalPadding)
            .onAppear {
                logger.debug("SimpleWheelPicker appeared. Initial value: \(value, format: .fixed(precision: 2))")
                // Ensures scrollPosition works correctly on first appearance
                if !isLoaded {
                    isLoaded = true
                    // Ensure the value is clamped initially
                    let clampedInitialValue = value.clamped(to: config.min...config.max)
                    if clampedInitialValue != value {
                         value = clampedInitialValue
                         logger.warning("Initial value \(value, format: .fixed(precision: 2)) was outside range [\(config.min)...\(config.max)], clamped to \(clampedInitialValue).")
                    }
                }
            }
        }
        // Note: Removing the .onChange(of: config) that resets value, 
        // as we want it to reflect the viewModel's state.
    }
    
    /// Picker Configuration
    struct Config: Equatable {
        var min: CGFloat
        var max: CGFloat
        var stepsPerUnit: Int = 10 // e.g., 10 steps per 1.0 value change means 0.1 increments
        var spacing: CGFloat = 8    // Visual spacing between ticks
        var showsText: Bool = true  // Whether to show text labels on major ticks
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