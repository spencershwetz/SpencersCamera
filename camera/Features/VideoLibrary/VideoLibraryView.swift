import SwiftUI
import Photos
import AVKit
import UIKit

struct VideoLibraryView: View {
    @StateObject private var viewModel = VideoLibraryViewModel()
    @Environment(\.dismiss) private var dismiss
    var dismissAction: () -> Void
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.edgesIgnoringSafeArea(.all)
                
                if viewModel.isLoading {
                    ProgressView()
                        .scaleEffect(1.5)
                        .tint(.white)
                } else if viewModel.videos.isEmpty {
                    EmptyVideoStateView(
                        viewModel: viewModel,
                        onRefresh: { viewModel.refreshVideos() }
                    )
                } else {
                    VideosGridView(videos: viewModel.videos, selectedVideo: $viewModel.selectedVideo)
                }
            }
            .navigationTitle("My Videos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") {
                        dismissAction()
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
            viewModel.requestAccess()
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Supporting Views
struct EmptyVideoStateView: View {
    let viewModel: VideoLibraryViewModel
    let onRefresh: () -> Void
    
    var body: some View {
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
                
                Button(action: onRefresh) {
                    Text("Refresh")
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
            }
        }
    }
}

struct VideosGridView: View {
    let videos: [VideoAsset]
    @Binding var selectedVideo: VideoAsset?
    
    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 200))], spacing: 10) {
                ForEach(videos) { video in
                    VideoThumbnailView(video: video)
                        .cornerRadius(10)
                        .shadow(radius: 2)
                        .aspectRatio(9/16, contentMode: .fit)
                        .onTapGesture {
                            selectedVideo = video
                        }
                }
            }
            .padding()
        }
    }
}

struct VideoPlayerView: View {
    let asset: PHAsset
    @State private var player: AVPlayer?
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
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
