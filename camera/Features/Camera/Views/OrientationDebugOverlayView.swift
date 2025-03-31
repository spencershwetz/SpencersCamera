import SwiftUI
import AVFoundation

struct OrientationDebugOverlayView: View {
    @ObservedObject var viewModel: CameraViewModel
    
    // Track device orientation
    @State private var deviceOrientation: UIDeviceOrientation = UIDevice.current.orientation
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Orientation Debug")
                .font(.headline)
                .foregroundColor(.yellow)
            
            // Get video orientation from session
            let videoAngle = getVideoRotationAngle()
            
            // Device orientation info
            HStack {
                Text("Device:")
                    .foregroundColor(.white)
                Text(orientationName(deviceOrientation))
                    .foregroundColor(.green)
                Text("(\(deviceOrientation.videoRotationAngleValue)°)")
                    .foregroundColor(.green)
            }
            .font(.system(size: 14, weight: .medium))
            
            // Interface orientation info
            HStack {
                Text("Interface:")
                    .foregroundColor(.white)
                Text(interfaceOrientationName(viewModel.currentInterfaceOrientation))
                    .foregroundColor(.cyan)
            }
            .font(.system(size: 14, weight: .medium))
            
            // Camera video orientation
            HStack {
                Text("Video angle:")
                    .foregroundColor(.white)
                Text("\(videoAngle)°")
                    .foregroundColor(.yellow)
                    .accessibility(identifier: "currentOrientation")
            }
            .font(.system(size: 14, weight: .medium))
            
            // LUT status
            HStack {
                Text("LUT active:")
                    .foregroundColor(.white)
                Text(viewModel.lutManager.currentLUTFilter != nil ? "Yes" : "No")
                    .foregroundColor(viewModel.lutManager.currentLUTFilter != nil ? .green : .red)
                    .accessibility(identifier: "lutIndicator")
            }
            .font(.system(size: 14, weight: .medium))
            
            // Current lens
            HStack {
                Text("Current lens:")
                    .foregroundColor(.white)
                Text("\(viewModel.currentLens.rawValue)×")
                    .foregroundColor(.orange)
            }
            .font(.system(size: 14, weight: .medium))
            
            // Test buttons for UI testing
            if viewModel.isUITesting {
                Button("Load Test LUT") {
                    loadTestLUT()
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 12)
                .background(Color.blue.opacity(0.6))
                .cornerRadius(8)
                .foregroundColor(.white)
                .accessibilityIdentifier("testLUTButton")
            }
        }
        .padding(12)
        .background(Color.black.opacity(0.7))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.yellow, lineWidth: 1)
        )
        .padding(8)
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            deviceOrientation = UIDevice.current.orientation
        }
    }
    
    private func getVideoRotationAngle() -> CGFloat {
        guard let videoConnection = viewModel.session.outputs.first?.connection(with: .video) else {
            return 0.0
        }
        
        return videoConnection.videoRotationAngle
    }
    
    private func orientationName(_ orientation: UIDeviceOrientation) -> String {
        switch orientation {
        case .portrait:
            return "Portrait"
        case .portraitUpsideDown:
            return "Portrait Upside Down"
        case .landscapeLeft:
            return "Landscape Left"
        case .landscapeRight:
            return "Landscape Right"
        case .faceUp:
            return "Face Up"
        case .faceDown:
            return "Face Down"
        case .unknown:
            return "Unknown"
        @unknown default:
            return "Unknown"
        }
    }
    
    private func interfaceOrientationName(_ orientation: UIInterfaceOrientation) -> String {
        switch orientation {
        case .portrait:
            return "Portrait"
        case .portraitUpsideDown:
            return "Portrait Upside Down"
        case .landscapeLeft:
            return "Landscape Left"
        case .landscapeRight:
            return "Landscape Right"
        case .unknown:
            return "Unknown"
        @unknown default:
            return "Unknown"
        }
    }
    
    private func loadTestLUT() {
        // Create a simple identity LUT for testing
        let dimension = 32
        var lutData = [Float]()
        
        // Generate identity LUT
        for b in 0..<dimension {
            for g in 0..<dimension {
                for r in 0..<dimension {
                    let rf = Float(r) / Float(dimension - 1)
                    let gf = Float(g) / Float(dimension - 1)
                    let bf = Float(b) / Float(dimension - 1)
                    lutData.append(rf)
                    lutData.append(gf)
                    lutData.append(bf)
                }
            }
        }
        
        // Apply test LUT to view model
        viewModel.lutManager.setupProgrammaticLUT(dimension: dimension, data: lutData)
    }
} 