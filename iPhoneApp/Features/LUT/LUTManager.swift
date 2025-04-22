import SwiftUI
import CoreImage
import UniformTypeIdentifiers
import os
import Metal

class LUTManager: ObservableObject {
    
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "LUTManager")
    private let device: MTLDevice
    private let settingsModel = SettingsModel()
    
    @Published var currentLUTFilter: CIFilter?
    @Published var currentLUTTexture: MTLTexture?
    private var dimension: Int = 0
    @Published var selectedLUTURL: URL? {
        didSet {
            // Save the URL string to UserDefaults via SettingsModel
            settingsModel.selectedLUTURLString = self.selectedLUTURL?.absoluteString
            logger.info("Saved selectedLUTURL to UserDefaults: \(self.selectedLUTURL?.absoluteString ?? "nil")")
        }
    }
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
        guard let metalDevice = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not supported on this device")
        }
        self.device = metalDevice
        loadRecentLUTs()
        
        // Try to load the previously selected LUT
        if let urlString = settingsModel.selectedLUTURLString,
           let url = URL(string: urlString) {
            logger.info("Attempting to load previously selected LUT from UserDefaults: \(url.path)")
            importLUT(from: url) { success in
                if success {
                    self.logger.info("Successfully reloaded selected LUT from UserDefaults.")
                } else {
                    self.logger.warning("Failed to reload selected LUT from UserDefaults URL: \(urlString). Clearing.")
                    self.settingsModel.selectedLUTURLString = nil
                    self.setupIdentityLUTTexture()
                }
            }
        } else {
            setupIdentityLUTTexture()
        }
    }
    
    // MARK: - Metal LUT Texture Setup
    
    private func createIdentityLUT(dimension: Int) -> (dimension: Int, data: [Float]) {
        var lutData = [Float]()
        lutData.reserveCapacity(dimension * dimension * dimension * 3)
        
        let scale = 1.0 / Float(dimension - 1)
        
        for b in 0..<dimension {
            for g in 0..<dimension {
                for r in 0..<dimension {
                    lutData.append(Float(r) * scale) // R
                    lutData.append(Float(g) * scale) // G
                    lutData.append(Float(b) * scale) // B
                }
            }
        }
        
        return (dimension: dimension, data: lutData)
    }
    
    private func setupIdentityLUTTexture() {
        let identityLUTInfo = createIdentityLUT(dimension: 32)
        setupLUTTexture(lutInfo: identityLUTInfo)
    }
    
    private func setupLUTTexture(lutInfo: (dimension: Int, data: [Float])) {
        let dimension = lutInfo.dimension
        
        // Create texture descriptor for 3D texture
        let textureDescriptor = MTLTextureDescriptor()
        textureDescriptor.textureType = .type3D
        textureDescriptor.pixelFormat = .rgba32Float
        textureDescriptor.width = dimension
        textureDescriptor.height = dimension
        textureDescriptor.depth = dimension
        textureDescriptor.mipmapLevelCount = 1
        textureDescriptor.usage = [MTLTextureUsage.shaderRead]
        
        guard let texture = device.makeTexture(descriptor: textureDescriptor) else {
            logger.error("Failed to create Metal texture for LUT")
            return
        }
        
        // Convert RGB data to RGBA format (adding alpha = 1.0)
        var rgbaData = [Float]()
        rgbaData.reserveCapacity(dimension * dimension * dimension * 4)
        
        for i in stride(from: 0, to: lutInfo.data.count, by: 3) {
            rgbaData.append(lutInfo.data[i])     // R
            rgbaData.append(lutInfo.data[i + 1]) // G
            rgbaData.append(lutInfo.data[i + 2]) // B
            rgbaData.append(1.0)                 // A
        }
        
        // Calculate region and upload data
        let region = MTLRegion(
            origin: MTLOrigin(x: 0, y: 0, z: 0),
            size: MTLSize(width: dimension, height: dimension, depth: dimension)
        )
        
        let bytesPerRow = dimension * MemoryLayout<Float>.size * 4
        let bytesPerImage = bytesPerRow * dimension
        
        texture.replace(
            region: region,
            mipmapLevel: 0,
            slice: 0,
            withBytes: rgbaData,
            bytesPerRow: bytesPerRow,
            bytesPerImage: bytesPerImage
        )
        
        DispatchQueue.main.async {
            self.currentLUTTexture = texture
        }
    }
    
    // MARK: - LUT Loading Methods
    
    /// Imports a LUT file from the given URL with completion handler
    /// - Parameters:
    ///   - url: The URL of the LUT file
    ///   - completion: Completion handler with success boolean
    func importLUT(from url: URL, completion: @escaping (Bool) -> Void) {
        // First check if the file exists
        guard FileManager.default.fileExists(atPath: url.path) else {
            logger.error("LUTManager Error: File does not exist at path: \(url.path)")
            completion(false)
            return
        }
        
        // Get file information before processing
        do {
            _ = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            logger.warning("LUTManager: Could not read file attributes: \(error.localizedDescription)")
        }
        
        // Create a secure bookmarked copy if needed (for files from iCloud or external sources)
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let destinationURL = documentsDirectory.appendingPathComponent("LUTs/\(url.lastPathComponent)")
        
        do {
            // Create LUTs directory if it doesn't exist
            let lutsDirectory = documentsDirectory.appendingPathComponent("LUTs")
            if !FileManager.default.fileExists(atPath: lutsDirectory.path) {
                try FileManager.default.createDirectory(at: lutsDirectory, withIntermediateDirectories: true)
            }
            
            // Only copy if not already in our LUTs folder
            if url.path != destinationURL.path {
                // Remove existing file at destination if needed
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }
                
                // Copy the file to our safe location
                try FileManager.default.copyItem(at: url, to: destinationURL)
            } else {
                logger.info("LUTManager: File is already in the correct location")
            }
            
            // Now load the LUT from the permanent location
            loadLUT(from: destinationURL)
            
            // Update successful
            DispatchQueue.main.async {
                self.selectedLUTURL = destinationURL
                completion(true)
            }
        } catch {
            logger.error("LUTManager Error: Failed to copy or load LUT: \(error.localizedDescription)")
            
            // Try to load directly from the original location as a fallback
            do {
                let lutInfo = try CubeLUTLoader.loadCubeFile(from: url)
                self.setupLUTTexture(lutInfo: lutInfo)
                self.setupLUTFilter(lutInfo: lutInfo) // Keep for CI pipeline if needed
                DispatchQueue.main.async {
                    self.selectedLUTURL = url
                    self.addToRecentLUTs(url: url)
                    completion(true)
                }
            } catch let loadError {
                logger.error("LUTManager Error: Failed to load LUT directly from \(url.path): \(loadError.localizedDescription)")
                DispatchQueue.main.async {
                    completion(false)
                }
            }
        }
    }
    
    func loadLUT(named fileName: String) {
        do {
            guard let fileURL = Bundle.main.url(forResource: fileName, withExtension: "cube") else {
                logger.error("LUTManager Error: File '\(fileName).cube' not found in bundle")
                throw NSError(domain: "LUTManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "LUT file not found in bundle"])
            }
            
            let lutInfo = try CubeLUTLoader.loadCubeFile(name: fileName)
            setupLUTTexture(lutInfo: lutInfo)
            setupLUTFilter(lutInfo: lutInfo)  // Keep CIFilter for backward compatibility
            addToRecentLUTs(url: fileURL)
        } catch let error {
            logger.error("LUTManager Error: Failed to load LUT '\(fileName)': \(error.localizedDescription)")
        }
    }
    
    func loadLUT(from url: URL) {
        // Start accessing security-scoped resource if needed
        let shouldStopAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if shouldStopAccessing {
                url.stopAccessingSecurityScopedResource()
                logger.info("LUTManager: Stopped accessing security-scoped resource for direct load")
            }
        }
        
        // Verify file exists
        guard FileManager.default.fileExists(atPath: url.path) else {
            logger.error("File does not exist at path: \(url.path)")
            return
        }
        
        logger.info("File exists: true")
        
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            if let fileSize = attributes[.size] as? NSNumber {
                logger.info("File size: \(fileSize.intValue) bytes")
            }
            if let fileType = attributes[.type] as? String {
                logger.info("File type: \(fileType)")
            }
        } catch {
            logger.warning("Could not get file attributes: \(error.localizedDescription)")
        }
        
        do {
            // Load data using CubeLUTLoader
            let lutInfo = try CubeLUTLoader.loadCubeFile(from: url)
            logger.info("LUT data loaded: dimension=\(lutInfo.dimension), data.count=\(lutInfo.data.count)")
            
            // Setup Metal Texture
            setupLUTTexture(lutInfo: lutInfo)
            
            // Setup Core Image Filter (optional, keep if needed)
            setupLUTFilter(lutInfo: lutInfo)
            
            DispatchQueue.main.async {
                self.selectedLUTURL = url
                self.addToRecentLUTs(url: url)
                self.logger.info("LUTManager: Successfully loaded LUT from URL and configured.")
            }
            
        } catch {
            logger.error("Failed to load LUT from URL \(url.path): \(error.localizedDescription)")
            // Optionally: Fallback to identity LUT or show error
            DispatchQueue.main.async {
                 self.clearLUT() // Reset to identity on failure
            }
        }
    }
    
    // Attempt to load a binary format LUT as a fallback
    private func tryLoadBinaryLUT(from url: URL) {
        do {
            // Read the file as binary data
            let data = try Data(contentsOf: url)
            logger.info("LUTManager: Read \(data.count) bytes from binary LUT file")
            
            // Try to parse as binary data and create a LUT
            if let lutInfo = try? parseBinaryLUTData(data) {
                setupLUTTexture(lutInfo: lutInfo)
                setupLUTFilter(lutInfo: lutInfo)  // Keep CIFilter for backward compatibility
                addToRecentLUTs(url: url)
                DispatchQueue.main.async {
                    self.selectedLUTURL = url
                }
                logger.info("LUTManager: Successfully loaded binary LUT")
            } else {
                logger.error("LUTManager: Failed to parse binary LUT data")
            }
        } catch {
            logger.error("LUTManager: Failed to read binary LUT file: \(error.localizedDescription)")
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
            logger.info("LUTManager: LUT filter created: dimension=\(lutInfo.dimension), data size=\(self.cubeData?.count ?? 0) bytes")
        } else {
            logger.error("LUTManager: Failed to create CIColorCube filter")
        }
    }
    
    // Applies the LUT to the given CIImage using the current filter instance
    func applyLUT(to image: CIImage) -> CIImage? {
        logger.trace("--> applyLUT called") // Use trace for frequent calls

        // Check if a valid LUT filter is currently configured
        guard let filter = self.currentLUTFilter else {
            logger.trace("    [applyLUT] No currentLUTFilter set. Returning original image.") // Use trace
            return image // Return original image if no LUT is active
        }

        // Apply the existing filter to the new image
        filter.setValue(image, forKey: kCIInputImageKey)

        // Return the output image
        let outputImage = filter.outputImage
        if outputImage != nil {
            logger.trace("    [applyLUT] Successfully applied existing LUT filter.") // Use trace
        } else {
            logger.warning("    [applyLUT] Failed: Existing CIFilter outputImage was nil.") // Use warning
        }
        return outputImage
    }
    
    // Creates a basic programmatic LUT when no files are available
    func setupProgrammaticLUT(dimension: Int, data: [Float]) {
        logger.info("LUTManager: Creating programmatic LUT: dimension=\(dimension), points=\(data.count/3)")
        
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
            logger.info("LUTManager: Programmatic LUT filter created")
        } else {
            logger.error("LUTManager: Failed to create programmatic CIColorCube filter")
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
        logger.info("LUTManager: Clearing current LUT and resetting to identity")
        setupIdentityLUTTexture() // Reset texture to identity
        // Also clear the CI filter if it's being managed
        DispatchQueue.main.async {
             self.currentLUTFilter = nil // Or set to an identity CI filter if needed
             self.selectedLUTURL = nil
             self.logger.info("LUT cleared, reset to identity texture.")
         }
    }
    
    /// Alias for clearLUT() for more readable API
    func clearCurrentLUT() {
        clearLUT()
    }
    
    // MARK: - Binary LUT Parsing
    
    private func parseBinaryLUTData(_ data: Data) throws -> (dimension: Int, data: [Float]) {
        // For binary LUTs, we'll assume a standard 32x32x32 dimension
        // This is a common size that works well for most use cases
        let dimension = 32
        let expectedFloatCount = dimension * dimension * dimension * 3 // RGB values
        
        // Convert binary data to array of floats
        var floatArray = [Float]()
        floatArray.reserveCapacity(expectedFloatCount)
        
        // Try to interpret the data as an array of floats
        let floatSize = MemoryLayout<Float>.size
        for i in stride(from: 0, to: data.count, by: floatSize) {
            if i + floatSize <= data.count {
                let floatData = data.subdata(in: i..<(i + floatSize))
                var float: Float = 0
                _ = withUnsafeMutableBytes(of: &float) { floatData.copyBytes(to: $0) }
                
                // Ensure values are in 0-1 range
                float = max(0, min(1, float))
                floatArray.append(float)
            }
        }
        
        // If we don't have enough data for a complete LUT, throw an error
        guard floatArray.count >= expectedFloatCount else {
            throw NSError(domain: "LUTManager",
                        code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "Insufficient data for binary LUT: found \(floatArray.count) values, expected \(expectedFloatCount)"])
        }
        
        // Trim any extra data
        if floatArray.count > expectedFloatCount {
            floatArray = Array(floatArray.prefix(expectedFloatCount))
        }
        
        return (dimension: dimension, data: floatArray)
    }
}
