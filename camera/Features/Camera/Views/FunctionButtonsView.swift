import SwiftUI

struct FunctionButtonsView: View {
    var body: some View {
        GeometryReader { geometry in
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
            .padding(.top, 8)
        }
        .frame(height: 44) // Fixed height for the function bar
    }
}

struct FunctionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(.white)
            .font(.system(size: 16, weight: .medium))
            .opacity(configuration.isPressed ? 0.7 : 1.0)
    }
}
