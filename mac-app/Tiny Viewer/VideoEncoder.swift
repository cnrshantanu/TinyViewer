import CoreMedia
import Foundation
import VideoToolbox

// MARK: - Bitrate per quality preset

extension StreamQuality {
    var bitrate: Int {
        switch self { case .low: 1_000_000; case .medium: 2_000_000; case .high: 4_000_000 }
    }
}

// MARK: - H.264 encoder (VTCompressionSession, Annex B output)

final class VideoEncoder {

    /// Called on an arbitrary background thread with the encoded Annex B NAL data.
    var onFrame: ((Data, Bool) -> Void)?   // (annexBData, isKeyFrame)
    var quality: StreamQuality = .medium

    private var session: VTCompressionSession?
    private let lock = NSLock()

    // MARK: - Encode

    func encode(_ pixelBuffer: CVPixelBuffer, timestamp: CMTime) {
        lock.lock()
        if session == nil {
            let w = CVPixelBufferGetWidth(pixelBuffer)
            let h = CVPixelBufferGetHeight(pixelBuffer)
            try? setupSession(width: w, height: h)
        }
        let s = session
        lock.unlock()
        guard let s else { return }

        VTCompressionSessionEncodeFrame(
            s, imageBuffer: pixelBuffer,
            presentationTimeStamp: timestamp, duration: .invalid,
            frameProperties: nil, infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            guard let self, status == noErr, let sampleBuffer else { return }
            self.handleOutput(sampleBuffer)
        }
    }

    // MARK: - Lifecycle

    func stop() {
        lock.lock()
        if let s = session { VTCompressionSessionInvalidate(s) }
        session = nil
        lock.unlock()
    }

    /// Call when quality changes — session recreates lazily on next frame.
    func resetSession() { stop() }

    // MARK: - Private

    private func setupSession(width: Int, height: Int) throws {
        var s: VTCompressionSession?
        let err = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil, imageBufferAttributes: nil,
            compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
            compressionSessionOut: &s
        )
        guard err == noErr, let s else { throw NSError(domain: "VideoEncoder", code: Int(err)) }

        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime,                    value: kCFBooleanTrue)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering,        value: kCFBooleanFalse)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel,                value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_H264EntropyMode,             value: kVTH264EntropyMode_CABAC)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate,              value: quality.bitrate as CFNumber)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ExpectedFrameRate,           value: quality.fps    as CFNumber)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 2.0 as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(s)
        session = s
    }

    private func handleOutput(_ sampleBuffer: CMSampleBuffer) {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        // Key frame = no kCMSampleAttachmentKey_NotSync attachment
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[CFString: Any]]
        let isKey = attachments?.first?[kCMSampleAttachmentKey_NotSync] == nil

        var annexB = Data()

        // Prepend SPS + PPS on key frames so the browser can (re-)configure the decoder
        if isKey, let fmt = CMSampleBufferGetFormatDescription(sampleBuffer) {
            for i in 0..<2 {
                var ptr: UnsafePointer<UInt8>? = nil
                var len = 0, count = 0
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    fmt, parameterSetIndex: i,
                    parameterSetPointerOut: &ptr, parameterSetSizeOut: &len,
                    parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
                if let ptr {
                    annexB += Data([0, 0, 0, 1])
                    annexB += Data(bytes: ptr, count: len)
                }
            }
        }

        // Convert AVCC length-prefixed NALUs → Annex B start-code NALUs
        var totalLen = 0
        CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil,
                                    totalLengthOut: &totalLen, dataPointerOut: nil)
        var buf = [UInt8](repeating: 0, count: totalLen)
        CMBlockBufferCopyDataBytes(dataBuffer, atOffset: 0, dataLength: totalLen, destination: &buf)

        var offset = 0
        while offset + 4 <= totalLen {
            let naluLen = Int(buf[offset]) << 24 | Int(buf[offset+1]) << 16
                        | Int(buf[offset+2]) << 8  | Int(buf[offset+3])
            guard offset + 4 + naluLen <= totalLen else { break }
            annexB += Data([0, 0, 0, 1])
            annexB += Data(buf[(offset + 4)..<(offset + 4 + naluLen)])
            offset += 4 + naluLen
        }

        onFrame?(annexB, isKey)
    }
}
