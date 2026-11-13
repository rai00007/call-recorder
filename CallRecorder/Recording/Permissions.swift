import Foundation
import AVFoundation
import CoreGraphics

enum Permissions {
    static var micStatus: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }
    /// Informational only: it can report false until the app is relaunched after granting, so it never blocks recording.
    static var screenGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// Returns a user-facing problem, or nil if recording may proceed. Screen access is checked by ScreenCaptureKit itself.
    static func ensure() async -> String? {
        if micStatus == .notDetermined { _ = await AVCaptureDevice.requestAccess(for: .audio) }
        switch micStatus {
        case .denied, .restricted:
            return "Microphone access is denied. Enable Call Recorder in System Settings → Privacy & Security → Microphone."
        default: return nil
        }
    }
}
