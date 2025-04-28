// DockKitIntegration.swift
// Spencer's Camera
//
// This file adds DockKit support to the main CameraViewModel by conforming to
// `CameraCaptureDelegate` and wiring-up a singleton `DockControlService`.  The
// integration is created in a separate file to keep the core camera logic
// untouched while enabling DockKit features behind `canImport(DockKit)` gates.

import Foundation
import CoreGraphics
import AVFoundation
import SwiftUI
import OSLog

#if canImport(DockKit)
import DockKit
#endif

// MARK: – CameraCaptureDelegate conformance

#if canImport(DockKit)
@available(iOS 18.0, *)
extension CameraViewModel: CameraCaptureDelegate {
    func startOrStopCapture() {
        Task { @MainActor in
            if isRecording {
                await stopRecording()
            } else {
                await startRecording()
            }
        }
    }

    func switchCamera() {
        // Cycle through available lenses (wide -> telephoto -> ultra-wide etc.)
        let nextLens: CameraLens
        if let currentIndex = availableLenses.firstIndex(of: currentLens) {
            let nextIndex = (currentIndex + 1) % availableLenses.count
            nextLens = availableLenses[nextIndex]
        } else {
            nextLens = .wide
        }
        cameraDeviceService.switchToLens(nextLens)
    }

    func zoom(type: CameraZoomType, factor: CGFloat) {
        let newZoom = max(1.0, min(CGFloat(currentZoomFactor) + (type == .increase ? factor : -factor), CGFloat(cameraDeviceService.currentDevice?.maxAvailableVideoZoomFactor ?? 10)))
        cameraDeviceService.setZoomFactor(newZoom, currentLens: currentLens, availableLenses: availableLenses)
    }

    // Convert DockKit-normalized rect (0…1) in video space to view-space coordinates used by overlay UI.
    // For now, simply forward unchanged. You can refine this using preview layer geometry later.
    @MainActor
    func convertToViewSpace(from rect: CGRect) async -> CGRect {
        return rect
    }
}
#endif

// MARK: – DockKit bootstrapping

#if canImport(DockKit)
@available(iOS 18.0, *)
private enum DockKitBootstrap {
    // Static singleton to ensure a single instance for the whole app.
    static let sharedService = DockControlService()
}

@available(iOS 18.0, *)
extension CameraViewModel {
    /// Call this method from the existing CameraViewModel initializer to start DockKit handling.
    func _bootstrapDockKitIfNeeded() {
        Task.detached { [weak self] in
            guard let self else { return }
            await DockKitBootstrap.sharedService.setCameraCaptureDelegate(self)
            let features = DockAccessoryFeatures()
            await DockKitBootstrap.sharedService.setUp(features: features)
        }
    }
}
#endif 