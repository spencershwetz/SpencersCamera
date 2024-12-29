import Foundation
import CoreImage
import UniformTypeIdentifiers

class LUTManager: ObservableObject {
    @Published var selectedLUTURL: URL?
    @Published var availableLUTs: [URL] = []
    @Published var currentLUTFilter: CIFilter?
    
    static let supportedTypes: [UTType] = {
        if let cubeType = UTType(tag: "cube",
                                tagClass: .filenameExtension,
                                conformingTo: .data) {
            return [cubeType]
        }
        return [.data]
    }()
    
    func loadLUT(from url: URL) {
        guard url.pathExtension.lowercased() == "cube" else {
            print("❌ Invalid file type. Only .cube files are supported")
            return
        }
        
        do {
            guard url.startAccessingSecurityScopedResource() else {
                print("❌ Failed to access security scoped resource")
                return
            }
            
            defer {
                url.stopAccessingSecurityScopedResource()
            }
            
            print("🎨 Loading LUT from: \(url.lastPathComponent)")
            let lutData = try Data(contentsOf: url)
            
            if let lutFilter = CIFilter(name: "CIColorCubeWithColorSpace") {
                lutFilter.setValue(lutData, forKey: "inputCubeData")
                
                if let colorSpace = CGColorSpace(name: CGColorSpace.itur_2100_HLG) {
                    lutFilter.setValue(colorSpace, forKey: "inputColorSpace")
                    print("✅ Set color space to HLG for Apple Log")
                } else {
                    print("⚠️ Failed to set HLG color space, falling back to extended sRGB")
                    if let srgbSpace = CGColorSpace(name: CGColorSpace.extendedSRGB) {
                        lutFilter.setValue(srgbSpace, forKey: "inputColorSpace")
                        print("✅ Set fallback color space to extended sRGB")
                    }
                }
                
                DispatchQueue.main.async {
                    self.selectedLUTURL = url
                    self.currentLUTFilter = lutFilter
                    print("✅ LUT loaded successfully: \(url.lastPathComponent)")
                }
            } else {
                print("❌ Failed to create color cube filter")
            }
        } catch {
            print("❌ Failed to load LUT: \(error.localizedDescription)")
        }
    }
    
    func clearLUT() {
        DispatchQueue.main.async {
            print("🧹 Clearing LUT")
            self.selectedLUTURL = nil
            self.currentLUTFilter = nil
            print("✅ LUT cleared successfully")
        }
    }
    
    func applyLUT(to image: CIImage) -> CIImage? {
        guard let filter = currentLUTFilter else {
            print("⚠️ No LUT filter available to apply")
            return nil
        }
        
        print("🎨 Applying LUT to image")
        filter.setValue(image, forKey: kCIInputImageKey)
        
        if let outputImage = filter.outputImage {
            print("✅ LUT applied successfully")
            return outputImage
        } else {
            print("❌ Failed to apply LUT")
            return nil
        }
    }
} 