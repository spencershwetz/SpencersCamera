/*
 DockControlService.swift
 Spencer's Camera
 
 An actor that encapsulates all interactions with DockKit accessories. It's largely based on
 Apple's "Controlling a DockKit accessory using your camera app" sample but trimmed and adapted
 for Spencer's Camera code-base (MVVM + service layer).  All DockKit specific imports live
 behind a `canImport(DockKit)` gate to allow building on devices where DockKit isn't available
 (e.g. Simulator).
 */

#if canImport(UIKit)
import UIKit
#endif
import Foundation
import AVFoundation
import Combine
#if canImport(DockKit)
import DockKit
#endif
import Spatial
import OSLog

@available(iOS 18.0, *)
actor DockControlService {
    // MARK: – Published state (Observation)
    @Published private(set) var status: DockAccessoryStatus = .disconnected
    @Published private(set) var battery: DockAccessoryBatteryStatus = .unavailable
    @Published private(set) var regionOfInterest = CGRect.zero
    @Published private(set) var trackedPersons: [DockAccessoryTrackedPerson] = []

    // MARK: – Private properties
#if !targetEnvironment(simulator)
    private var dockkitAccessory: DockAccessory?
#endif

    private var batterySummaryTask: Task<Void, Never>?
    private var trackingSummaryTask: Task<Void, Never>?
    private var accessoryEventsTask: Task<Void, Never>?

    private var trackingMode: TrackingMode = .system
    private var animating = false

#if !targetEnvironment(simulator)
    private var lastTrackingSummary: DockAccessory.TrackingState?
    private var lastBatteryState: DockAccessory.BatteryState?
#endif

    private weak var cameraCaptureDelegate: CameraCaptureDelegate?
    private weak var features: DockAccessoryFeatures?

    private var lastShutterEventTime: Date = .now

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "SpencersCamera", category: "DockControlService")

    // MARK: – Public API

    func setCameraCaptureDelegate(_ delegate: CameraCaptureDelegate) {
        cameraCaptureDelegate = delegate
    }

    func setUp(features: DockAccessoryFeatures) async {
#if !targetEnvironment(simulator)
        self.features = features
        do {
            for await stateEvent in try DockAccessoryManager.shared.accessoryStateChanges {
                if let dockkitAccessory = dockkitAccessory, dockkitAccessory == stateEvent.accessory {
                    // Already have an accessory, check for disconnects.
                    if stateEvent.state != .docked {
                        cleanupAccessoryStates()
                        status = .disconnected
                        self.dockkitAccessory = nil
                        continue
                    }
                } else if let newAccessory = stateEvent.accessory, stateEvent.state == .docked {
                    // New accessory docked
                    dockkitAccessory = newAccessory
                    await setupAccessorySubscriptions(for: newAccessory)
                }

                // Set status depending on tracking button state
                status = stateEvent.trackingButtonEnabled ? .connectedTracking : .connected
                if status == .connected { trackedPersons = [] }
            }
        } catch {
            logger.error("Error setting up DockKit session: \(error, privacy: .public)")
        }
#endif
    }

    // MARK: – Tracking control

    func updateFraming(to framing: FramingMode) async -> Bool {
#if !targetEnvironment(simulator)
        guard let accessory = dockkitAccessory else { return false }
        do {
            try await accessory.setFramingMode(dockKitFramingMode(from: framing))
        } catch {
            logger.error("Failed to set framing mode: \(error, privacy: .public)")
            return false
        }
#endif
        return true
    }

    func updateTrackingMode(to trackingMode: TrackingMode) async -> Bool {
#if !targetEnvironment(simulator)
        self.trackingMode = trackingMode
        do {
            try await DockAccessoryManager.shared.setSystemTrackingEnabled(trackingMode == .system)
        } catch {
            logger.error("Failed to set tracking mode: \(error, privacy: .public)")
            return false
        }
#endif
        return true
    }

    func selectSubject(at point: CGPoint?) async -> Bool {
#if !targetEnvironment(simulator)
        guard let accessory = dockkitAccessory else { return false }
        do {
            if let point = point {
                if #available(iOS 18.0, *) {
                    try await accessory.selectSubject(at: point)
                }
            } else {
                if #available(iOS 18.0, *) {
                    try await accessory.selectSubjects([])
                }
            }
        } catch {
            logger.error("Failed to select subject: \(error, privacy: .public)")
            return false
        }
