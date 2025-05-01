import SwiftUI
import Foundation

struct ZoomSliderView: View {
    @ObservedObject var viewModel: CameraViewModel
    let availableLenses: [CameraLens]
    @State private var impactFeedbackGenerator = UIImpactFeedbackGenerator(style: .light)
    
    var body: some View {
        VStack(spacing: 12) {
            
            // Lens buttons
            HStack(spacing: 14) {
                ForEach(availableLenses, id: \.self) { lens in
                    Button(action: {
                        impactFeedbackGenerator.impactOccurred()
                        viewModel.switchToLens(lens)
                    }) {
                        Text(lens.rawValue + "×")
                            .font(.system(size: viewModel.currentLens == lens ? 17 : 15, weight: .medium))
                            .foregroundColor(viewModel.currentLens == lens ? .yellow : .white)
                            .frame(width: viewModel.currentLens == lens ? 42 : 36, height: viewModel.currentLens == lens ? 42 : 36)
                            .background(
                                Circle()
                                    .fill(Color.black.opacity(0.65))
                            )
                    }
                    .transition(.scale)
                    .animation(.spring(response: 0.3), value: viewModel.currentLens == lens)
                }
            }
        }
    }
    

}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        return min(max(self, range.lowerBound), range.upperBound)
    }
} 