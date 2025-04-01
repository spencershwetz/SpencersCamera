import SwiftUI
import Photos
import AVKit
import UIKit

struct VideoLibraryView: View {
    @StateObject private var viewModel = VideoLibraryViewModel()
    @Environment(\.dismiss) private var dismiss
    @State private var currentOrientation = UIDevice.current.orientation
    @State private var rotationLockApplied = false // Keep track if initial orientation applied

    // Grid columns definition
    private let columns: [GridItem] = [
        GridItem(.adaptive(minimum: 150, maximum: 200)) // Adjust min/max for desired thumbnail size
    ]

    var body: some View {
        // Use OrientationFixView to allow landscape for this specific view
        OrientationFixView(allowsLandscapeMode: true) {
            NavigationStack {
                ZStack {
                    Color.black.edgesIgnoringSafeArea(.all) // Ensure black background

                    if viewModel.isLoading {
                        ProgressView("Loading Videos...")
                            .scaleEffect(1.5)
                            .tint(.white)
                    } else if viewModel.authorizationStatus != .authorized && viewModel.authorizationStatus != .limited {
                        // Specific view for permission issues
                        PermissionDeniedView(status: viewModel.authorizationStatus) {
                            viewModel.requestAccess() // Allow re-requesting if possible
                        }
                    } else if viewModel.videos.isEmpty {
                         // Specific view for when no videos are found (and permission is granted)
                         NoVideosFoundView {
                             viewModel.refreshVideos() // Action for the refresh button
                         }
                    } else {
                        // Main content grid
                        ScrollView {
                            LazyVGrid(columns: columns, spacing: 10) {
                                ForEach(viewModel.videos) { video in
                                    VideoThumbnailView(video: video)
                                        .onTapGesture {
                                            viewModel.selectedVideo = video
                                        }
                                }
                            }
                            .padding() // Add padding around the grid
                        }
                    }
                }
                .navigationTitle("My Videos")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.visible, for: .navigationBar) // Ensure toolbar is visible
                .toolbarBackground(Color.black.opacity(0.5), for: .navigationBar) // Style toolbar
                .toolbarColorScheme(.dark, for: .navigationBar) // Ensure toolbar items are white
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) { // Changed placement
                        Button("Close") {
                            print("DEBUG: Dismissing VideoLibraryView")
                            AppDelegate.isVideoLibraryPresented = false // Reset flag on close
                            dismiss()
                        }
                    }

                    ToolbarItem(placement: .navigationBarTrailing) { // Changed placement
                        Button {
                            viewModel.refreshVideos()
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .disabled(viewModel.isLoading)
                    }
                }
            }
            .sheet(item: $viewModel.selectedVideo) { video in
                 // Present VideoPlayerView also allowing landscape
                 OrientationFixView(allowsLandscapeMode: true) {
                     VideoPlayerView(asset: video.asset)
                 }
            }
            .onAppear {
                print("DEBUG: VideoLibraryView appeared")
                // Set global flag for AppDelegate to enable landscape
                AppDelegate.isVideoLibraryPresented = true
                // Initial fetch/permission check
                viewModel.requestAccess()
                setupOrientationNotification()
                // Attempt to set landscape orientation
                enableLandscapeOrientation()
            }
            .onDisappear {
                print("DEBUG: VideoLibraryView disappeared")
                // Flag is reset by the presenting view's onDismiss
                NotificationCenter.default.removeObserver(
                    NSObject(), // Use a dummy object or store the observer reference
                    name: UIDevice.orientationDidChangeNotification,
                    object: nil
                )
            }
            .onChange(of: currentOrientation) { _, newOrientation in
                 print("DEBUG: [ORIENTATION-DEBUG] VideoLibraryView detected orientation change: \(newOrientation.rawValue)")
                 // If view is active and device rotates, re-apply landscape if needed
                 if AppDelegate.isVideoLibraryPresented && newOrientation.isLandscape {
                     enableLandscapeOrientation()
                 }
            }
            .preferredColorScheme(.dark) // Ensure dark mode for the NavigationStack
        }
    }

    private func setupOrientationNotification() {
        // Avoid adding observer multiple times if view reappears
        NotificationCenter.default.removeObserver(self, name: UIDevice.orientationDidChangeNotification, object: nil)
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        NotificationCenter.default.addObserver(forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main) { _ in
            self.currentOrientation = UIDevice.current.orientation
        }
    }

    private func enableLandscapeOrientation() {
        // Ensure the flag is set
        AppDelegate.isVideoLibraryPresented = true

        // Use the modern API to request geometry update
        DispatchQueue.main.async { // Ensure UI updates run on the main thread
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                print("DEBUG: [VideoLibraryView] Requesting landscape geometry update.")
                // Allow both landscape orientations
                let geometryPreferences = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: [.landscapeLeft, .landscapeRight])
                windowScene.requestGeometryUpdate(geometryPreferences) { error in
                    // Explicit nil check for error
                    if error != nil {
                        print("DEBUG: [VideoLibraryView] Landscape geometry update error: \(error.localizedDescription)")
                    } else {
                        print("DEBUG: [VideoLibraryView] Landscape geometry update successful.")
                    }
                    // Force update orientation support on VCs after the request
                    windowScene.windows.forEach { $0.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations() }
                }
            }
        }
    }
}

