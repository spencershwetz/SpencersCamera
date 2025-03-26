import SwiftUI
import UIKit

struct FunctionButtonsView: View {
    @State private var topSafeAreaHeight: CGFloat = 44 // Default value
    
    var body: some View {
        GeometryReader { geometry in
            HStack {
                // Left side buttons
                HStack {
                    Button("F1") {
                        print("F1 tapped")
                    }
                    .buttonStyle(FunctionButtonStyle())
                    .padding(.trailing, 16) // Space between F1 and F2
                    
                    Button("F2") {
                        print("F2 tapped")
                    }
                    .buttonStyle(FunctionButtonStyle())
                }
                .padding(.leading, geometry.size.width * 0.15) // Keep F2 in current position
                
                Spacer()
                
                // Right side buttons
                HStack {
                    Button("F3") {
                        print("F3 tapped")
                    }
                    .buttonStyle(FunctionButtonStyle())
                    .padding(.trailing, 16) // Space between F3 and F4
                    
                    Button("F4") {
                        print("F4 tapped")
                    }
                    .buttonStyle(FunctionButtonStyle())
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
