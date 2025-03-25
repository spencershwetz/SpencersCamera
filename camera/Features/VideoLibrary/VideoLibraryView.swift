import SwiftUI
import Photos
import AVKit
import UIKit

struct VideoLibraryView: View {
    @StateObject private var viewModel = VideoLibraryViewModel()
    @Environment(\.dismiss) private var dismiss
    @State private var currentOrientation = UIDevice.current.orientation
    @State private var rotationLockApplied = false
    
    var body: some View {
        OrientationFixView(allowsLandscape: true) {
            NavigationStack {
                ZStack {
                    Color.black.edgesIgnoringSafeArea(.all)
                    
                    if viewModel.isLoading {
                        ProgressView()
                            .scaleEffect(1.5)
                            .tint(.white)
                    } else if viewModel.videos.isEmpty {
                        VStack(spacing: 20) {
                            Image(systemName: "video.slash")
                                .font(.system(size: 60))
                                .foregroundColor(.gray)
                                .padding()
                            
                            Text("No videos found")
                                .font(.title2)
                                .foregroundColor(.gray)
                            
                            if viewModel.authorizationStatus == .denied || viewModel.authorizationStatus == .restricted {
                                Text("Please enable photo library access in Settings")
                                    .font(.callout)
                                    .foregroundColor(.orange)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 30)
                                
                                Button(action: {
                                    if let url = URL(string: UIApplication.openSettingsURLString) {
                                        UIApplication.shared.open(url)
                                    }
                                }) {
                                    Text("Open Settings")
                                        .padding(.horizontal, 20)
                                        .padding(.vertical, 10)
                                        .background(Color.blue)
                                        .foregroundColor(.white)
                                        .cornerRadius(8)
                                }
                            } else {
                                Text("Try refreshing the library")
                                    .font(.callout)
                                    .foregroundColor(.gray)
                                
                                Button(action: {
                                    viewModel.refreshVideos()
                                }) {
                                    Text("Refresh")
                                        .padding(.horizontal, 20)
                                        .padding(.vertical, 10)
                                        .background(Color.blue)
                                        .foregroundColor(.white)
                                        .cornerRadius(8)
                                }
                            }
                        }
                    } else {
                        ScrollView {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 200))], spacing: 10) {
                                ForEach(viewModel.videos) { video in
                                    VideoThumbnailView(video: video)
                                        .cornerRadius(10)
                                        .shadow(radius: 2)
                                        .aspectRatio(9/16, contentMode: .fit)
                                        .onTapGesture {
                                            viewModel.selectedVideo = video
                                        }
                                }
                            }
                            .padding()
                        }
                    }
                }
                .navigationTitle("My Videos")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Close") {
                            print("DEBUG: Dismissing VideoLibraryView")
                            AppDelegate.isVideoLibraryPresented = false
                            dismiss()
                        }
                    }
                    
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(action: {
                            viewModel.refreshVideos()
                        }) {
                            Image(systemName: "arrow.clockwise")
                        }
                        .disabled(viewModel.isLoading)
                    }
                }
                .background(Color.black)
            }
            .sheet(item: $viewModel.selectedVideo) { video in
                VideoPlayerView(asset: video.asset)
            }
            .onAppear {
                print("DEBUG: VideoLibraryView appeared")
                print("DEBUG: [ORIENTATION-DEBUG] VideoLibraryView onAppear - interface orientation: \(UIApplication.shared.connectedScenes.first(where: { $0 is UIWindowScene }).flatMap { $0 as? UIWindowScene }?.interfaceOrientation.rawValue ?? 0)")
                print("DEBUG: [ORIENTATION-DEBUG] VideoLibraryView onAppear - device orientation: \(UIDevice.current.orientation.rawValue)")
                
                // Set global flag for AppDelegate to enable landscape
                AppDelegate.isVideoLibraryPresented = true
                
                viewModel.requestAccess()
                setupOrientationNotification()
                
                // Apply rotation lock with a delay to ensure the view is fully initialized
                if !rotationLockApplied {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        rotationLockApplied = true
                        print("DEBUG: [ORIENTATION-DEBUG] VideoLibraryView applying initial landscape orientation")
                        enableLandscapeOrientation()
                        
                        // Apply a second time after a short delay to ensure it takes effect
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            enableLandscapeOrientation()
                            
                            // Force orientation update on all controllers
                            if let windowScene = UIApplication.shared.connectedScenes.first(where: { $0 is UIWindowScene }) as? UIWindowScene {
                                for window in windowScene.windows {
                                    window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
                                }
                            }
                        }
                    }
                }
            }
            .onDisappear {
                print("DEBUG: VideoLibraryView disappeared")
                print("DEBUG: [ORIENTATION-DEBUG] VideoLibraryView onDisappear - device orientation: \(UIDevice.current.orientation.rawValue)")
                
                // Set flag to false when view disappears
                DispatchQueue.main.async {
                    AppDelegate.isVideoLibraryPresented = false
                }
                
                NotificationCenter.default.removeObserver(
                    NSObject(),
                    name: UIDevice.orientationDidChangeNotification,
                    object: nil
                )
            }
            .onChange(of: currentOrientation) { _, newOrientation in
                print("DEBUG: [ORIENTATION-DEBUG] VideoLibraryView orientation changed to: \(newOrientation.rawValue)")
                if newOrientation.isLandscape {
                    print("DEBUG: Library view detected landscape orientation: \(newOrientation.rawValue)")
                    print("DEBUG: [ORIENTATION-DEBUG] AppDelegate.isVideoLibraryPresented = \(AppDelegate.isVideoLibraryPresented)")
                    // Ensure AppDelegate knows we're in landscape mode
                    AppDelegate.isVideoLibraryPresented = true
                    
                    // Reapply landscape orientation to prevent popping back
                    if rotationLockApplied {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            print("DEBUG: [ORIENTATION-DEBUG] VideoLibraryView re-enabling landscape after orientation change")
                            enableLandscapeOrientation()
                        }
                    }
                } else if newOrientation == .portrait {
                    print("DEBUG: [ORIENTATION-DEBUG] Portrait orientation detected - checking if we need to prevent it")
                    // If we're in the video library, try to maintain landscape if that's what we want
                    if AppDelegate.isVideoLibraryPresented {
                        print("DEBUG: [ORIENTATION-DEBUG] VideoLibraryView still active, trying to maintain landscape")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            enableLandscapeOrientation()
                        }
                    }
                }
            }
            .preferredColorScheme(.dark)
        }
    }
    
    private func setupOrientationNotification() {
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        
        NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification,
            object: nil,
            queue: .main
        ) { [self] _ in
            let newOrientation = UIDevice.current.orientation
            self.currentOrientation = newOrientation
            print("DEBUG: [ORIENTATION-DEBUG] Orientation notification received: \(newOrientation.rawValue)")
            print("DEBUG: Container detected device orientation change")
        }
    }
    
    private func enableLandscapeOrientation() {
        // Update AppDelegate flag first to ensure proper orientation support
        AppDelegate.isVideoLibraryPresented = true
        
        // Find the active window scene
        if let windowScene = UIApplication.shared.connectedScenes.first(where: { $0 is UIWindowScene }) as? UIWindowScene {
            // Get current device orientation
            let deviceOrientation = UIDevice.current.orientation
            
            // Determine the target interface orientation based on device orientation
            var targetOrientation: UIInterfaceOrientation = .landscapeRight // Default if we can't determine
            
            // More aggressively map device orientation to interface orientation
            if deviceOrientation.isLandscape {
                // Map device orientation to interface orientation
                // Note: UIDeviceOrientation.landscapeLeft maps to UIInterfaceOrientation.landscapeRight and vice versa
                targetOrientation = deviceOrientation == .landscapeLeft ? .landscapeRight : .landscapeLeft
                print("DEBUG: Video library forcing landscape: \(targetOrientation.rawValue) based on device: \(deviceOrientation.rawValue)")
            } else if deviceOrientation == .faceUp || deviceOrientation == .faceDown {
                // When device is face up/down, use the current interface orientation if it's landscape
                // otherwise default to landscape right
                let currentInterfaceOrientation = windowScene.interfaceOrientation
                if currentInterfaceOrientation.isLandscape {
                    targetOrientation = currentInterfaceOrientation
                }
                print("DEBUG: Video library handling face up/down orientation, using: \(targetOrientation.rawValue)")
            }
            
            // Set supported orientations to include landscape
            let orientations: UIInterfaceOrientationMask = [.portrait, .landscapeLeft, .landscapeRight]
            let geometryPreferences = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: orientations)
            
            print("DEBUG: Applying landscape orientation using scene geometry update")
            print("DEBUG: [ORIENTATION-DEBUG] Current interface orientation before update: \(windowScene.interfaceOrientation.rawValue)")
            print("DEBUG: [ORIENTATION-DEBUG] Target orientation: \(targetOrientation.rawValue)")
            
            // Force the geometry update with explicit target orientation
            // Create proper mask from single orientation
            let orientationMask: UIInterfaceOrientationMask
            switch targetOrientation {
            case .portrait: orientationMask = .portrait
            case .portraitUpsideDown: orientationMask = .portraitUpsideDown
            case .landscapeLeft: orientationMask = .landscapeLeft
            case .landscapeRight: orientationMask = .landscapeRight
            default: orientationMask = .portrait
            }
            
            let specificGeometryPreferences = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: orientationMask)
            windowScene.requestGeometryUpdate(specificGeometryPreferences) { error in
                print("DEBUG: [ORIENTATION-DEBUG] Specific landscape geometry update result: \(error.localizedDescription)")
            }
            
            // Also update all view controllers to make sure they respect the orientation
            for window in windowScene.windows {
                window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
                print("DEBUG: [ORIENTATION-DEBUG] Called setNeedsUpdateOfSupportedInterfaceOrientations on root controller")
                if let presented = window.rootViewController?.presentedViewController {
                    presented.setNeedsUpdateOfSupportedInterfaceOrientations()
                    print("DEBUG: [ORIENTATION-DEBUG] Called setNeedsUpdateOfSupportedInterfaceOrientations on presented controller")
                    
                    // Recursively update all child controllers
                    updateOrientationForChildren(of: presented)
                }
            }
            
            // Attempt additional force rotation after a short delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                // Ensure AppDelegate flag is still set
                AppDelegate.isVideoLibraryPresented = true
                
                if UIDevice.current.orientation.isLandscape {
                    print("DEBUG: [ORIENTATION-DEBUG] Device already in landscape after 0.3s")
                } else {
                    print("DEBUG: [ORIENTATION-DEBUG] Device still not in landscape after 0.3s - forcing rotation")
                    
                    // Try a second geometry update with the specific orientation
                    // Create a new specific geometry preferences to ensure we use the updated API
                    let secondOrientationMask: UIInterfaceOrientationMask
                    // Default to landscape right if needed
                    let secondTargetOrientation: UIInterfaceOrientation = targetOrientation
                    
                    switch secondTargetOrientation {
                    case .portrait: secondOrientationMask = .portrait
                    case .portraitUpsideDown: secondOrientationMask = .portraitUpsideDown
                    case .landscapeLeft: secondOrientationMask = .landscapeLeft
                    case .landscapeRight: secondOrientationMask = .landscapeRight
                    default: secondOrientationMask = .landscapeRight
                    }
                    
                    let secondSpecificPreferences = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: secondOrientationMask)
                    windowScene.requestGeometryUpdate(secondSpecificPreferences) { error in
                        print("DEBUG: [ORIENTATION-DEBUG] Second specific landscape update: \(error.localizedDescription)")
                    }
                    
                    // Update to modern API for iOS 16+
                    if let windowScene = UIApplication.shared.connectedScenes
                        .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene {
                        for window in windowScene.windows {
                            window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
                            
                            // Force update on presented controllers too
                            if let presented = window.rootViewController?.presentedViewController {
                                presented.setNeedsUpdateOfSupportedInterfaceOrientations()
                            }
                        }
                    }
                }
            }
        }
    }
    
    // Helper method to update orientation for all child controllers
    private func updateOrientationForChildren(of viewController: UIViewController) {
        for child in viewController.children {
            child.setNeedsUpdateOfSupportedInterfaceOrientations()
            updateOrientationForChildren(of: child)
        }
    }
}

