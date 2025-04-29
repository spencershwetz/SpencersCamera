import SwiftUI

struct FocusSquare: View {
    var isLocked: Bool = false
    
    var body: some View {
        ZStack {
            Rectangle()
                .stroke(Color.yellow, lineWidth: 2)
                .frame(width: 80, height: 80)
                .shadow(color: .black.opacity(0.8), radius: 1)
            
            if isLocked {
                Image(systemName: "lock.fill")
                    .foregroundColor(.yellow)
                    .font(.system(size: 16, weight: .bold))
                    .offset(x: 45, y: -45) // Position in top-right corner
                    .shadow(color: .black.opacity(0.8), radius: 1)
            }
        }
    }
}

#Preview {
    VStack {
        FocusSquare(isLocked: false)
        FocusSquare(isLocked: true)
    }
} 