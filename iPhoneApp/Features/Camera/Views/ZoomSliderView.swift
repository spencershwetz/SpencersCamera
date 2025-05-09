import SwiftUI
import Foundation

struct ZoomSliderView: View {
    @ObservedObject var viewModel: CameraViewModel
    
    private enum MenuType {
        case lens, shutter, iso, wb
    }
    
    @State private var activeMenu: MenuType? = nil
    
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
            withAnimation {
                if activeMenu == type {
                    activeMenu = nil
                } else {
                    activeMenu = type
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
                    viewModel.switchToLens(lens)
                } label: {
                    Text("\(lens.rawValue)×")
                        .font(.system(size: viewModel.currentLens == lens ? 17 : 15, weight: .medium))
                        .foregroundColor(viewModel.currentLens == lens ? .yellow : .white)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Color.black.opacity(0.65)))
                }
            }
        }
    }
    
    private var shutterMenu: some View {
        HStack(spacing: 20) {
            Button("Auto") {
                if viewModel.isShutterPriorityEnabled { viewModel.toggleShutterPriority() }
            }
            .foregroundColor(viewModel.isShutterPriorityEnabled ? .white : .yellow)
            .buttonStyle(.plain)
            
            Button("180°") {
                if !viewModel.isShutterPriorityEnabled { viewModel.toggleShutterPriority() }
            }
            .foregroundColor(viewModel.isShutterPriorityEnabled ? .yellow : .white)
            .buttonStyle(.plain)
        }
    }
    
    // ISO menu with auto + wheel
    private var isoMenu: some View {
        HStack(spacing: 12) {
            Button("Auto") {
                viewModel.isAutoExposureEnabled = true
            }
            .foregroundColor(viewModel.isAutoExposureEnabled ? .yellow : .white)
            .buttonStyle(PlainButtonStyle())
            
            SimpleWheelPicker(
                config: isoWheelConfig,
                value: isoBinding,
                onEditingChanged: { editing in
                    if editing {
                        viewModel.isAutoExposureEnabled = false
                    }
                })
                .frame(height: 60)
        }
    }
    
    private var wbMenu: some View {
        HStack(spacing: 12) {
            Button("Auto") {
                viewModel.setWhiteBalanceAuto(true)
            }
            .foregroundColor(viewModel.isWhiteBalanceAuto ? .yellow : .white)
            .buttonStyle(PlainButtonStyle())
            
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
    }
    
    // MARK: - Wheel Configs & Bindings
    private var isoWheelConfig: SimpleWheelPicker.Config {
        SimpleWheelPicker.Config(
            min: CGFloat(viewModel.minISO),
            max: CGFloat(viewModel.maxISO),
            stepsPerUnit: 1,
            spacing: 6,
            showsText: false
        )
    }
    
    private var wbWheelConfig: SimpleWheelPicker.Config {
        SimpleWheelPicker.Config(
            min: 25, // Represents 2500K
            max: 100, // Represents 10000K
            stepsPerUnit: 1, // 1 step per 100K unit
            spacing: 8, // Increased spacing a bit due to fewer ticks
            showsText: true
        )
    }
    
    private var isoBinding: Binding<CGFloat> {
        Binding<CGFloat>(
            get: { CGFloat(viewModel.iso) },
            set: { newVal in
                viewModel.updateISO(Float(newVal))
            }
        )
    }
    
    private var wbBinding: Binding<CGFloat> {
        Binding<CGFloat>(
            get: { CGFloat(viewModel.whiteBalance / 100.0) }, // Divide by 100
            set: { newValInHundredKelvinUnits in
                viewModel.updateWhiteBalance(Float(newValInHundredKelvinUnits * 100.0)) // Multiply by 100
            }
        )
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        return min(max(self, range.lowerBound), range.upperBound)
    }
} 