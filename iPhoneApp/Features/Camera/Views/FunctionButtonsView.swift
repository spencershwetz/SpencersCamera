import SwiftUI
import UIKit

/// View containing the main function buttons (Record, Flip Camera, Settings, Library).
struct FunctionButtonsView: View {
    @ObservedObject var viewModel: CameraViewModel
    @ObservedObject var settingsModel: SettingsModel // Inject SettingsModel
    @ObservedObject private var orientationViewModel = DeviceOrientationViewModel.shared
    @Binding var isShowingSettings: Bool
    @Binding var isShowingLibrary: Bool
    @State private var topSafeAreaHeight: CGFloat = 44 // Default value
    
    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                // Left side buttons
                HStack {
                    functionButton(index: 1, assignedAbility: $settingsModel.functionButton1Ability)
                        .padding(.trailing, 16) // Space between F1 and F2
                    
                    functionButton(index: 2, assignedAbility: $settingsModel.functionButton2Ability)
                }
                .padding(.leading, geometry.size.width * 0.15)
                
                Spacer()
                    .frame(minWidth: geometry.size.width * 0.3)
                
                // Right side buttons (Placeholder for F3, F4)
                HStack {
                    // Placeholder for F3
                    Spacer().frame(width: 40, height: 30)
                        .padding(.trailing, 16)
                    // Placeholder for F4
                    Spacer().frame(width: 40, height: 30)
                }
                .padding(.trailing, geometry.size.width * 0.15)
            }
            .padding(.top, 20)
            .frame(width: geometry.size.width, height: 44)
            .background(Color.black.opacity(0.01))
        }
    }
    
    // Reusable view for a function button with context menu
    @ViewBuilder
    private func functionButton(index: Int, assignedAbility: Binding<FunctionButtonAbility>) -> some View {
        RotatingView(orientationViewModel: orientationViewModel, invertRotation: true) {
            Button(getButtonLabel(for: assignedAbility.wrappedValue)) {
                handleButtonTap(ability: assignedAbility.wrappedValue)
            }
            .foregroundColor(assignedAbility.wrappedValue == .lockExposure && viewModel.isExposureLocked ? .red : .white)
            .buttonStyle(FunctionButtonStyle())
        }
        .frame(width: 40, height: 30)
        .contextMenu {
            Text("Assign to F\(index)")
            Divider()
            ForEach(FunctionButtonAbility.allCases) { ability in
                Button {
                    assignedAbility.wrappedValue = ability
                } label: {
                    HStack {
                        Text(ability.displayName)
                        Spacer()
                        if assignedAbility.wrappedValue == ability {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        }
    }
    
    // Helper to get button label (can be customized later)
    private func getButtonLabel(for ability: FunctionButtonAbility) -> String {
        switch ability {
        case .none:
            return "F?"
        case .lockExposure:
            return "AE"
        case .shutterPriority:
            return "180°"
        // Add cases for future abilities
        }
    }
    
    // Placeholder for button tap action
    private func handleButtonTap(ability: FunctionButtonAbility) {
        print("Tapped button with ability: \(ability.displayName)")
        switch ability {
        case .none:
            // Do nothing or perhaps show an alert/hint to assign an ability
            print("Function button has no ability assigned.")
        case .lockExposure:
            viewModel.toggleExposureLock() // Call the new method on CameraViewModel
        case .shutterPriority:
            viewModel.toggleShutterPriority()
        // Add cases for future abilities
        }
    }
}

// A container that uses UIViewRepresentable to completely bypass safe areas
struct FunctionButtonsContainer<Content: View>: UIViewRepresentable {
    let content: Content
    
    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }
    
    func makeUIView(context: Context) -> UIView {
        let hostingController = UIHostingController(rootView: content)
        hostingController.view.backgroundColor = .clear
        
        // Disable safe area insets
        hostingController.additionalSafeAreaInsets = UIEdgeInsets(top: -60, left: 0, bottom: 0, right: 0)
        
        // Set up the container view
        let containerView = UIView()
        containerView.backgroundColor = .clear
        
        // Add hosting view as a child view
        containerView.addSubview(hostingController.view)
        
        // Set up constraints to position at the absolute top
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hostingController.view.topAnchor.constraint(equalTo: containerView.topAnchor),
            hostingController.view.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: containerView.bottomAnchor)
        ])
        
        // Store the hosting controller in the context
        context.coordinator.hostingController = hostingController
        
        return containerView
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {
        // Update the hosting controller's rootView if needed
        context.coordinator.hostingController?.rootView = content
        
        // Make sure it still has negative safe area insets
        context.coordinator.hostingController?.additionalSafeAreaInsets = UIEdgeInsets(top: -60, left: 0, bottom: 0, right: 0)
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    class Coordinator {
        var hostingController: UIHostingController<Content>?
    }
}

struct FunctionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .padding(.vertical, 3)
            .padding(.horizontal, 8)
            .background(Color.gray.opacity(0.3))
            .cornerRadius(5)
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
    }
}
