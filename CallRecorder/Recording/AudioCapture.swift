import Foundation
import ScreenCaptureKit
import AVFoundation

protocol CaptureSession: AnyObject {
    var onError: ((Error) -> Void)? { get set }
    var micActive: Bool { get }
    var systemActive: Bool { get }
    var droppedBuffers: Int { get }
    /// Recent input level 0...1 (best effort, for the level meter only).
    var level: Float { get }
    func start() async throws
    func stop() async
}

extension CaptureSession { var level: Float { 0 } }

final class AudioFile {
    private(set) var level: Float = 0
    let writer: AVAssetWriter, input: AVAssetWriterInput
    private(set) var started = false
    private(set) var dropped = 0
    init(_ url: URL) throws {
        writer = try AVAssetWriter(url: url, fileType: .m4a)
        input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96000])
        input.expectsMediaDataInRealTime = true
        writer.add(input)
    }
    func append(_ sb: CMSampleBuffer) {
        guard sb.isValid, CMSampleBufferGetNumSamples(sb) > 0 else { return }
        level = Self.rms(sb)
        if !started {
            writer.startWriting()
            writer.startSession(atSourceTime: sb.presentationTimeStamp)
            started = true
        }
        if input.isReadyForMoreMediaData { input.append(sb) } else { dropped += 1 }
    }
    static func rms(_ sb: CMSampleBuffer) -> Float {
        var out: Float = 0
        try? sb.withAudioBufferList { list, _ in
            var sum: Float = 0, n = 0
            for b in list {
                guard let p = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let c = Int(b.mDataByteSize) / MemoryLayout<Float>.size
                for i in 0..<c { sum += p[i] * p[i] }
                n += c
            }
            if n > 0 { out = min(1, sqrt(sum / Float(n)) * 4) }
        }
        return out
    }
    func finish() async {
        guard started else { return }
        input.markAsFinished()
        await writer.finishWriting()
    }
}

/// ScreenCaptureKit capture of system audio ("Others") and microphone ("Me") into two m4a files.
final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate, CaptureSession, @unchecked Sendable {
    let sys: AudioFile, mic: AudioFile
    let queue = DispatchQueue(label: "callrec.samples")
    var stream: SCStream?
    var onError: ((Error) -> Void)?
    var micActive: Bool { mic.started }
    var systemActive: Bool { sys.started }
    var droppedBuffers: Int { sys.dropped + mic.dropped }
    var level: Float { max(sys.level, mic.level) }

    init(sys: URL, mic: URL) throws { self.sys = try AudioFile(sys); self.mic = try AudioFile(mic) }

    func start() async throws {
        let content = try await SCShareableContent.current
        guard let display = content.displays.first else { throw NSError(domain: "callrec", code: 1, userInfo: [NSLocalizedDescriptionKey: "No display found"]) }
        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = true
        cfg.captureMicrophone = true
        cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = 48000
        cfg.channelCount = 1
        cfg.width = 2; cfg.height = 2   // we only want audio
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try s.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
    }
    func stop() async {
        try? await stream?.stopCapture()
        await withCheckedContinuation { c in queue.async { c.resume() } }
        await sys.finish(); await mic.finish()
    }
    func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .audio: sys.append(sb)
        case .microphone: mic.append(sb)
        default: break
        }
    }
    func stream(_ s: SCStream, didStopWithError error: Error) { onError?(error) }
}
