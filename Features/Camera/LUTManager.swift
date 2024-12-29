import CoreImage
import UniformTypeIdentifiers

class LUTManager: ObservableObject {
    @Published var currentLUT: CIFilter?
    @Published var selectedLUTName: String?
    
    func loadLUT(from url: URL) throws {
        guard url.pathExtension.lowercased() == "cube" else {
            throw LUTError.invalidFileFormat
        }
        
        let lutData = try Data(contentsOf: url)
        guard let lutFilter = CIFilter(name: "CIColorCubeWithColorSpace") else {
            throw LUTError.filterCreationFailed
        }
        
        lutFilter.setValue(lutData, forKey: "inputCubeData")
        currentLUT = lutFilter
        selectedLUTName = url.lastPathComponent
    }
    
    enum LUTError: Error {
        case invalidFileFormat
        case filterCreationFailed
    }
} 