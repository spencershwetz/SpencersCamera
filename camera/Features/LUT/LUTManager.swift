import SwiftUI
import CoreImage
import UniformTypeIdentifiers

class LUTManager: ObservableObject {
    
    @Published var currentLUTFilter: CIFilter?
    private var dimension: Int = 0
    @Published var selectedLUTURL: URL?
    @Published var recentLUTs: [String: URL]? = [:]
    
    // Maximum number of recent LUTs to store
    private let maxRecentLUTs = 5
    
    // UserDefaults key for storing recent LUTs
    private let recentLUTsKey = "recentLUTs"
    
    // New properties to store cube data
    private var cubeDimension: Int = 0
    private var cubeData: Data?
    
    // Supported file types
    static let supportedTypes = [UTType.data]
    
    init() {
        loadRecentLUTs()
    }
    
    func loadLUT(named fileName: String) {
        print("🔍 LUTManager: Attempting to load LUT file named '\(fileName)'")
        do {
            guard let fileURL = Bundle.main.url(forResource: fileName, withExtension: "cube") else {
                print("❌ LUTManager Error: File '\(fileName).cube' not found in bundle")
                print("📂 Bundle path: \(Bundle.main.bundlePath)")
                print("📂 Available resources: \(Bundle.main.paths(forResourcesOfType: "cube", inDirectory: nil))")
                throw NSError(domain: "LUTManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "LUT file not found in bundle"])
            }
            
            print("✅ LUT file found at: \(fileURL.path)")
            let lutInfo = try CubeLUTLoader.loadCubeFile(name: fileName)
            print("✅ LUT data loaded: dimension=\(lutInfo.dimension), data.count=\(lutInfo.data.count)")
            setupLUTFilter(lutInfo: lutInfo)
            addToRecentLUTs(url: fileURL)
            print("✅ LUT successfully loaded and configured")
        } catch {
            print("❌ LUTManager Error: Failed to load LUT '\(fileName)': \(error.localizedDescription)")
        }
    }
    
    func loadLUT(from url: URL) {
        print("\n📊 LUTManager: Attempting to load LUT from URL: \(url.path)")
        print("📊 LUTManager: URL is file URL: \(url.isFileURL)")
        print("📊 LUTManager: File exists: \(FileManager.default.fileExists(atPath: url.path))")
        
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            if let fileSize = attributes[.size] as? NSNumber {
                print("📊 LUTManager: File size: \(fileSize.intValue) bytes")
            }
            if let fileType = attributes[.type] as? String {
                print("📊 LUTManager: File type: \(fileType)")
            }
        } catch {
            print("❌ LUTManager Error: Could not read file attributes: \(error.localizedDescription)")
        }
        
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            if let data = try handle.readToEnd(), let preview = String(data: data.prefix(100), encoding: .utf8) {
                print("📊 LUTManager: File content preview: \(preview.prefix(50))")
            } else {
                print("📊 LUTManager: Could not read file content preview (may be binary data)")
            }
        } catch {
            print("❌ LUTManager Error: Failed to read file content: \(error.localizedDescription)")
        }
        
