import SwiftUI
import AVFoundation
import MetalKit
import CoreImage.CIFilterBuiltins
import Combine

extension Notification.Name {
    static let recordingStateChanged = Notification.Name("recordingStateChangedNotification")
}

// MetalCameraPreviewView: UIViewRepresentable wrapper for MTKView
struct MetalCameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    @ObservedObject var viewModel: CameraViewModel
    @ObservedObject var lutManager: LUTManager
    let previewVideoOutput: AVCaptureVideoDataOutput

    // Add explicit initializer
    init(session: AVCaptureSession, viewModel: CameraViewModel, lutManager: LUTManager, previewVideoOutput: AVCaptureVideoDataOutput) {
        self.session = session
        self.viewModel = viewModel
        self.lutManager = lutManager
        self.previewVideoOutput = previewVideoOutput
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self, session: session, viewModel: viewModel, lutManager: lutManager, previewVideoOutput: previewVideoOutput)
    }

    func makeUIView(context: Context) -> MTKView {
        let mtkView = MTKView()
        mtkView.device = MTLCreateSystemDefaultDevice()
        context.coordinator.mtkView = mtkView
        mtkView.delegate = context.coordinator
        mtkView.framebufferOnly = false // Required for CoreImage/Metal integration
        mtkView.enableSetNeedsDisplay = false // Use display link for continuous rendering
        mtkView.isPaused = false
        context.coordinator.setupMetal()
        return mtkView
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        // Update the view if needed
    }

    // MARK: - Coordinator
    class Coordinator: NSObject, MTKViewDelegate, AVCaptureVideoDataOutputSampleBufferDelegate {
        var parent: MetalCameraPreviewView
        var session: AVCaptureSession
        var viewModel: CameraViewModel
        var lutManager: LUTManager
        var previewVideoOutput: AVCaptureVideoDataOutput
        var device: MTLDevice!
        var commandQueue: MTLCommandQueue!
        var pipelineState: MTLRenderPipelineState!
        var textureCache: CVMetalTextureCache!
        var currentPixelBuffer: CVPixelBuffer?
        var recordingBorderLayer: CALayer?
        var volumeButtonHandler: VolumeButtonHandler?
        var ciContext = CIContext() 
        weak var mtkView: MTKView?
        
        // Add property to hold the intermediate render target texture
        private var renderTargetTexture: MTLTexture?
        
        // Store current orientation and subscriber
        private var currentOrientation: UIInterfaceOrientation = .portrait
        private var orientationSubscriber: AnyCancellable?

        init(parent: MetalCameraPreviewView, session: AVCaptureSession, viewModel: CameraViewModel, lutManager: LUTManager, previewVideoOutput: AVCaptureVideoDataOutput) {
            print("DEBUG: MetalCameraPreviewView.Coordinator init")
            self.parent = parent
            self.session = session
            self.viewModel = viewModel
            self.lutManager = lutManager
            self.previewVideoOutput = previewVideoOutput
            
            super.init()
            
            Task { @MainActor in
                self.setupVideoOutputDelegate()
            }

            NotificationCenter.default.addObserver(self, selector: #selector(handleRecordingStateChange), name: .recordingStateChanged, object: nil)
            
            // Subscribe to orientation changes from ViewModel
            orientationSubscriber = viewModel.$currentInterfaceOrientation
                .receive(on: DispatchQueue.main)
                .sink { [weak self] newOrientation in
                    print("DEBUG: Coordinator received orientation update: \(newOrientation.rawValue)")
                    self?.currentOrientation = newOrientation
                }

            print("Coordinator init - ViewModel Orientation: \(currentOrientation.rawValue)")
        }

        deinit {
            print("DEBUG: MetalCameraPreviewView.Coordinator deinit")
            NotificationCenter.default.removeObserver(self, name: .recordingStateChanged, object: nil)
            if let view = mtkView {
                Task { @MainActor in detachVolumeHandler(from: view) }
            } else {
                print("Coordinator Deinit Warning: MTKView reference lost, cannot detach volume handler.")
            }
        }

        func setupMetal() {
             guard let view = mtkView else {
                 print("Coordinator Error: MTKView not available for Metal setup.")
                 return
             }
             print("DEBUG: setupMetal called with view: \(view)")
             guard let device = view.device else {
                 fatalError("Metal device not available.")
             }
             self.device = device
             self.commandQueue = device.makeCommandQueue()

             // Setup texture cache
             CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)

             // Setup pipeline state
             guard let defaultLibrary = device.makeDefaultLibrary() else {
                 fatalError("Failed to get default Metal library.")
             }
             guard let vertexFunction = defaultLibrary.makeFunction(name: "vertexShader") else {
                 fatalError("Failed to find vertexShader function.")
             }
             guard let fragmentFunction = defaultLibrary.makeFunction(name: "samplingShader") else {
                 fatalError("Failed to find samplingShader function.")
             }

             let pipelineDescriptor = MTLRenderPipelineDescriptor()
             pipelineDescriptor.vertexFunction = vertexFunction
             pipelineDescriptor.fragmentFunction = fragmentFunction
             pipelineDescriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat

             do {
                 pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
             } catch {
                 fatalError("Failed to create pipeline state: \(error)")
             }
             print("DEBUG: Metal pipeline state created.")
             
             // Setup recording border layer
             setupRecordingBorder(mtkView: view)
        }

        @MainActor
        func setupVideoOutputDelegate() {
            print("DEBUG: setupVideoOutputDelegate called using provided previewOutput.")
            let videoDataOutputQueue = DispatchQueue(label: "videoDataOutputQueue", qos: .userInitiated)
            previewVideoOutput.setSampleBufferDelegate(self, queue: videoDataOutputQueue)
            print("✅ Coordinator set as sample buffer delegate for the specific Preview VideoDataOutput.")
            
            if let view = mtkView {
                attachVolumeHandler(to: view)
            } else {
                print("Coordinator Warning: MTKView not available when setting up video output delegate, cannot attach volume handler yet.")
            }
        }
        
        @MainActor
        private func attachVolumeHandler(to view: UIView) {
           guard volumeButtonHandler == nil else { return }
           
           if #available(iOS 17.2, *) {
               volumeButtonHandler = VolumeButtonHandler(session: session) { [weak self] action in
                   self?.handleVolumeButton(action: action)
               }
               volumeButtonHandler?.attach(to: view)
               print("VolumeButtonHandler attached.")
           } else {
               print("Volume button handling requires iOS 17.2 or later.")
           }
       }

       @MainActor
       private func detachVolumeHandler(from view: UIView) {
           if let handler = volumeButtonHandler {
                 handler.detach(from: view)
            }
           volumeButtonHandler = nil
           print("VolumeButtonHandler detached.")
       }

       private func handleVolumeButton(action: VolumeButtonHandler.Action) {
           print("Volume button pressed: \(action)")
           if action == .primary || action == .secondary { 
               Task { @MainActor in
                   if viewModel.isRecording {
                       await viewModel.stopRecording()
                   } else {
                       await viewModel.startRecording()
                   }
               }
           }
       }
        
        func setupRecordingBorder(mtkView: MTKView) {
            recordingBorderLayer = CALayer()
            recordingBorderLayer?.borderColor = UIColor.red.cgColor
            recordingBorderLayer?.borderWidth = 0
            recordingBorderLayer?.frame = mtkView.bounds
            mtkView.layer.addSublayer(recordingBorderLayer!)
            print("DEBUG: Recording border layer setup.")
        }
        
        @objc func handleRecordingStateChange() {
             DispatchQueue.main.async {
                self.updateRecordingBorder()
             }
         }
        
        func updateRecordingBorder() {
            guard let borderLayer = recordingBorderLayer else { return }
            
            let isRecording = viewModel.isRecording
            let targetWidth: CGFloat = isRecording ? 4.0 : 0.0
            
            let animation = CABasicAnimation(keyPath: "borderWidth")
            animation.fromValue = borderLayer.borderWidth
            animation.toValue = targetWidth
            animation.duration = 0.3
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            
            borderLayer.borderWidth = targetWidth
            borderLayer.add(animation, forKey: "borderWidthAnimation")
        }

        // Placeholder Function
        @MainActor
        func updatePreviewOrientation(for connection: AVCaptureConnection) {
            // TODO: Implement logic to update preview orientation based on connection or device orientation
            // print("DEBUG: updatePreviewOrientation called")
        }

        // Placeholder Function
        func drawRecordingBorder(in view: MTKView, commandBuffer: MTLCommandBuffer, drawableTexture: MTLTexture) {
            // TODO: Implement drawing logic for the recording border if needed beyond the CALayer approach
            // print("DEBUG: drawRecordingBorder called")
        }

        // MARK: - MTKViewDelegate Methods

        @MainActor
        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            // Log drawable size changes
            print("MetalCoordinator - drawableSizeWillChange: \(size)")
            recordingBorderLayer?.frame = view.bounds
            print("DEBUG: mtkView drawableSizeWillChange: \(size)")
            // Invalidate the render target texture when size changes
            renderTargetTexture = nil 
        }

        @MainActor
        func draw(in view: MTKView) {
            // Check if paused
            guard let currentDrawable = view.currentDrawable,
                  let commandBuffer = commandQueue.makeCommandBuffer(),
                  // renderPassDescriptor is not needed for CIContext rendering + blit
                  let lastPixelBuffer = currentPixelBuffer else {
                // print("DEBUG: draw(in:) - Guard failed (drawable, commandBuffer, or pixelBuffer missing)")
                return
            }

            // Log the actual drawable size being used for rendering
            print("MetalCoordinator - draw(in:) - Drawable Size: \(view.drawableSize)")

            // 1. Create CIImage from Pixel Buffer
            // This automatically handles different pixel formats (YUV, BGRA)
            let ciImage = CIImage(cvPixelBuffer: lastPixelBuffer)
            
            // 2. Apply Orientation Correction
            let orientedImage = ciImage // Use the image directly from the buffer

            // ++ ADD Vertical Flip Transform ++
            // CIImage origin is bottom-left, Metal texture origin is top-left.
            // Apply a vertical flip transform before rendering.
            let flipTransform = CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -orientedImage.extent.height)
            let finalInputImage = orientedImage.transformed(by: flipTransform)

            // 3. Apply LUT Filter (if enabled and available)
            var finalImage = finalInputImage // Start with the flipped image
            if viewModel.lutManager.isLUTPreviewEnabled, let lutFilter = viewModel.lutManager.currentLUTFilter {
                // Apply LUT to the *flipped* image
                lutFilter.setValue(finalInputImage, forKey: kCIInputImageKey)
                if let outputImage = lutFilter.outputImage {
                    finalImage = outputImage
                } else {
                    print("Warning: LUT filter applied but produced nil output image.")
                    finalImage = finalInputImage // Fallback to source if LUT fails
                }
            }

            // 4. Ensure Intermediate Texture exists and is correctly configured
            if renderTargetTexture == nil || 
               renderTargetTexture?.width != currentDrawable.texture.width ||
               renderTargetTexture?.height != currentDrawable.texture.height ||
               renderTargetTexture?.pixelFormat != currentDrawable.texture.pixelFormat {
                
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: currentDrawable.texture.pixelFormat, // Match drawable format
                    width: currentDrawable.texture.width,
                    height: currentDrawable.texture.height,
                    mipmapped: false
                )
                // Crucially, add .shaderWrite usage for CIContext rendering
                descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget] 
                
                renderTargetTexture = device.makeTexture(descriptor: descriptor)
                
                if renderTargetTexture == nil {
                    print("Coordinator Error: Failed to create intermediate render target texture.")
                    commandBuffer.commit() // Commit buffer even on error to avoid stall
                    return
                }
                // print("DEBUG: Created intermediate render target texture: \(renderTargetTexture!.width)x\(renderTargetTexture!.height)")
            }

            guard let targetTexture = renderTargetTexture else {
                 print("Coordinator Error: Intermediate render target texture is nil after check.")
                 commandBuffer.commit()
                 return
            }

            // 5. Render final CIImage to the Intermediate Texture
            let destinationColorSpace = CGColorSpaceCreateDeviceRGB()

            // Render using CIContext
            // Note: CIContext automatically handles color space conversions if the source
            // CIImage has a color space assigned (which CIImage(cvPixelBuffer:) often does)
            // and the destination color space is different.
            ciContext.render(
                finalImage, // Render the potentially LUT-applied and flipped image
                to: targetTexture,
                commandBuffer: commandBuffer,
                bounds: CGRect(x: 0, y: 0, width: targetTexture.width, height: targetTexture.height), // <-- Use CGRect from texture dimensions
                colorSpace: destinationColorSpace
            )

            // 6. Blit from Intermediate Texture to Drawable Texture
            guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
                print("Coordinator Error: Failed to create blit command encoder.")
                commandBuffer.commit() // Commit before returning
                return
            }
            
            blitEncoder.copy(
                from: targetTexture, // Source is our intermediate texture
                sourceSlice: 0,
                sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSizeMake(targetTexture.width, targetTexture.height, targetTexture.depth),
                to: currentDrawable.texture, // Destination is the view's drawable
                destinationSlice: 0,
                destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
            )
            blitEncoder.endEncoding()

            // 7. Present the drawable
            commandBuffer.present(currentDrawable)
            commandBuffer.commit()
            // print("DEBUG: draw(in:) - Frame drawn and committed")
        }

        // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate
        
        nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
            guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
            
            // Store the latest pixel buffer
            currentPixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)

            // Request a redraw for the next display cycle
            // Ensure this happens only after currentPixelBuffer is set
            DispatchQueue.main.async {
                self.mtkView?.setNeedsDisplay()
            }
        }
        
        nonisolated func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
             print("Frame dropped")
            // You might want to track dropped frames
        }

        func removeFromParent() {
            // Clean up resources, remove observers, etc.
            // Remove incorrect cleanup call. Cleanup is handled by detachVolumeHandler.
            // volumeButtonHandler?.stopHandlingVolumeButtons() 
            
            // Detach handler safely
            if let view = self.mtkView {
                // Remove await as detachVolumeHandler is not async
                Task { @MainActor in detachVolumeHandler(from: view) } 
            }
            print("DEBUG: MetalCameraPreviewView.Coordinator removeFromParent called")
        }
    }
}

// Custom MTKView subclass to handle background color
class CustomMTKView: MTKView {
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if let layer = self.layer as? CAMetalLayer {
            layer.backgroundColor = UIColor.black.cgColor
            print("DEBUG: Set black background via CAMetalLayer")
        } else {
            self.backgroundColor = .black
             print("DEBUG: Set black background via UIView backgroundColor")
        }
    }
}

// Add helper extension for orientation conversion
extension UIInterfaceOrientation {
    var exifOrientation: Int32 {
        switch self {
        case .portrait: return 6 // Rotated 90 CW
        case .portraitUpsideDown: return 8 // Rotated 270 CW
        case .landscapeLeft: return 3 // Rotated 180
        case .landscapeRight: return 1 // Default orientation (0 rotation)
        case .unknown:
            return 1 // Default if unknown
        @unknown default:
            return 1 // Default for future cases
        }
    }
}