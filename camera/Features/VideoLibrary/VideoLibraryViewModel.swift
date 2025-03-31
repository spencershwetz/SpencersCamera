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

class VideoLibraryViewModel: NSObject, ObservableObject {
    @Published var videos: [VideoAsset] = []
    @Published var isLoading: Bool = false
    @Published var selectedVideo: VideoAsset?
    @Published var authorizationStatus: PHAuthorizationStatus = .notDetermined
    
    private var cancellables = Set<AnyCancellable>()
    private let logger = Logger(subsystem: "com.camera.app", category: "VideoLibrary")
    
    override init() {
        super.init()
        PHPhotoLibrary.shared().register(self)
    }
    
    deinit {
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }
    
    func requestAccess() {
        isLoading = true
        logger.debug("Requesting photo library access")
        
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] status in
            DispatchQueue.main.async {
                self?.handleAuthorizationStatus(status)
            }
        }
    }
    
    private func handleAuthorizationStatus(_ status: PHAuthorizationStatus) {
        authorizationStatus = status
        logger.debug("Photo library authorization status: \(status.rawValue)")
        
        switch status {
        case .authorized, .limited:
            fetchVideos()
        case .denied, .restricted:
            isLoading = false
            logger.error("Photo library access denied or restricted")
            videos = []
        case .notDetermined:
            isLoading = false
            logger.error("Photo library access not determined")
            videos = []
        @unknown default:
            isLoading = false
            logger.error("Unknown photo library access status")
            videos = []
        }
    }
    
    private func fetchVideos() {
        logger.debug("Fetching videos from photo library")
        
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(format: "mediaType = %d", PHAssetMediaType.video.rawValue)
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            let fetchResult = PHAsset.fetchAssets(with: .video, options: options)
            var newVideos: [VideoAsset] = []
            
            fetchResult.enumerateObjects { (asset, _, _) in
                let videoAsset = VideoAsset(asset: asset)
                newVideos.append(videoAsset)
            }
            
            DispatchQueue.main.async {
                self.videos = newVideos
                self.isLoading = false
                
                if newVideos.isEmpty {
                    self.logger.debug("No videos found in library")
                } else {
                    self.logger.debug("Loaded \(newVideos.count) videos")
                }
            }
        }
    }
    
    func refreshVideos() {
        isLoading = true
        fetchVideos()
    }
}

extension VideoLibraryViewModel: PHPhotoLibraryChangeObserver {
    func photoLibraryDidChange(_ changeInstance: PHChange) {
        DispatchQueue.main.async {
            self.fetchVideos()
        }
    }
}
