import CoreImage

extension CIContext {
    static let shared: CIContext = {
        let options = [
            CIContextOption.workingColorSpace: CGColorSpace(name: CGColorSpace.displayP3)!,
            CIContextOption.useSoftwareRenderer: false
        ]
        return CIContext(options: options)
    }()
} 