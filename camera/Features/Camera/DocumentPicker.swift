import SwiftUI
import UniformTypeIdentifiers

struct DocumentPicker: UIViewControllerRepresentable {
    let types: [UTType]
    let onPick: (URL) -> Void
    
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        print("📄 DocumentPicker: Creating document picker for types: \(types.map { $0.identifier })")
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        print("📄 DocumentPicker: Document picker created successfully")
        return picker
    }
    
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        print("📄 DocumentPicker: Creating coordinator")
        return Coordinator(onPick: onPick)
    }
    
    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        
        init(onPick: @escaping (URL) -> Void) {
            self.onPick = onPick
            super.init()
            print("📄 DocumentPicker: Coordinator initialized")
        }
        
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else {
                print("❌ DocumentPicker: No document was selected")
                return
            }
            
            print("✅ DocumentPicker: Document selected at URL: \(url.path)")
            
            if !url.startAccessingSecurityScopedResource() {
                print("❌ DocumentPicker: Failed to access security scoped resource at \(url.path)")
                return
            }
            
            defer {
                url.stopAccessingSecurityScopedResource()
                print("📄 DocumentPicker: Stopped accessing security scoped resource")
            }
            
            guard FileManager.default.fileExists(atPath: url.path) else {
                print("❌ DocumentPicker: File does not exist at path: \(url.path)")
                return
            }
            
            do {
                let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
                
                if FileManager.default.fileExists(atPath: tempURL.path) {
                    try FileManager.default.removeItem(at: tempURL)
                    print("📄 DocumentPicker: Removed existing file at temp location")
                }
                
                try FileManager.default.copyItem(at: url, to: tempURL)
                print("✅ DocumentPicker: Successfully copied file to: \(tempURL.path)")
                
                let fileAttributes = try FileManager.default.attributesOfItem(atPath: tempURL.path)
                if let fileSize = fileAttributes[.size] as? NSNumber {
                    print("📄 DocumentPicker: File size: \(fileSize.intValue) bytes")
                }
                
                DispatchQueue.main.async {
                    self.onPick(tempURL)
                }
            } catch {
                print("❌ DocumentPicker: Error handling selected file: \(error.localizedDescription)")
            }
        }
        
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            print("📄 DocumentPicker: Document selection was cancelled")
        }
    }
} 