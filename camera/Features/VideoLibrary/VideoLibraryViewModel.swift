import SwiftUI
import Photos
import Combine

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
    
    func requestAccess() {
        isLoading = true
        
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] status in
            guard let self = self else { return }
            
            DispatchQueue.main.async {
                self.authorizationStatus = status
                
                switch status {
                case .authorized, .limited:
                    self.fetchVideos()
                case .denied, .restricted:
                    self.isLoading = false
                    // Could present an alert here explaining the user needs to enable photo access
                case .notDetermined:
                    self.isLoading = false
                @unknown default:
                    self.isLoading = false
                }
            }
        }
    }
    
    private func fetchVideos() {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(format: "mediaType = %d", PHAssetMediaType.video.rawValue)
        
        let fetchResult = PHAsset.fetchAssets(with: options)
        
        var newVideos: [VideoAsset] = []
        
        fetchResult.enumerateObjects { (asset, _, _) in
            let videoAsset = VideoAsset(asset: asset)
            newVideos.append(videoAsset)
        }
        
        DispatchQueue.main.async {
            self.videos = newVideos
            self.isLoading = false
        }
    }
} 