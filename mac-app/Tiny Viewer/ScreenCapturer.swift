import CoreImage
import CoreMedia
import Foundation
import ImageIO
import ScreenCaptureKit

// MARK: - Quality Preset

enum StreamQuality: String, CaseIterable {
    case low    = "Low"
    case medium = "Medium"
    case high   = "High"

    /// Maximum capture width in pixels (SCStream physical pixels).
    /// On a 1920×1080 Retina display (3840×2160 physical), High=1920 gives
    /// half-retina = full logical-pixel resolution.
    var maxWidth:    Int    { switch self { case .low: 640;  case .medium: 960;  case .high: 1920 } }

    /// JPEG quality: 0.0 = maximum compression (worst), 1.0 = minimum compression (best).
    /// Low/Medium are tuned for bandwidth; High is tuned for clarity.
    var jpegQuality: Double { switch self { case .low: 0.65; case .medium: 0.75; case .high: 0.85 } }

    /// Maximum capture rate (frames/sec). Actual delivery rate is limited by network RTT.
    var fps:         Int32  { switch self { case .low: 10;   case .medium: 15;   case .high: 20   } }
}

// MARK: - Screen Capturer

@Observable
class ScreenCapturer: NSObject, SCStreamOutput {

    nonisolated(unsafe) var onFrame: ((Data) -> Void)?

    private(set) var isCapturing  = false
    private(set) var captureError: String?
    var quality: StreamQuality = .medium

    private var stream: SCStream?
    nonisolated let ciContext = CIContext()

    // MARK: - Public API

    func start() {
        Task {
            do {
                let content = try await SCShareableContent.current
                guard let display = content.displays.first else {
                    print("[ScreenCapturer] No displays available")
                    return
                }

                let q      = quality
                let scale  = min(1.0, Double(q.maxWidth) / Double(display.width))
                let config = SCStreamConfiguration()
                config.width                 = max(1, Int(Double(display.width)  * scale))
                config.height                = max(1, Int(Double(display.height) * scale))
                config.minimumFrameInterval  = CMTime(value: 1, timescale: q.fps)
                config.queueDepth            = 3

                let filter = SCContentFilter(
                    display: display,
                    excludingApplications: [],
                    exceptingWindows: []
                )

                let stream = SCStream(filter: filter, configuration: config, delegate: nil)
                try stream.addStreamOutput(self, type: .screen,
                                           sampleHandlerQueue: .global(qos: .userInitiated))
                try await stream.startCapture()
                self.stream       = stream
                self.isCapturing  = true
                self.captureError = nil
                print("[ScreenCapturer] Started — \(config.width)×\(config.height) @ \(q.fps) fps (\(q.rawValue))")
            } catch {
                self.isCapturing  = false
                self.captureError = error.localizedDescription
                print("[ScreenCapturer] Error: \(error)")
            }
        }
    }

    func stop() {
        let s = stream
        stream        = nil
        isCapturing   = false
        captureError  = nil
        Task { try? await s?.stopCapture() }
    }

    // MARK: - SCStreamOutput

    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }

        let buf = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(buf, "public.jpeg" as CFString, 1, nil)
        else { return }

        CGImageDestinationAddImage(
            dst, cgImage,
            [kCGImageDestinationLossyCompressionQuality: quality.jpegQuality] as CFDictionary
        )
        guard CGImageDestinationFinalize(dst) else { return }

        onFrame?(buf as Data)
    }
}
