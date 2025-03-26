import SwiftUI

struct FunctionButtonsView: View {
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                // Debug view to show the top of the screen area
                Rectangle()
                    .fill(Color.red.opacity(0.3))
                    .frame(height: 1)
                    .padding(.horizontal, 0)
                
                HStack {
                    // Left side function buttons
                    HStack(spacing: 12) {
                        Button("F1") { }
                            .buttonStyle(FunctionButtonStyle())
                        Button("F2") { }
                            .buttonStyle(FunctionButtonStyle())
                    }
                    
                    Spacer()
                        .frame(minWidth: geometry.size.width * 0.4) // Forces significant space in middle
                    
                    // Right side function buttons
                    HStack(spacing: 12) {
                        Button("F3") { }
                            .buttonStyle(FunctionButtonStyle())
                        Button("F4") { }
                            .buttonStyle(FunctionButtonStyle())
                    }
                }
                .padding(.horizontal)
                .padding(.top, 4)
                
                Text("SafeArea Top: \(geometry.safeAreaInsets.top)")
                    .font(.system(size: 10))
                    .foregroundColor(.red)
                    .padding(.top, 2)
                    .opacity(0.7)
            }
            .onAppear {
                print("DEBUG: FunctionButtonsView appeared, safeAreaInsets: \(geometry.safeAreaInsets)")
            }
        }
        .frame(height: 60) // Increased height to accommodate debugging elements
        .background(Color.black) // Solid black background
    }
}

struct FunctionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(.white)
            .font(.system(size: 16, weight: .medium))
            .padding(.vertical, 6)
            .padding(.horizontal, 12)
            .background(Color.black.opacity(0.6))
            .cornerRadius(8)
            .opacity(configuration.isPressed ? 0.7 : 1.0)
    }
}
