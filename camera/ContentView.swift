//
//  ContentView.swift
//  camera
//
//  Created by spencer on 2024-12-22.
//

import SwiftUI
import CoreData
import CoreMedia

struct ContentView: View {
    @StateObject private var viewModel = CameraViewModel()
    
    var body: some View {
        ZStack {
            if viewModel.isSessionRunning {
                CameraPreviewView(session: viewModel.session)
                    .ignoresSafeArea()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                
                VStack {
                    Spacer()
                    
                    // Camera controls
                    VStack(spacing: 20) {
                        HStack {
                            Text("WB: \(Int(viewModel.whiteBalance))K")
                            Slider(value: $viewModel.whiteBalance,
                                   in: 2000...8000,
                                   step: 100) { _ in
                                viewModel.updateWhiteBalance(viewModel.whiteBalance)
                            }
                        }
                        
                        HStack {
                            Text("ISO: \(Int(viewModel.iso))")
                            Slider(value: $viewModel.iso,
                                   in: viewModel.minISO...viewModel.maxISO,
                                   step: 1) { _ in
                                viewModel.updateISO(viewModel.iso)
                            }
                        }
                        
                        HStack {
                            Text("Shutter: 1/\(Int(viewModel.shutterSpeed.timescale)/Int(viewModel.shutterSpeed.value))")
                            Slider(value: .init(get: {
                                Float(viewModel.shutterSpeed.timescale)/Float(viewModel.shutterSpeed.value)
                            }, set: { newValue in
                                viewModel.updateShutterSpeed(CMTimeMake(value: 1, timescale: Int32(newValue)))
                            }), in: 15...8000, step: 1)
                        }
                        
                        Button(action: {
                            if viewModel.isRecording {
                                viewModel.stopRecording()
                            } else {
                                viewModel.startRecording()
                            }
                        }) {
                            Image(systemName: viewModel.isRecording ? "stop.circle" : "record.circle")
                                .font(.system(size: 60))
                                .foregroundColor(viewModel.isRecording ? .white : .red)
                                .opacity(viewModel.isProcessingRecording ? 0.5 : 1.0)
                        }
                        .disabled(viewModel.isProcessingRecording)
                    }
                    .padding()
                    .background(.ultraThinMaterial)
                }
            } else {
                ProgressView("Initializing Camera...")
            }
        }
        .edgesIgnoringSafeArea(.all)
        .alert(item: $viewModel.error) { error in
            Alert(title: Text("Error"),
                  message: Text(error.description),
                  dismissButton: .default(Text("OK")))
        }
    }
}

#Preview {
    ContentView().environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
}
