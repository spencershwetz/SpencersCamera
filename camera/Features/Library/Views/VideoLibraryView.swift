import SwiftUI
import PhotosUI

// Add Identifiable conformance to PHAsset
extension PHAsset: Identifiable {
    // Use localIdentifier as the stable identifier
    public var id: String { localIdentifier }
}

struct VideoLibraryView: View {
    @Environment(\.dismiss) var dismiss
    @State private var videoAssets: [PHAsset] = []
    @State private var authorizationStatus: PHAuthorizationStatus = .notDetermined
    @State private var selectedAssetForPlayback: PHAsset? = nil
    
    // For thumbnail loading
    private let imageManager = PHCachingImageManager()
    private let thumbnailSize = CGSize(width: 150, height: 150) // Adjust size as needed
    
    // Grid layout
    private let gridColumns = [
        GridItem(.adaptive(minimum: 100), spacing: 2) // Adjust minimum size and spacing
    ]

    var body: some View {
        NavigationView {
            Group {
                switch authorizationStatus {
                case .authorized, .limited:
                    if videoAssets.isEmpty {
                        Text("No videos found.")
                            .foregroundColor(.secondary)
                    } else {
                        ScrollView {
                            LazyVGrid(columns: gridColumns, spacing: 2) {
                                ForEach(videoAssets, id: \.localIdentifier) { asset in
                                    VideoThumbnailView(asset: asset, imageManager: imageManager, targetSize: thumbnailSize)
                                        .onTapGesture {
                                            self.selectedAssetForPlayback = asset
                                        }
                                }
                            }
                        }
                    }
                case .denied, .restricted:
                    VStack {
                        Text("Permission Denied")
                            .font(.headline)
                        Text("Enable photo library access in Settings.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                 UIApplication.shared.open(url)
                            }
                        }
                        .padding(.top)
                    }
                case .notDetermined:
                    ProgressView("Requesting Access...")
                @unknown default:
                    Text("Unknown authorization status.")
                }
            }
            .navigationTitle("Video Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .onAppear(perform: checkAuthorizationAndFetch)
            .preferredColorScheme(.dark) // Keep consistent dark mode
        }
        .fullScreenCover(item: $selectedAssetForPlayback) { asset in
            VideoPlayerView(asset: asset)
        }
    }

    private func checkAuthorizationAndFetch() {
        authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite) // Check current status
        
        if authorizationStatus == .authorized || authorizationStatus == .limited {
            fetchVideos()
        } else if authorizationStatus == .notDetermined {
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                DispatchQueue.main.async {
                    self.authorizationStatus = status
                    if status == .authorized || status == .limited {
                        fetchVideos()
                    }
                }
            }
        }
        // If denied/restricted, the view will update via the switch statement
    }

    private func fetchVideos() {
        imageManager.stopCachingImagesForAllAssets() // Clear cache before new fetch
        
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        fetchOptions.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue)

        let fetchResult = PHAsset.fetchAssets(with: fetchOptions)
        
        var assets: [PHAsset] = []
        fetchResult.enumerateObjects { (asset, _, _) in
            assets.append(asset)
        }
        
        DispatchQueue.main.async {
            self.videoAssets = assets
            // Start caching thumbnails for the fetched assets
            imageManager.startCachingImages(
                for: assets,
                targetSize: thumbnailSize,
                contentMode: .aspectFill,
                options: nil
            )
        }
    }
}

// Separate view for handling thumbnail loading
struct VideoThumbnailView: View {
    let asset: PHAsset
    let imageManager: PHCachingImageManager
    let targetSize: CGSize
    
    @State private var thumbnail: UIImage? = nil

    var body: some View {
        Group {
            if let image = thumbnail {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: targetSize.width, height: targetSize.height) // Ensure frame matches request size
                    .clipped()
                    .overlay(alignment: .bottomTrailing) {
                        // Display video duration
                        Text(formatDuration(asset.duration))
                            .font(.caption2)
                            .foregroundColor(.white)
                            .padding(3)
                            .background(Color.black.opacity(0.6))
                            .cornerRadius(4)
                            .padding(3)
                    }

            } else {
                Rectangle() // Placeholder
                    .fill(Color.secondary.opacity(0.3))
                    .frame(width: targetSize.width, height: targetSize.height)
                    .overlay(ProgressView()) // Show loading indicator
            }
        }
        .onAppear(perform: loadThumbnail)
        .onDisappear {
            // Optional: Consider cancelling image request if needed, though caching helps
        }
    }

    private func loadThumbnail() {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true // Allow fetching from iCloud if necessary
        options.deliveryMode = .opportunistic // Start with lower quality, then improve

        imageManager.requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: options
        ) { image, _ in
            // Check if the view is still needing this image
             if let img = image {
                 DispatchQueue.main.async {
                     self.thumbnail = img
                 }
             }
        }
    }
    
    // Helper to format duration (e.g., 0:15, 1:23)
    private func formatDuration(_ duration: TimeInterval) -> String {
        guard !duration.isNaN, duration > 0 else { return "" }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        formatter.unitsStyle = .positional
        formatter.zeroFormattingBehavior = .pad
        return formatter.string(from: duration) ?? ""
    }
}


#Preview {
    VideoLibraryView()
        .preferredColorScheme(.dark)
} 