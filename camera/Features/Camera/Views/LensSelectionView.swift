import SwiftUI

struct LensSelectionView: View {
    @ObservedObject var viewModel: CameraViewModel
    let availableLenses: [CameraLens]
    
    var body: some View {
        HStack(spacing: 25) {
            ForEach(availableLenses, id: \.self) { lens in
                Button(action: {
                    viewModel.switchToLens(lens)
                }) {
                    Text(lens.rawValue + "×")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(viewModel.currentLens == lens ? .yellow : .white)
                        .frame(width: 32, height: 32)
                        .background(
                            Circle()
                                .fill(Color.black.opacity(0.35))
                                .overlay(
                                    Circle()
                                        .strokeBorder(
                                            viewModel.currentLens == lens ? Color.yellow : Color.white.opacity(0.5),
                                            lineWidth: 1
                                        )
                                )
                        )
                }
            }
        }
        .padding(.horizontal)
        .background(Color.black.opacity(0.25))
    }
} 