import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var lutManager: LUTManager
    @StateObject private var documentDelegate: LUTDocumentPickerDelegate
    @State private var showLUTHistory = false
    
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
                
                Section {
                    // Current LUT display
                    if let selectedLUT = lutManager.selectedLUTURL?.lastPathComponent {
                        HStack {
                            Label {
                                Text("Current LUT")
                            } icon: {
                                Image(systemName: "photo.artframe")
                            }
                            .foregroundColor(.primary)
                            
                            Spacer()
                            
                            Text(selectedLUT)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    
                    // Clear button
                    Button(action: {
                        lutManager.currentLUTFilter = nil
                        lutManager.selectedLUTURL = nil
                    }) {
                        Label("Clear LUT", systemImage: "trash")
                    }
                    .foregroundColor(.red)
                    
                    // Import button
                    Button(action: importLUT) {
                        Label("Import LUT", systemImage: "square.and.arrow.down")
                    }
                    
                    // Recent LUTs
                    if let recent = lutManager.recentLUTs, !recent.isEmpty {
                        DisclosureGroup("Recently Used LUTs") {
                            ForEach(Array(recent.keys), id: \.self) { key in
                                if let url = recent[key] {
                                    Button(action: {
                                        lutManager.loadLUT(from: url)
                                    }) {
                                        Text(key)
                                            .foregroundColor(.blue)
                                    }
                                }
                            }
                        }
                    }
                } header: {
                    Text("LUT Management")
                }
                
                Section(header: Text("LUT Info"), footer: Text("LUTs are applied after LOG conversion to ensure proper display")) {
                    Text("Supported formats: .cube, .3dl")
                        .font(.footnote)
                        .foregroundColor(.secondary)
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
    
    private func importLUT() {
        showDocumentPicker()
    }
}

// Document picker delegate as a separate class
class LUTDocumentPickerDelegate: NSObject, UIDocumentPickerDelegate, ObservableObject {
    let lutManager: LUTManager
    
    init(lutManager: LUTManager) {
        self.lutManager = lutManager
        super.init()
        print("📄 LUTDocumentPickerDelegate: Initialized with LUTManager")
    }
    
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let selectedURL = urls.first else {
            print("❌ LUTDocumentPickerDelegate: No document was selected")
            return
        }
        
        print("✅ LUTDocumentPickerDelegate: Document selected at URL: \(selectedURL.path)")
        
        // Start accessing the security-scoped resource
        let securityScopedAccess = selectedURL.startAccessingSecurityScopedResource()
        if !securityScopedAccess {
            print("❌ LUTDocumentPickerDelegate: Failed to access security scoped resource at \(selectedURL.path)")
        } else {
            print("✅ LUTDocumentPickerDelegate: Successfully accessed security scoped resource")
        }
        
        // Make sure we stop accessing the resource when we're done
        defer {
            if securityScopedAccess {
                selectedURL.stopAccessingSecurityScopedResource()
                print("📄 LUTDocumentPickerDelegate: Stopped accessing security scoped resource")
            }
        }
        
        // Check if file exists
        guard FileManager.default.fileExists(atPath: selectedURL.path) else {
            print("❌ LUTDocumentPickerDelegate: File does not exist at path: \(selectedURL.path)")
            return
        }
        
        // Due to the issue with creating copies, we'll create a bookmark to the file instead
        // This allows the app to access the file later without needing to copy it
        do {
            let bookmarkData = try selectedURL.bookmarkData(options: .minimalBookmark, 
                                                  includingResourceValuesForKeys: nil, 
                                                  relativeTo: nil)
            
            // Use the bookmark to create a URL that we can use later
            var isStale = false
            let _ = try URL(resolvingBookmarkData: bookmarkData, 
                           options: .withoutUI, 
                           relativeTo: nil, 
                           bookmarkDataIsStale: &isStale)
            
            if isStale {
                print("⚠️ LUTDocumentPickerDelegate: Bookmark is stale, creating a new one")
                // You might want to recreate the bookmark here if needed
            }
            
            print("✅ LUTDocumentPickerDelegate: Created bookmark for file")
            
            // Check if file is readable
            try checkFileIsReadable(at: selectedURL)
            
            // Pass the URL directly to LUTManager on the main thread
            DispatchQueue.main.async {
                self.lutManager.loadLUT(from: selectedURL)
            }
        } catch {
            print("❌ LUTDocumentPickerDelegate: Error handling selected file: \(error.localizedDescription)")
            if let nsError = error as NSError? {
                print("❌ Error details - Domain: \(nsError.domain), Code: \(nsError.code)")
                
                // If this is related to bookmark creation, try a fallback approach
                if nsError.domain == NSCocoaErrorDomain && nsError.code == 260 {
                    print("⚠️ LUTDocumentPickerDelegate: Trying fallback approach for file access")
                    
                    // Pass the URL directly to LUTManager as a fallback
                    DispatchQueue.main.async {
                        self.lutManager.loadLUT(from: selectedURL)
                    }
                }
            }
        }
    }
    
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        print("📄 LUTDocumentPickerDelegate: Document selection was cancelled")
    }
    
    private func checkFileIsReadable(at url: URL) throws {
        print("🔍 LUTDocumentPickerDelegate: Checking if file is readable: \(url.path)")
        
        // Check if we can open the file for reading
        let fileHandle = try FileHandle(forReadingFrom: url)
        defer {
            try? fileHandle.close()
        }
        
        // Try to read a small chunk of data
        if let data = try fileHandle.read(upToCount: 100), !data.isEmpty {
            print("✅ LUTDocumentPickerDelegate: File is readable, read \(data.count) bytes")
            
            // If it's a text file, print a preview
            if let textPreview = String(data: data, encoding: .utf8) {
                print("📄 Content preview: \(textPreview.prefix(50))")
            } else {
                print("📄 File contains binary data (not UTF-8 text)")
            }
        } else {
            print("⚠️ LUTDocumentPickerDelegate: File is empty or unreadable")
            throw NSError(domain: "LUTDocumentPicker", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "File is empty or could not be read"
            ])
        }
    }
}

#Preview {
    SettingsView(lutManager: LUTManager())
}
