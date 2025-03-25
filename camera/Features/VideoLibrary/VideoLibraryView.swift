import SwiftUI
import Photos
import AVKit
import UIKit

struct VideoLibraryView: View {
    @StateObject private var viewModel = VideoLibraryViewModel()
    @Environment(\.dismiss) private var dismiss
    @State private var currentOrientation = UIDevice.current.orientation
    
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
                // Set global flag for AppDelegate to enable landscape
                AppDelegate.isVideoLibraryPresented = true
                
                viewModel.requestAccess()
                setupOrientationNotification()
                
                // Force a refresh of the UI layout for rotation
                UIViewController.attemptRotationToDeviceOrientation()
                
                // Force device to consider rotating immediately
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    UIDevice.current.setValue(UIDeviceOrientation.unknown.rawValue, forKey: "orientation")
                    
                    // If the device is already in landscape, use landscape right
                    let currentOrientation = UIDevice.current.orientation
                    if currentOrientation.isLandscape {
                        print("DEBUG: Device already in landscape: \(currentOrientation.rawValue)")
                        UIDevice.current.setValue(currentOrientation.rawValue, forKey: "orientation")
                    } else {
                        // Otherwise try to rotate to landscape right
                        print("DEBUG: Forcing rotation to landscape right")
                        UIDevice.current.setValue(UIDeviceOrientation.landscapeRight.rawValue, forKey: "orientation")
                    }
                }
            }
            .onDisappear {
                print("DEBUG: VideoLibraryView disappeared")
                AppDelegate.isVideoLibraryPresented = false
                
                NotificationCenter.default.removeObserver(
                    NSObject(),
                    name: UIDevice.orientationDidChangeNotification,
                    object: nil
                )
            }
            .onChange(of: currentOrientation) { _, newOrientation in
                if newOrientation.isLandscape {
                    print("DEBUG: Library view detected landscape orientation: \(newOrientation.rawValue)")
                    // Ensure AppDelegate knows we're in landscape mode
                    AppDelegate.isVideoLibraryPresented = true
                } else if newOrientation.isPortrait {
                    print("DEBUG: Library view detected portrait orientation: \(newOrientation.rawValue)")
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
        ) { _ in
            self.currentOrientation = UIDevice.current.orientation
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
                
                // Force rotation update
                UIViewController.attemptRotationToDeviceOrientation()
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
} 