import AppIntents
import LockedCameraCapture

// Shared CameraCaptureIntent for Widget and Capture Extensions
// This MUST be built into the widget, capture extension, and main app so the system can discover it.

struct SpencersCameraCaptureIntent: CameraCaptureIntent {
    static var title: LocalizedStringResource = "Open Spencer's Camera"
    static var description = IntentDescription("Launch Spencer's Camera capture experience.")

    func perform() async throws -> some IntentResult {
        // No custom logic required – the system takes care of launching the correct target.
        return .result()
    }
}
