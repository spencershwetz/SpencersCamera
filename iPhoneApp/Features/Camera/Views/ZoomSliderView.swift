import SwiftUI
import Foundation
import UIKit  // Add UIKit import for UIImpactFeedbackGenerator

struct ZoomSliderView: View {
    @ObservedObject var viewModel: CameraViewModel
    
    private enum MenuType {
        case lens, shutter, iso, wb
    }
    
    @State private var activeMenu: MenuType? = nil
    // Track menu transitions to prevent haptic conflicts
    @State private var isTransitioning = false
    
    // MARK: - Body
    var body: some View {
        // Replace ZStack with VStack and manage menu visibility directly
        VStack(spacing: 0) { // Added spacing: 0, can adjust if needed
            // Show menu above the buttons when active
            if let activeMenu {
                menuContent(for: activeMenu)
                    .padding(.bottom, 8) // Space between menu and buttons
                    .transition(.move(edge: .bottom).combined(with: .opacity)) // Adjusted transition edge
                    .zIndex(10) // Keep zIndex in case of overlapping animations
            }

            // Main buttons row
            baseControls
        }
        .animation(.easeInOut(duration: 0.25), value: activeMenu)
        // Reset transition flag after animation completes
        .onChange(of: activeMenu) { _ in
            // Set transitioning flag
            isTransitioning = true
            
            // Clear flag after animation duration
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                isTransitioning = false
            }
        }
    }
    
    // MARK: - Base Row
    private var baseControls: some View {
        HStack(spacing: 14) {
            baseButton(title: "Lens", type: .lens)
            baseButton(title: "Shutter", type: .shutter)
            baseButton(title: "ISO", type: .iso)
            baseButton(title: "WB", type: .wb)
        }
    }
    
    private func baseButton(title: String, type: MenuType) -> some View {
        Button {
            // Skip haptics if already transitioning
            if !isTransitioning {
                // Use HapticManager for reliable feedback
                HapticManager.shared.lightImpact()
                
                withAnimation {
                    if activeMenu == type {
                        activeMenu = nil
                    } else {
                        activeMenu = type
                    }
                }
            }
        } label: {
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(activeMenu == type ? .yellow : .white)
                .frame(width: 60, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.black.opacity(0.65))
                )
        }
        // Add a slight delay to button actions to improve haptic reliability
        .buttonStyle(HapticButtonStyle())
    }
    
    // MARK: - Menus
    @ViewBuilder
    private func menuContent(for type: MenuType) -> some View {
        VStack {
            // Menu content in a fixed-size container with background
            HStack {
                Spacer(minLength: 0)
                
                switch type {
                case .lens:
                    lensMenu
                case .shutter:
                    shutterMenu
                case .iso:
                    isoMenu
                case .wb:
                    wbMenu
                }
                
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.black.opacity(0.8))
            )
        }
    }
    
    // Lens options (.5, 1, 2, 5)
    private var lensMenu: some View {
        HStack(spacing: 14) {
            ForEach(viewModel.availableLenses, id: \.self) { lens in
                Button {
                    // Always trigger haptics for lens buttons
                    DispatchQueue.main.async {
                        HapticManager.shared.lightImpact()
                    }
                    
                    viewModel.switchToLens(lens)
                } label: {
                    Text("\(lens.rawValue)×")
                        .font(.system(size: viewModel.currentLens == lens ? 17 : 15, weight: .medium))
                        .foregroundColor(viewModel.currentLens == lens ? .yellow : .white)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Color.black.opacity(0.65)))
                }
                .buttonStyle(HapticButtonStyle())
            }
        }
    }
    
    private var shutterMenu: some View {
        HStack(spacing: 20) {
            Button("Auto") {
                // Use HapticManager on main thread for reliability
                DispatchQueue.main.async {
                    HapticManager.shared.lightImpact()
                }
                
                if viewModel.isShutterPriorityEnabled { viewModel.toggleShutterPriority() }
            }
            .foregroundColor(viewModel.isShutterPriorityEnabled ? .white : .yellow)
            .buttonStyle(HapticButtonStyle())
            
            Button("180°") {
                // Use HapticManager on main thread for reliability
                DispatchQueue.main.async {
                    HapticManager.shared.lightImpact()
                }
                
                if !viewModel.isShutterPriorityEnabled { viewModel.toggleShutterPriority() }
            }
            .foregroundColor(viewModel.isShutterPriorityEnabled ? .yellow : .white)
            .buttonStyle(HapticButtonStyle())
        }
    }
    
    // ISO menu with auto + wheel
    private var isoMenu: some View {
        HStack(spacing: 12) {
            VStack {
                HStack(spacing: 12) {
                    // Auto button
                    Button("Auto") {
                        // Use HapticManager on main thread for reliability
                        DispatchQueue.main.async {
                            HapticManager.shared.lightImpact()
                        }
                        
                        viewModel.isAutoExposureEnabled = true
                    }
                    .foregroundColor(viewModel.isAutoExposureEnabled ? .yellow : .white)
                    .buttonStyle(HapticButtonStyle())
                    
                    // ISO Wheel
                    SimpleWheelPicker(
                        config: isoWheelConfig,
                        value: isoBinding,
                        onEditingChanged: { editing in
                            if editing {
                                // Set manual ISO override immediately if in SP mode
                                if viewModel.currentExposureMode == .shutterPriority && !viewModel.isManualISOInSP {
                                    viewModel.isManualISOInSP = true
                                    viewModel.logger.info("Manual ISO override set in SP mode (onEditingChanged in wheel).")
                                    viewModel.exposureService.setManualISOInSP(true)
                                }
                                viewModel.isAutoExposureEnabled = false
                            }
                        })
                        .frame(height: 60)
                }
                .background(Color.black.opacity(0.3))
                .cornerRadius(4)
            }
        }
    }
    
    private var wbMenu: some View {
        HStack(spacing: 12) {
            VStack {
                HStack(spacing: 12) {
                    // Auto button
                    Button("Auto") {
                        // Use HapticManager on main thread for reliability
                        DispatchQueue.main.async {
                            HapticManager.shared.lightImpact()
                        }
                        
                        viewModel.setWhiteBalanceAuto(true)
                    }
                    .foregroundColor(viewModel.isWhiteBalanceAuto ? .yellow : .white)
                    .buttonStyle(HapticButtonStyle())
                    
                    // WB Wheel
                    SimpleWheelPicker(
                        config: wbWheelConfig,
                        value: wbBinding,
                        onEditingChanged: { editing in
                            if editing {
                                viewModel.setWhiteBalanceAuto(false)
                            }
                        })
                        .frame(height: 60)
                        .disabled(viewModel.isWhiteBalanceAuto)
                        .opacity(viewModel.isWhiteBalanceAuto ? 0.5 : 1)
                }
                .background(Color.black.opacity(0.3))
                .cornerRadius(4)
            }
        }
    }
    
    // MARK: - Wheel Configs & Bindings
    private var isoWheelConfig: SimpleWheelPicker.Config {
        SimpleWheelPicker.Config(
            min: CGFloat(viewModel.minISO),
            max: CGFloat(viewModel.maxISO),
            stepsPerUnit: 1, // 1 step per 1 ISO, so 100 ISO per major tick
            spacing: 12,     // Wider spacing for clarity at 100 ISO per tick
            showsText: true  // Display text labels for better usability
        )
    }
    
    private var wbWheelConfig: SimpleWheelPicker.Config {
        SimpleWheelPicker.Config(
            min: 25,          // Represents 2500K
            max: 100,         // Represents 10000K
            stepsPerUnit: 5,  // 5 steps per 100K unit to get tick density similar to EV bias wheel
            spacing: 6,       // Changed to 6 to match EV bias wheel
            showsText: true   // Keep showing text labels
        )
    }
    
    private var isoBinding: Binding<CGFloat> {
        // Create a binding with throttling to prevent GPU timeouts
        // Similar to exposureBiasBinding in CameraView
        
        // Throttling data
        class ThrottleData {
            var lastUpdateTime = Date.distantPast
            var pendingValue: CGFloat?
            var timer: Timer?
        }
        let throttleData = ThrottleData()
        let minTimeInterval: TimeInterval = 0.1 // 100ms between updates
        
        return Binding<CGFloat>(
            get: { CGFloat(viewModel.iso) },
            set: { newValue in
                // Always update the local model value immediately for responsive UI
                let newISO = Float(newValue.clamped(to: CGFloat(viewModel.minISO)...CGFloat(viewModel.maxISO)))
                viewModel.iso = newISO
                
                // Throttle camera updates to prevent GPU overload
                let now = Date()
                if now.timeIntervalSince(throttleData.lastUpdateTime) >= minTimeInterval {
                    // Enough time has passed, apply immediately
                    viewModel.updateISO(newISO)
                    throttleData.lastUpdateTime = now
                    throttleData.pendingValue = nil
                } else {
                    // Too soon, schedule for later
                    throttleData.pendingValue = CGFloat(newISO)
                    
                    // Invalidate existing timer
                    throttleData.timer?.invalidate()
                    
                    // Schedule a new timer to apply latest value
                    throttleData.timer = Timer.scheduledTimer(withTimeInterval: minTimeInterval, repeats: false) { _ in
                        if let pendingValue = throttleData.pendingValue {
                            viewModel.updateISO(Float(pendingValue))
                            throttleData.lastUpdateTime = Date()
                            throttleData.pendingValue = nil
                        }
                    }
                }
            }
        )
    }
    
    private var wbBinding: Binding<CGFloat> {
        // Create a binding with throttling to prevent GPU timeouts
        // Similar to exposureBiasBinding in CameraView
        
        // Throttling data
        class ThrottleData {
            var lastUpdateTime = Date.distantPast
            var pendingValue: CGFloat?
            var timer: Timer?
        }
        let throttleData = ThrottleData()
        let minTimeInterval: TimeInterval = 0.1 // 100ms between updates
        
        return Binding<CGFloat>(
            get: { CGFloat(viewModel.whiteBalance / 100.0) }, // Divide by 100
            set: { newValInHundredKelvinUnits in
                // Calculate the actual kelvin value
                let kelvinValue = Float(newValInHundredKelvinUnits * 100.0) // Multiply by 100
                
                // Always update the local model value immediately for responsive UI
                viewModel.whiteBalance = kelvinValue
                
                // Throttle camera updates to prevent GPU overload
                let now = Date()
                if now.timeIntervalSince(throttleData.lastUpdateTime) >= minTimeInterval {
                    // Enough time has passed, apply immediately
                    viewModel.updateWhiteBalance(kelvinValue)
                    throttleData.lastUpdateTime = now
                    throttleData.pendingValue = nil
                } else {
                    // Too soon, schedule for later
                    throttleData.pendingValue = CGFloat(kelvinValue / 100.0)
                    
                    // Invalidate existing timer
                    throttleData.timer?.invalidate()
                    
                    // Schedule a new timer to apply latest value
                    throttleData.timer = Timer.scheduledTimer(withTimeInterval: minTimeInterval, repeats: false) { _ in
                        if let pendingValue = throttleData.pendingValue {
                            viewModel.updateWhiteBalance(Float(pendingValue * 100.0))
                            throttleData.lastUpdateTime = Date()
                            throttleData.pendingValue = nil
                        }
                    }
                }
            }
        )
    }
}

// Custom button style to ensure haptic reliability
struct HapticButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())  // Ensure the entire frame is tappable
            .opacity(configuration.isPressed ? 0.7 : 1.0)
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        return min(max(self, range.lowerBound), range.upperBound)
    }
} 