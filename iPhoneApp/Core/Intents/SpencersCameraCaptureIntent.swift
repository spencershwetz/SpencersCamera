import AppIntents
import LockedCameraCapture // Required for CameraCaptureIntent
import SwiftUI // For Sendable conformance? Maybe just Foundation

// MARK: - SpencersCameraCaptureIntent

// We can start simple: A CameraCaptureIntent with no custom parameters.
// You can extend this later with a custom `AppContext` conforming to `Codable & Sendable`.

struct SpencersCameraCaptureIntent: CameraCaptureIntent {
    static var title: LocalizedStringResource = "Open Spencer's Camera"
    static var description = IntentDescription("Launch Spencer's Camera capture experience.")

    func perform() async throws -> some IntentResult {
        // For now, we don't need to do anything here. The system will handle launching
        // either the main app or the capture extension depending on context.
        return .result()
    }
} 