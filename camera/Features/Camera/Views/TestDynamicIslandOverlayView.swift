import SwiftUI

/// A test view for positioning content in the Dynamic Island area
struct TestDynamicIslandOverlayView: View {
    @State private var topInset: CGFloat = 0
    @State private var viewFrame: CGRect = .zero
    
    var body: some View {
        GeometryReader { geometry in
            let _ = print("DEBUG: GeometryReader size: \(geometry.size)")
            
            ZStack(alignment: .top) {
                // Background to see the view bounds
                Color.black.opacity(0.5)
                    .edgesIgnoringSafeArea(.all)
                
                // Function buttons container
                VStack(spacing: 0) {
                    // Function buttons
                    HStack {
                        // Left side buttons
                        HStack(spacing: 12) {
                            Button("F1") {
                                print("F1 tapped")
                            }
                            .buttonStyle(TestFunctionButtonStyle())
                            
                            Button("F2") {
                                print("F2 tapped")
                            }
                            .buttonStyle(TestFunctionButtonStyle())
                        }
                        
                        Spacer()
                        
                        // Right side buttons
                        HStack(spacing: 12) {
                            Button("F3") {
                                print("F3 tapped")
                            }
                            .buttonStyle(TestFunctionButtonStyle())
                            
                            Button("F4") {
                                print("F4 tapped")
                            }
                            .buttonStyle(TestFunctionButtonStyle())
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 2)
                    .background(GeometryReader { buttonGeometry in
                        Color.clear
                            .preference(key: ViewFrameKey.self, value: buttonGeometry.frame(in: .global))
                    })
                    
                    Spacer() // Push content to top
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .ignoresSafeArea()
        .onPreferenceChange(ViewFrameKey.self) { frame in
            viewFrame = frame
            print("DEBUG: Button container frame: \(frame)")
        }
        .onAppear {
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let window = windowScene.windows.first {
                topInset = window.safeAreaInsets.top
                print("DEBUG: TestDynamicIslandOverlayView onAppear - Top safe area inset: \(topInset)")
                print("DEBUG: TestDynamicIslandOverlayView onAppear - Window frame: \(window.frame)")
                print("DEBUG: TestDynamicIslandOverlayView onAppear - Safe area insets: \(window.safeAreaInsets)")
            }
        }
    }
}

/// Custom button style for test function buttons
struct TestFunctionButtonStyle: ButtonStyle {
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

// Preference key to track view frame
struct ViewFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

/// Preview provider for TestDynamicIslandOverlayView
struct TestDynamicIslandOverlayView_Previews: PreviewProvider {
    static var previews: some View {
        TestDynamicIslandOverlayView()
    }
} 