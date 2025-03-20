import SwiftUI
import AVFoundation

struct CameraViewfinderOverlay: View {
    @ObservedObject var viewModel: CameraViewModel
    let orientation: UIDeviceOrientation
    @State private var showFocusBox = false
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Clear background to let camera show through
                Color.clear
                
                // Grid overlay (rule of thirds)
                GridOverlayView()
                    .opacity(0.5)
                
                // Focus area rectangle (center of screen)
                if showFocusBox {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.white, lineWidth: 1)
                        .frame(width: min(geometry.size.width, geometry.size.height) * 0.25, 
                               height: min(geometry.size.width, geometry.size.height) * 0.15)
                        .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                }
                
                // Flexible layout that adapts to any orientation
                overlayContent(in: geometry)
                
                // LUT indicator overlay when active
                if viewModel.lutManager.currentLUTFilter != nil {
                    VStack {
                        HStack {
                            Spacer()
                            VStack(alignment: .trailing, spacing: 4) {
                                Text("LUT ACTIVE")
                                    .font(.caption.bold())
                                    .foregroundColor(.white)
                                
                                Text(viewModel.lutManager.currentLUTName)
                                    .font(.caption)
                                    .foregroundColor(.white)
                            }
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.black.opacity(0.7))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .strokeBorder(Color.green, lineWidth: 2)
                                    )
                            )
                            .padding(.top, 20)
                            .padding(.trailing, 20)
                        }
                        Spacer()
                    }
                }
                
                // Debug info overlay
                VStack {
                    Text("Debug: Orientation \(orientationName(orientation))")
                        .foregroundColor(.yellow)
                        .font(.system(size: 12))
                    
                    Text("Size: \(Int(geometry.size.width))×\(Int(geometry.size.height))")
                        .foregroundColor(.yellow)
                        .font(.system(size: 12))
                    
                    Text("Safe: T:\(Int(geometry.safeAreaInsets.top)) L:\(Int(geometry.safeAreaInsets.leading)) B:\(Int(geometry.safeAreaInsets.bottom)) R:\(Int(geometry.safeAreaInsets.trailing))")
                        .foregroundColor(.yellow)
                        .font(.system(size: 12))
                }
                .position(x: geometry.size.width / 2, y: 50)
                .zIndex(100)
            }
            .onChange(of: orientation) { oldValue, newValue in
                print("DEBUG: Orientation changed from \(orientationName(oldValue)) to \(orientationName(newValue))")
            }
        }
    }
    
    // The main overlay content that adapts to different orientations
    private func overlayContent(in geometry: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            // Top status bar
            topStatusBar
                .padding(.horizontal, 16)
                .padding(.top, geometry.safeAreaInsets.top + 16)
                .frame(height: 100)
            
            Spacer()
            
            // Settings button
            Button(action: {
                // Settings action
            }) {
                ZStack {
                    Circle()
                        .fill(Color.black.opacity(0.5))
                        .frame(width: 50, height: 50)
                    
                    Image(systemName: "gearshape")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 24, height: 24)
                        .foregroundColor(.white)
                }
            }
            .padding(.trailing, 16)
            .frame(maxWidth: .infinity, alignment: .trailing)
            
            Spacer()
            
            // Bottom controls
            VStack(spacing: 24) {
                // Zoom controls
                HStack(spacing: 20) {
                    // AF indicator
                    Button(action: {
                        showFocusBox.toggle()
                    }) {
                        ZStack {
                            Circle()
                                .fill(showFocusBox ? Color.yellow : Color.black.opacity(0.7))
                                .frame(width: 60, height: 60)
                            
                            Text("AF")
                                .foregroundColor(showFocusBox ? .black : .yellow)
                                .font(.system(size: 20, weight: .bold))
                        }
                    }
                    
                    Spacer()
                    
                    // Zoom buttons
                    ForEach([0.5, 1.0, 2.0, 5.0], id: \.self) { level in
                        CameraZoomButton(
                            level: formatZoomLevel(level),
                            isSelected: isZoomLevelSelected(level, currentLevel: viewModel.currentZoomLevel),
                            action: {
                                viewModel.currentZoomLevel = level
                            }
                        )
                    }
                    
                    Spacer()
                    
                    // Back button
                    Button(action: {
                        // Back action
                    }) {
                        ZStack {
                            Circle()
                                .fill(Color.black.opacity(0.7))
                                .frame(width: 60, height: 60)
                            
                            Image(systemName: "chevron.backward")
                                .foregroundColor(.white)
                                .font(.system(size: 24, weight: .bold))
                        }
                    }
                }
                .padding(.horizontal, 16)
                
                // Record button
                Button(action: {
                    if viewModel.isRecording {
                        viewModel.stopRecording()
                    } else {
                        viewModel.startRecording()
                    }
                }) {
                    Circle()
                        .fill(viewModel.isRecording ? Color.white : Color.red)
                        .frame(width: 70, height: 70)
                        .overlay(
                            Circle()
                                .stroke(Color.white, lineWidth: 3)
                                .frame(width: 76, height: 76)
                        )
                }
                .padding(.bottom, geometry.safeAreaInsets.bottom + 20)
            }
            .padding(.bottom, 16)
        }
    }
    
    // Top status bar with audio meters, mode and format indicators
    private var topStatusBar: some View {
        HStack(alignment: .top) {
            // Left side - Audio meters and AUTO mode
            VStack(alignment: .leading, spacing: 16) {
                // Audio level meters with L/R labels
                HStack(alignment: .top, spacing: 4) {
                    // Audio level meters
                    AudioLevelMeter(levels: viewModel.audioLevels)
                        .frame(width: 60, height: 30)
                    
                    // L/R labels
                    VStack(alignment: .leading, spacing: 2) {
                        Text("L")
                            .font(.system(size: 12))
                            .foregroundColor(.gray)
                        Text("R")
                            .font(.system(size: 12))
                            .foregroundColor(.gray)
                    }
                    .offset(y: 4)
                }
                
                // AUTO mode with lock
                Button(action: {
                    viewModel.isAutoExposureEnabled.toggle()
                }) {
                    HStack(spacing: 8) {
                        Text(viewModel.isAutoExposureEnabled ? "AUTO" : "MANUAL")
                            .foregroundColor(viewModel.isAutoExposureEnabled ? .green : .orange)
                            .font(.system(size: 16, weight: .bold))
                        
                        Image(systemName: "lock.fill")
                            .foregroundColor(.gray)
                            .font(.system(size: 14))
                    }
                }
            }
            
            Spacer()
            
            // Center - Record time or storage info
            if viewModel.isRecording {
                Text(viewModel.recordingTimeString)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.red.opacity(0.7))
                    .cornerRadius(16)
            } else {
                Text("675 MIN")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.gray)
            }
            
            Spacer()
            
            // Right side - Format info
            VStack(alignment: .trailing, spacing: 16) {
                // Format indicators
                HStack(spacing: 4) {
                    Text("4K")
                        .foregroundColor(.gray)
                        .font(.system(size: 16, weight: .medium))
                    Text("•")
                        .foregroundColor(.gray)
                    Text("\(Int(viewModel.selectedFrameRate))")
                        .foregroundColor(.gray)
                        .font(.system(size: 16, weight: .medium))
                    Text("•")
                        .foregroundColor(.gray)
                    Text("LOG")
                        .foregroundColor(viewModel.isAppleLogEnabled ? .green : .gray)
                        .font(.system(size: 16, weight: .medium))
                    Text("•")
                        .foregroundColor(.gray)
                    Text("HEVC")
                        .foregroundColor(.gray)
                        .font(.system(size: 16, weight: .medium))
                }
            }
        }
        .padding(.top, 8)
        .background(Color.black.opacity(0.3))
    }
    
    private func orientationName(_ orientation: UIDeviceOrientation) -> String {
        switch orientation {
        case .portrait: return "Portrait"
        case .portraitUpsideDown: return "PortraitUpsideDown"
        case .landscapeLeft: return "LandscapeLeft"
        case .landscapeRight: return "LandscapeRight"
        case .faceUp: return "FaceUp"
        case .faceDown: return "FaceDown"
        default: return "Unknown"
        }
    }
    
    private func formatZoomLevel(_ level: Double) -> String {
        if level == 1.0 {
            return "1×"
        } else if level < 1.0 {
            return ".\(Int(level * 10))"
        } else {
            return String(format: "%g", level)
        }
    }
    
    private func isZoomLevelSelected(_ level: Double, currentLevel: Double) -> Bool {
        abs(currentLevel - level) < 0.1
    }
}

