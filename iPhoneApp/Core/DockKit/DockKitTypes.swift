// DockKitTypes.swift
// Spencer's Camera
//
// This file defines DockKit–specific enumerations, classes, and protocols that allow the main
// app codebase to interact with DockKit accessories without creating tight coupling between
// the existing camera logic and the DockKit service implementation.

import Foundation
import SwiftUI
import Observation
import AVFoundation

// MARK: - Camera supporting types for DockKit integration

/// An enumeration that describes the zoom direction requested by a DockKit accessory.
enum CameraZoomType {
    case increase
    case decrease
}

// MARK: - DockKit accessory status & battery

enum DockAccessoryStatus {
    /// A status that indicates there's no accessory connected.
    case disconnected
    /// A status that indicates an accessory is connected.
    case connected
    /// A status that indicates an accessory is connected and is actively tracking.
    case connectedTracking
}

enum DockAccessoryBatteryStatus {
    /// Battery information not available for the accessory.
    case unavailable
    /// The accessory reported battery information.
    case available(percentage: Double = 0.0, charging: Bool = false)

    var percentage: Double {
        if case let .available(percentage, _) = self { return percentage } else { return 0.0 }
    }

    var charging: Bool {
        if case let .available(_, charging) = self { return charging } else { return false }
    }
}

// MARK: - DockKit feature toggle container

@Observable
class DockAccessoryFeatures {
    var isTapToTrackEnabled: Bool = false
    var isTrackingSummaryEnabled: Bool = false
    var isSetROIEnabled: Bool = false
    var trackingMode: TrackingMode = .system
    var framingMode: FramingMode = .auto

    var current: EnabledDockKitFeatures {
        .init(isTapToTrackEnabled: isTapToTrackEnabled,
              isTrackingSummaryEnabled: isTrackingSummaryEnabled,
              isSetROIEnabled: isSetROIEnabled,
              trackingMode: trackingMode,
              framingMode: framingMode)
    }
}

struct EnabledDockKitFeatures {
    let isTapToTrackEnabled: Bool
    let isTrackingSummaryEnabled: Bool
    let isSetROIEnabled: Bool
    let trackingMode: TrackingMode
    let framingMode: FramingMode
}

// MARK: - Tracking summary helpers

@Observable
class DockAccessoryTrackedPerson: Identifiable {
    let id = UUID()
    let saliency: Int?
    var rect: CGRect
    let speaking: Double?
    let looking: Double?

    init(saliency: Int? = nil,
         rect: CGRect,
         speaking: Double? = nil,
         looking: Double? = nil) {
        self.saliency = saliency
        self.rect = rect
        self.speaking = speaking
        self.looking = looking
    }

    func update(rect: CGRect) { self.rect = rect }
}

// MARK: - DockKit configuration enums

enum FramingMode: String, CaseIterable, Identifiable {
    case auto = "Frame Auto"
    case center = "Frame Center"
    case left = "Frame Left"
    case right = "Frame Right"

    var id: Self { self }

    @ViewBuilder
    func symbol() -> some View {
        switch self {
        case .auto: Image(systemName: "sparkles")
        case .center: Image(systemName: "person.crop.rectangle")
        case .left: Image(systemName: "inset.filled.rectangle.and.person.filled")
        case .right: Image(systemName: "inset.filled.rectangle.and.person.filled")
        }
    }
}

enum TrackingMode: String, CaseIterable, Identifiable {
    case system = "System Tracking"
    case custom = "Custom Tracking"
    case manual = "Manual Control"

    var id: Self { self }
}

enum Animation: String, CaseIterable, Identifiable {
    case yes
    case no
    case wakeup
    case kapow

    var id: Self { self }
}

enum ChevronType: String, CaseIterable, Identifiable {
    case tiltUp
    case tiltDown
    case panLeft
    case panRight

    var id: Self { self }
}

// MARK: - Service delegate protocols

protocol DockAccessoryTrackingDelegate: AnyObject {
    func track(metadata: [AVMetadataObject],
               sampleBuffer: CMSampleBuffer?,
               deviceType: AVCaptureDevice.DeviceType,
               devicePosition: AVCaptureDevice.Position)
}

protocol CameraCaptureDelegate: AnyObject {
    func startOrStopCapture()
    func switchCamera()
    func zoom(type: CameraZoomType, factor: CGFloat)
    func convertToViewSpace(from rect: CGRect) async -> CGRect
} 