// MARK: - Helper Views for States

struct PermissionDeniedView: View {
    let status: PHAuthorizationStatus
    let onRequestAccess: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 60))
                .foregroundColor(.orange)
            Text("Photo Library Access Denied")
                .font(.title2)
                .foregroundColor(.white)
            Text(status == .denied ? "Please grant access to your Photo Library in the Settings app to view videos." : "Access to photos is restricted.")
                .font(.callout)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(Color.blue)
            .foregroundColor(.white)
            .cornerRadius(8)

            if status == .notDetermined {
                 Button("Request Access Again") {
                     onRequestAccess()
                 }
                 .padding(.top, 10)
            }
        }
        .padding()
    }
}

struct NoVideosFoundView: View {
     let onRefresh: () -> Void

     var body: some View {
         VStack(spacing: 20) {
             Image(systemName: "video.slash")
                 .font(.system(size: 60))
                 .foregroundColor(.gray)
             Text("No Videos Found")
                 .font(.title2)
                 .foregroundColor(.white)
             Text("There are no videos in your Photo Library, or the app couldn't find them.")
                 .font(.callout)
                 .foregroundColor(.gray)
                 .multilineTextAlignment(.center)
                 .padding(.horizontal, 40)
             Button("Refresh Library") {
                 onRefresh()
             }
             .padding(.horizontal, 20)
             .padding(.vertical, 10)
             .background(Color.blue)
             .foregroundColor(.white)
             .cornerRadius(8)
         }
         .padding()
     }
}


// MARK: - Thumbnail View (Minor Styling Adjustments)

struct VideoThumbnailView: View {
    let video: VideoAsset
    @State private var thumbnail: UIImage?
    @State private var duration: String = ""

    var body: some View {
        GeometryReader { geo in // Use GeometryReader to get size for thumbnail request
            ZStack(alignment: .bottomTrailing) {
                if let thumbnail = thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height) // Fill the grid item
                        .clipped() // Clip the image to bounds
                        .cornerRadius(8) // Apply corner radius
                } else {
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                        .cornerRadius(8)
                        .overlay(ProgressView().tint(.white)) // Show progress indicator while loading
                }

                // Duration overlay
                Text(duration)
                    .font(.caption2) // Slightly smaller font
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.6)) // Darker background
                    .cornerRadius(4)
                    .padding(6) // Padding from the corner
            }
            .onAppear {
                // Request thumbnail size based on geometry
                loadThumbnail(size: geo.size)
                formatDuration()
            }
            .onChange(of: geo.size) { oldSize, newSize in
                 // Reload thumbnail if size changes significantly (e.g., orientation change)
                 if abs(oldSize.width - newSize.width) > 10 || abs(oldSize.height - newSize.height) > 10 {
                     loadThumbnail(size: newSize)
                 }
            }
        }
         .aspectRatio(9/16, contentMode: .fit) // Maintain aspect ratio for the ZStack container
         .background(Color.black) // Background for the aspect ratio container
         .cornerRadius(8)
         .shadow(color: .black.opacity(0.3), radius: 3, x: 0, y: 2) // Subtle shadow
    }

    private func loadThumbnail(size: CGSize) {
        // Scale size for better quality thumbnail
        let scale = UIScreen.main.scale
        let targetSize = CGSize(width: size.width * scale, height: size.height * scale)

        let imageManager = PHImageManager.default()
        let requestOptions = PHImageRequestOptions()
        requestOptions.isNetworkAccessAllowed = true
        requestOptions.deliveryMode = .opportunistic // Changed to opportunistic for faster initial load
        requestOptions.resizeMode = .fast // Use fast resize mode

        // Cancel previous request if any
        // imageManager.cancelImageRequest(...) // Need to store request ID if cancelling

        imageManager.requestImage(
            for: video.asset,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: requestOptions
        ) { image, info in
             // **FIXED ERROR HANDLING HERE**
             // Safely check for an error in the info dictionary
             if let error = info?[PHImageErrorKey] as? Error {
                 print("Error loading thumbnail: \(error.localizedDescription)")
                 DispatchQueue.main.async {
                     self.thumbnail = nil // Clear thumbnail on error
                 }
                 return
             }

             let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
             if let image = image {
                 // Update thumbnail, potentially replacing a lower-quality one
                 DispatchQueue.main.async { // Ensure UI update is on main thread
                    self.thumbnail = image
                 }
                 if !isDegraded {
                      // logger.debug("Loaded high-quality thumbnail for \(video.id)")
                 }
             } else {
                  print("Failed to load thumbnail for asset \(video.asset.localIdentifier), image is nil but no error reported.")
                  DispatchQueue.main.async {
                     self.thumbnail = nil // Clear thumbnail if image is nil
                  }
             }
        }
    }


    private func formatDuration() {
        let seconds = video.asset.duration
        guard seconds.isFinite && !seconds.isNaN && seconds >= 0 else {
             duration = "--:--"
             return
         }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute, .second] : [.minute, .second]
        formatter.unitsStyle = .positional
        formatter.zeroFormattingBehavior = .pad
        duration = formatter.string(from: TimeInterval(seconds)) ?? "--:--"
    }
}


