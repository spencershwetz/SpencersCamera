import SwiftUI

struct ZoomControlsView: View {
    @Binding var currentZoomLevel: Double
    let availableZoomLevels: [Double] = [0.5, 1.0, 2.0, 5.0]
    
    var body: some View {
        VStack(spacing: 16) {
            ForEach(availableZoomLevels, id: \.self) { level in
                ZoomButton(
                    level: formatZoomLevel(level),
                    isSelected: isZoomLevelSelected(level),
                    action: {
                        currentZoomLevel = level
                    }
                )
            }
        }
    }
    
    private func formatZoomLevel(_ level: Double) -> String {
        if level == 1.0 {
            return "1×"
        } else if level < 1.0 {
            return String(format: "%.1f", level)
        } else {
            return String(format: "%g", level)
        }
    }
    
    private func isZoomLevelSelected(_ level: Double) -> Bool {
        abs(currentZoomLevel - level) < 0.1
    }
}

struct ZoomButton: View {
    let level: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(isSelected ? Color.white.opacity(0.3) : Color.black.opacity(0.5))
                    .frame(width: 40, height: 40)
                
                Text(level)
                    .foregroundColor(.white)
                    .font(.system(size: 16, weight: isSelected ? .bold : .regular))
            }
        }
    }
}

struct ZoomControlsView_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            Color.black
            ZoomControlsView(currentZoomLevel: .constant(1.0))
        }
    }
} 