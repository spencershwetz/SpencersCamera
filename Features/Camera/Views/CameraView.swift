private func cameraPreview() -> AnyView {
    return AnyView(
        Group {
            if viewModel.isSessionRunning {
                DirectCameraPreview(session: viewModel.session)
                    .edgesIgnoringSafeArea(.all)
            } else {
                // Placeholder when camera not available
                ZStack {
                    Color.black.edgesIgnoringSafeArea(.all)
                    Text("Camera initializing...")
                        .foregroundColor(.white)
                }
            }
        }
    )
}

// New direct preview component that uses our CustomPreviewView
struct DirectCameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    
    func makeUIView(context: Context) -> CustomPreviewView {
        // Create the view with session
        let preview = CustomPreviewView(session: session)
        
        // Force immediate layout
        DispatchQueue.main.async {
            preview.setNeedsLayout()
            preview.layoutIfNeeded()
        }
        
        return preview
    }
    
    func updateUIView(_ uiView: CustomPreviewView, context: Context) {
        // Ensure the session is connected to the layer
        if uiView.previewLayer.session == nil {
            uiView.previewLayer.session = session
        }
    }
} 