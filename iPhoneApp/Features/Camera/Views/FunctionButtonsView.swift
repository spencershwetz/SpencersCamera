import SwiftUI
import UIKit

/// View containing the main function buttons (Record, Flip Camera, Settings, Library).
struct FunctionButtonsView: View {
    @ObservedObject var viewModel: CameraViewModel
    @ObservedObject private var orientationViewModel = DeviceOrientationViewModel.shared
    @Binding var isShowingSettings: Bool
    @Binding var isShowingLibrary: Bool // Add binding for library presentation
    @State private var topSafeAreaHeight: CGFloat = 44 // Default value
    
    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) { // Set HStack spacing to 0 to have full control
                // Left side buttons
                HStack {
                    RotatingView(orientationViewModel: orientationViewModel, invertRotation: true) {
                        Button("F1") {
                            print("F1 tapped")
                        }
                        .buttonStyle(FunctionButtonStyle())
                    }
                    .frame(width: 40, height: 30)
                    .padding(.trailing, 16) // Space between F1 and F2
                    
                    RotatingView(orientationViewModel: orientationViewModel, invertRotation: true) {
                        Button("F2") {
                            print("F2 tapped")
                        }
                        .buttonStyle(FunctionButtonStyle())
                    }
                    .frame(width: 40, height: 30)
                }
                .padding(.leading, geometry.size.width * 0.15) // Keep F2 in current position
                
                Spacer()
                    .frame(minWidth: geometry.size.width * 0.3) // Ensure minimum space for Dynamic Island
                
                // Right side buttons
                HStack {
                    RotatingView(orientationViewModel: orientationViewModel, invertRotation: true) {
                        Button("F3") {
                            print("F3 tapped")
                        }
                        .buttonStyle(FunctionButtonStyle())
                    }
                    .frame(width: 40, height: 30)
                    .padding(.trailing, 16) // Space between F3 and F4
                    
                    RotatingView(orientationViewModel: orientationViewModel, invertRotation: true) {
                        Button("F4") {
                            print("F4 tapped")
                        }
                        .buttonStyle(FunctionButtonStyle())
                    }
                    .frame(width: 40, height: 30)
                }
                .padding(.trailing, geometry.size.width * 0.15) // Keep F3 in current position
            }
            .frame(width: geometry.size.width, height: 44)
            .background(Color.black.opacity(0.01))
            .position(x: geometry.size.width / 2, y: 28)
        }
        .ignoresSafeArea()
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
            .foregroundColor(.white)
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
    }
}
