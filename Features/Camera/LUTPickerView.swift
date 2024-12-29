import SwiftUI
import UniformTypeIdentifiers

struct LUTPickerView: View {
    @ObservedObject var lutManager: LUTManager
    @State private var isFilePickerPresented = false
    
    var body: some View {
        Button(action: {
            isFilePickerPresented = true
        }) {
            Label(lutManager.selectedLUTName ?? "Select LUT", systemImage: "photo.artframe")
                .foregroundColor(.white)
                .padding(8)
                .background(.ultraThinMaterial)
                .cornerRadius(8)
        }
        .fileImporter(
            isPresented: $isFilePickerPresented,
            allowedContentTypes: [UTType(filenameExtension: "cube")!],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                do {
                    try lutManager.loadLUT(from: url)
                } catch {
                    print("Error loading LUT: \(error)")
                }
            case .failure(let error):
                print("Error selecting LUT: \(error)")
            }
        }
    }
} 