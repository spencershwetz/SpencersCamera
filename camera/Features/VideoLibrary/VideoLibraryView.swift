import SwiftUI
import Photos
import AVKit
import UIKit

struct VideoLibraryView: View {
    @StateObject private var viewModel = VideoLibraryViewModel()
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
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
                        
                        if let errorMessage = viewModel.errorMessage {
                            Text(errorMessage)
                                .font(.callout)
                                .foregroundColor(.orange)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 30)
                        }
                        
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
                        Text("Found \(viewModel.videos.count) videos")
                            .foregroundColor(.gray)
                            .font(.caption)
                            .padding(.top, 8)
                        
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 180))], spacing: 10) {
                            ForEach(viewModel.videos) { video in
                                VideoThumbnailView(video: video)
                                    .cornerRadius(10)
                                    .shadow(radius: 2)
                                    .aspectRatio(9/16, contentMode: .fit)
                                    .onTapGesture {
                                        viewModel.selectedVideo = video
                                        print("DEBUG: Video selected: \(video.localIdentifier)")
                                    }
                                    .id(video.id)
                            }
                        }
                        .padding()
                    }
                    .refreshable {
                        print("DEBUG: Pull-to-refresh triggered")
                        viewModel.refreshVideos()
                    }
                }
            }
            .navigationTitle("My Videos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") {
                        print("DEBUG: Dismissing VideoLibraryView")
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
            SimpleVideoPlayerView(asset: video.asset)
        }
        .onAppear {
            print("DEBUG: VideoLibraryView appeared")
            viewModel.requestAccess()
        }
        .preferredColorScheme(.dark)
    }
}

struct VideoThumbnailView: View {
    let video: VideoAsset
    @State private var thumbnail: UIImage?
    @State private var duration: String = ""
    @State private var isLoadingThumbnail: Bool = true
    @State private var thumbnailError: String? = nil
    
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let thumbnail = thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if isLoadingThumbnail {
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .overlay(
                        ProgressView()
                            .scaleEffect(0.8)
                            .tint(.white)
                    )
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .overlay(
                        Image(systemName: "photo.fill")
                            .foregroundColor(.white.opacity(0.6))
                            .font(.largeTitle)
                    )
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
        print("DEBUG: [THUMBNAIL] Loading thumbnail for video: \(video.localIdentifier)")
        isLoadingThumbnail = true
        
        let imageManager = PHImageManager.default()
        let requestOptions = PHImageRequestOptions()
        requestOptions.isNetworkAccessAllowed = true
        requestOptions.deliveryMode = .fastFormat
        requestOptions.isSynchronous = false
        
        let targetSize = CGSize(width: 180, height: 320)
        
        imageManager.requestImage(
            for: video.asset,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: requestOptions
        ) { image, info in
            if let image = image {
                DispatchQueue.main.async {
                    self.thumbnail = image
                    self.isLoadingThumbnail = false
                    print("DEBUG: [THUMBNAIL] Successfully loaded thumbnail for: \(self.video.localIdentifier)")
                }
            } else {
                print("DEBUG: [THUMBNAIL] Failed to load thumbnail for: \(self.video.localIdentifier)")
                DispatchQueue.main.async {
                    self.thumbnailError = "Failed to load thumbnail"
                    self.isLoadingThumbnail = false
                }
            }
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

struct SimpleVideoPlayerView: View {
    let asset: PHAsset
    @State private var player: AVPlayer?
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        ZStack {
            Color.black.edgesIgnoringSafeArea(.all)
            
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
            loadVideo()
        }
        .onDisappear {
            player?.pause()
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
} 