#endif
        return true
    }

    func setRegionOfInterest(to region: CGRect) async -> Bool {
#if !targetEnvironment(simulator)
        guard let accessory = dockkitAccessory else { return false }
        do {
            try await accessory.setRegionOfInterest(region)
        } catch {
            logger.error("Failed to set ROI: \(error, privacy: .public)")
            return false
        }
#endif
        return true
    }

    func animate(_ animation: Animation) async -> Bool {
#if !targetEnvironment(simulator)
        guard let accessory = dockkitAccessory else { return false }
        if animating { return false }
        do {
            animating = true
            try await DockAccessoryManager.shared.setSystemTrackingEnabled(false)
            let progress = try await accessory.animate(motion: dockKitAnimation(from: animation))
            while !progress.isCancelled && !progress.isFinished {
                try await Task.sleep(for: .milliseconds(100))
            }
            try await DockAccessoryManager.shared.setSystemTrackingEnabled(trackingMode == .system)
            animating = false
        } catch {
            logger.error("Failed to run animation: \(error, privacy: .public)")
            try? await DockAccessoryManager.shared.setSystemTrackingEnabled(trackingMode == .system)
            animating = false
            return false
        }
#endif
        return true
    }

    func track(metadata: [AVMetadataObject],
               sampleBuffer: CMSampleBuffer,
               deviceType: AVCaptureDevice.DeviceType,
               devicePosition: AVCaptureDevice.Position) async {
#if !targetEnvironment(simulator)
        guard let accessory = dockkitAccessory else { return }
        if DockAccessoryManager.shared.isSystemTrackingEnabled { return }
        if animating { return }

        let orientation = getCameraOrientation()

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let referenceDimensions = CGSize(width: CVPixelBufferGetWidth(pixelBuffer),
                                         height: CVPixelBufferGetHeight(pixelBuffer))

        var cameraIntrinsics: matrix_float3x3?
        if let data = CMGetAttachment(sampleBuffer, key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix, attachmentModeOut: nil) as? Data {
            cameraIntrinsics = data.withUnsafeBytes { $0.load(as: matrix_float3x3.self) }
        }

        let cameraInfo = DockAccessory.CameraInformation(captureDevice: deviceType,
                                                         cameraPosition: devicePosition,
                                                         orientation: orientation,
                                                         cameraIntrinsics: cameraIntrinsics,
                                                         referenceDimensions: referenceDimensions)

        if let imageBuffer = sampleBuffer.imageBuffer {
            Task { try? await accessory.track(metadata, cameraInformation: cameraInfo, image: imageBuffer) }
        } else {
            Task { try? await accessory.track(metadata, cameraInformation: cameraInfo) }
        }
#endif
    }

    // MARK: – Summary subscriptions

    func toggleTrackingSummary(to enable: Bool) {
#if !targetEnvironment(simulator)
        trackingSummaryTask?.cancel()
        trackingSummaryTask = nil

        guard enable else {
            trackedPersons = []
            features?.isTrackingSummaryEnabled = false
            return
        }

        guard let dockkitAccessory else {
            features?.isTrackingSummaryEnabled = false
            return
        }

        trackingSummaryTask = Task {
            do {
                if #available(iOS 18.0, *) {
                    for await summary in try dockkitAccessory.trackingStates {
                        lastTrackingSummary = summary
                        var persons: [DockAccessoryTrackedPerson] = []
                        for subject in summary.trackedSubjects {
                            if case .person(let p) = subject,
                               let rect = await cameraCaptureDelegate?.convertToViewSpace(from: p.rect) {
                                persons.append(DockAccessoryTrackedPerson(saliency: p.saliencyRank,
                                                                           rect: rect,
                                                                           speaking: p.speakingConfidence,
                                                                           looking: p.lookingAtCameraConfidence))
                            }
                        }
                        trackedPersons = persons
                    }
                }
            } catch {
                logger.error("Error receiving tracking summary: \(error, privacy: .public)")
                features?.isTrackingSummaryEnabled = false
            }
        }
