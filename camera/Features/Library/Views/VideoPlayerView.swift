import SwiftUI
import AVKit
import PhotosUI

struct VideoPlayerView: View {
    let asset: PHAsset
    @Environment(\.dismiss) var dismiss
    @State private var player: AVPlayer? = nil
    
    // Use the same manager instance if performance becomes an issue, but fine for now
    private let imageManager = PHImageManager.default()

    var body: some View {
        ZStack {
            Color.black.edgesIgnoringSafeArea(.all)
            
            if let player = player {
                VideoPlayer(player: player)
                    .edgesIgnoringSafeArea(.all)
                    .onAppear { player.play() } // Start playback automatically
                    .onDisappear { player.pause() }
            } else {
                ProgressView()
                    .scaleEffect(1.5)
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
            }
            
            dismissButton
                .padding() // Add padding around the button
        }
        .onAppear(perform: loadVideo)
        .statusBar(hidden: true)
        .preferredColorScheme(.dark)
    }
    
    @ViewBuilder
    private var dismissButton: some View {
        VStack {
            HStack {
                Spacer() // Push button to the right
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .resizable()
                        .frame(width: 30, height: 30)
                        .foregroundColor(.white.opacity(0.7))
                        .background(Color.black.opacity(0.5).blur(radius: 5).clipShape(Circle()))
                        .padding(.top, 10) // Adjust padding as needed
                }
            }
            Spacer() // Push button to the top
        }
    }

    private func loadVideo() {
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true // Important for iCloud Photos
        options.deliveryMode = .highQualityFormat // Request best quality

        imageManager.requestPlayerItem(
            forVideo: asset,
            options: options
        ) { playerItem, info in
            if let item = playerItem {
                DispatchQueue.main.async {
                    self.player = AVPlayer(playerItem: item)
                }
            } else {
                // Handle error (e.g., show an alert)
                print("❌ Failed to load player item: \(info?.description ?? "Unknown error")")
                // Optionally dismiss if loading fails irrecoverably
                // dismiss()
            }
        }
    }
}

// #Preview requires a mock PHAsset or conditional compilation
// #Preview {
//     // You'd need a way to provide a PHAsset here for the preview
//     // VideoPlayerView(asset: /* some PHAsset */)
// } 