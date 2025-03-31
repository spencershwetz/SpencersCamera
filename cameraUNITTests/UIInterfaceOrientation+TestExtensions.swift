import UIKit

// Add extension for UIInterfaceOrientation to the test target
// This resolves the ambiguous method issues when extensions
// in the main app target aren't visible during testing
extension UIInterfaceOrientation {
    var isPortrait: Bool {
        return self == .portrait || self == .portraitUpsideDown
    }
    
    var isLandscape: Bool {
        return self == .landscapeLeft || self == .landscapeRight
    }
    
    var isValidInterfaceOrientation: Bool {
        return self == .portrait || self == .portraitUpsideDown || self == .landscapeLeft || self == .landscapeRight
    }
} 