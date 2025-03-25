import SwiftUI
import Photos
import Combine
import os.log

struct VideoAsset: Identifiable {
    let id = UUID()
    let asset: PHAsset
    let creationDate: Date?
    
    init(asset: PHAsset) {
        self.asset = asset
        self.creationDate = asset.creationDate
    }
}

class VideoLibraryViewModel: ObservableObject {
    @Published var videos: [VideoAsset] = []
    @Published var isLoading: Bool = false
    @Published var selectedVideo: VideoAsset?
    @Published var authorizationStatus: PHAuthorizationStatus = .notDetermined
    
    private var cancellables = Set<AnyCancellable>()
    private let logger = Logger(subsystem: "com.camera.app", category: "VideoLibrary")
    
    init() {
        // Request access immediately upon initialization
        requestAccess()
    }
    
    func requestAccess() {
        isLoading = true
        logger.debug("Requesting photo library access")
        
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] status in
            guard let self = self else { return }
            
            DispatchQueue.main.async {
                self.authorizationStatus = status
                self.logger.debug("Photo library authorization status: \(status.rawValue)")
                
                switch status {
                case .authorized, .limited:
                    self.fetchVideos()
                case .denied, .restricted:
                    self.isLoading = false
                    self.logger.error("Photo library access denied or restricted")
                case .notDetermined:
                    self.isLoading = false
                    self.logger.error("Photo library access not determined")
                @unknown default:
                    self.isLoading = false
                    self.logger.error("Unknown photo library access status")
                }
            }
        }
    }
    
    private func fetchVideos() {
        logger.debug("Fetching videos from photo library")
        
        // Create fetch options for video assets
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(format: "mediaType = %d", PHAssetMediaType.video.rawValue)
        options.includeAllBurstAssets = false
        options.includeHiddenAssets = false
        
        // Perform the fetch
        let fetchResult = PHAsset.fetchAssets(with: .video, options: options)
        logger.debug("Found \(fetchResult.count) videos in photo library")
        
        var newVideos: [VideoAsset] = []
        
        fetchResult.enumerateObjects { [weak self] (asset, index, stop) in
            guard let self = self else { return }
            let videoAsset = VideoAsset(asset: asset)
            newVideos.append(videoAsset)
            
            // Log some info about first few videos for debugging
            if index < 5 {
                self.logger.debug("Video \(index): duration \(asset.duration)s, created \(String(describing: asset.creationDate))")
            }
        }
        
        DispatchQueue.main.async {
            self.videos = newVideos
            self.isLoading = false
            
            if newVideos.isEmpty {
                self.logger.error("No videos found in photo library after fetch")
            } else {
                self.logger.debug("Successfully loaded \(newVideos.count) videos")
            }
        }
    }
    
    // Force a refresh of the video library
    func refreshVideos() {
        isLoading = true
        fetchVideos()
    }
} 