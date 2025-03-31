import UIKit

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