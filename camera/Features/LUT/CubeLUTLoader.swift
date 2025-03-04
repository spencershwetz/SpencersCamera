//
//  CubeLUTLoader.swift
//  camera
//
//  Created by spencer on 2024-12-30.
//

import Foundation
import CoreImage

/// Loads a .cube file and returns data for CIColorCube filter
class CubeLUTLoader {
    
    /// Parse .cube file into Float array and return dimension + LUT data
    static func loadCubeFile(name: String) throws -> (dimension: Int, data: [Float]) {
        guard let filePath = Bundle.main.url(forResource: name, withExtension: "cube") else {
            print("❌ CubeLUTLoader: LUT file '\(name).cube' not found in bundle")
            throw NSError(domain: "CubeLUTLoader", code: 1, userInfo: [NSLocalizedDescriptionKey: "LUT file not found"])
        }
        return try loadCubeFile(from: filePath)
    }
    
    /// Parse .cube file into Float array and return dimension + LUT data
    static func loadCubeFile(from url: URL) throws -> (dimension: Int, data: [Float]) {
        print("\n🔄 CubeLUTLoader: Loading LUT from \(url.path)")
        
        // First check if URL can be accessed (file might be security-scoped)
        if !FileManager.default.fileExists(atPath: url.path) {
            print("❌ CubeLUTLoader: File doesn't exist at path: \(url.path)")
            throw NSError(domain: "CubeLUTLoader", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "LUT file not found at specified path"
            ])
        }
        
        // Start accessing security-scoped resource if needed
        var didStartAccess = false
        if url.startAccessingSecurityScopedResource() {
            didStartAccess = true
            print("✅ CubeLUTLoader: Started accessing security-scoped resource")
        }
        
        // Make sure we stop accessing the resource when we're done
        defer {
            if didStartAccess {
                url.stopAccessingSecurityScopedResource()
                print("✅ CubeLUTLoader: Stopped accessing security-scoped resource")
            }
        }
        
        // Validate file exists and is readable
        try validateLUTFile(at: url)
        
