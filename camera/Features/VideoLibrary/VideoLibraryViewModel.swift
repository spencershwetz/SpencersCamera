import SwiftUI
import Photos
import Combine
import os.log

struct VideoAsset: Identifiable {
    let id = UUID()
    let asset: PHAsset
    let creationDate: Date?
    let localIdentifier: String
    
    init(asset: PHAsset) {
        self.asset = asset
        self.creationDate = asset.creationDate
        self.localIdentifier = asset.localIdentifier
    }
}

class VideoLibraryViewModel: ObservableObject {
    @Published var videos: [VideoAsset] = []
    @Published var isLoading: Bool = false
    @Published var selectedVideo: VideoAsset?
    @Published var authorizationStatus: PHAuthorizationStatus = .notDetermined
    @Published var errorMessage: String? = nil
    
    private var cancellables = Set<AnyCancellable>()
    private let logger = Logger(subsystem: "com.camera.app", category: "VideoLibrary")
    
    init() {
        // Request access immediately upon initialization
        requestAccess()
    }
    
    func requestAccess() {
        isLoading = true
        errorMessage = nil
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
                    self.errorMessage = "Photo library access denied or restricted"
                    self.logger.error("Photo library access denied or restricted")
                case .notDetermined:
                    self.isLoading = false
                    self.errorMessage = "Photo library access not determined"
                    self.logger.error("Photo library access not determined")
                @unknown default:
                    self.isLoading = false
                    self.errorMessage = "Unknown photo library access status"
                    self.logger.error("Unknown photo library access status")
                }
            }
        }
    }
    
    private func fetchVideos() {
        logger.debug("Fetching videos from photo library")
        isLoading = true
        errorMessage = nil
        
        // Create fetch options for video assets
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(format: "mediaType = %d", PHAssetMediaType.video.rawValue)
        options.includeAllBurstAssets = false
        options.includeHiddenAssets = false
        
        // Log the start time for debugging
        let startTime = Date()
        print("DEBUG: [VIDEOS] Starting video fetch at \(startTime)")
        
        // Perform the fetch operation with a smaller batch size to avoid UI blocking
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            // Perform the fetch
            let fetchResult = PHAsset.fetchAssets(with: .video, options: options)
            self.logger.debug("Found \(fetchResult.count) videos in photo library")
            print("DEBUG: [VIDEOS] Fetch completed in \(Date().timeIntervalSince(startTime)) seconds")
            print("DEBUG: [VIDEOS] Processing \(fetchResult.count) videos")
            
            var newVideos: [VideoAsset] = []
            var fetchErrors: [String] = []
            
            // Determine if we need to process all at once or in batches
            let shouldProcessInBatches = fetchResult.count > 100
            let batchSize = 50
            let totalCount = fetchResult.count
            
            if shouldProcessInBatches {
                // Process in batches to avoid memory issues with large libraries
                print("DEBUG: [VIDEOS] Processing videos in batches of \(batchSize)")
                
                // First handle first 20 videos quickly to display something
                let initialBatchSize = min(20, totalCount)
                
                for i in 0..<initialBatchSize {
                    autoreleasepool {
                        let asset = fetchResult.object(at: i)
                        
                        if asset.mediaType != .video {
                            fetchErrors.append("Asset at index \(i) is not a video")
                            return
                        }
                        
                        let videoAsset = VideoAsset(asset: asset)
                        newVideos.append(videoAsset)
                        
                        if i < 5 {
                            self.logger.debug("Video \(i): duration \(asset.duration)s, created \(String(describing: asset.creationDate)), ID: \(asset.localIdentifier)")
                        }
                    }
                }
                
                // Update UI with initial batch
                DispatchQueue.main.async {
                    print("DEBUG: [VIDEOS] Delivering initial batch of \(newVideos.count) videos")
                    self.videos = newVideos
                    self.isLoading = false // Mark as not loading even though we're still processing more
                }
                
                // Continue processing remaining videos in background
                DispatchQueue.global(qos: .utility).async {
                    for i in initialBatchSize..<totalCount {
                        autoreleasepool {
                            let asset = fetchResult.object(at: i)
                            
                            if asset.mediaType != .video {
                                fetchErrors.append("Asset at index \(i) is not a video")
                                return
                            }
                            
                            let videoAsset = VideoAsset(asset: asset)
                            newVideos.append(videoAsset)
                            
                            // Update UI every batch
                            if i % batchSize == 0 || i == totalCount - 1 {
                                DispatchQueue.main.async {
                                    print("DEBUG: [VIDEOS] Updating with \(newVideos.count) videos (processed \(i+1) of \(totalCount))")
                                    self.videos = newVideos
                                }
                            }
                        }
                    }
                    
                    // Final update for total completion
                    DispatchQueue.main.async {
                        print("DEBUG: [VIDEOS] Completed processing all \(newVideos.count) videos in \(Date().timeIntervalSince(startTime)) seconds")
                        self.videos = newVideos
                        
                        if !fetchErrors.isEmpty {
                            self.errorMessage = "Some videos could not be loaded: \(fetchErrors.count) errors"
                            print("DEBUG: [VIDEOS] Encountered \(fetchErrors.count) errors: \(fetchErrors.first ?? "Unknown")")
                        }
                    }
                }
            } else {
                // For smaller libraries, process all at once
                fetchResult.enumerateObjects { [weak self] (asset, index, stop) in
                    guard let self = self else { return }
                    
                    // Process in autorelease pool to avoid memory buildup
                    autoreleasepool {
                        // Validate the asset
                        if asset.mediaType != .video {
                            fetchErrors.append("Asset at index \(index) is not a video")
                            return
                        }
                        
                        let videoAsset = VideoAsset(asset: asset)
                        newVideos.append(videoAsset)
                        
                        // Log some info about first few videos for debugging
                        if index < 5 {
                            self.logger.debug("Video \(index): duration \(asset.duration)s, created \(String(describing: asset.creationDate)), ID: \(asset.localIdentifier)")
                        }
                    }
                }
                
                // Update UI on main thread with all videos at once
                DispatchQueue.main.async {
                    print("DEBUG: [VIDEOS] Processed all \(newVideos.count) videos in \(Date().timeIntervalSince(startTime)) seconds")
                    self.videos = newVideos
                    self.isLoading = false
                    
                    if newVideos.isEmpty {
                        // Check if there were any errors during fetch
                        if !fetchErrors.isEmpty {
                            self.errorMessage = "Errors fetching videos: \(fetchErrors.first ?? "Unknown error")"
                            self.logger.error("Errors during video fetch: \(fetchErrors.joined(separator: ", "))")
                        } else {
                            self.errorMessage = "No videos found in photo library"
                            self.logger.error("No videos found in photo library after fetch")
                        }
                    } else {
                        self.errorMessage = nil
                        self.logger.debug("Successfully loaded \(newVideos.count) videos")
                        
                        // Print more details about the first few videos for debugging
                        for (index, video) in newVideos.prefix(5).enumerated() {
                            print("DEBUG: [VIDEOS] Video \(index): ID: \(video.localIdentifier), duration: \(video.asset.duration)s")
                        }
                    }
                }
            }
        }
    }
    
    // Force a refresh of the video library
    func refreshVideos() {
        isLoading = true
        errorMessage = nil
        fetchVideos()
    }
}

// MARK: - Extensions

extension Array where Element: Identifiable {
    func isLast(_ item: Element) -> Bool {
        guard let lastItem = self.last else {
            return false
        }
        return lastItem.id == item.id
    }
} 