        do {
            let lutInfo = try CubeLUTLoader.loadCubeFile(from: url)
            print("✅ LUT data loaded from URL: dimension=\(lutInfo.dimension), data.count=\(lutInfo.data.count)")
            setupLUTFilter(lutInfo: lutInfo)
            addToRecentLUTs(url: url)
            selectedLUTURL = url
            print("✅ LUT successfully loaded and configured from URL")
        } catch {
            print("❌ LUTManager Error: Failed to load LUT from URL: \(error.localizedDescription)")
        }
    }
    
    // Sets up the CIColorCube filter with the provided LUT information
    func setupLUTFilter(lutInfo: (dimension: Int, data: [Float])) {
        self.cubeDimension = lutInfo.dimension
        self.dimension = lutInfo.dimension
        let expectedCount = lutInfo.dimension * lutInfo.dimension * lutInfo.dimension * 4 // RGBA
        
        // Convert RGB data to RGBA (required by CIFilter)
        var rgbaData = [Float]()
        rgbaData.reserveCapacity(expectedCount)
        
        // Original data is in RGB format, we need to add alpha = 1.0 for each entry
        for i in stride(from: 0, to: lutInfo.data.count, by: 3) {
            if i + 2 < lutInfo.data.count {
                rgbaData.append(lutInfo.data[i])     // R
                rgbaData.append(lutInfo.data[i+1])   // G
                rgbaData.append(lutInfo.data[i+2])   // B
                rgbaData.append(1.0)                 // A (always 1.0)
            }
        }
        
        // Create a copy of the data and convert to NSData
        // Fix for the dangling buffer pointer issue
        var dataCopy = rgbaData
        let nsData = NSData(bytes: &dataCopy, length: dataCopy.count * MemoryLayout<Float>.size)
        self.cubeData = nsData as Data
        
        if let filter = CIFilter(name: "CIColorCube") {
            filter.setValue(lutInfo.dimension, forKey: "inputCubeDimension")
            filter.setValue(self.cubeData, forKey: "inputCubeData")
            self.currentLUTFilter = filter
            print("✅ LUT filter created: dimension=\(lutInfo.dimension), data size=\(self.cubeData?.count ?? 0) bytes")
        } else {
            print("❌ Failed to create CIColorCube filter")
        }
    }
    
    // Applies the LUT to the given CIImage using a freshly created filter instance
    func applyLUT(to image: CIImage) -> CIImage? {
        guard let cubeData = self.cubeData else {
            print("❌ No cube data available in LUTManager")
            return nil
        }
        
        guard let filter = CIFilter(name: "CIColorCube") else {
            print("❌ Failed to create CIColorCube filter")
            return nil
        }
        
        filter.setValue(cubeDimension, forKey: "inputCubeDimension")
        filter.setValue(cubeData, forKey: "inputCubeData")
        filter.setValue(image, forKey: kCIInputImageKey)
        return filter.outputImage
    }
    
    // Creates a basic programmatic LUT when no files are available
    func setupProgrammaticLUT(dimension: Int, data: [Float]) {
        print("🎨 Creating programmatic LUT: dimension=\(dimension), points=\(data.count/3)")
        
        var rgbaData = [Float]()
        rgbaData.reserveCapacity(dimension * dimension * dimension * 4)
        
        // Convert RGB data to RGBA (required by CIFilter)
        for i in stride(from: 0, to: data.count, by: 3) {
            if i + 2 < data.count {
                rgbaData.append(data[i])     // R
                rgbaData.append(data[i+1])   // G
                rgbaData.append(data[i+2])   // B
                rgbaData.append(1.0)         // A (always 1.0)
            }
        }
        
        // Create a copy of the data to avoid dangling pointer
        var dataCopy = rgbaData
        let nsData = NSData(bytes: &dataCopy, length: dataCopy.count * MemoryLayout<Float>.size)
        self.cubeData = nsData as Data
        self.cubeDimension = dimension
        
        if let filter = CIFilter(name: "CIColorCube") {
            filter.setValue(dimension, forKey: "inputCubeDimension")
            filter.setValue(self.cubeData, forKey: "inputCubeData")
            self.currentLUTFilter = filter
            print("✅ Programmatic LUT filter created")
        } else {
            print("❌ Failed to create programmatic CIColorCube filter")
        }
    }
    
    // MARK: - Recent LUT Management
    
    private func loadRecentLUTs() {
        if let recentDict = UserDefaults.standard.dictionary(forKey: recentLUTsKey) as? [String: String] {
            var loadedLUTs: [String: URL] = [:]
            
            for (name, urlString) in recentDict {
                if let url = URL(string: urlString) {
                    loadedLUTs[name] = url
                }
            }
            
            self.recentLUTs = loadedLUTs
        }
    }
    
    private func addToRecentLUTs(url: URL) {
        if recentLUTs == nil {
            recentLUTs = [:]
        }
        
        // Add or update the URL
        recentLUTs?[url.lastPathComponent] = url
        
        // Ensure we don't exceed the maximum number of recent LUTs
        if let count = recentLUTs?.count, count > maxRecentLUTs {
            // Remove oldest entries
            let sortedKeys = recentLUTs?.keys.sorted { lhs, rhs in
                if let lhsURL = recentLUTs?[lhs], let rhsURL = recentLUTs?[rhs] {
                    return (try? lhsURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date() >
                           (try? rhsURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
                }
                return false
            }
            
            if let keysToRemove = sortedKeys?.suffix(from: maxRecentLUTs) {
                for key in keysToRemove {
                    recentLUTs?.removeValue(forKey: key)
                }
            }
        }
        
        // Save to UserDefaults
        let urlDict = recentLUTs?.mapValues { $0.absoluteString }
        UserDefaults.standard.set(urlDict, forKey: recentLUTsKey)
    }
    
    // MARK: - LUT Management
    
    /// Clears the current LUT filter
    func clearLUT() {
        currentLUTFilter = nil
        selectedLUTURL = nil
        print("✅ LUT filter cleared")
    }
}