// MARK: - Video Player View (Minor Adjustments)

struct VideoPlayerView: View {
    let asset: PHAsset
    @State private var player: AVPlayer?
    @Environment(\.dismiss) private var dismiss
    @State private var currentOrientation = UIDevice.current.orientation

    var body: some View {
        // Wrap in OrientationFixView to allow landscape
        OrientationFixView(allowsLandscapeMode: true) {
            ZStack {
                Color.black.edgesIgnoringSafeArea(.all) // Ensure black background

                if let player = player {
                    VideoPlayer(player: player)
                        .edgesIgnoringSafeArea(.all) // Use newer modifier
                        .onAppear { player.play() } // Auto-play when view appears
                        .onDisappear { player.pause() } // Pause when view disappears
                } else {
                    ProgressView("Loading Video...")
                        .scaleEffect(1.5)
                        .tint(.white)
                }

                 // Close button overlay
                 VStack {
                     HStack {
                         Spacer()
                         Button {
                             dismiss()
                         } label: {
                             Image(systemName: "xmark.circle.fill")
                                 .font(.title)
                                 .foregroundColor(.white.opacity(0.7))
                                 .padding()
                         }
                     }
                     Spacer()
                 }
            }
            .onAppear {
                // Also set flag for video player
                AppDelegate.isVideoLibraryPresented = true
                loadVideo()
                setupOrientationNotification()
                // Attempt to set landscape orientation
                enableLandscapeOrientation()
            }
            .onDisappear {
                player?.pause() // Ensure player is paused
                // Flag reset is handled by presenting view's onDismiss
                NotificationCenter.default.removeObserver(
                    NSObject(), // Use a dummy object or store the observer reference
                    name: UIDevice.orientationDidChangeNotification,
                    object: nil
                )
            }
            .onChange(of: currentOrientation) { _, newOrientation in
                 // If view is active and device rotates, re-apply landscape if needed
                 if AppDelegate.isVideoLibraryPresented && newOrientation.isLandscape {
                     enableLandscapeOrientation()
                 }
            }
            .preferredColorScheme(.dark)
        }
    }

    private func loadVideo() {
        let manager = PHImageManager.default()
        let options = PHVideoRequestOptions()
        options.deliveryMode = .highQualityFormat // Request high quality
        options.isNetworkAccessAllowed = true // Allow network access if needed (iCloud)
        options.version = .current // Get the current version

        print("Requesting AVAsset for PHAsset: \(asset.localIdentifier)")
        manager.requestAVAsset(forVideo: asset, options: options) { avAsset, audioMix, info in
             // **FIXED ERROR HANDLING HERE**
             // Safely check for an error in the info dictionary
             if let error = info?[PHImageErrorKey] as? Error {
                 print("Error loading AVAsset: \(error.localizedDescription)")
                 DispatchQueue.main.async {
                     self.player = nil // Ensure player is nil on error
                 }
                 return
             }

            DispatchQueue.main.async {
                if let avAsset = avAsset {
                    print("Successfully loaded AVAsset.")
                    self.player = AVPlayer(playerItem: AVPlayerItem(asset: avAsset))
                    // self.player?.play() // Play is handled by .onAppear now
                } else {
                     print("Failed to load AVAsset, avAsset is nil but no error reported.")
                     self.player = nil // Ensure player is nil
                }
            }
        }
    }

     private func setupOrientationNotification() {
         // Avoid adding observer multiple times if view reappears
         NotificationCenter.default.removeObserver(self, name: UIDevice.orientationDidChangeNotification, object: nil)
         UIDevice.current.beginGeneratingDeviceOrientationNotifications()
         NotificationCenter.default.addObserver(forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main) { _ in
             self.currentOrientation = UIDevice.current.orientation
         }
     }

     private func enableLandscapeOrientation() {
         // Ensure the flag is set
         AppDelegate.isVideoLibraryPresented = true

         // Use the modern API to request geometry update
         DispatchQueue.main.async { // Ensure UI updates run on the main thread
             if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                 print("DEBUG: [VideoPlayerView] Requesting landscape geometry update.")
                 // Allow both landscape orientations
                 let geometryPreferences = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: [.landscapeLeft, .landscapeRight])
                 windowScene.requestGeometryUpdate(geometryPreferences) { error in
                     // Explicit nil check for error
                     if error != nil {
                         print("DEBUG: [VideoPlayerView] Landscape geometry update error: \(error.localizedDescription)")
                     } else {
                         print("DEBUG: [VideoPlayerView] Landscape geometry update successful.")
                     }
                     // Force update orientation support on VCs after the request
                     windowScene.windows.forEach { $0.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations() }
                 }
             }
         }
     }
}
