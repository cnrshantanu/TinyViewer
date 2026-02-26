import AppKit
import CoreImage
import CoreMedia
import Foundation
import ScreenCaptureKit

// MARK: - Quality Preset

enum StreamQuality: String, CaseIterable {
    case low    = "Low"
    case medium = "Medium"
    case high   = "High"

    var maxWidth:    Int    { switch self { case .low: 960;  case .medium: 1280; case .high: 1920 } }
    var jpegQuality: Double { switch self { case .low: 0.35; case .medium: 0.6;  case .high: 0.8  } }
    var fps:         Int32  { switch self { case .low: 8;    case .medium: 10;   case .high: 15   } }
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
                config.queueDepth            = 2

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

        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let jpeg = rep.representation(
            using: .jpeg,
            properties: [.compressionFactor: NSNumber(value: quality.jpegQuality)]
        ) else { return }

        onFrame?(jpeg)
    }
}