struct VideoThumbnailView: View {
    let video: VideoAsset
    @State private var thumbnail: UIImage?
    @State private var duration: String = ""
    
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let thumbnail = thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
            }
            
            VStack(alignment: .trailing) {
                HStack {
                    Spacer()
                    Text(duration)
                        .font(.caption)
                        .padding(6)
                        .background(.ultraThinMaterial)
                        .cornerRadius(4)
                }
                .padding(8)
            }
            
            Image(systemName: "play.fill")
                .font(.title2)
                .padding(8)
                .background(.ultraThinMaterial)
                .clipShape(Circle())
                .padding(8)
        }
        .onAppear {
            loadThumbnail()
            formatDuration()
        }
    }
    
    private func loadThumbnail() {
        let imageManager = PHImageManager.default()
        let requestOptions = PHImageRequestOptions()
        requestOptions.isNetworkAccessAllowed = true
        requestOptions.deliveryMode = .highQualityFormat
        
        imageManager.requestImage(
            for: video.asset, 
            targetSize: CGSize(width: 300, height: 300),
            contentMode: .aspectFill,
            options: requestOptions
        ) { image, _ in
            self.thumbnail = image
        }
    }
    
    private func formatDuration() {
        let seconds = video.asset.duration
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute, .second] : [.minute, .second]
        formatter.unitsStyle = .positional
        formatter.zeroFormattingBehavior = .pad
        duration = formatter.string(from: seconds) ?? ""
    }
}

