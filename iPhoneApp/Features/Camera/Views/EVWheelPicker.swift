import SwiftUI

/// A horizontally scrolling wheel picker for Exposure Value (EV) compensation, based on the reference WheelPicker.
struct EVWheelPicker: View {
    // Bind to the camera's exposure bias value
    @Binding var value: Float
    let minEV: Float
    let maxEV: Float
    let step: Float
    let onEditingChanged: (Bool) -> Void
    
    // For haptic feedback
    @State private var lastFeedbackValue: Float = 0.0
    
    private var evValues: [Float] {
        stride(from: minEV, through: maxEV, by: step).map { round($0 * 100) / 100 }
    }
    
    var body: some View {
        GeometryReader { geo in
            let horizontalPadding = geo.size.width / 2
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(evValues, id: \.self) { ev in
                            VStack(spacing: 4) {
                                Rectangle()
                                    .fill(ev == 0 ? Color.accentColor : Color.gray.opacity(0.6))
                                    .frame(width: 2, height: ev == 0 ? 32 : 20)
                                Text(ev == 0 ? "0" : String(format: "%+.1f", ev))
                                    .font(.caption2)
                                    .foregroundColor(ev == value ? .accentColor : .secondary)
                            }
                            .frame(width: 40)
                            .id(ev)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if value != ev {
                                    hapticFeedbackIfNeeded(oldValue: value, newValue: ev)
                                    value = ev
                                    onEditingChanged(true)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, horizontalPadding)
                }
                .onAppear {
                    DispatchQueue.main.async {
                        proxy.scrollTo(value, anchor: .center)
                    }
                }
                .onChange(of: value) { oldValue, newValue in
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                    if oldValue != newValue {
                        hapticFeedbackIfNeeded(oldValue: oldValue, newValue: newValue)
                    }
                }
                .overlay(
                    Rectangle()
                        .frame(width: 2, height: 48)
                        .foregroundColor(.accentColor)
                        .opacity(0.8),
                    alignment: .center
                )
            }
            .overlay(
                Rectangle()
                    .frame(width: 2, height: 48)
                    .foregroundColor(.accentColor)
                    .opacity(0.8),
                alignment: .center
            )
        }
        .frame(height: 72)
    }
    
    private func offsetForValue(geo: GeometryProxy) -> CGFloat {
        guard let idx = evValues.firstIndex(of: value) else { return 0 }
        let itemWidth: CGFloat = 40 + 16 // width + spacing
        let centerOffset = CGFloat(idx) * itemWidth - geo.size.width / 2 + itemWidth / 2
        return -centerOffset
    }
    
    private func hapticFeedbackIfNeeded(oldValue: Float, newValue: Float) {
        if Int(oldValue * 10) != Int(newValue * 10) {
            let generator = UIImpactFeedbackGenerator(style: .rigid)
            generator.impactOccurred()
        }
    }
}

// Safe index access for arrays
private extension Array {
    subscript(safe index: Int) -> Element? {
        (startIndex..<endIndex).contains(index) ? self[index] : nil
    }
}

#Preview {
    EVWheelPicker(value: .constant(0.0), minEV: -3.0, maxEV: 3.0, step: 0.3) { _ in }
        .background(Color.black)
        .frame(width: 350, height: 80)

}