        let fileContents: String
        do {
            fileContents = try String(contentsOf: url, encoding: .utf8)
            print("✅ Read \(fileContents.count) characters from LUT file")
            
            // Print first few lines of the file for debugging
            let previewLines = fileContents.components(separatedBy: .newlines).prefix(5).joined(separator: "\n")
            print("📃 LUT File Preview (first 5 lines):\n\(previewLines)")
        } catch {
            print("❌ Failed to read LUT file: \(error.localizedDescription)")
            if let nsError = error as NSError? {
                print("❌ Error details - Domain: \(nsError.domain), Code: \(nsError.code)")
                for (key, value) in nsError.userInfo {
                    print("❌ UserInfo[\(key)] = \(value)")
                }
            }
            
            // Try alternate approach for binary files
            if (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType?.conforms(to: .data) == true {
                print("⚠️ File appears to be binary data, attempting alternate loading method")
                throw NSError(domain: "CubeLUTLoader", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "Binary .cube files are not yet supported",
                    NSUnderlyingErrorKey: error
                ])
            }
            
            throw NSError(domain: "CubeLUTLoader", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Failed to read LUT file: \(error.localizedDescription)",
                NSUnderlyingErrorKey: error
            ])
        }
        
        let lines = fileContents.components(separatedBy: .newlines)
        print("📝 Parsing \(lines.count) lines from LUT file")
        
        var dimension = 0
        var cubeData = [Float]()
        var foundSize = false
        var headerEnded = false
        var linesProcessed = 0
        var dataLinesProcessed = 0
        var headerLines: [String] = []
        
        for line in lines {
            linesProcessed += 1
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Skip comments and empty lines
            if trimmed.hasPrefix("#") || trimmed.isEmpty {
                if !headerEnded && !trimmed.isEmpty {
                    headerLines.append(trimmed)
                }
                continue
            }
            
            // Process LUT size
            if trimmed.lowercased().contains("lut_3d_size") {
                let parts = trimmed.components(separatedBy: CharacterSet.whitespaces)
                if let sizeString = parts.last, let size = Int(sizeString) {
                    dimension = size
                    let totalCount = size * size * size * 3
                    cubeData.reserveCapacity(totalCount)
                    foundSize = true
                    print("✅ Found LUT_3D_SIZE: \(size), expecting \(totalCount) data points")
                    headerLines.append(trimmed)
                } else {
                    print("⚠️ Found LUT_3D_SIZE but couldn't parse value: \(trimmed)")
                }
            } 
            // Process data lines
            else if dimension > 0 {
                if !headerEnded {
                    headerEnded = true
                    print("📋 LUT Header:\n\(headerLines.joined(separator: "\n"))")
                }
                
                // Parse RGB values on this line
                let components = trimmed.components(separatedBy: CharacterSet.whitespaces)
                    .filter { !$0.isEmpty }
                    .compactMap { Float($0) }
                
                if components.count == 3 {
                    cubeData.append(contentsOf: components)
                    dataLinesProcessed += 1
                    
                    // Print the first few data points for debugging
                    if dataLinesProcessed <= 3 {
                        print("📊 Data Line \(dataLinesProcessed): \(components)")
                    }
                } else if !trimmed.isEmpty {
                    print("⚠️ Line \(linesProcessed): Invalid data format - expected 3 values, got \(components.count): \(trimmed)")
                }
            }
        }
        
        let expectedDataLines = dimension * dimension * dimension
        print("📊 LUT Stats: Processed \(dataLinesProcessed) data lines out of expected \(expectedDataLines)")
        print("📊 Parsed \(cubeData.count) values, expected \(dimension * dimension * dimension * 3)")
        
        if dimension == 0 || !foundSize {
            print("❌ Missing LUT_3D_SIZE in file")
            throw NSError(domain: "CubeLUTLoader", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid .cube file - Missing LUT_3D_SIZE"])
        }
        
        if cubeData.isEmpty {
            print("❌ No valid data found in LUT file")
            throw NSError(domain: "CubeLUTLoader", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid or empty .cube file - No data found"])
        }
        
        // If we have at least some data but not the complete amount, warn but continue
        let expectedDataCount = dimension * dimension * dimension * 3
        if cubeData.count < expectedDataCount {
            print("⚠️ Incomplete LUT data: Found \(cubeData.count) values, expected \(expectedDataCount)")
            
            // If we're significantly short, throw an error
            if cubeData.count < expectedDataCount / 2 {
                print("❌ Insufficient LUT data: Found \(cubeData.count) values, expected \(expectedDataCount)")
                throw NSError(domain: "CubeLUTLoader", code: 4, userInfo: [
                    NSLocalizedDescriptionKey: "Incomplete LUT data: Only \(cubeData.count)/\(expectedDataCount) values found"
                ])
            }
            
            // For minor shortfalls, pad with zeros to maintain expected dimensions
            let shortfall = expectedDataCount - cubeData.count
            if shortfall > 0 && shortfall < expectedDataCount / 10 {  // Less than 10% missing
                print("⚠️ Padding \(shortfall) missing values with zeros")
                cubeData.append(contentsOf: Array(repeating: 0.0, count: shortfall))
            }
        }
        
        // Validate values are in reasonable range (0.0-1.0)
        let outOfRangeValues = cubeData.filter { $0 < 0.0 || $0 > 1.0 }
        if !outOfRangeValues.isEmpty {
            print("⚠️ Found \(outOfRangeValues.count) values outside the expected 0.0-1.0 range")
            print("⚠️ Example out-of-range values: \(outOfRangeValues.prefix(5))")
            
            // Clamp values to valid range
            for i in 0..<cubeData.count {
                cubeData[i] = max(0.0, min(1.0, cubeData[i]))
            }
            print("✅ Clamped all values to 0.0-1.0 range for compatibility")
        }
        
        print("✅ Successfully parsed LUT file with dimension \(dimension) and \(cubeData.count) values")
        return (dimension, cubeData)
    }
    
    /// Validates that a LUT file exists and is readable
    static func validateLUTFile(at url: URL) throws {
        print("🔍 Validating LUT file at \(url.path)")
        
        // Check if the file exists
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            print("❌ LUT file does not exist at \(url.path)")
            throw NSError(domain: "CubeLUTLoader", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "LUT file does not exist at path"
            ])
        }
        
        // Check if file is readable
        do {
            let resourceValues = try url.resourceValues(forKeys: [.isReadableKey, .fileSizeKey, .contentTypeKey])
            guard resourceValues.isReadable == true else {
                print("❌ LUT file is not readable")
                throw NSError(domain: "CubeLUTLoader", code: 6, userInfo: [
                    NSLocalizedDescriptionKey: "LUT file is not readable"
                ])
            }
            
            if let fileSize = resourceValues.fileSize {
                print("✅ LUT file size: \(fileSize) bytes")
                if fileSize == 0 {
                    print("❌ LUT file is empty (0 bytes)")
                    throw NSError(domain: "CubeLUTLoader", code: 7, userInfo: [
                        NSLocalizedDescriptionKey: "LUT file is empty"
                    ])
                }
            }
            
            if let contentType = resourceValues.contentType {
                print("✅ LUT file content type: \(contentType.identifier)")
            }
        } catch {
            print("❌ Failed to get resource values: \(error.localizedDescription)")
            throw NSError(domain: "CubeLUTLoader", code: 8, userInfo: [
                NSLocalizedDescriptionKey: "Failed to read LUT file properties",
                NSUnderlyingErrorKey: error
            ])
        }
        
        // Attempt to check file permissions
        do {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            if let permissions = attributes[.posixPermissions] as? NSNumber {
                print("✅ LUT file permissions: \(String(format: "%o", permissions.intValue))")
            }
        } catch {
            print("⚠️ Could not read file attributes: \(error.localizedDescription)")
        }
        
        print("✅ LUT file validation passed")
    }
}
