//
//  CaptureExtension.swift
//  CaptureExtension
//
//  Created by spencer on 2025-05-03.
//

import Foundation
import LockedCameraCapture
import SwiftUI

@main
struct CaptureExtension: LockedCameraCaptureExtension {
    var body: some LockedCameraCaptureExtensionScene {
        LockedCameraCaptureUIScene { session in
            CaptureExtensionViewFinder(session: session)
        }
    }
}
