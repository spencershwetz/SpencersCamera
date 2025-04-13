import SwiftUI

struct DeviceRotationViewModifier: ViewModifier {
    let orientationViewModel: DeviceOrientationViewModel
    
    func body(content: Content) -> some View {
        GeometryReader { geometry in
            content
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                .rotationEffect(orientationViewModel.rotationAngle)
                .animation(.easeInOut(duration: 0.3), value: orientationViewModel.orientation)
                /*
                .onChange(of: orientationViewModel.orientation) { oldValue, newValue in
                    // print("DEBUG: [RotationModifier] Orientation changed from \\(oldValue.rawValue) to \\(newValue.rawValue)")
                    // print("DEBUG: [RotationModifier] Applying rotation angle: \\(orientationViewModel.rotationAngle.degrees)°")
                    // print("DEBUG: [RotationModifier] View frame: \\(geometry.size)")
                }
                */
        }
        .frame(width: 60, height: 60) // Match the button size
    }
}

extension View {
    func rotateWithDeviceOrientation(using orientationViewModel: DeviceOrientationViewModel) -> some View {
        // print("DEBUG: [RotationModifier] Applying rotation modifier to view")
        return modifier(DeviceRotationViewModifier(orientationViewModel: orientationViewModel))
    }
} 