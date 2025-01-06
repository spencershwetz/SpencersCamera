import SwiftUI
import CoreImage
import UniformTypeIdentifiers

class LUTManager: ObservableObject {
    
    @Published var currentLUTFilter: CIFilter?
    private var dimension: Int = 0
    @Published var selectedLUTURL: URL?
    
    public static let supportedTypes: [UTType] = [
        UTType(filenameExtension: "cube")!,  // .cube LUT files
        UTType(filenameExtension: "3dl")!    // .3dl LUT files
    ]
    
    func loadLUT(named fileName: String) {
        do {
            let lutInfo = try CubeLUTLoader.loadCubeFile(name: fileName)
            setupLUTFilter(lutInfo: lutInfo)
        } catch {
            print("Failed to load LUT: \(error.localizedDescription)")
        }
    }
    
    func loadLUT(from url: URL) {
        selectedLUTURL = url
        do {
            let lutInfo = try CubeLUTLoader.loadCubeFile(from: url)
            setupLUTFilter(lutInfo: lutInfo)
        } catch {
            print("Failed to load LUT: \(error.localizedDescription)")
            DispatchQueue.main.async {
                self.currentLUTFilter = nil
                self.selectedLUTURL = nil
            }
        }
    }
    
    private func setupLUTFilter(lutInfo: (dimension: Int, data: [Float])) {
        dimension = lutInfo.dimension
        
        // Create CIColorCube filter
        let filter = CIFilter(name: "CIColorCube")
        
        // Convert [Float] of RGB to RGBA
        let rgbData = lutInfo.data
        var rgbaData = [Float](repeating: 0, count: dimension * dimension * dimension * 4)
        var idx = 0
        for i in stride(from: 0, to: rgbData.count, by: 3) {
            rgbaData[idx]   = rgbData[i]     // R
            rgbaData[idx+1] = rgbData[i+1]   // G
            rgbaData[idx+2] = rgbData[i+2]   // B
            rgbaData[idx+3] = 1.0            // A
            idx += 4
        }
        
        // Pass data to the filter using withUnsafeBufferPointer for safe memory management
        rgbaData.withUnsafeBufferPointer { pointer in
            let data = Data(buffer: pointer)
            filter?.setValue(dimension, forKey: "inputCubeDimension")
            filter?.setValue(data, forKey: "inputCubeData")
        }
        
        DispatchQueue.main.async {
            self.currentLUTFilter = filter
        }
    }
    
    func clearLUT() {
        currentLUTFilter = nil
        selectedLUTURL = nil
    }
    
    func applyLUT(to inputImage: CIImage) -> CIImage? {
        guard let filter = currentLUTFilter else { return nil }
        
        filter.setValue(inputImage, forKey: kCIInputImageKey)
        return filter.outputImage
    }
}
