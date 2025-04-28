import SwiftUI

struct FocusSquare: View {
    var body: some View {
        Rectangle()
            .stroke(Color.yellow, lineWidth: 2)
            .frame(width: 80, height: 80)
            .shadow(color: .black.opacity(0.8), radius: 1)
    }
}

#Preview {
    FocusSquare()
} 