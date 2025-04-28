import SwiftUI

struct ExposureBiasSlider: View {
    @ObservedObject var viewModel: CameraViewModel
    // Drag gesture state
    @State private var dragOffset: CGSize = .zero
    @State private var startBias: Float = 0.0

    var body: some View {
        GeometryReader { geo in
            VStack {
                Spacer()
                Slider(value: Binding(
                    get: { Double(viewModel.exposureBias) },
                    set: { newVal in
                        let floatVal = Float(newVal)
                        let delta = floatVal - viewModel.exposureBias
                        viewModel.adjustExposureBias(by: delta)
                    }
                ), in: Double(viewModel.minExposureBias)...Double(viewModel.maxExposureBias))
                .rotationEffect(.degrees(-90))
                .frame(width: 150)
                .offset(x: (geo.size.width/2) - 40) // Right side offset
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    ExposureBiasSlider(viewModel: CameraViewModel())
} 