struct VideoPlayerView: View {
    let asset: PHAsset
    @State private var player: AVPlayer?
    @Environment(\.dismiss) private var dismiss
    @State private var currentOrientation = UIDevice.current.orientation
    
    var body: some View {
        OrientationFixView(allowsLandscape: true) {
            ZStack {
                if let player = player {
                    VideoPlayer(player: player)
                        .ignoresSafeArea()
                } else {
                    ProgressView()
                        .scaleEffect(1.5)
                        .tint(.white)
                }
            }
            .onAppear {
                // Also set flag for video player
                AppDelegate.isVideoLibraryPresented = true
                loadVideo()
                setupOrientationNotification()
                
                // Apply landscape orientation
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    enableLandscapeOrientation()
                }
            }
            .onDisappear {
                player?.pause()
                // Don't reset the flag here in case we're returning to library
                NotificationCenter.default.removeObserver(
                    NSObject(), 
                    name: UIDevice.orientationDidChangeNotification,
                    object: nil
                )
            }
            .onChange(of: currentOrientation) { _, newOrientation in
                if newOrientation.isLandscape {
                    print("DEBUG: VideoPlayer detected landscape orientation: \(newOrientation.rawValue)")
                    // Ensure AppDelegate knows we're in landscape mode
                    AppDelegate.isVideoLibraryPresented = true
                    
                    // Reapply landscape orientation to prevent popping back
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        enableLandscapeOrientation()
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .preferredColorScheme(.dark)
        }
    }
    
    private func loadVideo() {
        let manager = PHImageManager.default()
        let options = PHVideoRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        
        manager.requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
            DispatchQueue.main.async {
                if let avAsset = avAsset {
                    self.player = AVPlayer(playerItem: AVPlayerItem(asset: avAsset))
                    self.player?.play()
                }
            }
        }
    }
    
    private func setupOrientationNotification() {
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        
        NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            self.currentOrientation = UIDevice.current.orientation
        }
    }
    
    private func enableLandscapeOrientation() {
        // Use the modern API instead of setting device orientation directly
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            let orientations: UIInterfaceOrientationMask = [.portrait, .landscapeLeft, .landscapeRight]
            let geometryPreferences = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: orientations)
            
            print("DEBUG: Applying landscape orientation using scene geometry update")
            windowScene.requestGeometryUpdate(geometryPreferences) { error in
                print("DEBUG: VideoPlayer landscape update result: \(error.localizedDescription)")
            }
            
            // Also update all view controllers to make sure they respect the orientation
            for window in windowScene.windows {
                window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
                if let presented = window.rootViewController?.presentedViewController {
                    presented.setNeedsUpdateOfSupportedInterfaceOrientations()
                }
            }
        }
    }
} 