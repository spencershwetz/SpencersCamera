import AVFoundation
import CoreMedia

// MARK: - Double Extensions

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        return min(max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - CMTime Extensions

extension CMTime {
    var displayString: String {
        let totalSeconds = CMTimeGetSeconds(self)
        let hours = Int(totalSeconds / 3600)
        let minutes = Int(totalSeconds.truncatingRemainder(dividingBy: 3600) / 60)
        let seconds = Int(totalSeconds.truncatingRemainder(dividingBy: 60))
        
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }
}

// MARK: - CGSize Extensions

extension CGSize {
    var aspectRatio: CGFloat {
        return width / height
    }
    
    func scaledToFit(in containerSize: CGSize) -> CGSize {
        let scale = min(containerSize.width / width, containerSize.height / height)
        return CGSize(width: width * scale, height: height * scale)
    }
}