// MARK: - Supporting Views

struct CameraZoomButton: View {
    let level: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(isSelected ? Color.white.opacity(0.3) : Color.black.opacity(0.7))
                    .frame(width: 60, height: 60)
                
                Text(level)
                    .foregroundColor(.white)
                    .font(.system(size: 18, weight: isSelected ? .bold : .regular))
            }
        }
    }
}

struct GridOverlayView: View {
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                let width = geometry.size.width
                let height = geometry.size.height
                
                // Vertical lines
                path.move(to: CGPoint(x: width / 3, y: 0))
                path.addLine(to: CGPoint(x: width / 3, y: height))
                
                path.move(to: CGPoint(x: 2 * width / 3, y: 0))
                path.addLine(to: CGPoint(x: 2 * width / 3, y: height))
                
                // Horizontal lines
                path.move(to: CGPoint(x: 0, y: height / 3))
                path.addLine(to: CGPoint(x: width, y: height / 3))
                
                path.move(to: CGPoint(x: 0, y: 2 * height / 3))
                path.addLine(to: CGPoint(x: width, y: 2 * height / 3))
            }
            .stroke(Color.white, lineWidth: 0.5)
        }
    }
}

struct AudioLevelMeter: View {
    let levels: [Float]
    private let segmentCount = 8
    
