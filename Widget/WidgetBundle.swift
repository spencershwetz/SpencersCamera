//
//  WidgetBundle.swift
//  Widget
//
//  Created by spencer on 2025-05-03.
//

import WidgetKit
import SwiftUI

@main
struct SpencersCameraWidgetBundle: WidgetBundle {
    var body: some Widget {
        SpencersCameraWidget()
        WidgetControl()
        WidgetLiveActivity()
    }
}
