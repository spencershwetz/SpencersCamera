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
        // Replace VStack with ZStack + overlay to maintain stable layout
        ZStack {
            // Main buttons row
            baseControls
        }
        .overlay(alignment: .top) {
            // Show menu above the buttons when active
            if let activeMenu {
                menuContent(for: activeMenu)
                    .padding(.bottom, 8) // Space between menu and buttons
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(10) // Ensure menu is above buttons
            }
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
            min: 2500,
            max: 10000,
            stepsPerUnit: 10, // 10 steps per 1K -> 100 K increments
            spacing: 6,
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
            get: { CGFloat(viewModel.whiteBalance) },
            set: { newVal in
                viewModel.updateWhiteBalance(Float(newVal))
            }
        )
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        return min(max(self, range.lowerBound), range.upperBound)
    }
} 