    var body: some View {
        HStack(spacing: 1) {
            // Left channel
            VStack(spacing: 1) {
                ForEach(0..<segmentCount, id: \.self) { index in
                    let reversedIndex = segmentCount - 1 - index
                    let normIndex = Float(reversedIndex) / Float(segmentCount - 1)
                    let isActive = (levels.count > 0 ? levels[0] : 0) >= normIndex
                    
                    Rectangle()
                        .fill(self.colorForLevel(reversedIndex))
                        .frame(width: 6, height: 3)
                        .opacity(isActive ? 1.0 : 0.3)
                }
            }
            
            // Right channel
            VStack(spacing: 1) {
                ForEach(0..<segmentCount, id: \.self) { index in
                    let reversedIndex = segmentCount - 1 - index
                    let normIndex = Float(reversedIndex) / Float(segmentCount - 1)
                    let isActive = (levels.count > 1 ? levels[1] : 0) >= normIndex
                    
                    Rectangle()
                        .fill(self.colorForLevel(reversedIndex))
                        .frame(width: 6, height: 3)
                        .opacity(isActive ? 1.0 : 0.3)
                }
            }
        }
    }
    
    private func colorForLevel(_ index: Int) -> Color {
        let normalized = Float(index) / Float(segmentCount - 1)
        if normalized > 0.75 {
            return .red
        } else if normalized > 0.5 {
            return .yellow
        } else {
            return .green
        }
    }
}

struct CameraViewfinderOverlay_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            Color.black
            CameraViewfinderOverlay(
                viewModel: CameraViewModel(),
                orientation: .portrait
            )
        }
        .previewLayout(.fixed(width: 390, height: 844))
    }
} 