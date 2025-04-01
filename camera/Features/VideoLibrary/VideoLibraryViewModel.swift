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
        logger.debug("VideoLibraryViewModel Initialized")
        // Request access immediately upon initialization
        requestAccess()
    }

    func requestAccess() {
        isLoading = true
        logger.debug("Requesting photo library access")

        // Get current status first
        let currentStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        self.authorizationStatus = currentStatus
        logger.debug("Current photo library authorization status: \(currentStatus.rawValue)")

        if currentStatus == .authorized || currentStatus == .limited {
            logger.debug("Access already granted (\(currentStatus.rawValue)). Fetching videos.")
            fetchVideos()
        } else if currentStatus == .notDetermined {
            logger.debug("Requesting authorization...")
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] status in
                guard let self = self else { return }

                DispatchQueue.main.async {
                    self.authorizationStatus = status
                    self.logger.debug("Photo library authorization result: \(status.rawValue)")

                    switch status {
                    case .authorized, .limited:
                        self.fetchVideos()
                    case .denied, .restricted:
                        self.isLoading = false
                        self.logger.error("Photo library access denied or restricted after request.")
                    case .notDetermined:
                        self.isLoading = false
                         self.logger.error("Photo library access still not determined after request.")
                    @unknown default:
                        self.isLoading = false
                        self.logger.error("Unknown photo library access status after request.")
                    }
                }
            }
        } else { // Denied or Restricted
             logger.error("Photo library access is denied or restricted. Cannot fetch videos.")
             DispatchQueue.main.async {
                 self.isLoading = false
                 self.videos = [] // Ensure video list is empty
             }
        }
    }

    private func fetchVideos() {
        logger.debug("Fetching videos from photo library...")
        isLoading = true // Ensure loading state is true

        // Ensure we have at least limited access
        guard authorizationStatus == .authorized || authorizationStatus == .limited else {
            logger.error("Cannot fetch videos without authorization. Status: \(self.authorizationStatus.rawValue)")
            DispatchQueue.main.async {
                self.isLoading = false
                self.videos = []
            }
            return
        }


        DispatchQueue.global(qos: .userInitiated).async { [weak self] in // Perform fetch on background thread
            guard let self = self else { return }

            // Create fetch options for video assets
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            options.predicate = NSPredicate(format: "mediaType = %d", PHAssetMediaType.video.rawValue)
            options.includeAllBurstAssets = false
            options.includeHiddenAssets = false // Consider if hidden assets might be relevant

            // Perform the fetch
            let fetchResult = PHAsset.fetchAssets(with: .video, options: options)
            self.logger.debug("PHAsset.fetchAssets returned \(fetchResult.count) assets.")

            var newVideos: [VideoAsset] = []
            if fetchResult.count > 0 {
                fetchResult.enumerateObjects { (asset, index, stop) in
                    let videoAsset = VideoAsset(asset: asset)
                    newVideos.append(videoAsset)

                    // Log some info about first few videos for debugging
                    if index < 5 {
                        self.logger.debug("Fetched Video \(index): ID \(asset.localIdentifier), duration \(String(format: "%.1f", asset.duration))s, created \(String(describing: asset.creationDate))")
                    }
                }
            } else {
                 self.logger.warning("Fetch result count is 0. No videos found matching criteria.")
            }

            DispatchQueue.main.async {
                self.videos = newVideos
                self.isLoading = false

                if newVideos.isEmpty {
                    self.logger.error("No videos populated in the view model after fetch.")
                } else {
                    self.logger.debug("Successfully loaded \(newVideos.count) videos into view model.")
                }
            }
        }
    }

    // Force a refresh of the video library
    func refreshVideos() {
        logger.debug("Manual refresh triggered.")
        // Re-check access before fetching
        requestAccess()
    }
}