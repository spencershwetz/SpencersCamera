import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var lutManager: LUTManager
    @StateObject private var documentDelegate: LUTDocumentPickerDelegate
    
    init(lutManager: LUTManager) {
        self.lutManager = lutManager
        // Initialize the document delegate with the LUT manager
        _documentDelegate = StateObject(wrappedValue: LUTDocumentPickerDelegate(lutManager: lutManager))
    }
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Camera Settings")) {
                    // Other settings can go here
                }
                
                Section(header: Text("LUT Settings")) {
                    if let selectedLUT = lutManager.selectedLUTURL?.lastPathComponent {
                        HStack {
                            Text("Current LUT")
                            Spacer()
                            Text(selectedLUT)
                                .foregroundColor(.secondary)
                        }
                        
                        Button("Clear LUT") {
                            lutManager.clearLUT()
                        }
                        .foregroundColor(.red)
                    }
                    
                    Button("Import LUT") {
                        showDocumentPicker()
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarItems(trailing: Button("Done") {
                dismiss()
            })
        }
    }
    
    private func showDocumentPicker() {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: LUTManager.supportedTypes,
            asCopy: true
        )
        picker.delegate = documentDelegate
        
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = windowScene.windows.first,
           let rootViewController = window.rootViewController {
            rootViewController.present(picker, animated: true)
        }
    }
}

// Document picker delegate as a separate class
class LUTDocumentPickerDelegate: NSObject, UIDocumentPickerDelegate, ObservableObject {
    let lutManager: LUTManager
    
    init(lutManager: LUTManager) {
        self.lutManager = lutManager
        super.init()
    }
    
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let selectedURL = urls.first else { return }
        lutManager.loadLUT(from: selectedURL)
    }
}

#Preview {
    SettingsView(lutManager: LUTManager())
}
