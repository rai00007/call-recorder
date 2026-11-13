import Foundation
import AVFoundation

/// Mixes the given tracks (those that exist) into one m4a.
func mixAudio(_ inputs: [URL], to out: URL) async throws {
    let comp = AVMutableComposition()
    for u in inputs where FileManager.default.fileExists(atPath: u.path) {
        let asset = AVURLAsset(url: u)
        guard let src = try await asset.loadTracks(withMediaType: .audio).first,
              let t = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { continue }
        try t.insertTimeRange(CMTimeRange(start: .zero, duration: try await asset.load(.duration)), of: src, at: .zero)
    }
    guard let ex = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetAppleM4A) else { throw NSError(domain: "callrec", code: 2, userInfo: [NSLocalizedDescriptionKey: "Export failed"]) }
    try await ex.export(to: out, as: .m4a)
}

func audioIsPlayable(_ url: URL) async -> Bool {
    guard FileManager.default.fileExists(atPath: url.path) else { return false }
    return (try? await AVURLAsset(url: url).load(.isPlayable)) == true
}

func audioDuration(_ url: URL) async -> TimeInterval? {
    guard let d = try? await AVURLAsset(url: url).load(.duration).seconds, d.isFinite, d > 0 else { return nil }
    return d
}
