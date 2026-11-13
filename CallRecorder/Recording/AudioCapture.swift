import Foundation
import ScreenCaptureKit
import AVFoundation

protocol CaptureSession: AnyObject {
    var onError: ((Error) -> Void)? { get set }
    var micActive: Bool { get }
    var systemActive: Bool { get }
    var droppedBuffers: Int { get }
    func start() async throws
    func stop() async
}

final class AudioFile {
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
        if !started {
            writer.startWriting()
            writer.startSession(atSourceTime: sb.presentationTimeStamp)
            started = true
        }
        if input.isReadyForMoreMediaData { input.append(sb) } else { dropped += 1 }
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
