import SwiftUI

struct LensSelectionView: View {
    @ObservedObject var viewModel: CameraViewModel
    let availableLenses: [CameraLens]
    
    var body: some View {
        HStack(spacing: 45) {
            ForEach(availableLenses, id: \.self) { lens in
                Button(action: {
                    viewModel.switchToLens(lens)
                }) {
                    Text(lens.rawValue + "×")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(viewModel.currentLens == lens ? .yellow : .white)
                        .frame(width: 44, height: 44)
                }
            }
        }
        .padding(.horizontal)
        .background(Color.black.opacity(0.25))
    }
} 