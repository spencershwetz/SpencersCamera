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
    
    // Computed property for the current LUT name
    var currentLUTName: String {
        selectedLUTURL?.lastPathComponent ?? "Custom LUT"
    }
    
    // Supported file types
    static let supportedTypes: [UTType] = [
        UTType(filenameExtension: "cube") ?? UTType.data,
        UTType(filenameExtension: "3dl") ?? UTType.data,
        UTType(filenameExtension: "lut") ?? UTType.data,
        UTType(filenameExtension: "look") ?? UTType.data,
        UTType.data // Fallback
    ]
    
    init() {
        loadRecentLUTs()
    }
    
    // MARK: - LUT Loading Methods
    
    /// Imports a LUT file from the given URL with completion handler
    /// - Parameters:
    ///   - url: The URL of the LUT file
    ///   - completion: Completion handler with success boolean
    func importLUT(from url: URL, completion: @escaping (Bool) -> Void) {
        print("\n📊 LUTManager: Attempting to import LUT from URL: \(url.path)")
        
        // First check if the file exists
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("❌ LUTManager Error: File does not exist at path: \(url.path)")
            completion(false)
            return
        }
        
        // Get file information before processing
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            if let fileSize = attributes[.size] as? NSNumber {
                print("📊 LUTManager: Original file size: \(fileSize.intValue) bytes")
            }
        } catch {
            print("⚠️ LUTManager: Could not read file attributes: \(error.localizedDescription)")
        }
        
        // Create a secure bookmarked copy if needed (for files from iCloud or external sources)
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let destinationURL = documentsDirectory.appendingPathComponent("LUTs/\(url.lastPathComponent)")
        
        do {
            // Create LUTs directory if it doesn't exist
            let lutsDirectory = documentsDirectory.appendingPathComponent("LUTs")
            if !FileManager.default.fileExists(atPath: lutsDirectory.path) {
                try FileManager.default.createDirectory(at: lutsDirectory, withIntermediateDirectories: true)
                print("📁 LUTManager: Created LUTs directory at \(lutsDirectory.path)")
            }
            
            // Only copy if not already in our LUTs folder
            if url.path != destinationURL.path {
                // Remove existing file at destination if needed
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                    print("🗑️ LUTManager: Removed existing file at destination")
                }
                
                // Copy the file to our safe location
                try FileManager.default.copyItem(at: url, to: destinationURL)
                print("✅ LUTManager: Copied LUT to permanent storage: \(destinationURL.path)")
            } else {
                print("ℹ️ LUTManager: File is already in the correct location")
            }
            
            // Now load the LUT from the permanent location
            loadLUT(from: destinationURL)
            
            // Update successful
            DispatchQueue.main.async {
                self.selectedLUTURL = destinationURL
                completion(true)
            }
        } catch {
            print("❌ LUTManager Error: Failed to copy or load LUT: \(error.localizedDescription)")
            
            // Try to load directly from the original location as a fallback
            loadLUT(from: url)
            DispatchQueue.main.async {
                self.selectedLUTURL = url
                completion(true)
            }
        }
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
        } catch let error {
            print("❌ LUTManager Error: Failed to load LUT '\(fileName)': \(error.localizedDescription)")
        }
    }
    
    func loadLUT(from url: URL) {
        print("\n📊 LUTManager: Attempting to load LUT from URL: \(url.path)")
        print("📊 LUTManager: URL is file URL: \(url.isFileURL)")
        
        // Verify file exists
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("❌ LUTManager Error: File does not exist at path: \(url.path)")
            return
        }
        
        print("📊 LUTManager: File exists: true")
        
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            if let fileSize = attributes[.size] as? NSNumber {
                print("📊 LUTManager: File size: \(fileSize.intValue) bytes")
            }
            if let fileType = attributes[.type] as? String {
                print("📊 LUTManager: File type: \(fileType)")
            }
        } catch {
            print("⚠️ LUTManager Error: Could not read file attributes: \(error.localizedDescription)")
        }
        
        // First try to read the file content preview
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            if let data = try handle.readToEnd(), let preview = String(data: data.prefix(100), encoding: .utf8) {
                print("📊 LUTManager: File content preview: \(preview.prefix(50))")
            } else {
                print("📊 LUTManager: Could not read file content preview (may be binary data)")
            }
        } catch {
            print("⚠️ LUTManager Error: Failed to read file content preview: \(error.localizedDescription)")
        }
        
        do {
            // Direct access to load the LUT data
            let lutInfo = try CubeLUTLoader.loadCubeFile(from: url)
            print("✅ LUT data loaded from URL: dimension=\(lutInfo.dimension), data.count=\(lutInfo.data.count)")
            setupLUTFilter(lutInfo: lutInfo)
            addToRecentLUTs(url: url)
            DispatchQueue.main.async {
                self.selectedLUTURL = url
            }
            print("✅ LUT successfully loaded and configured from URL")
        } catch {
            print("❌ LUTManager Error: Failed to load LUT from URL: \(error.localizedDescription)")
            
            // Try a fallback approach for binary LUT files
            if error.localizedDescription.contains("Invalid LUT format") || error.localizedDescription.contains("not properly formatted") {
                print("🔄 Attempting fallback for binary LUT format...")
                tryLoadBinaryLUT(from: url)
            }
        }
    }
    
    // Attempt to load a binary format LUT as a fallback
    private func tryLoadBinaryLUT(from url: URL) {
        do {
            // Read the file as binary data
            let data = try Data(contentsOf: url)
            print("📊 Read \(data.count) bytes from binary LUT file")
            
            // Create a basic identity LUT (no color changes) as fallback
            let dimension = 32 // Standard dimension for basic LUTs
            var lutData = [Float]()
            
            // Generate a basic identity LUT
            for b in 0..<dimension {
                for g in 0..<dimension {
                    for r in 0..<dimension {
                        let rf = Float(r) / Float(dimension - 1)
                        let gf = Float(g) / Float(dimension - 1)
                        let bf = Float(b) / Float(dimension - 1)
                        lutData.append(rf)
                        lutData.append(gf)
                        lutData.append(bf)
                    }
                }
            }
            
            // Setup the fallback LUT
            setupLUTFilter(lutInfo: (dimension: dimension, data: lutData))
            print("⚠️ Created fallback identity LUT with dimension \(dimension)")
            DispatchQueue.main.async {
                self.selectedLUTURL = url
            }
            addToRecentLUTs(url: url)
        } catch {
            print("❌ Binary LUT fallback also failed: \(error.localizedDescription)")
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
        guard let cubeData = self.cubeData else { return nil }
        
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        
        let params: [String: Any] = [
            "inputCubeDimension": cubeDimension,
            "inputCubeData": cubeData,
            "inputColorSpace": colorSpace as Any, // Explicit cast to Any
            kCIInputImageKey: image
        ]
        
        return CIFilter(name: "CIColorCube", parameters: params)?.outputImage
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
    
    /// Clears the current LUT filter (removing any applied LUT)
    func clearLUT() {
        print("Clearing current LUT filter")
        currentLUTFilter = nil
        selectedLUTURL = nil
        print("✅ LUT filter cleared")
    }
    
    /// Alias for clearLUT() for more readable API
    func clearCurrentLUT() {
        clearLUT()
    }
    
    /// Loads an identity LUT that doesn't modify colors (for testing)
    func loadIdentityLUT() {
        // Create a simple identity LUT with dimension 2
        let dimension = 2
        var lutData = [Float]()
        
        // Generate identity LUT data (output = input)
        for b in 0..<dimension {
            let bf = Float(b) / Float(dimension - 1)
            for g in 0..<dimension {
                let gf = Float(g) / Float(dimension - 1)
                for r in 0..<dimension {
                    let rf = Float(r) / Float(dimension - 1)
                    lutData.append(rf)
                    lutData.append(gf)
                    lutData.append(bf)
                }
            }
        }
        
        // Set up the LUT filter
        setupLUTFilter(lutInfo: (dimension: dimension, data: lutData))
        print("✅ Identity LUT loaded for testing")
    }
}
