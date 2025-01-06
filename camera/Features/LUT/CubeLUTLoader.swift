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
            throw NSError(domain: "CubeLUTLoader", code: 1, userInfo: [NSLocalizedDescriptionKey: "LUT file not found"])
        }
        return try loadCubeFile(from: filePath)
    }
    
    /// Parse .cube file into Float array and return dimension + LUT data
    static func loadCubeFile(from url: URL) throws -> (dimension: Int, data: [Float]) {
        let fileContents = try String(contentsOf: url, encoding: .utf8)
        let lines = fileContents.components(separatedBy: .newlines)
        
        var dimension = 0
        var cubeData = [Float]()
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("#") || trimmed.isEmpty {
                continue
            }
            if trimmed.lowercased().contains("lut_3d_size") {
                let parts = trimmed.components(separatedBy: CharacterSet.whitespaces)
                if let sizeString = parts.last, let size = Int(sizeString) {
                    dimension = size
                    let totalCount = size * size * size * 3
                    cubeData.reserveCapacity(totalCount)
                }
            } else if dimension > 0 {
                let components = trimmed.components(separatedBy: CharacterSet.whitespaces)
                    .compactMap { Float($0) }
                if components.count == 3 {
                    cubeData.append(contentsOf: components)
                }
            }
        }
        
        if dimension == 0 || cubeData.isEmpty {
            throw NSError(domain: "CubeLUTLoader", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid or empty .cube file"])
        }
        
        return (dimension, cubeData)
    }
}
