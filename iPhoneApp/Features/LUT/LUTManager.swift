import SwiftUI
import CoreImage
import UniformTypeIdentifiers
import os
import Metal

class LUTManager: ObservableObject {
    
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "LUTManager")
    private let device: MTLDevice
    
    @Published var currentLUTFilter: CIFilter?
    @Published var currentLUTTexture: MTLTexture?
    private var dimension: Int = 0
    @Published var selectedLUTURL: URL?
    @Published var availableLUTs: [String: URL] = [:]
    
    // UserDefaults key for the last active LUT name
    private let lastActiveLUTNameKey = "lastActiveLUTName"
    
    // New properties to store cube data
    private var cubeDimension: Int = 0
    private var cubeData: Data?
    
    // Computed property for the current LUT name
    var currentLUTName: String {
        selectedLUTURL?.deletingPathExtension().lastPathComponent ?? "None"
    }
    
    // Supported file types
    static let supportedTypes: [UTType] = [
        UTType(filenameExtension: "cube") ?? UTType.data,
    ]
    
    init() {
        guard let metalDevice = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not supported on this device")
        }
        self.device = metalDevice
        setupIdentityLUTTexture()
        scanAndLoadInitialLUTs()
    }
    
    // MARK: - Initialization and Persistence
    
    private func scanAndLoadInitialLUTs() {
        var loadedAvailableLUTs: [String: URL] = [:]
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let lutsDirectory = documentsDirectory.appendingPathComponent("LUTs")
        
        // Ensure LUTs directory exists
        if !FileManager.default.fileExists(atPath: lutsDirectory.path) {
            do {
                try FileManager.default.createDirectory(at: lutsDirectory, withIntermediateDirectories: true)
                logger.info("Created LUTs directory at: \(lutsDirectory.path)")
            } catch {
                logger.error("Failed to create LUTs directory: \(error.localizedDescription)")
                return
            }
        }
        
        // Scan the LUTs directory
        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(at: lutsDirectory, includingPropertiesForKeys: nil)
            for url in fileURLs where url.pathExtension.lowercased() == "cube" {
                let name = url.deletingPathExtension().lastPathComponent
                loadedAvailableLUTs[name] = url
                logger.debug("Found LUT: \(name) at \(url.path)")
            }
        } catch {
            logger.error("Failed to scan LUTs directory: \(error.localizedDescription)")
        }
        
        // Update the published property on the main thread
        DispatchQueue.main.async {
            self.availableLUTs = loadedAvailableLUTs
            self.logger.info("Scanned LUT directory. Found \(loadedAvailableLUTs.count) LUTs.")
            
            // Load the last active LUT from UserDefaults
            if let lastActiveName = UserDefaults.standard.string(forKey: self.lastActiveLUTNameKey),
               let urlToLoad = loadedAvailableLUTs[lastActiveName] {
                self.logger.info("Found last active LUT name: \(lastActiveName). Attempting to load.")
                self.loadLUT(from: urlToLoad)
            } else {
                self.logger.info("No last active LUT found in UserDefaults or corresponding file not found.")
                self.setupIdentityLUTTexture()
                self.currentLUTFilter = nil
                self.selectedLUTURL = nil
            }
        }
    }
    
    private func saveLastActiveLUTName(name: String?) {
        UserDefaults.standard.set(name, forKey: lastActiveLUTNameKey)
        logger.debug("Saved last active LUT name: \(name ?? "None")")
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
        self.currentLUTFilter = nil
        self.selectedLUTURL = nil
        self.dimension = 0
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
            self.dimension = dimension
        }
    }
    
    // MARK: - LUT Loading Methods
    
    /// Imports a LUT file from the given URL with completion handler
    /// - Parameters:
    ///   - url: The URL of the LUT file
    ///   - completion: Completion handler with success boolean
    func importLUT(from url: URL, completion: @escaping (Bool) -> Void) {
        // First check if the file exists
        guard url.isFileURL else {
            logger.error("LUTManager Error: URL is not a file URL: \(url)")
            completion(false)
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            logger.error("LUTManager Error: File does not exist at path: \(url.path)")
            completion(false)
            return
        }
        
        // Get file information before processing
        do {
            _ = try FileManager.default.attributesOfItem(atPath: url.path)
            logger.debug("File attributes read successfully for \(url.lastPathComponent)")
        } catch {
            logger.warning("LUTManager: Could not read file attributes for \(url.lastPathComponent): \(error.localizedDescription)")
        }
        
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let lutsDirectory = documentsDirectory.appendingPathComponent("LUTs")
        let destinationURL = lutsDirectory.appendingPathComponent(url.lastPathComponent)
        
        do {
            // Ensure LUTs directory exists (redundant if init worked, but safe)
            if !FileManager.default.fileExists(atPath: lutsDirectory.path) {
                try FileManager.default.createDirectory(at: lutsDirectory, withIntermediateDirectories: true)
            }
            
            // Copy the file to our safe location if it's not already there
            if !FileManager.default.fileExists(atPath: destinationURL.path) {
                let shouldStopAccessing = url.startAccessingSecurityScopedResource()
                defer {
                    if shouldStopAccessing {
                        url.stopAccessingSecurityScopedResource()
                        logger.info("Stopped accessing security-scoped resource for import copy: \(url.lastPathComponent)")
                    }
                }
                logger.info("Attempting to copy \(url.lastPathComponent) to \(destinationURL.path)")
                try FileManager.default.copyItem(at: url, to: destinationURL)
                logger.info("Successfully copied \(url.lastPathComponent) to LUTs directory.")
            } else if url.path != destinationURL.path {
                logger.info("\(destinationURL.lastPathComponent) already exists, replacing with source from \(url.path)")
                let shouldStopAccessing = url.startAccessingSecurityScopedResource()
                defer {
                    if shouldStopAccessing {
                        url.stopAccessingSecurityScopedResource()
                        logger.info("Stopped accessing security-scoped resource for import overwrite: \(url.lastPathComponent)")
                    }
                }
                _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: url)
                logger.info("Successfully replaced \(destinationURL.lastPathComponent) in LUTs directory.")
            } else {
                logger.info("LUTManager: File \(url.lastPathComponent) is already in the correct location.")
            }
            
            // Now load the LUT from the permanent location
            loadLUT(from: destinationURL)
            
            // Add to available LUTs dictionary if not already present
            let lutName = destinationURL.deletingPathExtension().lastPathComponent
            if availableLUTs[lutName] == nil {
                DispatchQueue.main.async {
                    self.availableLUTs[lutName] = destinationURL
                    self.logger.info("Added imported LUT '\(lutName)' to available list.")
                }
            }
            
            completion(true)
        } catch {
            logger.error("LUTManager Error: Failed to copy or load LUT during import: \(error.localizedDescription)")
            completion(false)
        }
    }
    
    func loadLUT(from url: URL) {
        // Verify file exists
        guard FileManager.default.fileExists(atPath: url.path) else {
            logger.error("File does not exist at path: \(url.path). Cannot load LUT.")
            return
        }
        
        logger.info("Attempting to load LUT from: \(url.path)")
        
        do {
            let lutInfo = try CubeLUTLoader.loadCubeFile(from: url)
            setupLUTTexture(lutInfo: lutInfo)
            setupLUTFilter(lutInfo: lutInfo)
            
            let lutName = url.deletingPathExtension().lastPathComponent
            DispatchQueue.main.async {
                self.selectedLUTURL = url
                self.logger.info("Successfully loaded LUT: \(lutName)")
                self.saveLastActiveLUTName(name: lutName)
                if self.availableLUTs[lutName] == nil {
                    self.availableLUTs[lutName] = url
                }
            }
        } catch let loadError {
            logger.error("LUTManager Error: Failed to load LUT directly from \(url.path): \(loadError.localizedDescription)")
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
        logger.trace("--> applyLUT called")

        // Check if a valid LUT filter is currently configured
        guard let filter = self.currentLUTFilter else {
            logger.trace("    [applyLUT] No currentLUTFilter set. Returning original image.")
            return image
        }

        // Apply the existing filter to the new image
        filter.setValue(image, forKey: kCIInputImageKey)

        // Return the output image
        let outputImage = filter.outputImage
        if outputImage != nil {
            logger.trace("    [applyLUT] Successfully applied existing LUT filter.")
        } else {
            logger.warning("    [applyLUT] Failed: Existing CIFilter outputImage was nil.")
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
    
    // MARK: - LUT Management
    
    /// Clears the currently active LUT and resets to identity.
    func clearLUT() {
        DispatchQueue.main.async {
            self.setupIdentityLUTTexture()
            self.currentLUTFilter = nil
            self.selectedLUTURL = nil
            self.logger.info("Cleared active LUT, reset to identity.")
            self.saveLastActiveLUTName(name: nil)
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

// MARK: - Error Handling
enum LUTError: Error {
    case fileNotFound
    case directoryCreationFailed
    case copyFailed(Error)
    case loadFailed(Error)
    case invalidURL
    case unknown
}
