import SwiftUI

struct CameraView: View {
    @StateObject private var lutManager = LUTManager()
    
    var body: some View {
        ZStack {
            CameraPreviewView(lutManager: lutManager)
            
            VStack {
                Spacer()
                HStack {
                    // Other camera controls...
                    LUTPickerView(lutManager: lutManager)
                }
                .padding()
            }
        }
    }
} 