#endif
    }

    func toggleBatterySummary(to enable: Bool) {
#if !targetEnvironment(simulator)
        batterySummaryTask?.cancel()
        batterySummaryTask = nil

        guard enable else { battery = .unavailable; return }
        guard let dockkitAccessory else { return }

        batterySummaryTask = Task {
            do {
                if #available(iOS 18.0, *) {
                    for await summary in try dockkitAccessory.batteryStates {
                        battery = .available(percentage: summary.batteryLevel,
                                             charging: summary.chargeState == .charging)
                    }
                }
            } catch {
                logger.error("Error receiving battery summary: \(error, privacy: .public)")
            }
        }
#endif
    }

    // MARK: – Manual control helpers (chevrons)

    func handleChevronTapped(type: ChevronType, speed: Double = 0.2) async {
#if !targetEnvironment(simulator)
        guard trackingMode == .manual else { return } // only in manual
        guard let accessory = dockkitAccessory else { return }

        var velocity = Vector3D()
        switch type {
        case .tiltUp:    velocity.x = -speed
        case .tiltDown:  velocity.x =  speed
        case .panLeft:   velocity.y = -speed
        case .panRight:  velocity.y =  speed
        }
        try? await accessory.setAngularVelocity(velocity)
#endif
    }

    // MARK: – Private helpers

#if !targetEnvironment(simulator)
    private func subscribeToAccessoryEvents(for accessory: DockAccessory) {
        accessoryEventsTask = Task {
            do {
                for await event in try accessory.accessoryEvents {
                    switch event {
                    case let .button(_, pressed):
                        logger.notice("Button event: \(pressed ? "pressed" : "released")")
                    case .cameraZoom(let factor):
                        cameraCaptureDelegate?.zoom(type: factor > 0 ? .increase : .decrease, factor: abs(CGFloat(factor)))
                    case .cameraShutter:
                        if Date.now.timeIntervalSince(lastShutterEventTime) > 0.2 {
                            cameraCaptureDelegate?.startOrStopCapture()
                            lastShutterEventTime = .now
                        }
                    case .cameraFlip:
                        cameraCaptureDelegate?.switchCamera()
                    default: break
                    }
                }
            } catch {
                logger.error("Error listening for accessory events")
            }
        }
    }

    private func setupAccessorySubscriptions(for accessory: DockAccessory) async {
        do { try await DockAccessoryManager.shared.setSystemTrackingEnabled(true) } catch {}
        subscribeToAccessoryEvents(for: accessory)
        toggleBatterySummary(to: true)
    }

    private func dockKitFramingMode(from mode: FramingMode) -> DockAccessory.FramingMode {
        switch mode {
        case .auto:   return .automatic
        case .center: return .center
        case .left:   return .left
        case .right:  return .right
        }
    }

    private func dockKitAnimation(from animation: Animation) -> DockAccessory.Animation {
        switch animation {
        case .yes:   return .yes
        case .no:    return .no
        case .wakeup:return .wakeup
        case .kapow: return .kapow
        }
    }

    private func cleanupAccessoryStates() {
        features?.isSetROIEnabled = false
        features?.isTapToTrackEnabled = false
        features?.framingMode = .auto
        features?.trackingMode = .system
        toggleBatterySummary(to: false)
        trackedPersons = []
    }

    private func getCameraOrientation() -> DockAccessory.CameraOrientation {
        switch UIDevice.current.orientation {
        case .portrait: return .portrait
        case .portraitUpsideDown: return .portraitUpsideDown
        case .landscapeLeft: return .landscapeLeft
        case .landscapeRight: return .landscapeRight
        case .faceDown: return .faceDown
        case .faceUp: return .faceUp
        default: return .corrected
        }
    }
#endif
} 
